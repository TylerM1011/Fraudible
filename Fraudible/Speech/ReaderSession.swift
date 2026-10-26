import Foundation
import Observation

/// Reads a text-to-speech book aloud: highlights each paragraph and word, remembers where you
/// stopped (down to the word), and drives whichever speech engine the chosen voice uses
/// (Apple's built-in voices or Kokoro).
@Observable
final class ReaderSession: AudioOwner {
    static let rates: [Double] = [0.8, 1, 1.25, 1.5, 1.75, 2]

    let bookID: String
    private(set) var paragraphs: [String]?
    private(set) var loadError: String?
    /// The paragraph being read (or that reading will start from).
    private(set) var index: Int
    /// The word being spoken — or, when paused, the word reading will resume from —
    /// as UTF-16 offsets into the current paragraph's text.
    private(set) var word: Range<Int>?
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

    /// The text split for speaking. Kokoro gets shorter pieces (about a sentence) so audio starts
    /// quickly; it has to synthesize a whole piece before any of it can play.
    @ObservationIgnored private var appleChunks: [Chunk] = []
    @ObservationIgnored private var kokoroChunks: [Chunk] = []
    private var chunks: [Chunk] { voice.engine == .kokoro ? kokoroChunks : appleChunks }
    @ObservationIgnored private var chunkIndex = 0
    @ObservationIgnored private var backend: SpeechBackend?
    /// The word saved when the book was last paused, applied once the text has loaded.
    @ObservationIgnored private var savedWordOffset: Int?
    private let library: Library
    private let kokoro: KokoroManager

    init(book: LibraryBook, library: Library, kokoro: KokoroManager) {
        self.bookID = book.id
        self.library = library
        self.kokoro = kokoro
        self.index = book.ttsPosition ?? 0
        self.chunkIndex = book.ttsChunkPosition ?? 0
        self.savedWordOffset = book.ttsWordOffset
        self.rate = book.ttsRate ?? 1
        let offline = OfflineAudioStore.voice(for: book.id).map { "kokoro:\($0)" }
        let offlineReady = offline.map { OfflineAudioStore.isComplete(book.id, voice: String($0.dropFirst(7))) } ?? false
        self.voice = VoiceCatalog.resolve(book.ttsVoice, kokoroAvailable: kokoro.isDownloaded || (offlineReady && offline == book.ttsVoice))
        load(book)
    }

    var progress: Double {
        guard let count = paragraphs?.count, count > 0 else { return 0 }
        return Double(index + 1) / Double(count)
    }

    /// The text of the word reading will resume from, when paused on one.
    var pausedWord: String? {
        guard !isPlaying, let word, let paragraphs, paragraphs.indices.contains(index) else { return nil }
        let text = paragraphs[index]
        guard word.upperBound <= text.utf16.count else { return nil }
        let lower = String.Index(utf16Offset: word.lowerBound, in: text)
        let upper = String.Index(utf16Offset: word.upperBound, in: text)
        return String(text[lower..<upper])
    }

