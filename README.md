# Fraudible

A React Native (Expo SDK 57) audiobook app built on free, legal, public-domain catalogues.

- **Search** LibriVox and Project Gutenberg at the same time. Every result is labelled
  **Audiobook** (human narration from LibriVox) or **Text-to-speech** (a Gutenberg ebook read aloud by an AI voice).
- **Download for offline use.** Audiobook chapters are saved as MP3s; ebooks are saved as cleaned-up text.
- **Audiobook player** with chapters, ±30s, tap-to-seek, speed control, background playback,
  lock-screen controls and a mini player. Your position is saved automatically.
- **Kokoro reader**: ebooks are read aloud by [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), a natural-sounding
  open-source neural voice that runs entirely on the phone (via `react-native-executorch`). Paragraph highlighting,
  tap-to-jump, speed control, British and American voices. It remembers where you stopped.
- **Import your own** PDF, EPUB or TXT files and have them read aloud.
- **Torrent link** for LibriVox audiobooks (the Internet Archive publishes one per item), via the "Torrent" button in the player.

## Requirements

- **A development build, not Expo Go.** Kokoro needs native code that Expo Go doesn't include.
- iPhone on **iOS 17 or later** (Android 13+ also supported).
- To build on your Mac: **Xcode** from the Mac App Store, plus its command-line tools.

## Run it

```bash
cd ~/dev/Fraudible
npm install
npx expo run:ios --device     # builds and installs on your iPhone (connected by USB, or on the same Wi-Fi)
```

The first build takes a while (10–20 minutes). After that, day-to-day work is the same as Expo Go:

```bash
npx expo start                # then open the Fraudible app on your phone
```

Only rebuild (`npx expo run:ios`) after adding or upgrading a package with native code.

No Xcode? Build in the cloud instead (needs a free Expo account; installing on a real iPhone needs an Apple Developer account):

```bash
npx eas-cli@latest build --profile development --platform ios
```

## Project layout

```
src/
  app/                      Expo Router screens
    (tabs)/index.tsx        Search
    (tabs)/library.tsx      Library + import
    listen/[id].tsx         Audiobook player
    read/[id].tsx           Kokoro reader
  components/
    ImportExtractor.tsx     Hidden WebView running pdf.js / JSZip to pull text from PDFs and EPUBs
    MiniPlayer.tsx, ui.tsx
  lib/
    catalog.ts              LibriVox (Internet Archive) + Gutendex API calls
    storage.ts              Downloads and on-device files
    library.tsx             Library state, persisted with AsyncStorage
    player.tsx              App-wide audiobook player
    kokoro.tsx              Kokoro voice download, loading and voice list
    wav.ts                  Turns Kokoro's audio into WAV files for playback
    audioFocus.ts           Stops the reader when an audiobook starts (and vice versa)
    text.ts                 Text clean-up and paragraph chunking
```

## Good to know

- The catalogue is public-domain books (mostly published before ~1930), so expect classics rather than new releases.
- The Kokoro voice is a **one-time download of about 330 MB**, offered the first time you open a text-to-speech book.
  British and American voices are separate packs that share the big model file, so the second is a small extra download.
- Kokoro works best on recent phones and uses more battery than the built-in phone voices. It prepares audio a couple of
  paragraphs ahead, so there's a short "Preparing audio…" pause when you start or jump.
- Importing a PDF or EPUB needs an internet connection the first time, to load the PDF/EPUB reader library. After that the book is stored offline.
- Scanned (image-only) PDFs have no text to extract, so they can't be read aloud.
