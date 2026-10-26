import AVFoundation
import UIKit

/// Speaks a list of chunks in order. Two implementations: Apple's built-in voices and Kokoro.
protocol SpeechBackend: AnyObject {
    /// A chunk started playing.
    var onChunkStart: ((Int) -> Void)? { get set }
    /// A word started being spoken: its range of UTF-16 offsets within the current chunk's text.
    var onWord: ((Range<Int>) -> Void)? { get set }
    /// The last chunk finished.
    var onFinish: (() -> Void)? { get set }
    /// Waiting for audio that isn't ready yet (Kokoro only).
    var onBuffering: ((Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    /// Start speaking chunk `index`, beginning at the word that starts at UTF-16 offset
    /// `wordOffset` in its text (0 = the start), interrupting anything already playing.
    func play(from index: Int, at wordOffset: Int)
    /// Stop on the current word. Resuming is `play(from:at:)` with that word.
    func pause()
    func stop()
    func setRate(_ rate: Double)
}

extension SpeechBackend {
    func play(from index: Int) { play(from: index, at: 0) }
}

// MARK: - Apple voices

/// Built-in voices via AVSpeechSynthesizer: nothing to download, works everywhere.
final class AppleSpeechBackend: SpeechBackend {
    var onChunkStart: ((Int) -> Void)?
    var onWord: ((Range<Int>) -> Void)?
    var onFinish: (() -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let chunks: [Chunk]
    private let voice: AVSpeechSynthesisVoice?
    private var rate: Double
    private let synthesizer = AVSpeechSynthesizer()
    private let relay = SpeechDelegateRelay()
    /// The utterance currently speaking, the chunk it belongs to, and where in the chunk's
    /// text it starts (an utterance can begin mid-chunk when resuming on a word).
    private var current: (id: ObjectIdentifier, index: Int, base: Int)?
    /// The chunk-relative offset of the word being spoken, so a speed change restarts there.
    private var lastWordOffset = 0

    init(chunks: [Chunk], voiceIdentifier: String, rate: Double) {
        self.chunks = chunks
        self.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        self.rate = rate
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = relay
        relay.onFinish = { [weak self] id in self?.utteranceFinished(id) }
        relay.onWord = { [weak self] id, range in
            guard let self, let current = self.current, current.id == id else { return }
            let chunkRange = (current.base + range.lowerBound)..<(current.base + range.upperBound)
            self.lastWordOffset = chunkRange.lowerBound
            self.onWord?(chunkRange)
        }
    }

    func play(from index: Int, at wordOffset: Int) {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speak(index, at: wordOffset)
    }

    /// Cut off immediately; resuming speaks again from the highlighted word.
    func pause() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Takes effect immediately by restarting the current chunk at the new speed.
    func setRate(_ rate: Double) {
        self.rate = rate
        guard let current, synthesizer.isSpeaking else { return }
        play(from: current.index, at: lastWordOffset)
    }

    private func speak(_ index: Int, at wordOffset: Int = 0) {
        guard index < chunks.count else {
            current = nil
            onFinish?()
            return
        }
        let text = chunks[index].text
        let base = min(max(0, wordOffset), text.utf16.count)
        let start = String.Index(utf16Offset: base, in: text)
        Log.reader.info("apple: speak chunk \(index, privacy: .public) at \(base, privacy: .public) voice=\(self.voice?.identifier ?? "default", privacy: .public)")
        let utterance = AVSpeechUtterance(string: String(text[start...]))
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(rate)
        let nextIsNewParagraph = index + 1 < chunks.count && chunks[index + 1].paragraph != chunks[index].paragraph
        utterance.postUtteranceDelay = nextIsNewParagraph ? 0.35 : 0.05
        current = (ObjectIdentifier(utterance), index, base)
        lastWordOffset = base
        synthesizer.speak(utterance)
        onChunkStart?(index)
    }

    private func utteranceFinished(_ id: ObjectIdentifier) {
        guard let current, current.id == id else { return } // a stale or cancelled utterance
        speak(current.index + 1)
    }

    /// AVSpeechUtterance's rate isn't linear: 0.5 is normal speed and 1.0 is very fast.
    private static func utteranceRate(_ multiplier: Double) -> Float {
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let value = multiplier <= 1 ? normal * multiplier : normal + (multiplier - 1) * 0.22
        return Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), value)))
    }
}

