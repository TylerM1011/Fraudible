import Foundation
import Observation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Kokoro on-device neural text-to-speech (via KokoroSwift, which runs on Apple's MLX).
///
/// The model is downloaded once (~330 MB) into Application Support and loaded on demand;
/// after that everything runs offline. Voices are bundled with the app (Resources/voices.npz).
/// MLX needs the iPhone's GPU, so Kokoro isn't available in the Simulator.
@Observable
final class KokoroManager {
    enum Status: Equatable {
        case idle, downloading, loading, ready
        case failed(String)
    }

    static let modelURL = URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    static let modelBytes: Int64 = 327_115_152
    static let downloadSize = "≈330 MB"

    #if targetEnvironment(simulator)
    static let isSupported = false
    #else
    static let isSupported = true
    #endif

    private(set) var status: Status = .idle
    /// 0...1 while downloading.
    private(set) var progress: Double = 0
    private(set) var isDownloaded = false

    let engine = KokoroEngine()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Error>?

    static var modelFile: URL {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Kokoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kokoro-v1_0.safetensors")
    }

    init() {
        isDownloaded = Self.isSupported && Self.modelIsComplete()
    }

    private static func modelIsComplete() -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size == modelBytes
    }

    // MARK: - Download

    func download() {
        guard Self.isSupported, !isDownloaded, downloadTask == nil else { return }
        status = .downloading
        progress = 0
        downloadTask = Task {
            defer { downloadTask = nil }
            let partial = Self.modelFile.appendingPathExtension("part")
            do {
                // The manager lives for the whole app, so a strong capture is fine here.
                try await Downloader.download(Self.modelURL, to: partial) { [self] p in
                    Task { @MainActor in
                        guard Int(p * 100) != Int(self.progress * 100) else { return }
                        self.progress = p
                    }
                }
                let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size == Self.modelBytes else {
                    try? FileManager.default.removeItem(at: partial)
                    throw KokoroError.corruptDownload
                }
                try? FileManager.default.removeItem(at: Self.modelFile)
                try FileManager.default.moveItem(at: partial, to: Self.modelFile)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var file = Self.modelFile
                try? file.setResourceValues(values)
                isDownloaded = true
                progress = 1
                status = .idle
            } catch is CancellationError {
                status = .failed("Download cancelled.")
            } catch let error as URLError where error.code == .cancelled {
                status = .failed("Download cancelled.")
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Frees the ~330 MB. The voice can be downloaded again later.
    func deleteModel() {
        engine.unload()
        loadTask = nil
        try? FileManager.default.removeItem(at: Self.modelFile)
        isDownloaded = false
        status = .idle
    }

    // MARK: - Loading

    /// Load the model into memory (once). Throws if it isn't downloaded.
    func ensureLoaded() async throws {
        guard isDownloaded else { throw KokoroError.notDownloaded }
        if status == .ready { return }
        if let loadTask { return try await loadTask.value }
        Log.kokoro.info("ensureLoaded: loading model from \(Self.modelFile.path, privacy: .public)")
        status = .loading
        let task = Task {
            try await engine.load(modelFile: Self.modelFile)
        }
        loadTask = task
        do {
            try await task.value
            status = .ready
            Log.kokoro.info("ensureLoaded: ready")
        } catch {
            Log.kokoro.error("ensureLoaded failed: \(String(describing: error), privacy: .public)")
            loadTask = nil
            status = .failed(error.localizedDescription)
            throw error
        }
    }
}

nonisolated enum KokoroError: LocalizedError {
    case notDownloaded, corruptDownload, noVoices, unknownVoice(String)
    var errorDescription: String? {
        switch self {
        case .notDownloaded: "The Kokoro voice hasn’t been downloaded yet."
        case .corruptDownload: "The voice download was incomplete. Please try again."
        case .noVoices: "The Kokoro voice styles are missing from the app."
        case .unknownVoice(let id): "Unknown Kokoro voice “\(id)”."
        }
    }
}

/// Audio for one chunk, with when each word is spoken.
nonisolated struct KokoroAudio: Sendable {
    var samples: [Float]
    var words: [WordTiming]
}

/// Owns the KokoroTTS model. Every call runs on one serial background queue, because the
/// model isn't thread-safe and synthesis is heavy.
nonisolated final class KokoroEngine: @unchecked Sendable {
    static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    private let queue = DispatchQueue(label: "com.tyler.fraudible.kokoro", qos: .userInitiated)
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    func load(modelFile: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.tts != nil { return continuation.resume() }
                guard let voicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz"),
                      let voices = NpyzReader.read(fileFromPath: voicesURL), !voices.isEmpty else {
                    return continuation.resume(throwing: KokoroError.noVoices)
                }
                // Keep MLX's buffer cache small; phones don't have memory to spare.
                GPU.set(cacheLimit: 64 * 1024 * 1024)
                self.voices = voices
                let started = Date()
                Log.kokoro.info("load: \(voices.count, privacy: .public) voice styles; creating KokoroTTS")
                self.tts = KokoroTTS(modelPath: modelFile, g2p: .misaki)
                Log.kokoro.info("load: model ready in \(Date().timeIntervalSince(started), privacy: .public)s")
                continuation.resume()
            }
        }
    }

    func unload() {
        queue.async {
            self.tts = nil
            self.voices = [:]
            GPU.clearCache()
        }
    }

    /// Synthesize `text` with a voice such as "bf_emma". Returns mono float samples at `sampleRate`,
    /// plus when each word is spoken (for highlighting).
    /// `useCPU` is for when the app is in the background, where iOS doesn't allow GPU work.
    func synthesize(_ text: String, voice: String, useCPU: Bool) async throws -> KokoroAudio {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KokoroAudio, Error>) in
            queue.async {
                do {
                    guard let tts = self.tts else { throw KokoroError.notDownloaded }
                    guard let style = self.voices["\(voice).npy"] ?? self.voices[voice] else { throw KokoroError.unknownVoice(voice) }
                    let language: Language = voice.hasPrefix("b") ? .enGB : .enUS
                    let started = Date()
                    // Synthesize a sentence or so at a time to keep GPU memory in bounds.
                    var samples: [Float] = []
                    var words: [WordTiming] = []
                    var pieceSearch = text.startIndex
                    for piece in TextProcessing.kokoroPieces(text) {
                        let (audio, tokens) = try Device.withDefaultDevice(useCPU ? Device.cpu : Device.gpu) {
                            try self.generate(tts, style: style, language: language, text: piece)
                        }
                        // Where this piece sits in the chunk, so word ranges can be made chunk-relative.
                        var pieceOffset = 0
                        if let found = text.range(of: piece, range: pieceSearch..<text.endIndex) {
                            pieceOffset = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
                            pieceSearch = found.upperBound
                        }
                        let timeOffset = Double(samples.count) / Self.sampleRate
                        words += Self.wordTimings(tokens, in: piece, offset: pieceOffset, time: timeOffset)
                        samples += audio
                        GPU.clearCache()
                    }
                    let stats = Self.stats(samples)
                    Log.kokoro.info("synthesize: \(text.count, privacy: .public) chars -> \(Double(samples.count) / Self.sampleRate, privacy: .public)s audio in \(Date().timeIntervalSince(started), privacy: .public)s; \(words.count, privacy: .public) words; peak \(stats.peak, privacy: .public) rms \(stats.rms, privacy: .public) zcr \(stats.zcr, privacy: .public)")
                    continuation.resume(returning: KokoroAudio(samples: samples, words: words))
                } catch {
                    Log.kokoro.error("synthesize failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Kokoro takes at most 510 phoneme tokens per call. Chunks are kept short, but if one is
    /// still too long, split it at a space and synthesize the halves (word timings are dropped then).
    private func generate(_ tts: KokoroTTS, style: MLXArray, language: Language, text: String) throws -> ([Float], [MToken]?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return ([], nil) }
        do {
            // withError turns MLX failures (e.g. running out of GPU memory) into Swift errors
            // instead of crashing the app.
            return try withError { try tts.generateAudio(voice: style, language: language, text: trimmed) }
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            let words = trimmed.split(separator: " ")
            guard words.count > 1 else { return ([], nil) }
            let mid = words.count / 2
            let first = try generate(tts, style: style, language: language, text: words[..<mid].joined(separator: " "))
            let second = try generate(tts, style: style, language: language, text: words[mid...].joined(separator: " "))
            return (first.0 + second.0, nil)
        }
    }

    /// Kokoro reports each token's text and start/end time. Find each word in the piece (in order)
    /// to turn that into chunk-relative character ranges.
    private static func wordTimings(_ tokens: [MToken]?, in piece: String, offset: Int, time: Double) -> [WordTiming] {
        guard let tokens else { return [] }
        var result: [WordTiming] = []
        var cursor = piece.startIndex
        for token in tokens {
            guard let start = token.start_ts, let end = token.end_ts,
                  token.text.rangeOfCharacter(from: .alphanumerics) != nil,
                  let found = piece.range(of: token.text, range: cursor..<piece.endIndex) else { continue }
            cursor = found.upperBound
            let lower = offset + piece.utf16.distance(from: piece.startIndex, to: found.lowerBound)
            let upper = offset + piece.utf16.distance(from: piece.startIndex, to: found.upperBound)
            result.append(WordTiming(start: time + start, end: time + end, range: lower..<upper))
        }
        return result
    }

    /// Peak level, RMS loudness and zero-crossing rate: speech is roughly peak 0.3–1, RMS 0.03–0.15,
    /// ZCR 0.02–0.15; static noise has a ZCR near 0.5.
    private static func stats(_ samples: [Float]) -> (peak: Float, rms: Float, zcr: Float) {
        guard samples.count > 1 else { return (0, 0, 0) }
        var peak: Float = 0, sumSquares: Float = 0, crossings = 0
        for i in samples.indices {
            let s = samples[i]
            peak = max(peak, abs(s))
            sumSquares += s * s
            if i > 0, (samples[i - 1] < 0) != (s < 0) { crossings += 1 }
        }
        return (peak, (sumSquares / Float(samples.count)).squareRoot(), Float(crossings) / Float(samples.count - 1))
    }
}
