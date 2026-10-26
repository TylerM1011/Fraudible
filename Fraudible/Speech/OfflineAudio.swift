import AVFoundation
import Observation
import UIKit

/// A book's read-aloud audio made ahead of time with a Kokoro voice, so it plays instantly and
/// offline without running the model.
///
/// Stored under <book folder>/speech/<voice id>/: one AAC file per chunk (about a sentence)
/// plus a JSON file of when each word is spoken (for highlighting). The chunk is only counted as
/// done once its JSON is written, so an interrupted run carries on cleanly. `meta.json` records
/// how the text was split; `complete` marks a finished book. Excluded from iCloud backup.
nonisolated enum OfflineAudioStore {
    /// Bump if the chunking changes, so audio made with the old split isn't misused.
    static let layoutVersion = 1
    /// Kokoro speaks about 13 characters a second at normal speed.
    static let charsPerSecond = 13.0
    /// Rough size of the AAC audio (≈48 kbit/s).
    static let bytesPerSecond = 6_000.0

    struct Meta: Codable, Sendable {
        var voice: String
        var total: Int
        var chunkMax: Int
        var layout: Int
    }

    static func speechRoot(_ bookID: String) -> URL {
        Storage.booksRoot.appendingPathComponent(bookID, isDirectory: true).appendingPathComponent("speech", isDirectory: true)
    }

    static func directory(_ bookID: String, voice: String) -> URL {
        speechRoot(bookID).appendingPathComponent(voice, isDirectory: true)
    }

    private static func audioURL(_ index: Int, in dir: URL) -> URL { dir.appendingPathComponent(String(format: "%05d.m4a", index)) }
    private static func wordsURL(_ index: Int, in dir: URL) -> URL { dir.appendingPathComponent(String(format: "%05d.json", index)) }
    private static func metaURL(_ dir: URL) -> URL { dir.appendingPathComponent("meta.json") }
    private static func completeURL(_ dir: URL) -> URL { dir.appendingPathComponent("complete") }

    /// The voice this book has (some) offline audio in, if any.
    static func voice(for bookID: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: speechRoot(bookID).path)) ?? []
        return names.first { !$0.hasPrefix(".") }
    }

    static func isComplete(_ bookID: String, voice: String) -> Bool {
        FileManager.default.fileExists(atPath: completeURL(directory(bookID, voice: voice)).path)
    }

    /// Prepare the folder for a book's audio in `voice`, clearing anything made with another voice
    /// or an older layout. Returns the chunks already done.
    static func prepare(_ bookID: String, voice: String, total: Int, chunkMax: Int) throws -> Set<Int> {
        let fm = FileManager.default
        // One offline voice per book: making a new one replaces the old.
        for name in (try? fm.contentsOfDirectory(atPath: speechRoot(bookID).path)) ?? [] where name != voice {
            try? fm.removeItem(at: speechRoot(bookID).appendingPathComponent(name))
        }
        let dir = directory(bookID, voice: voice)
        let wanted = Meta(voice: voice, total: total, chunkMax: chunkMax, layout: layoutVersion)
        if let data = try? Data(contentsOf: metaURL(dir)), let meta = try? JSONDecoder().decode(Meta.self, from: data),
           meta.total != total || meta.chunkMax != chunkMax || meta.layout != layoutVersion {
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var root = speechRoot(bookID)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        try JSONEncoder().encode(wanted).write(to: metaURL(dir))
        return doneChunks(in: dir)
    }

    static func doneChunks(in dir: URL) -> Set<Int> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { $0.hasSuffix(".json") && $0 != "meta.json" ? Int($0.dropLast(5)) : nil })
    }

    static func markComplete(_ bookID: String, voice: String) {
        FileManager.default.createFile(atPath: completeURL(directory(bookID, voice: voice)).path, contents: Data())
    }

    static func delete(_ bookID: String) {
        try? FileManager.default.removeItem(at: speechRoot(bookID))
    }

    /// Bytes used by a book's offline audio.
    static func size(_ bookID: String) -> Int64 {
        let root = speechRoot(bookID)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Save one chunk's audio (compressed to AAC) and word timings.
    @concurrent static func save(_ audio: KokoroAudio, index: Int, in dir: URL) async throws {
        let samples = audio.samples.isEmpty ? [Float](repeating: 0, count: Int(KokoroEngine.sampleRate * 0.2)) : audio.samples
        let format = AVAudioFormat(standardFormatWithSampleRate: KokoroEngine.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw OfflineAudioError.encode }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let target = audioURL(index, in: dir)
        let temp = dir.appendingPathComponent(String(format: "%05d.part.m4a", index))
        try? FileManager.default.removeItem(at: temp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: KokoroEngine.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            // The file is finished when it's released, at the end of this block.
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        // Written last: its presence means the chunk is done.
        try JSONEncoder().encode(audio.words).write(to: wordsURL(index, in: dir), options: .atomic)
    }

    /// One chunk's audio and word timings, if it has been made.
    @concurrent static func load(_ index: Int, in dir: URL) async -> KokoroAudio? {
        let words = wordsURL(index, in: dir)
        guard FileManager.default.fileExists(atPath: words.path),
              let file = try? AVAudioFile(forReading: audioURL(index, in: dir), commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.sampleRate == KokoroEngine.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let timings = (try? JSONDecoder().decode([WordTiming].self, from: Data(contentsOf: words))) ?? []
        return KokoroAudio(samples: samples, words: timings)
    }
}

nonisolated enum OfflineAudioError: LocalizedError {
    case encode
    var errorDescription: String? { "Couldn’t save the audio." }
}

/// Makes offline audio for books, one book at a time, in the background of the app.
/// iPhone only lets this run quickly while Fraudible is open (the GPU is off-limits in the
/// background), so it keeps the screen awake while working and carries on where it left off.
@Observable
final class OfflineAudioMaker {
    enum State: Equatable {
        case queued, running, paused, complete
        case failed(String)
    }

    struct Job: Equatable {
        var voice: ReaderVoice
        var done = 0
        var total = 0
        var state: State
        /// Recent seconds of work per chunk, for the time-left estimate.
        var secondsPerChunk: Double?

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
        var timeLeft: Double? { secondsPerChunk.map { $0 * Double(max(0, total - done)) } }
    }

    private(set) var jobs: [String: Job] = [:]

    private let library: Library
    private let kokoro: KokoroManager
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runningID: String?
    private static let savedKey = "fraudible.offlineAudio"

    init(library: Library, kokoro: KokoroManager) {
        self.library = library
        self.kokoro = kokoro
        restore()
    }

    func job(_ bookID: String) -> Job? { jobs[bookID] }

    /// Make (or carry on making) a book's offline audio with a Kokoro voice.
    func start(_ bookID: String, voice: ReaderVoice) {
        guard voice.engine == .kokoro else { return }
        if let existing = jobs[bookID], existing.voice != voice {
            if runningID == bookID { cancelRunning() }
            OfflineAudioStore.delete(bookID)
        }
        var job = jobs[bookID] ?? Job(voice: voice, state: .queued)
        job.voice = voice
        job.state = .queued
        jobs[bookID] = job
        save()
        runNext()
    }

    func pause(_ bookID: String) {
        guard var job = jobs[bookID], job.state != .complete else { return }
        if runningID == bookID { cancelRunning() }
        job.state = .paused
        jobs[bookID] = job
        save()
        runNext()
    }

    /// Remove a book's offline audio (finished or not).
    func delete(_ bookID: String) {
        if runningID == bookID { cancelRunning() }
        jobs[bookID] = nil
        OfflineAudioStore.delete(bookID)
        save()
        runNext()
    }

    /// Short status for the library list.
    func badge(_ bookID: String) -> String? {
        guard let job = jobs[bookID] else { return nil }
        let percent = "\(Int(job.fraction * 100))%"
        switch job.state {
        case .complete: return "Offline audio"
        case .running: return "Making audio \(percent)"
        case .queued: return "Audio queued"
        case .paused: return "Audio paused \(percent)"
        case .failed: return "Audio stopped"
        }
    }

    // MARK: - Running

    private func cancelRunning() {
        task?.cancel()
        task = nil
        runningID = nil
        updateIdleTimer()
    }

    private func runNext() {
        guard task == nil, let next = jobs.first(where: { $0.value.state == .queued })?.key else {
            updateIdleTimer()
            return
        }
        runningID = next
        jobs[next]?.state = .running
        updateIdleTimer()
        task = Task { await run(next) }
    }

    private func run(_ bookID: String) async {
        defer {
            if runningID == bookID {
                task = nil
                runningID = nil
                runNext()
            }
        }
        guard let book = library.book(bookID), let fileName = book.textFileName, let voice = jobs[bookID]?.voice else {
            jobs[bookID] = nil
            save()
            return
        }
        let voiceID = voice.engineVoiceID
        do {
            let chunkMax = TextProcessing.kokoroChunk
            let chunks = try await Task.detached(priority: .utility) {
                let paragraphs = try Storage.loadParagraphs(bookId: bookID, fileName: fileName)
                return TextProcessing.chunk(paragraphs, max: chunkMax)
            }.value
            let dir = OfflineAudioStore.directory(bookID, voice: voiceID)
            var done = try OfflineAudioStore.prepare(bookID, voice: voiceID, total: chunks.count, chunkMax: chunkMax)
            update(bookID) { $0.total = chunks.count; $0.done = done.count }
            Log.kokoro.info("offline: \(bookID, privacy: .public) \(done.count, privacy: .public)/\(chunks.count, privacy: .public) done")
            if done.count < chunks.count { try await kokoro.ensureLoaded() }

            for index in chunks.indices where !done.contains(index) {
                try Task.checkCancellation()
                guard library.book(bookID) != nil else { throw CancellationError() } // book removed
                let started = Date()
                let audio = try await synthesizeWhenPossible(chunks[index].text, voice: voiceID)
                try Task.checkCancellation()
                try await OfflineAudioStore.save(audio, index: index, in: dir)
                done.insert(index)
                let took = Date().timeIntervalSince(started)
                update(bookID) { job in
                    job.done = done.count
                    job.secondsPerChunk = job.secondsPerChunk.map { $0 * 0.9 + took * 0.1 } ?? took
                }
            }
            try Task.checkCancellation()
            OfflineAudioStore.markComplete(bookID, voice: voiceID)
            update(bookID) { $0.state = .complete; $0.done = $0.total }
            Log.kokoro.info("offline: \(bookID, privacy: .public) complete")
        } catch is CancellationError {
            // Paused or deleted; the caller already set the state.
        } catch where !Task.isCancelled {
            Log.kokoro.error("offline: \(bookID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            update(bookID) { $0.state = .failed(error.localizedDescription) }
        } catch {
            // Cancelled part-way through something that threw its own error.
        }
        if library.book(bookID) == nil { jobs[bookID] = nil } // the book was removed meanwhile
        save()
    }

    /// Synthesize a chunk. In the background iOS may refuse the work; then wait until the app is
    /// open again and retry, rather than failing the whole book.
    private func synthesizeWhenPossible(_ text: String, voice: String) async throws -> KokoroAudio {
        while true {
            let background = UIApplication.shared.applicationState == .background
            do {
                return try await kokoro.engine.synthesize(text, voice: voice, useCPU: background)
            } catch {
                guard UIApplication.shared.applicationState != .active else { throw error }
                while UIApplication.shared.applicationState != .active {
                    try await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func update(_ bookID: String, _ change: (inout Job) -> Void) {
        guard var job = jobs[bookID] else { return }
        change(&job)
        jobs[bookID] = job
    }

    /// Keep the screen on while making audio, since it slows right down once the app is closed.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = runningID != nil
    }

    // MARK: - Saving the list of books with offline audio

    private func save() {
        let saved = jobs.mapValues { $0.voice.id }
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
    }

    /// On launch: list the books with offline audio. Unfinished ones wait for you to resume them.
    private func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: String] ?? [:]
        for (bookID, voiceID) in saved {
            guard library.book(bookID) != nil,
                  let voice = VoiceCatalog.kokoro.first(where: { $0.id == voiceID }) else { continue }
            let complete = OfflineAudioStore.isComplete(bookID, voice: voice.engineVoiceID)
            jobs[bookID] = Job(voice: voice, state: complete ? .complete : .paused)
            if !complete { refreshCounts(bookID, voice: voice) }
        }
        save()
    }

    private func refreshCounts(_ bookID: String, voice: ReaderVoice) {
        guard let fileName = library.book(bookID)?.textFileName else { return }
        Task {
            let counts = try? await Task.detached(priority: .utility) {
                let paragraphs = try Storage.loadParagraphs(bookId: bookID, fileName: fileName)
                let chunks = TextProcessing.chunk(paragraphs, max: TextProcessing.kokoroChunk)
                let done = OfflineAudioStore.doneChunks(in: OfflineAudioStore.directory(bookID, voice: voice.engineVoiceID))
                return (chunks.count, done.count)
            }.value
            if let counts { update(bookID) { $0.total = counts.0; $0.done = counts.1 } }
        }
    }
}
