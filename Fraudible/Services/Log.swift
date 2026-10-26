import os

/// Unified logging. View it in Xcode's console while running, or in Console.app
/// (filter on subsystem com.tyler.fraudible).
nonisolated enum Log {
    static let reader = Logger(subsystem: "com.tyler.fraudible", category: "reader")
    static let kokoro = Logger(subsystem: "com.tyler.fraudible", category: "kokoro")
    static let audio = Logger(subsystem: "com.tyler.fraudible", category: "audio")
}
