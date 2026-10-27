import AVFoundation
import MediaPlayer
import UIKit

/// Something that can own the speaker and the lock-screen controls:
/// the audiobook player or the text-to-speech reader.
protocol AudioOwner: AnyObject {
    /// Stop talking because the other one is about to start.
    func yieldAudio()
    func remotePlay()
    func remotePause()
    func remoteTogglePlayPause()
    func remoteSkip(by seconds: Double)
    func remoteNext()
    func remotePrevious()
    func remoteSeek(to seconds: Double)

    // Sleep timer
    /// Actually producing sound right now (the sleep timer only counts down while this is true).
    var isAudioPlaying: Bool { get }
    /// 0...1, for fading out at the end of a sleep timer.
    func setOutputVolume(_ volume: Float)
    /// Get ready to stop when the current chapter ends. False if there's no chapter to go by.
    func armEndOfChapter() -> Bool
}

/// Lets the audiobook player and the reader stop each other, so two things never talk at once,
/// and routes the lock-screen / headphone controls to whichever one is active.
final class AudioFocus {
    static let shared = AudioFocus()

    private weak var owner: AudioOwner?
    private var configured = false

    /// Called by whoever is about to play. Stops the other one.
    func claim(_ newOwner: AudioOwner) {
        if let owner, owner !== newOwner { owner.yieldAudio() }
        owner = newOwner
        activateSession()
    }

    func isOwner(_ candidate: AudioOwner) -> Bool { owner === candidate }

    /// Whoever has the speaker (or last had it).
    var current: AudioOwner? { owner }

    func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            // Falls back to the default session; playback still works in the foreground.
            Log.audio.error("audio session: \(String(describing: error), privacy: .public)")
        }
        configureRemoteCommands()
    }

    // MARK: - Now Playing

    func setNowPlaying(title: String, artist: String, album: String, duration: Double?, elapsed: Double, rate: Double, artwork: UIImage?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = makeArtwork(artwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateNowPlaying(elapsed: Double, rate: Double, duration: Double? = nil) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [30]

        center.playCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remotePlay() })
        center.pauseCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remotePause() })
        center.togglePlayPauseCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remoteTogglePlayPause() })
        center.skipForwardCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remoteSkip(by: 30) })
        center.skipBackwardCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remoteSkip(by: -30) })
        center.nextTrackCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remoteNext() })
        center.previousTrackCommand.addTarget(handler: Self.handler { AudioFocus.shared.owner?.remotePrevious() })
        center.changePlaybackPositionCommand.addTarget(handler: Self.seekHandler())
    }

    /// Remote-command handlers can be called on any thread; hop to the main actor to act.
    nonisolated private static func handler(_ action: @escaping @MainActor @Sendable () -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    nonisolated private static func seekHandler() -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in AudioFocus.shared.owner?.remoteSeek(to: position) }
            return .success
        }
    }
}

/// Artwork's image handler can be called off the main thread, so build it outside the main actor.
nonisolated private func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

/// Loads a cover image (local file or remote URL) for the lock screen. Best-effort.
enum ArtworkLoader {
    static func load(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if url.isFileURL { return UIImage(contentsOfFile: url.path) }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
