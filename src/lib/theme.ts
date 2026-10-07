import type { BookKind } from './types';

export const colors = {
  bg: '#12100E',
  surface: '#1D1A17',
  surfaceHigh: '#2A2622',
  border: '#36312B',
  text: '#F2EDE6',
  muted: '#A39A8F',
  faint: '#6E665D',
  accent: '#E8A33D',
  accentText: '#1A1208',
  danger: '#E5675B',
  audiobook: '#3FB8AF',
  tts: '#A78BFA',
};

export const kindLabel: Record<BookKind, string> = {
  audiobook: 'Audiobook',
  tts: 'Text-to-speech',
};

export const kindColor: Record<BookKind, string> = {
  audiobook: colors.audiobook,
  tts: colors.tts,
};

/**
 * Plain text glyphs used instead of an icon font.
 * U+FE0E asks iOS to render the text form rather than an emoji.
 */
export const glyph = {
  play: '▶︎',
  pause: '❚❚',
  prev: '⏮︎',
  next: '⏭︎',
  back: '‹',
  search: '⌕',
  headphones: '♫',
  speech: '“”',
};
