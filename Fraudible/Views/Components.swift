import SwiftUI

/// Book cover with rounded corners and a soft shadow. Falls back to a tinted placeholder.
struct Cover: View {
    let url: URL?
    let title: String
    var kind: BookKind = .tts
    var width: CGFloat = 56
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            LinearGradient(colors: [kind.tint.opacity(0.55), kind.tint.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: width * 0.42, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.9))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: width, height: width * 1.45)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: width > 100 ? 18 : 4, y: width > 100 ? 10 : 2)
        .accessibilityHidden(true)
    }
}

/// Small coloured label saying how a book is listened to.
struct KindLabel: View {
    let kind: BookKind

    var body: some View {
        Label(kind.shortLabel, systemImage: kind.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(kind.tint)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }
}

/// A circular progress ring, like the App Store's download indicator.
struct ProgressRing: View {
    let value: Double
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: value)
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: size * 0.28, height: size * 0.28)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}

/// The download / progress / retry / open control used in search results.
struct DownloadControl: View {
    enum Action { case download, cancel, retry, open }

    let kind: BookKind
    let book: LibraryBook?
    let onAction: (Action) -> Void

    var body: some View {
        switch book?.status {
        case nil:
            Button { onAction(.download) } label: {
                Label("Get", systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Download")
        case .downloading:
            Button { onAction(.cancel) } label: {
                ProgressRing(value: book?.progress ?? 0, tint: kind.tint)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Cancels the download")
        case .error:
            Button { onAction(.retry) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .tint(.red)
        case .ready:
            Button(kind == .audiobook ? "Listen" : "Read") { onAction(.open) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
        }
    }
}
