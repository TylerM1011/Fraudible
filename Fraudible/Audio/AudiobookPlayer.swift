import AVFoundation
import Observation
import UIKit

/// App-wide audiobook player. It lives at the root so playback carries on while you browse
/// other screens (and in the background, with lock-screen controls).
@Observable
final class AudiobookPlayer: AudioOwner {
    static let rates: [Double] = [0.8, 1, 1.25, 1.5, 1.75, 2]

    /// The id of the book currently loaded, if any.
    private(set) var bookID: String?
    private(set) var trackIndex = 0
    private(set) var rate: Double = 1
    private(set) var isPlaying = false
    /// Position and length of the current chapter, updated twice a second.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private let library: Library
    private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var artwork: UIImage?

    init(library: Library) {
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = false

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.didFinishTrack()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            MainActor.assumeIsolated {
                if type == .began { self?.syncPlayingState(false) }
            }
        }
    }

    var book: LibraryBook? { bookID.flatMap { library.book($0) } }
    var currentTrack: Track? { book?.tracks?[safe: trackIndex] }
    var fraction: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    // MARK: - Loading

    /// Load a downloaded audiobook, resuming from its saved position unless a track is given.
    func open(_ book: LibraryBook, track: Int? = nil, seconds: Double? = nil) {
        if track == nil, book.id == bookID {
            if !isPlaying { play() }
            return
        }
        let index = track ?? book.audioPosition?.track ?? 0
        let start = seconds ?? (track == nil ? book.audioPosition?.seconds ?? 0 : 0)
        load(book, index: index, seconds: start, autoplay: true)
    }

    private func load(_ book: LibraryBook, index: Int, seconds: Double, autoplay: Bool) {
        guard let url = book.trackFileURL(index), let track = book.tracks?[safe: index] else { return }
        if autoplay { AudioFocus.shared.claim(self) } // don't talk over the reader
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain // keeps voices natural at higher speeds
        player.replaceCurrentItem(with: item)

        let newBook = bookID != book.id
        bookID = book.id
        trackIndex = index
        currentTime = seconds
        duration = track.duration ?? 0
        lastSaved = seconds
        library.update(book.id) { $0.audioPosition = AudioPosition(track: index, seconds: seconds) }

        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay { play() } else { syncPlayingState(false) }

        if newBook {
            artwork = nil
            Task {
                let image = await ArtworkLoader.load(book.coverImageURL)
                guard self.bookID == book.id else { return }
                self.artwork = image
                self.publishNowPlaying()
            }
        }
        publishNowPlaying()

        // The catalogue's durations are approximate; use the real one once the file is open.
        Task {
            if let real = try? await item.asset.load(.duration).seconds, real.isFinite, real > 0, item === self.player.currentItem {
                self.duration = real
                self.publishNowPlaying()
            }
        }
    }

    // MARK: - Transport

    func play() {
        guard player.currentItem != nil else {
            if let book { open(book) }
            return
        }
        AudioFocus.shared.claim(self)
        player.defaultRate = Float(rate)
        player.playImmediately(atRate: Float(rate))
        syncPlayingState(true)
    }

    func pause() {
        player.pause()
        syncPlayingState(false)
        savePosition(force: true)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = max(0, min(seconds, upper))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        savePosition(force: true)
        publishNowPlaying()
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func nextTrack() {
        guard let book, let tracks = book.tracks, trackIndex + 1 < tracks.count else { return }
        load(book, index: trackIndex + 1, seconds: 0, autoplay: isPlaying)
    }

    /// Like most players: go to the start of this chapter first, then the previous one.
    func previousTrack() {
        guard let book else { return }
        if currentTime > 5 || trackIndex == 0 { seek(to: 0) }
        else { load(book, index: trackIndex - 1, seconds: 0, autoplay: isPlaying) }
    }

    func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
        publishNowPlaying()
    }

    /// Called when a book is deleted.
    func unload(_ id: String) {
        guard id == bookID else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        bookID = nil
        syncPlayingState(false)
        AudioFocus.shared.clearNowPlaying()
    }

    // MARK: - Internals

    private func tick(_ seconds: Double) {
        guard bookID != nil, seconds.isFinite else { return }
        currentTime = seconds
        // Keep the play/pause icon honest if the system paused us (e.g. headphones unplugged).
        let actuallyPlaying = player.timeControlStatus != .paused
        if actuallyPlaying != isPlaying { syncPlayingState(actuallyPlaying) }
        savePosition(force: false)
    }

    /// Save the listening position every 15 seconds, and whenever playback pauses.
    private func savePosition(force: Bool) {
        guard let id = bookID else { return }
        let moved = abs(currentTime - lastSaved)
        if moved >= 15 || (force && moved >= 1) || (!isPlaying && moved >= 1) {
            lastSaved = currentTime
            let track = trackIndex, seconds = currentTime
            library.update(id) { $0.audioPosition = AudioPosition(track: track, seconds: seconds) }
        }
    }

    private func didFinishTrack() {
        guard let book, let tracks = book.tracks else { return }
        if trackIndex + 1 < tracks.count {
            load(book, index: trackIndex + 1, seconds: 0, autoplay: true)
        } else {
            syncPlayingState(false)
            library.update(book.id) { $0.audioPosition = AudioPosition(track: 0, seconds: 0) }
        }
    }

    private func syncPlayingState(_ playing: Bool) {
        isPlaying = playing
        AudioFocus.shared.updateNowPlaying(elapsed: currentTime, rate: playing ? rate : 0, duration: duration)
    }

    private func publishNowPlaying() {
        guard let book, let track = currentTrack, AudioFocus.shared.isOwner(self) else { return }
        AudioFocus.shared.setNowPlaying(
            title: track.title,
            artist: book.author,
            album: book.title,
            duration: duration,
            elapsed: currentTime,
            rate: isPlaying ? rate : 0,
            artwork: artwork
        )
    }

    // MARK: - AudioOwner

    func yieldAudio() { if isPlaying { pause() } }
    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteTogglePlayPause() { toggle() }
    func remoteSkip(by seconds: Double) { seek(by: seconds) }
    func remoteNext() { nextTrack() }
    func remotePrevious() { previousTrack() }
    func remoteSeek(to seconds: Double) { seek(to: seconds) }
}
