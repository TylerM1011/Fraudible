/**
 * Kokoro on-device text-to-speech (via react-native-executorch).
 *
 * The voice model is downloaded once (~330 MB) and cached on the phone; after
 * that everything runs offline. One engine is loaded at a time, for either the
 * British or American voice pack (they share the large model file).
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import {
  createKokoroTextToSpeech,
  download,
  models,
  type KokoroTextToSpeech,
  type KokoroTtsModel,
} from 'react-native-executorch';

export type VoicePack = 'EN_GB' | 'EN_US';

export interface KokoroVoice {
  id: string;
  name: string;
  accent: 'British' | 'American';
  gender: 'Female' | 'Male';
  pack: VoicePack;
}

export const KOKORO_VOICES: KokoroVoice[] = [
  { id: 'bf_emma', name: 'Emma', accent: 'British', gender: 'Female', pack: 'EN_GB' },
  { id: 'bm_daniel', name: 'Daniel', accent: 'British', gender: 'Male', pack: 'EN_GB' },
  { id: 'af_heart', name: 'Heart', accent: 'American', gender: 'Female', pack: 'EN_US' },
  { id: 'af_sarah', name: 'Sarah', accent: 'American', gender: 'Female', pack: 'EN_US' },
  { id: 'af_river', name: 'River', accent: 'American', gender: 'Female', pack: 'EN_US' },
  { id: 'am_michael', name: 'Michael', accent: 'American', gender: 'Male', pack: 'EN_US' },
  { id: 'am_adam', name: 'Adam', accent: 'American', gender: 'Male', pack: 'EN_US' },
];

/** British voice for phones set to UK English, otherwise American. */
export function defaultVoiceId(): string {
  try {
    const locale = Intl.DateTimeFormat().resolvedOptions().locale.toLowerCase();
    if (locale.startsWith('en-gb') || locale.startsWith('en-ie') || locale.startsWith('en-au') || locale.startsWith('en-nz')) {
      return 'bf_emma';
    }
  } catch {
    // fall through
  }
  return 'af_heart';
}

export function findVoice(id?: string): KokoroVoice {
  return KOKORO_VOICES.find((v) => v.id === id) ?? KOKORO_VOICES.find((v) => v.id === defaultVoiceId())!;
}

export const VOICE_DOWNLOAD_SIZE = '≈330 MB';

const downloadedKey = (pack: VoicePack) => `fraudible.kokoro.downloaded.${pack}`;

type EngineStatus = 'idle' | 'downloading' | 'loading' | 'ready' | 'error';

interface KokoroContextValue {
  status: EngineStatus;
  /** 0..1 while downloading. */
  progress: number;
  error?: string;
  /** Which voice pack is loaded (or loading). */
  pack?: VoicePack;
  /** Whether a pack's files have been downloaded before. */
  isDownloaded: (pack: VoicePack) => boolean;
  /** Download (if needed) and load a voice pack. Resolves with the engine. */
  ensure: (pack: VoicePack) => Promise<KokoroTextToSpeech<string>>;
  cancelDownload: () => void;
}

const KokoroContext = createContext<KokoroContextValue | null>(null);

export function KokoroProvider({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<EngineStatus>('idle');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string>();
  const [pack, setPack] = useState<VoicePack>();
  const [downloaded, setDownloaded] = useState<Record<VoicePack, boolean>>({ EN_GB: false, EN_US: false });

  const engine = useRef<{ pack: VoicePack; tts: KokoroTextToSpeech<string> } | null>(null);
  const pending = useRef<{ pack: VoicePack; promise: Promise<KokoroTextToSpeech<string>> } | null>(null);
  const abort = useRef<AbortController | null>(null);

  useEffect(() => {
    Promise.all((['EN_GB', 'EN_US'] as VoicePack[]).map((p) => AsyncStorage.getItem(downloadedKey(p))))
      .then(([gb, us]) => setDownloaded({ EN_GB: gb === '1', EN_US: us === '1' }))
      .catch(() => {});
    return () => engine.current?.tts.dispose();
  }, []);

  const ensure = useCallback((wanted: VoicePack) => {
    if (engine.current?.pack === wanted) return Promise.resolve(engine.current.tts);
    if (pending.current?.pack === wanted) return pending.current.promise;

    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;

    const promise = (async () => {
      setPack(wanted);
      setError(undefined);
      setProgress(0);
      setStatus('downloading');
      try {
        const config = models.textToSpeech.KOKORO[wanted].DEFAULT as KokoroTtsModel<string>;
        let lastPct = -1;
        const local = await download(config, {
          signal: controller.signal,
          onProgress: (p) => {
            const pct = Math.floor(p * 100);
            if (pct !== lastPct) {
              lastPct = pct;
              setProgress(p);
            }
          },
        });
        AsyncStorage.setItem(downloadedKey(wanted), '1').catch(() => {});
        setDownloaded((d) => ({ ...d, [wanted]: true }));

        setStatus('loading');
        const tts = await createKokoroTextToSpeech(local);
        engine.current?.tts.dispose();
        engine.current = { pack: wanted, tts };
        setStatus('ready');
        return tts;
      } catch (e) {
        const message = controller.signal.aborted ? 'Download cancelled.' : (e as Error).message || 'Could not load the voice.';
        setError(message);
        setStatus('error');
        throw new Error(message);
      } finally {
        if (pending.current?.pack === wanted) pending.current = null;
      }
    })();

    pending.current = { pack: wanted, promise };
    return promise;
  }, []);

  const cancelDownload = useCallback(() => abort.current?.abort(), []);

  const value = useMemo<KokoroContextValue>(
    () => ({
      status,
      progress,
      error,
      pack,
      isDownloaded: (p) => downloaded[p],
      ensure,
      cancelDownload,
    }),
    [status, progress, error, pack, downloaded, ensure, cancelDownload]
  );

  return <KokoroContext.Provider value={value}>{children}</KokoroContext.Provider>;
}

export function useKokoro(): KokoroContextValue {
  const ctx = useContext(KokoroContext);
  if (!ctx) throw new Error('useKokoro must be used inside KokoroProvider');
  return ctx;
}
