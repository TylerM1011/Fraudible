import SwiftUI

/// The app follows the system appearance and Apple's Liquid Glass design: system colours,
/// materials and controls, with the app's pink accent (Assets › AccentColor) as the tint.
/// The only custom colours are the two that tell audiobooks and text-to-speech books apart.
extension BookKind {
    var tint: Color { self == .audiobook ? .orange : .purple }
    var symbol: String { self == .audiobook ? "headphones" : "text.bubble.fill" }
    var shortLabel: String { self == .audiobook ? "Audiobook" : "Read aloud" }
}

func formatTime(_ totalSeconds: Double) -> String {
    let s = max(0, Int(totalSeconds.isFinite ? totalSeconds : 0))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// "1×", "1.25×"
func rateLabel(_ rate: Double) -> String {
    (rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)) + "×"
}
