# Fraudible

A native iPhone audiobook app (Swift + SwiftUI, with iOS 26's Liquid Glass design) built on free, legal, public-domain catalogues.

- **Search** LibriVox, Project Gutenberg and Open Library at the same time. Every result is labelled
  **Audiobook** (human narration from LibriVox) or **Text-to-speech** (an ebook read aloud).
- **Scanned books from Open Library**: public-domain scans held by the Internet Archive. Downloading one saves
  the original PDF (open it from the reader's **PDF** button, or share it from the Library's long-press menu)
  plus its machine-read text, tidied up for reading aloud. Only freely downloadable scans are shown; lending-only
  books are left out.
- **Download for offline use.** Audiobook chapters are saved as MP3s; ebooks are saved as cleaned-up text.
- **Audiobook player** with chapters, ±30s, drag-to-seek, speed control, background playback,
  lock-screen and headphone controls, and a mini player. Your position is saved automatically.
- **Reader** for ebooks, with paragraph highlighting, tap-to-jump, speed control and two kinds of voice:
  - **Apple voices**: built in, nothing to download, start instantly. Better-sounding *Enhanced* and *Premium*
    versions can be downloaded in Settings › Accessibility › Spoken Content › Voices › English.
  - **Kokoro**: a natural-sounding open-source neural voice ([Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M))
    that runs entirely on the phone via [KokoroSwift](https://github.com/mlalma/kokoro-ios) and Apple's MLX.
    One-time download of about 330 MB, offered in the reader. British and American voices.
- **Import your own** PDF, EPUB or TXT files and have them read aloud. Extraction happens on the phone (PDFKit and a
  small EPUB reader), so no connection is needed.
- **Torrent link** for LibriVox audiobooks (the Internet Archive publishes one per item), via "Torrent" in the player.

## Requirements

- **Xcode 26 or later** on a Mac.
- iPhone or iPad on **iOS 26 or later** (the app uses Liquid Glass).
- Kokoro needs a **real device**: MLX uses the GPU, which the Simulator doesn't provide. In the Simulator the
  reader uses Apple voices only; everything else works.

## Run it

1. Open `Fraudible.xcodeproj` in Xcode.
2. Wait for Xcode to fetch the Swift packages (KokoroSwift, MLX, MisakiSwift, MLXUtilsLibrary, ZIPFoundation).
   The first time takes a few minutes.
3. Pick your iPhone as the run destination and press **Run** (⌘R).

Signing uses your team (`49ALN9FV5Q`) and the same bundle id as the old Expo app, `com.tyler.fraudible`.
If Xcode complains about signing, open the **Fraudible** target › *Signing & Capabilities* and pick your team.

Use the **Release** configuration (Product › Scheme › Edit Scheme › Run › Build Configuration) when trying Kokoro:
debug builds of MLX are several times slower.

### Coming from the Expo version

Installing over the old app keeps your downloads. On first launch the Swift app reads the old library
(from React Native's AsyncStorage) and carries over every book, chapter position and reading position.
The old Kokoro voice download isn't reusable, so Kokoro needs downloading once more.

## Project layout

```
Fraudible.xcodeproj
Fraudible-Info.plist          Background audio mode
Fraudible/
  FraudibleApp.swift          App entry, router (tabs, navigation, player sheet), theme
  Models/
    Book.swift                SearchResult, LibraryBook, Track…
    Library.swift             Library state, downloads, persisted as JSON in Application Support
    ExpoMigration.swift       One-time import of the old Expo app's library
  Services/
    Catalog.swift             LibriVox (Internet Archive), Gutendex and Open Library API calls
    Storage.swift             Book folders on the device, downloads with progress
    TextProcessing.swift      Text clean-up and paragraph/sentence chunking
    Importer.swift            PDF (PDFKit), EPUB (ZIPFoundation) and TXT text extraction
  Audio/
    AudiobookPlayer.swift     App-wide AVPlayer: chapters, speed, saved positions
    AudioFocus.swift          Audiobook and reader stop each other; lock-screen controls
  Speech/
    ReaderSession.swift       Drives reading aloud for one book
    SpeechBackends.swift      Apple (AVSpeechSynthesizer) and Kokoro (AVAudioEngine) playback
    Kokoro.swift              Kokoro model download, loading and synthesis
    Voices.swift              Voice lists and defaults
  Views/                      SwiftUI screens (system Liquid Glass components)
  Resources/voices.npz        Kokoro voice styles (from KokoroTestApp, Apache 2.0)
```

## Good to know

- The catalogue is public-domain books (mostly published before ~1930), so expect classics rather than new releases.
- Kokoro prepares audio a few sentences ahead, so there's a short "Preparing audio…" pause when you start or jump.
  It works best on recent iPhones and uses more battery than Apple's voices. iOS restricts GPU work in the
  background, so with the screen locked Kokoro carries on from the audio it has prepared (a few minutes) and
  switches to the slower CPU; if it falls behind it pauses until you open the app again.
- Scanned (image-only) PDFs have no text to extract, so they can't be read aloud.
- Open Library text comes from OCR, so expect the odd misread word; Gutenberg's hand-checked text reads better
  when a book is on both. Scanned PDFs are large (often 20–100 MB).
- Downloads continue while the app is open; leaving the app for a long time can interrupt them (tap to retry).
