import AVFoundation

/// A voice the reader can use: one of Apple's built-in voices or a Kokoro neural voice.
nonisolated struct ReaderVoice: Identifiable, Hashable, Sendable {
    nonisolated enum Engine: String, Sendable { case apple, kokoro }

    /// "apple:<voice identifier>" or "kokoro:<voice id>"; this is what the library saves.
    var id: String
    var engine: Engine
    var name: String
    var accent: String
    var detail: String
    /// Kokoro voice id ("bf_emma") or Apple voice identifier.
    var engineVoiceID: String

    var isBritish: Bool { accent == "British" }
}

enum VoiceCatalog {
    /// Kokoro voices bundled in Resources/voices.npz. Prefix a = American, b = British; f/m = female/male.
    private static let kokoroNames: [(id: String, name: String)] = [
        ("bf_emma", "Emma"), ("bf_isabella", "Isabella"), ("bf_alice", "Alice"), ("bf_lily", "Lily"),
        ("bm_daniel", "Daniel"), ("bm_george", "George"), ("bm_lewis", "Lewis"), ("bm_fable", "Fable"),
        ("af_heart", "Heart"), ("af_bella", "Bella"), ("af_nicole", "Nicole"), ("af_sarah", "Sarah"),
        ("af_river", "River"), ("am_michael", "Michael"), ("am_adam", "Adam"), ("am_eric", "Eric"),
        ("am_liam", "Liam"),
    ]

    static let kokoro: [ReaderVoice] = kokoroNames.map { entry in
        ReaderVoice(
            id: "kokoro:\(entry.id)",
            engine: .kokoro,
            name: entry.name,
            accent: entry.id.hasPrefix("b") ? "British" : "American",
            detail: entry.id.dropFirst().hasPrefix("f") ? "Female" : "Male",
            engineVoiceID: entry.id
        )
    }

    /// English voices installed on this phone, best quality first. Users can download more
    /// (including Enhanced and Premium versions) in Settings › Accessibility › Spoken Content › Voices.
    static func apple() -> [ReaderVoice] {
        let accents = ["en-GB": "British", "en-US": "American", "en-AU": "Australian", "en-IE": "Irish", "en-IN": "Indian", "en-ZA": "South African"]
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            accents[voice.language] != nil && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
        return voices
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if a.language != b.language { return a.language == "en-GB" || (a.language == "en-US" && b.language != "en-GB") }
                return a.name < b.name
            }
            .map { v in
                let quality = switch v.quality {
                case .premium: "Premium"
                case .enhanced: "Enhanced"
                default: "Standard"
                }
                return ReaderVoice(
                    id: "apple:\(v.identifier)",
                    engine: .apple,
                    name: v.name,
                    accent: accents[v.language] ?? v.language,
                    detail: quality,
                    engineVoiceID: v.identifier
                )
            }
    }

    static var prefersBritish: Bool {
        let region = Locale.current.region?.identifier ?? ""
        return ["GB", "IE", "AU", "NZ"].contains(region)
    }

    /// The saved voice if it still exists, otherwise a sensible default: Kokoro if its model is
    /// downloaded, else the best installed Apple voice, British for UK-ish phones.
    static func resolve(_ saved: String?, kokoroAvailable: Bool) -> ReaderVoice {
        if let saved {
            if saved.hasPrefix("kokoro:"), kokoroAvailable, let v = kokoro.first(where: { $0.id == saved }) { return v }
            if saved.hasPrefix("apple:"), let v = apple().first(where: { $0.id == saved }) { return v }
        }
        if kokoroAvailable {
            return kokoro.first { $0.engineVoiceID == (prefersBritish ? "bf_emma" : "af_heart") }!
        }
        let installed = apple()
        let wanted = prefersBritish ? "British" : "American"
        if let best = installed.first(where: { $0.accent == wanted }) ?? installed.first { return best }
        // No English voices installed (very unusual): fall back to the system default.
        let fallback = AVSpeechSynthesisVoice(language: prefersBritish ? "en-GB" : "en-US")
        return ReaderVoice(
            id: "apple:\(fallback?.identifier ?? "default")",
            engine: .apple,
            name: fallback?.name ?? "System voice",
            accent: wanted,
            detail: "Standard",
            engineVoiceID: fallback?.identifier ?? ""
        )
    }
}