/// AVSpeechSynthesizer may call its delegate off the main thread; hop back before touching state.
nonisolated private final class SpeechDelegateRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor (ObjectIdentifier) -> Void)?
    var onWord: (@MainActor (ObjectIdentifier, Range<Int>) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let handler = onFinish
        Task { @MainActor in handler?(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let range = characterRange.location..<(characterRange.location + characterRange.length)
        let handler = onWord
        Task { @MainActor in handler?(id, range) }
    }
}

// MARK: - Kokoro

/// Kokoro neural voice. Audio is synthesized a few chunks ahead of playback and played through
/// AVAudioEngine; speed changes use a time-pitch unit, so they apply instantly without re-synthesis.
final class KokoroSpeechBackend: SpeechBackend {
    var onChunkStart: ((Int) -> Void)?
    var onWord: ((Range<Int>) -> Void)?
    var onFinish: (() -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// How many chunks to prepare ahead of the one playing (each is about a sentence).
    /// About a minute of audio: enough to ride out slow patches without keeping the GPU busy
    /// (which makes the rest of the app stutter) for minutes at a time.
    private static let lookahead = 6

    private let chunks: [Chunk]
    private let engine: KokoroEngine
    private let voiceID: String

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroEngine.sampleRate, channels: 1)!

    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var words: [Int: [WordTiming]] = [:]
    /// The chunk that is playing (or that we're waiting to play).
    private var position = 0
    /// The chunk whose buffer is scheduled on the player, if any.
    private var scheduled: Int?
    private var waiting = false
    private var active = false
    /// The user paused: don't start anything until they resume.
    private var paused = false
    /// Bumped on every jump/stop so completion callbacks from old buffers are ignored.
    private var playToken = 0
    private var builder: Task<Void, Never>?
    private var builderToken = 0
    private var configObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    /// Polls the playback position to report which word is being spoken.
    private var wordTimer: Timer?
    /// The player's sample time when the current chunk started, and the last word reported.
    private var chunkStartSample: AVAudioFramePosition = 0
    private var lastWord: Range<Int>?
    /// Where to start in the chunk about to play (a word's UTF-16 offset), when resuming mid-chunk.
    private var startWordOffset = 0
    /// How far into the chunk's audio the scheduled buffer starts, in seconds.
    private var chunkTimeOffset: Double = 0

    init(chunks: [Chunk], engine: KokoroEngine, voiceID: String, rate: Double) {
        self.chunks = chunks
        self.engine = engine
        self.voiceID = voiceID
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        timePitch.rate = Float(rate)

        // Route changes (e.g. headphones) stop the engine; restart the current chunk if we were playing.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, !self.paused, !self.waiting else { return }
                self.play(from: self.position, at: self.lastWord?.lowerBound ?? 0)
            }
        }
        // If synthesis had to pause while the app was in the background, pick it up again.
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startBuilder() }
        }
    }

    func play(from index: Int, at wordOffset: Int) {
        Log.reader.info("kokoro backend: play from \(index, privacy: .public) at \(wordOffset, privacy: .public)")
        playToken += 1
        playerNode.stop()
        scheduled = nil
        active = true
        paused = false
        position = index
        startWordOffset = max(0, wordOffset)
        buffers = buffers.filter { $0.key >= index - 1 && $0.key <= index + Self.lookahead }
        words = words.filter { buffers[$0.key] != nil }
        startBuilder()
        playCurrent()
    }

    /// Stop on the current word. The synthesized audio is kept, so resuming on that word is instant.
    func pause() {
        Log.reader.info("kokoro backend: pause")
        paused = true
        playToken += 1
        scheduled = nil
        stopWordTimer()
        playerNode.stop()
    }

    func stop() {
        active = false
        waiting = false
        paused = false
        scheduled = nil
        playToken += 1
        builderToken += 1
        builder?.cancel()
        builder = nil
        stopWordTimer()
        playerNode.stop()
        audioEngine.stop()
        buffers = [:]
        words = [:]
        for observer in [configObserver, foregroundObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        configObserver = nil
        foregroundObserver = nil
    }

    func setRate(_ rate: Double) {
        timePitch.rate = Float(rate)
    }

    // MARK: Playback

    private func playCurrent() {
        guard active else { return }
        guard position < chunks.count else {
            active = false
            stopWordTimer()
            onFinish?()
            return
        }
        guard let buffer = buffers[position] else {
            Log.reader.info("kokoro backend: waiting for chunk \(self.position, privacy: .public)")
            waiting = true
            onBuffering?(true)
            return
        }
        if waiting {
            waiting = false
            onBuffering?(false)
        }
        // Paused while waiting for audio: keep it ready, but don't start until the user resumes.
        guard !paused else { return }
        do {
            if !audioEngine.isRunning { try audioEngine.start() }
            Log.reader.info("kokoro backend: playing chunk \(self.position, privacy: .public), \(buffer.frameLength, privacy: .public) frames")
        } catch {
            Log.reader.error("kokoro backend: engine start failed: \(String(describing: error), privacy: .public)")
            onError?("Couldn’t start audio: \(error.localizedDescription)")
            return
        }
        let token = playToken
        let index = position
        // Resuming mid-chunk: play from just before the word, and offset word tracking to match.
        let skip = startWordOffset > 0 ? startTime(forWordAt: startWordOffset, in: index, duration: Double(buffer.frameLength) / KokoroEngine.sampleRate) : 0
        startWordOffset = 0
        chunkTimeOffset = skip
        let toPlay = skip > 0 ? tail(of: buffer, from: skip) : buffer
        chunkStartSample = currentSampleTime() ?? 0
        lastWord = nil
        scheduled = index
        playerNode.scheduleBuffer(toPlay, completionCallbackType: .dataPlayedBack, completionHandler: onMainActor { [weak self] in
            self?.chunkFinished(token: token, index: index)
        })
        playerNode.play()
        onChunkStart?(index)
        startWordTimer()
    }

    private func chunkFinished(token: Int, index: Int) {
        guard token == playToken, active, index == position else { return }
        buffers[index - 1] = nil // keep one behind for a quick "previous"
        words[index - 1] = nil
        scheduled = nil
        position = index + 1
        startBuilder()
        playCurrent()
    }

    // MARK: Word tracking

    private func currentSampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    private func startWordTimer() {
        guard wordTimer == nil else { return }
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWord() }
        }
    }

    private func stopWordTimer() {
        wordTimer?.invalidate()
        wordTimer = nil
    }

    private func reportWord() {
        guard let index = scheduled, let timings = words[index], !timings.isEmpty,
              let now = currentSampleTime() else { return }
        let seconds = chunkTimeOffset + Double(now - chunkStartSample) / KokoroEngine.sampleRate
        guard let word = timings.last(where: { $0.start <= seconds }), word.range != lastWord else { return }
        lastWord = word.range
        onWord?(word.range)
    }

    /// When the word at `offset` starts in a chunk's audio. Without word timings (rare), estimate
    /// from how far through the text it is.
    private func startTime(forWordAt offset: Int, in index: Int, duration: Double) -> Double {
        if let timings = words[index], let word = timings.first(where: { $0.range.upperBound > offset }) {
            return min(duration, max(0, word.start - 0.05))
        }
        let length = max(1, chunks[index].text.utf16.count)
        return min(duration, duration * Double(offset) / Double(length))
    }

    /// A copy of the buffer starting `seconds` in.
    private func tail(of buffer: AVAudioPCMBuffer, from seconds: Double) -> AVAudioPCMBuffer {
        let skip = min(Int(buffer.frameLength), Int(seconds * KokoroEngine.sampleRate))
        let count = max(1, Int(buffer.frameLength) - skip)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        out.frameLength = out.frameCapacity
        let available = Int(buffer.frameLength) - skip
        if available > 0 {
            out.floatChannelData![0].update(from: buffer.floatChannelData![0] + skip, count: available)
        } else {
            out.floatChannelData![0][0] = 0
        }
        return out
    }

    // MARK: Building

    private func nextToBuild() -> Int? {
        let end = min(chunks.count, position + Self.lookahead)
        guard position < end else { return nil }
        return (position..<end).first { buffers[$0] == nil }
    }

    private func startBuilder() {
        guard builder == nil, active else { return }
        builderToken += 1
        let token = builderToken
        builder = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, token == self.builderToken, let index = self.nextToBuild() else { break }
                let useCPU = UIApplication.shared.applicationState == .background
                do {
                    let audio = try await self.engine.synthesize(self.chunks[index].text, voice: self.voiceID, useCPU: useCPU)
                    guard token == self.builderToken, !Task.isCancelled else { break }
                    self.buffers[index] = self.makeBuffer(audio.samples)
                    self.words[index] = audio.words
                    if self.waiting && index == self.position { self.playCurrent() }
                } catch {
                    guard token == self.builderToken else { break }
                    // iOS limits heavy work in the background. Rather than failing, wait (showing
                    // "Preparing audio…") and carry on when the app comes back to the foreground.
                    if UIApplication.shared.applicationState != .background {
                        self.onError?(error.localizedDescription)
                    }
                    break
                }
            }
            if let self, token == self.builderToken { self.builder = nil }
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        // A chunk with nothing speakable becomes a short pause.
        let data = samples.isEmpty ? [Float](repeating: 0, count: Int(KokoroEngine.sampleRate * 0.2)) : samples
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count))!
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: data.count)
        }
        return buffer
    }
}

/// AVAudioPlayerNode calls completion handlers on its own audio thread, so build the handler
/// outside the main actor and hop back to it.
nonisolated private func onMainActor(_ action: @escaping @MainActor @Sendable () -> Void) -> AVAudioPlayerNodeCompletionHandler {
    { _ in Task { @MainActor in action() } }
}
