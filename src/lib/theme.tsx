import AsyncStorage from '@react-native-async-storage/async-storage';
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Platform, useColorScheme } from 'react-native';
import type { BookKind } from './types';

const MODE_KEY = 'fraudible.themeMode';

export interface Colors {
  bg: string;
  surface: string;
  surfaceHigh: string;
  border: string;
  text: string;
  muted: string;
  faint: string;
  accent: string;
  accentText: string;
  danger: string;
  audiobook: string;
  tts: string;
}

/** Retro, high-contrast palettes: cream-and-ink paper in light mode, console-screen black in dark mode. */
const palettes: Record<'light' | 'dark', Colors> = {
  light: {
    bg: '#F2ECDC',
    surface: '#FFFCF4',
    surfaceHigh: '#E8E0CB',
    border: '#161310',
    text: '#161310',
    muted: '#5B564C',
    faint: '#8C8575',
    accent: '#FF3E8E',
    accentText: '#161310',
    danger: '#D6362A',
    audiobook: '#1E9E4C',
    tts: '#6D4FD6',
  },
  dark: {
    bg: '#0E0D0B',
    surface: '#1A1814',
    surfaceHigh: '#262320',
    border: '#F2ECDC',
    text: '#F2ECDC',
    muted: '#AFA897',
    faint: '#726C5F',
    accent: '#FF5FA8',
    accentText: '#161310',
    danger: '#FF6B5E',
    audiobook: '#49D17E',
    tts: '#A78BFA',
  },
};

export type Scheme = keyof typeof palettes;
export type ThemeMode = Scheme | 'system';

export const kindLabel: Record<BookKind, string> = {
  audiobook: 'Audiobook',
  tts: 'Text-to-speech',
};

export function kindColors(colors: Colors): Record<BookKind, string> {
  return { audiobook: colors.audiobook, tts: colors.tts };
}

/** Plain text glyphs used instead of an icon font. U+FE0E asks iOS to render the text form rather than an emoji. */
export const glyph = {
  play: '▶︎',
  pause: '❚❚',
  prev: '⏮︎',
  next: '⏭︎',
  back: '‹',
  search: '⌕',
  headphones: '♫',
  speech: '“”',
  sun: '☀',
  moon: '☾',
};

/** Blocky monospace used for headings and chrome, echoing an 8-bit/pixel-console look. */
export const fonts = {
  mono: Platform.select({ ios: 'Courier New', android: 'monospace', default: 'monospace' }),
};

interface ThemeContextValue {
  colors: Colors;
  scheme: Scheme;
  mode: ThemeMode;
  setMode: (mode: ThemeMode) => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({ children }: { children: ReactNode }) {
  const systemScheme = useColorScheme();
  const [mode, setModeState] = useState<ThemeMode>('system');

  useEffect(() => {
    AsyncStorage.getItem(MODE_KEY).then((saved) => {
      if (saved === 'light' || saved === 'dark' || saved === 'system') setModeState(saved);
    });
  }, []);

  const setMode = (next: ThemeMode) => {
    setModeState(next);
    AsyncStorage.setItem(MODE_KEY, next);
  };

  const scheme: Scheme = mode === 'system' ? (systemScheme === 'light' ? 'light' : 'dark') : mode;
  const colors = palettes[scheme];
  const value = useMemo(() => ({ colors, scheme, mode, setMode }), [colors, scheme, mode]);

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useTheme must be used within a ThemeProvider');
  return ctx;
}
