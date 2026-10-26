import SwiftUI

/// Retro, high-contrast palettes: cream-and-ink paper in light mode, console-screen black in dark mode.
nonisolated struct Palette: Sendable {
    var bg: Color
    var surface: Color
    var surfaceHigh: Color
    var border: Color
    var text: Color
    var muted: Color
    var faint: Color
    var accent: Color
    var accentText: Color
    var danger: Color
    var audiobook: Color
    var tts: Color

    static let light = Palette(
        bg: Color(hex: 0xF2ECDC), surface: Color(hex: 0xFFFCF4), surfaceHigh: Color(hex: 0xE8E0CB),
        border: Color(hex: 0x161310), text: Color(hex: 0x161310), muted: Color(hex: 0x5B564C),
        faint: Color(hex: 0x8C8575), accent: Color(hex: 0xFF3E8E), accentText: Color(hex: 0x161310),
        danger: Color(hex: 0xD6362A), audiobook: Color(hex: 0x1E9E4C), tts: Color(hex: 0x6D4FD6)
    )

    static let dark = Palette(
        bg: Color(hex: 0x0E0D0B), surface: Color(hex: 0x1A1814), surfaceHigh: Color(hex: 0x262320),
        border: Color(hex: 0xF2ECDC), text: Color(hex: 0xF2ECDC), muted: Color(hex: 0xAFA897),
        faint: Color(hex: 0x726C5F), accent: Color(hex: 0xFF5FA8), accentText: Color(hex: 0x161310),
        danger: Color(hex: 0xFF6B5E), audiobook: Color(hex: 0x49D17E), tts: Color(hex: 0xA78BFA)
    )

    static func forScheme(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }

    func kind(_ kind: BookKind) -> Color { kind == .audiobook ? audiobook : tts }
}

nonisolated extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The palette follows the effective colour scheme, so views read it from the environment.
extension EnvironmentValues {
    @Entry var palette: Palette = .dark
}

/// Light, dark or follow the phone. Saved with @AppStorage.
enum ThemeMode: String {
    case system, light, dark
}

extension Font {
    /// Blocky monospace used for headings and chrome, echoing an 8-bit/pixel-console look.
    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Courier New", size: size).weight(weight)
    }
}

/// Plain text glyphs used instead of icons. U+FE0E asks iOS for the text form rather than an emoji.
enum Glyph {
    static let play = "▶\u{FE0E}"
    static let pause = "❚❚"
    static let prev = "⏮\u{FE0E}"
    static let next = "⏭\u{FE0E}"
    static let sun = "☀\u{FE0E}"
    static let moon = "☾"
}
