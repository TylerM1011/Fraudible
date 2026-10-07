/** How a book is listened to. */
export type BookKind = 'audiobook' | 'tts';

/** Where a book came from. */
export type BookSource = 'librivox' | 'gutenberg' | 'import';

/** A single row in the search results. */
export interface SearchResult {
  /** Unique across sources, e.g. "librivox:dracula_librivox". */
  key: string;
  kind: BookKind;
  source: Exclude<BookSource, 'import'>;
  /** Internet Archive identifier (LibriVox) or Gutenberg book id. */
  sourceId: string;
  title: string;
  author: string;
  coverUrl?: string;
  /** ISO 639-1 code where known, e.g. "en". */
  language?: string;
  /** Human-readable runtime for audiobooks, e.g. "15:31:02". */
  runtime?: string;
  downloads?: number;
  /** Gutenberg only: the URLs of the formats on offer. */
  formats?: Record<string, string>;
}

/** One chapter/file of a downloaded audiobook. */
export interface Track {
  title: string;
  /** Remote URL it was downloaded from. */
  url: string;
  /** Local file URI once downloaded. */
  file?: string;
  /** Seconds, if the catalogue reported it. */
  duration?: number;
}

export type BookStatus = 'downloading' | 'ready' | 'error';

export interface LibraryBook {
  id: string;
  kind: BookKind;
  source: BookSource;
  title: string;
  author: string;
  coverUrl?: string;
  language?: string;
  addedAt: number;
  status: BookStatus;
  /** 0..1 while downloading. */
  progress: number;
  error?: string;
  /** The search result this book was created from, kept so a failed download can be retried. */
  origin?: SearchResult;

  // Audiobooks
  tracks?: Track[];
  audioPosition?: { track: number; seconds: number };

  // Text-to-speech books
  /** Local file URI of the cleaned plain text. */
  textFile?: string;
  /** Index of the paragraph the reader was on. */
  ttsPosition?: number;
  /** Index of the exact chunk within that paragraph the reader last played, so a long
   *  paragraph resumes where it stopped instead of restarting from its first sentence. */
  ttsChunkPosition?: number;
  /** Total paragraph count, for showing progress in the library. */
  ttsChunks?: number;
  ttsRate?: number;
  ttsVoice?: string;
}
