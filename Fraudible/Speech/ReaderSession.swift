import Foundation
import Observation

/// Reads a text-to-speech book aloud: highlights each paragraph, remembers where you stopped,
/// and drives whichever speech engine the chosen voice uses (Apple's built-in voices or Kokoro).
@Observable
final class ReaderSession: AudioOwner {
    static let rates: [Double] = [0.8, 1, 1.25, 1.5, 1.75, 2]

    let bookID: String
    private(set) var paragraphs: [String]?
    private(set) var loadError: String?
    /// The paragraph being read (or that reading will start from).
    private(set) var index: Int
    /// A read-aloud session is active (it may be paused).
    private(set) var reading = false
    private(set) var isPlaying = false
    /// Waiting for Kokoro to prepare the next bit of audio.
    private(set) var buffering = false
    /// Loading the Kokoro model into memory before the first sentence.
    private(set) var preparingVoice = false
    private(set) var rate: Double
    private(set) var voice: ReaderVoice
    /// Set when something goes wrong; the screen shows it as an alert.
    var errorMessage: String?
    /// A Kokoro voice the user picked that is still downloading; switched to once it's ready.
    private(set) var pendingVoice: ReaderVoice?

    @ObservationIgnored private var chunks: [Chunk] = []
    @ObservationIgnored private var chunkIndex = 0
    @ObservationIgnored private var backend: SpeechBackend?
    private let library: Library
    private let kokoro: KokoroManager

    init(book: LibraryBook, library: Library, kokoro: KokoroManager) {
        self.bookID = book.id
        self.library = library
        self.kokoro = kokoro
        self.index = book.ttsPosition ?? 0
        self.chunkIndex = book.ttsChunkPosition ?? 0
        self.rate = book.ttsRate ?? 1
        self.voice = VoiceCatalog.resolve(book.ttsVoice, kokoroAvailable: kokoro.isDownloaded)
        load(book)
    }

    var progress: Double {
        guard let count = paragraphs?.count, count > 0 else { return 0 }
        return Double(index + 1) / Double(count)
    }