    private func load(_ book: LibraryBook) {
        guard let fileName = book.textFileName else {
            loadError = "This book has no text."
            return
        }
        let id = book.id
        Task {
            do {
                let (paragraphs, appleChunks, kokoroChunks) = try await Task.detached(priority: .userInitiated) {
                    let paragraphs = try Storage.loadParagraphs(bookId: id, fileName: fileName)
                    return (paragraphs, TextProcessing.chunk(paragraphs), TextProcessing.chunk(paragraphs, max: TextProcessing.kokoroChunk))
                }.value
                self.appleChunks = appleChunks
                self.kokoroChunks = kokoroChunks
                self.paragraphs = paragraphs
                self.index = min(self.index, max(0, paragraphs.count - 1))
                // Show the word you paused on last time; play resumes from it.
                if let offset = self.savedWordOffset, paragraphs.indices.contains(self.index) {
                    self.word = Self.wordRange(at: offset, in: paragraphs[self.index])
                }
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Controls

    func togglePlay() {
        Log.reader.info("togglePlay playing=\(self.isPlaying, privacy: .public) reading=\(self.reading, privacy: .public) word=\(self.word?.lowerBound ?? -1, privacy: .public)")
        if isPlaying {
            pause()
        } else {
            // Resume from the highlighted word (or the start of the chunk if there isn't one).
            start(fromParagraph: index, resumeChunk: chunkIndex, wordOffset: word?.lowerBound)
        }
    }

    /// Stop on the current word and remember it, so play picks up from exactly there.
    func pause() {
        guard isPlaying else { return }
        backend?.pause()
        isPlaying = false
        savePosition()
        publishNowPlaying()
    }

    func jump(_ delta: Int) {
        guard let paragraphs, !paragraphs.isEmpty else { return }
        let next = max(0, min(paragraphs.count - 1, index + delta))
        if isPlaying { start(fromParagraph: next) } else { setParagraph(next) }
    }

    func tapParagraph(_ i: Int) {
        if isPlaying { start(fromParagraph: i) } else { setParagraph(i) }
    }

    func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        setRate(Self.rates[(i + 1) % Self.rates.count])
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        backend?.setRate(newRate)
        library.update(bookID) { $0.ttsRate = newRate }
    }

    func choose(_ newVoice: ReaderVoice) {
        if newVoice.engine == .kokoro && !kokoro.isDownloaded && !OfflineAudioStore.isComplete(bookID, voice: newVoice.engineVoiceID) {
            // Picked a Kokoro voice before downloading the model: fetch it, then switch.
            pendingVoice = newVoice
            kokoro.download()
            return
        }
        pendingVoice = nil
        guard newVoice != voice else { return }
        // Where we are in the paragraph, since the two engines split the text differently.
        let resumeAt = word?.lowerBound ?? (chunks.indices.contains(chunkIndex) ? chunks[chunkIndex].offset : 0)
        voice = newVoice
        library.update(bookID) { $0.ttsVoice = newVoice.id }
        chunkIndex = chunks.lastIndex { $0.paragraph == index && $0.offset <= resumeAt } ?? chunks.firstIndex { $0.paragraph == index } ?? 0
        let wasPlaying = isPlaying
        tearDownBackend()
        if wasPlaying { start(fromParagraph: index, wordOffset: resumeAt) }
    }

    /// Called when the Kokoro download finishes, to switch to the voice the user asked for.
    func kokoroBecameAvailable() {
        if let pendingVoice { choose(pendingVoice) }
    }

    /// End the session entirely (leaving the screen). The position is saved down to the word.
    func stop() {
        if reading { savePosition() }
        tearDownBackend()
        reading = false
        isPlaying = false
        buffering = false
        if AudioFocus.shared.isOwner(self) { AudioFocus.shared.clearNowPlaying() }
    }

    // MARK: - Internals

    private func savePosition() {
        let paragraph = index, chunk = chunkIndex, wordOffset = word?.lowerBound
        library.update(bookID) {
            $0.ttsPosition = paragraph
            $0.ttsChunkPosition = chunk
            $0.ttsWordOffset = wordOffset
        }
    }

    private func setParagraph(_ i: Int) {
        index = i
        word = nil
        chunkIndex = chunks.firstIndex { $0.paragraph == i } ?? 0
        let chunk = chunkIndex
        library.update(bookID) {
            $0.ttsPosition = i
            $0.ttsChunkPosition = chunk
            $0.ttsWordOffset = nil
        }
    }

    /// Start (or restart) reading from a paragraph: at a word if given, else at a saved chunk
    /// within it, else at its beginning.
    private func start(fromParagraph paragraph: Int, resumeChunk: Int? = nil, wordOffset: Int? = nil) {
        guard !chunks.isEmpty else {
            Log.reader.error("start: no chunks loaded yet (paragraphs=\(self.paragraphs?.count ?? -1, privacy: .public))")
            return
        }
        var target = chunks.firstIndex { $0.paragraph == paragraph } ?? 0
        var offsetInChunk = 0
        if let wordOffset, let i = chunks.lastIndex(where: { $0.paragraph == paragraph && $0.offset <= wordOffset }) {
            target = i
            offsetInChunk = max(0, wordOffset - chunks[i].offset)
        } else if let resumeChunk, chunks.indices.contains(resumeChunk), chunks[resumeChunk].paragraph == paragraph {
            target = resumeChunk
        }
        if paragraph != index || wordOffset == nil { word = nil }
        index = paragraph
        chunkIndex = target
        reading = true
        isPlaying = true
        AudioFocus.shared.claim(self) // don't talk over an audiobook

        Log.reader.info("start paragraph=\(paragraph, privacy: .public) chunk=\(target, privacy: .public) at=\(offsetInChunk, privacy: .public) engine=\(self.voice.engine.rawValue, privacy: .public)")
        if let backend {
            backend.play(from: target, at: offsetInChunk)
            publishNowPlaying()
            return
        }
        switch voice.engine {
        case .apple:
            attach(AppleSpeechBackend(chunks: chunks, voiceIdentifier: voice.engineVoiceID, rate: rate)).play(from: target, at: offsetInChunk)
        case .kokoro:
            let voiceID = voice.engineVoiceID
            if OfflineAudioStore.isComplete(bookID, voice: voiceID) {
                // All the audio is already on the phone: no need to load the model at all.
                attach(KokoroSpeechBackend(chunks: chunks, rate: rate, source: audioSource(voiceID))).play(from: target, at: offsetInChunk)
            } else {
                preparingVoice = true
                let voiceAtStart = voice
                Task {
                    do {
                        try await kokoro.ensureLoaded()
                        preparingVoice = false
                        // The user may have paused or changed voice while the model loaded.
                        guard reading, isPlaying, voice == voiceAtStart, backend == nil else { return }
                        let made = KokoroSpeechBackend(chunks: chunks, rate: rate, source: audioSource(voiceID))
                        attach(made).play(from: chunkIndex, at: offsetInChunk)
                    } catch {
                        preparingVoice = false
                        fail(error.localizedDescription)
                    }
                }
            }
        }
        publishNowPlaying()
    }

    /// Kokoro audio for a chunk: from the book's offline audio when that chunk has been made,
    /// otherwise synthesized now.
    private func audioSource(_ voiceID: String) -> KokoroSpeechBackend.AudioSource {
        let dir = OfflineAudioStore.directory(bookID, voice: voiceID)
        let chunks = chunks, kokoro = kokoro
        return { index, useCPU in
            if let saved = await OfflineAudioStore.load(index, in: dir) { return saved }
            try await kokoro.ensureLoaded()
            return try await kokoro.engine.synthesize(chunks[index].text, voice: voiceID, useCPU: useCPU)
        }
    }

    private func attach(_ made: SpeechBackend) -> SpeechBackend {
        made.onChunkStart = { [weak self] i in self?.chunkStarted(i) }
        made.onWord = { [weak self] range in self?.wordSpoken(range) }
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

    private func wordSpoken(_ range: Range<Int>) {
        guard isPlaying, chunks.indices.contains(chunkIndex) else { return }
        let offset = chunks[chunkIndex].offset
        word = (offset + range.lowerBound)..<(offset + range.upperBound)
    }

    private func chunkStarted(_ i: Int) {
        guard chunks.indices.contains(i) else { return }
        chunkIndex = i
        let paragraph = chunks[i].paragraph
        if paragraph != index {
            index = paragraph
            word = nil
        }
        library.update(bookID) {
            $0.ttsPosition = paragraph
            $0.ttsChunkPosition = i
            $0.ttsWordOffset = nil
        }
        publishNowPlaying()
    }

    private func finished() {
        reading = false
        isPlaying = false
        buffering = false
        word = nil
        AudioFocus.shared.updateNowPlaying(elapsed: 0, rate: 0)
    }

    private func fail(_ message: String) {
        Log.reader.error("fail: \(message, privacy: .public)")
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

    /// The word starting at a UTF-16 offset: letters, digits and apostrophes.
    private static func wordRange(at offset: Int, in text: String) -> Range<Int>? {
        guard offset >= 0, offset < text.utf16.count else { return nil }
        let start = String.Index(utf16Offset: offset, in: text)
        var end = start
        while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "'" || text[end] == "’" {
            end = text.index(after: end)
        }
        guard end > start else { return nil }
        return offset..<(offset + text.utf16.distance(from: start, to: end))
    }

    // MARK: - AudioOwner

    func yieldAudio() { pause() }
    func remotePlay() { if !isPlaying { togglePlay() } }
    func remotePause() { pause() }
    func remoteTogglePlayPause() { togglePlay() }
    func remoteSkip(by seconds: Double) { jump(seconds > 0 ? 1 : -1) }
    func remoteNext() { jump(1) }
    func remotePrevious() { jump(-1) }
    func remoteSeek(to seconds: Double) {}
}
