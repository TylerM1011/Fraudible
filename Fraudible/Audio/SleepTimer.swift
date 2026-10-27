import Foundation
import Observation
import SwiftUI

/// Stops playback after a set time or at the end of the current chapter, like Spotify's and
/// YouTube's sleep timers. Works for whichever is playing: an audiobook or the reader.
///
/// The countdown only runs while something is playing, so pausing doesn't use up the time.
/// The last few seconds fade out rather than cutting off mid-sentence.
@Observable
final class SleepTimer {
    static let shared = SleepTimer()

    enum Mode: Equatable { case off, countdown, endOfChapter }

    static let presets = [5, 10, 15, 30, 45, 60] // minutes
    private static let fadeSeconds = 8.0

    private(set) var mode: Mode = .off
    /// Seconds left on the countdown.
    private(set) var remaining: TimeInterval = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var fadedOwner: AudioOwner?

    var isActive: Bool { mode != .off }

    func start(minutes: Int) {
        cancel()
        remaining = Double(minutes * 60)
        mode = .countdown
        Log.audio.info("sleep timer: \(minutes, privacy: .public) min")
        task = Task { await countDown() }
    }

    /// Stop when the current chapter ends. Returns false if the book has no chapters to go by.
    func startEndOfChapter(for owner: AudioOwner) {
        cancel()
        guard owner.armEndOfChapter() else { return }
        mode = .endOfChapter
        Log.audio.info("sleep timer: end of chapter")
    }

    func cancel() {
        task?.cancel()
        task = nil
        mode = .off
        restoreVolume()
    }

    /// Called by the player when it stops at the end of a chapter.
    func chapterEnded() {
        Log.audio.info("sleep timer: stopped at end of chapter")
        cancel()
    }

    private func countDown() async {
        var last = Date()
        while !Task.isCancelled, mode == .countdown {
            try? await Task.sleep(for: .milliseconds(500))
            let now = Date()
            let elapsed = now.timeIntervalSince(last)
            last = now
            guard let owner = AudioFocus.shared.current, owner.isAudioPlaying else {
                restoreVolume() // paused part-way through the fade
                continue
            }
            remaining = max(0, remaining - elapsed)
            if remaining <= Self.fadeSeconds {
                owner.setOutputVolume(Float(remaining / Self.fadeSeconds))
                fadedOwner = owner
            }
            if remaining <= 0 {
                Log.audio.info("sleep timer: time's up")
                owner.remotePause()
                task = nil
                mode = .off
                restoreVolume()
            }
        }
    }

    private func restoreVolume() {
        fadedOwner?.setOutputVolume(1)
        fadedOwner = nil
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The sleep timer's menu: preset times, end of chapter, or turn it off.
struct SleepTimerMenu<Content: View>: View {
    let owner: AudioOwner
    /// Whether "End of chapter" makes sense for what's playing.
    let canStopAtChapterEnd: Bool
    @ViewBuilder let label: () -> Content
    private var timer: SleepTimer { .shared }

    var body: some View {
        Menu {
            Section("Sleep Timer") {
                ForEach(SleepTimer.presets, id: \.self) { minutes in
                    Button(minutes == 60 ? "1 hour" : "\(minutes) minutes") { timer.start(minutes: minutes) }
                }
                if canStopAtChapterEnd {
                    Button("End of chapter", systemImage: "book.closed") { timer.startEndOfChapter(for: owner) }
                }
            }
            if timer.isActive {
                Button("Turn Off Timer", systemImage: "xmark", role: .destructive) { timer.cancel() }
            }
        } label: {
            label()
        }
        .accessibilityLabel(timer.isActive ? "Sleep timer on" : "Sleep timer")
    }
}

/// Moon icon, with the time left (or "Chapter") underneath when the timer is on.
/// Its own view so the twice-a-second countdown only redraws this, not the whole screen.
struct SleepTimerIcon: View {
    var size: CGFloat = 18
    private var timer: SleepTimer { .shared }

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: timer.isActive ? size * 0.8 : size, weight: .semibold))
                .foregroundStyle(timer.isActive ? Color.accentColor : .primary)
            if timer.isActive {
                Text(timer.mode == .endOfChapter ? "Chapter" : SleepTimer.format(timer.remaining))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .animation(.smooth, value: timer.isActive)
    }
}
