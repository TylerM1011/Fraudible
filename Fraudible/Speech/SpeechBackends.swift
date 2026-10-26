import AVFoundation
import UIKit

/// Speaks a list of chunks in order. Two implementations: Apple's built-in voices and Kokoro.
protocol SpeechBackend: AnyObject {
    /// A chunk started playing.
    var onChunkStart: ((Int) -> Void)? { get set }
    /// The last chunk finished.
    var onFinish: (() -> Void)? { get set }
    /// Waiting for audio that isn't ready yet (Kokoro only).
    var onBuffering: ((Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    /// Start speaking from `index`, interrupting anything already playing.
    func play(from index: Int)
    func pause()
    func resume()
    func stop()
    func setRate(_ rate: Double)
}

// MARK: - Apple voices

/// Built-in voices via AVSpeechSynthesizer: nothing to download, works everywhere.
final class AppleSpeechBackend: SpeechBackend {
    var onChunkStart: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let chunks: [Chunk]
    private let voice: AVSpeechSynthesisVoice?
    private var rate: Double
    private let synthesizer = AVSpeechSynthesizer()
    private let relay = SpeechDelegateRelay()
    /// The utterance currently speaking, and the chunk it belongs to.
    private var current: (id: ObjectIdentifier, index: Int)?

    init(chunks: [Chunk], voiceIdentifier: String, rate: Double) {
        self.chunks = chunks
        self.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        self.rate = rate
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = relay
        relay.onFinish = { [weak self] id in self?.utteranceFinished(id) }
    }

    func play(from index: Int) {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speak(index)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
        else if let current { speak(current.index) }
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Takes effect immediately by restarting the current chunk at the new speed.
    func setRate(_ rate: Double) {
        self.rate = rate
        guard let current, synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        play(from: current.index)
    }

    private func speak(_ index: Int) {
        guard index < chunks.count else {
            current = nil
            onFinish?()
            return
        }
        let utterance = AVSpeechUtterance(string: chunks[index].text)
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(rate)
        let nextIsNewParagraph = index + 1 < chunks.count && chunks[index + 1].paragraph != chunks[index].paragraph
        utterance.postUtteranceDelay = nextIsNewParagraph ? 0.35 : 0.05
        current = (ObjectIdentifier(utterance), index)
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

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let handler = onFinish
        Task { @MainActor in handler?(id) }
    }
}

// MARK: - Kokoro

/// Kokoro neural voice. Audio is synthesized a few chunks ahead of playback and played through
/// AVAudioEngine; speed changes use a time-pitch unit, so they apply instantly without re-synthesis.
final class KokoroSpeechBackend: SpeechBackend {
    var onChunkStart: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    /// How many chunks to prepare ahead of the one playing (each is a sentence or two).
    private static let lookahead = 16

    private let chunks: [Chunk]
    private let engine: KokoroEngine
    private let voiceID: String

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroEngine.sampleRate, channels: 1)!

    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    /// The chunk that is playing (or that we're waiting to play).
    private var position = 0
    private var waiting = false
    private var active = false
    /// Bumped on every jump/stop so completion callbacks from old buffers are ignored.
    private var playToken = 0
    private var builder: Task<Void, Never>?
    private var builderToken = 0
    private var configObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

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
                guard let self, self.active, !self.waiting else { return }
                self.play(from: self.position)
            }
        }
        // If synthesis had to pause while the app was in the background, pick it up again.
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startBuilder() }
        }
    }

    func play(from index: Int) {
        playToken += 1
        playerNode.stop()
        active = true
        position = index
        buffers = buffers.filter { $0.key >= index - 1 && $0.key <= index + Self.lookahead }
        startBuilder()
        playCurrent()
    }

    func pause() {
        playerNode.pause()
    }

    func resume() {
        guard active else { return }
        if !audioEngine.isRunning {
            // The engine was stopped (interruption, route change): start the chunk again.
            play(from: position)
            return
        }
        playerNode.play()
    }

    func stop() {
        active = false
        waiting = false
        playToken += 1
        builderToken += 1
        builder?.cancel()
        builder = nil
        playerNode.stop()
        audioEngine.stop()
        buffers = [:]
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
            onFinish?()
            return
        }
        guard let buffer = buffers[position] else {
            waiting = true
            onBuffering?(true)
            return
        }
        if waiting {
            waiting = false
            onBuffering?(false)
        }
        do {
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            onError?("Couldn’t start audio: \(error.localizedDescription)")
            return
        }
        let token = playToken
        let index = position
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: onMainActor { [weak self] in
            self?.chunkFinished(token: token, index: index)
        })
        playerNode.play()
        onChunkStart?(index)
    }

    private func chunkFinished(token: Int, index: Int) {
        guard token == playToken, active, index == position else { return }
        buffers[index - 1] = nil // keep one behind for a quick "previous"
        position = index + 1
        startBuilder()
        playCurrent()
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
                    let samples = try await self.engine.synthesize(self.chunks[index].text, voice: self.voiceID, useCPU: useCPU)
                    guard token == self.builderToken, !Task.isCancelled else { break }
                    self.buffers[index] = self.makeBuffer(samples)
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