    private func load(_ book: LibraryBook) {
        guard let fileName = book.textFileName else {
            loadError = "This book has no text."
            return
        }
        let id = book.id
        Task {
            do {
                let (paragraphs, chunks) = try await Task.detached(priority: .userInitiated) {
                    let paragraphs = try Storage.loadParagraphs(bookId: id, fileName: fileName)
                    return (paragraphs, TextProcessing.chunk(paragraphs))
                }.value
                self.chunks = chunks
                self.paragraphs = paragraphs
                self.index = min(self.index, max(0, paragraphs.count - 1))
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Controls

    func togglePlay() {
        if isPlaying {
            backend?.pause()
            isPlaying = false
            publishNowPlaying()
            return
        }
        guard reading, let backend else {
            return start(fromParagraph: index, resumeChunk: chunkIndex)
        }
        AudioFocus.shared.claim(self)
        backend.resume()
        isPlaying = true
        publishNowPlaying()
    }

    func jump(_ delta: Int) {
        guard let paragraphs, !paragraphs.isEmpty else { return }
        let next = max(0, min(paragraphs.count - 1, index + delta))
        if reading { start(fromParagraph: next) } else { setParagraph(next) }
    }

    func tapParagraph(_ i: Int) {
        if reading { start(fromParagraph: i) } else { setParagraph(i) }
    }

    func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
        backend?.setRate(rate)
        library.update(bookID) { $0.ttsRate = self.rate }
    }

    func choose(_ newVoice: ReaderVoice) {
        if newVoice.engine == .kokoro && !kokoro.isDownloaded {
            // Picked a Kokoro voice before downloading the model: fetch it, then switch.
            pendingVoice = newVoice
            kokoro.download()
            return
        }
        pendingVoice = nil
        guard newVoice != voice else { return }
        voice = newVoice
        library.update(bookID) { $0.ttsVoice = newVoice.id }
        let wasReading = reading
        tearDownBackend()
        if wasReading { start(fromParagraph: index, resumeChunk: chunkIndex) }
    }

    /// Called when the Kokoro download finishes, to switch to the voice the user asked for.
    func kokoroBecameAvailable() {
        if let pendingVoice { choose(pendingVoice) }
    }

    /// End the session entirely (leaving the screen).
    func stop() {
        tearDownBackend()
        reading = false
        isPlaying = false
        buffering = false
        if AudioFocus.shared.isOwner(self) { AudioFocus.shared.clearNowPlaying() }
    }

    // MARK: - Internals

    private func setParagraph(_ i: Int) {
        index = i
        chunkIndex = chunks.firstIndex { $0.paragraph == i } ?? 0
        library.update(bookID) {
            $0.ttsPosition = i
            $0.ttsChunkPosition = self.chunkIndex
        }
    }

    /// Start (or restart) reading from a paragraph, optionally resuming at an exact chunk within it.
    private func start(fromParagraph paragraph: Int, resumeChunk: Int? = nil) {
        guard !chunks.isEmpty else { return }
        let target: Int
        if let resumeChunk, chunks.indices.contains(resumeChunk), chunks[resumeChunk].paragraph == paragraph {
            target = resumeChunk
        } else {
            target = chunks.firstIndex { $0.paragraph == paragraph } ?? 0
        }
        index = paragraph
        chunkIndex = target
        reading = true
        isPlaying = true
        AudioFocus.shared.claim(self) // don't talk over an audiobook

        if let backend {
            backend.play(from: target)
            return
        }
        switch voice.engine {
        case .apple:
            attach(AppleSpeechBackend(chunks: chunks, voiceIdentifier: voice.engineVoiceID, rate: rate)).play(from: target)
        case .kokoro:
            preparingVoice = true
            let voiceAtStart = voice
            Task {
                do {
                    try await kokoro.ensureLoaded()
                    preparingVoice = false
                    // The user may have stopped or changed voice while the model loaded.
                    guard reading, isPlaying, voice == voiceAtStart, backend == nil else { return }
                    let made = KokoroSpeechBackend(chunks: chunks, engine: kokoro.engine, voiceID: voice.engineVoiceID, rate: rate)
                    attach(made).play(from: chunkIndex)
                } catch {
                    preparingVoice = false
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func attach(_ made: SpeechBackend) -> SpeechBackend {
        made.onChunkStart = { [weak self] i in self?.chunkStarted(i) }
        made.onFinish = { [weak self] in self?.finished() }
        made.onBuffering = { [weak self] waiting in self?.buffering = waiting }
        made.onError = { [weak self] message in self?.fail(message) }
        backend = made
        return made
    }

    private func tearDownBackend() {
        backend?.stop()
        backend = nil
        buffering = false
        preparingVoice = false
    }

    private func chunkStarted(_ i: Int) {
        guard chunks.indices.contains(i) else { return }
        chunkIndex = i
        let paragraph = chunks[i].paragraph
        if paragraph != index { index = paragraph }
        library.update(bookID) {
            $0.ttsPosition = paragraph
            $0.ttsChunkPosition = i
        }
        publishNowPlaying()
    }

    private func finished() {
        reading = false
        isPlaying = false
        buffering = false
        AudioFocus.shared.updateNowPlaying(elapsed: 0, rate: 0)
    }

    private func fail(_ message: String) {
        tearDownBackend()
        reading = false
        isPlaying = false
        errorMessage = message
    }

    private func publishNowPlaying() {
        guard AudioFocus.shared.isOwner(self), let book = library.book(bookID) else { return }
        let total = paragraphs?.count ?? 0
        AudioFocus.shared.setNowPlaying(
            title: book.title,
            artist: book.author,
            album: total > 0 ? "Paragraph \(index + 1) of \(total)" : "Fraudible",
            duration: nil,
            elapsed: 0,
            rate: isPlaying ? 1 : 0,
            artwork: nil
        )
    }

    // MARK: - AudioOwner

    func yieldAudio() {
        if isPlaying {
            backend?.pause()
            isPlaying = false
        }
    }
    func remotePlay() { if !isPlaying { togglePlay() } }
    func remotePause() { if isPlaying { togglePlay() } }
    func remoteTogglePlayPause() { togglePlay() }
    func remoteSkip(by seconds: Double) { jump(seconds > 0 ? 1 : -1) }
    func remoteNext() { jump(1) }
    func remotePrevious() { jump(-1) }
    func remoteSeek(to seconds: Double) {}
}
