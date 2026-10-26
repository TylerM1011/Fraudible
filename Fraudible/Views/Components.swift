import SwiftUI

/// Labels a result as an audiobook or a text-to-speech ebook.
struct KindBadge: View {
    let kind: BookKind
    @Environment(\.palette) private var c

    var body: some View {
        let color = c.kind(kind)
        Text("\(kind == .audiobook ? "♫" : "“") \(kind.label)")
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.13))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct Cover: View {
    let url: URL?
    let title: String
    var size: CGFloat = 56
    @Environment(\.palette) private var c

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        ZStack {
            c.surfaceHigh
            Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased().ifEmpty("?"))
                .font(.mono(size * 0.45, weight: .bold))
                .foregroundStyle(c.muted)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size * 1.4)
        .clipShape(shape)
        .overlay(shape.stroke(c.border, lineWidth: 2))
        .accessibilityHidden(true)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color?
    var height: CGFloat = 4
    @Environment(\.palette) private var c

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                c.surfaceHigh
                (color ?? c.accent)
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
        .overlay(Rectangle().stroke(c.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}

/// The chunky, outlined button used across the app.
struct RetroButtonStyle: ButtonStyle {
    enum Variant { case primary, ghost, danger }
    var variant: Variant = .primary
    var small = false
    @Environment(\.palette) private var c
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = variant == .primary ? c.accent : c.surface
        let foreground: Color = switch variant {
        case .primary: c.accentText
        case .ghost: c.text
        case .danger: c.danger
        }
        configuration.label
            .font(.mono(small ? 12 : 14))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 14 : 18)
            .padding(.vertical, small ? 7 : 11)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(variant == .danger ? c.danger : c.border, lineWidth: 2))
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Round transport button used by both players.
struct RoundButton: View {
    let label: String
    var big = false
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.palette) private var c

    var body: some View {
        let size: CGFloat = big ? 76 : 52
        Button(action: action) {
            Text(label)
                .font(.mono(big ? 26 : 16, weight: .bold))
                .foregroundStyle(big ? c.accentText : c.text)
                .frame(width: size, height: size)
                .background(big ? c.accent : c.surfaceHigh)
                .clipShape(Circle())
                .overlay(Circle().stroke(c.border, lineWidth: 2))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// Small toolbar control that flips between the light ("paper") and dark ("screen") themes.
struct ThemeToggle: View {
    @AppStorage("fraudible.themeMode") private var mode = ThemeMode.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var c

    var body: some View {
        Button {
            mode = (scheme == .dark ? ThemeMode.light : ThemeMode.dark).rawValue
        } label: {
            Text(scheme == .dark ? Glyph.sun : Glyph.moon)
                .font(.system(size: 15))
                .foregroundStyle(c.text)
                .frame(width: 32, height: 32)
                .background(c.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(c.border, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scheme == .dark ? "Switch to light mode" : "Switch to dark mode")
    }
}

/// A heading in the chunky uppercase monospace style.
struct SectionLabel: View {
    let text: String
    var color: Color?
    @Environment(\.palette) private var c

    var body: some View {
        Text(text)
            .font(.mono(13, weight: .heavy))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(color ?? c.muted)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

func formatTime(_ totalSeconds: Double) -> String {
    let s = max(0, Int(totalSeconds.isFinite ? totalSeconds : 0))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

extension View {
    /// Shared navigation-bar styling: the palette background and the monospace title.
    func retroNavigation(_ c: Palette) -> some View {
        self
            .toolbarBackground(c.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
