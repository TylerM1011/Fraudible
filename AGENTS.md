This is a native iOS app written in Swift and SwiftUI (no Expo or React Native). Target: iOS 18+, built with Xcode 26 or later.

## Project

- Open `Fraudible.xcodeproj`. The `Fraudible/` folder is a synchronized group: any file added there is part of the app target automatically; no project-file edits needed for new sources or resources.
- Swift packages: KokoroSwift (`mlalma/kokoro-ios`, an embedded dynamic framework that brings in MLX and MisakiSwift), MLXUtilsLibrary, ZIPFoundation.
- Build settings follow the Xcode 26 template: Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. Types are main-actor by default; anything used off the main thread (data models, parsers, the Kokoro engine) is declared `nonisolated`, and CPU-heavy async functions are `@concurrent` or run in `Task.detached`.
- Background audio is enabled in `Fraudible-Info.plist` (`UIBackgroundModes: audio`).

## Conventions

- State lives in `@Observable` classes injected with `.environment(...)`: `Library`, `AudiobookPlayer`, `KokoroManager`, `AppRouter`.
- The library stores file *names*, never absolute paths; resolve them with `Storage.bookDir(_:)`.
- Colours come from `@Environment(\.palette)`; headings use `Font.mono(_:weight:)`.
- Kokoro (MLX) needs a real device; guard Simulator-only paths with `KokoroManager.isSupported`.

## Commands

```bash
xcodebuild -project Fraudible.xcodeproj -scheme Fraudible -destination 'generic/platform=iOS' build
xcodebuild -project Fraudible.xcodeproj -scheme Fraudible -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Build before declaring a task done.
