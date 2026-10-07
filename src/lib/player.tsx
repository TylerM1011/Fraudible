/**
 * App-wide audiobook player. It lives at the root so playback carries on while
 * you browse other screens (and in the background, with lock-screen controls).
 *
 * Performance note: playback status ticks twice a second, so it lives in its own
 * context (usePlayerStatus). Screens that only need the controls (usePlayer) do
 * not re-render on every tick.
 */
import { setAudioModeAsync, useAudioPlayer, useAudioPlayerStatus, type AudioStatus } from 'expo-audio';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { stopReaderPlayback } from './audioFocus';
import { useLibrary } from './library';
import type { LibraryBook } from './types';

export const RATES = [0.8, 1, 1.25, 1.5, 1.75, 2];

interface PlayerControls {
  /** The book currently loaded in the player, if any. */
  book?: LibraryBook;
  trackIndex: number;
  rate: number;
  /** Load a downloaded audiobook, resuming from its saved position unless a track is given. */
  open: (book: LibraryBook, track?: number, seconds?: number) => void;
  toggle: () => void;
  pause: () => void;
  seekBy: (deltaSeconds: number) => void;
  seekTo: (seconds: number) => void;
  nextTrack: () => void;
  prevTrack: () => void;
  cycleRate: () => void;
}

const ControlsContext = createContext<PlayerControls | null>(null);
const StatusContext = createContext<AudioStatus | null>(null);

export function PlayerProvider({ children }: { children: React.ReactNode }) {
  const { books, update } = useLibrary();
  const player = useAudioPlayer(null, { updateInterval: 500 });
  const status = useAudioPlayerStatus(player);

  const [bookId, setBookId] = useState<string>();
  const [trackIndex, setTrackIndex] = useState(0);
  const [rate, setRate] = useState(1);
  const book = useMemo(() => (bookId ? books.find((b) => b.id === bookId) : undefined), [books, bookId]);

  // Latest values for callbacks, so the callbacks themselves never change identity.
  const live = useRef({ status, book, trackIndex, rate, bookId });
  live.current = { status, book, trackIndex, rate, bookId };
  const lastSaved = useRef(0);

  useEffect(() => {
    setAudioModeAsync({ playsInSilentMode: true, shouldPlayInBackground: true, interruptionMode: 'doNotMix' }).catch(() => {});
  }, []);

  const loadTrack = useCallback(
    async (b: LibraryBook, index: number, seconds: number, autoplay: boolean) => {
      const track = b.tracks?.[index];
      if (!track?.file) return;
      stopReaderPlayback(); // don't talk over the reader
      player.replace({ uri: track.file });
      setBookId(b.id);
      setTrackIndex(index);
      lastSaved.current = seconds;
      update(b.id, { audioPosition: { track: index, seconds } });
      if (seconds > 0) await player.seekTo(seconds).catch(() => {});
      player.shouldCorrectPitch = true;
      player.setPlaybackRate(live.current.rate);
      if (autoplay) player.play();
      try {
        player.setActiveForLockScreen(
          true,
          { title: track.title, artist: b.author, albumTitle: b.title, artworkUrl: b.coverUrl },
          { showSeekBackward: true, showSeekForward: true }
        );
      } catch {
        // Lock-screen controls aren't available on every platform/runtime.
      }
    },
    [player, update]
  );

  const open = useCallback(
    (b: LibraryBook, track?: number, seconds?: number) => {
      if (track === undefined && b.id === live.current.bookId) {
        if (!live.current.status.playing) player.play();
        return;
      }
      const index = track ?? b.audioPosition?.track ?? 0;
      const start = seconds ?? (track === undefined ? b.audioPosition?.seconds ?? 0 : 0);
      loadTrack(b, index, start, true);
    },
    [loadTrack, player]
  );

  // Advance to the next chapter when one finishes.
  useEffect(() => {
    const { book: b, trackIndex: i } = live.current;
    if (!status.didJustFinish || !b?.tracks) return;
    if (i + 1 < b.tracks.length) loadTrack(b, i + 1, 0, true);
    else update(b.id, { audioPosition: { track: 0, seconds: 0 } });
  }, [status.didJustFinish, loadTrack, update]);

  // Save the listening position every 15 seconds, and whenever playback pauses.
  useEffect(() => {
    const { bookId: id, trackIndex: i } = live.current;
    if (!id || !status.isLoaded) return;
    const t = status.currentTime;
    const moved = Math.abs(t - lastSaved.current);
    if (moved >= 15 || (!status.playing && moved >= 1)) {
      lastSaved.current = t;
      update(id, { audioPosition: { track: i, seconds: t } });
    }
  }, [status.currentTime, status.playing, status.isLoaded, update]);

  // expo-audio's pause() throws natively if nothing has been loaded into the player yet
  // (e.g. the reader calling audiobook.pause() before any audiobook was ever opened).
  const safePause = useCallback(() => {
    try {
      player.pause();
    } catch {
      // nothing loaded; already "paused"
    }
  }, [player]);

  const toggle = useCallback(() => {
    if (live.current.status.playing) safePause();
    else {
      stopReaderPlayback();
      player.play();
    }
  }, [player, safePause]);

  const pause = safePause;

  const seekTo = useCallback(
    (seconds: number) => {
      const max = live.current.status.duration || seconds;
      player.seekTo(Math.max(0, Math.min(seconds, max))).catch(() => {});
    },
    [player]
  );

  const seekBy = useCallback((delta: number) => seekTo(live.current.status.currentTime + delta), [seekTo]);

  const nextTrack = useCallback(() => {
    const { book: b, trackIndex: i, status: s } = live.current;
    if (b?.tracks && i + 1 < b.tracks.length) loadTrack(b, i + 1, 0, s.playing);
  }, [loadTrack]);

  const prevTrack = useCallback(() => {
    const { book: b, trackIndex: i, status: s } = live.current;
    if (!b) return;
    // Like most players: go to the start of this chapter first, then the previous one.
    if (s.currentTime > 5 || i === 0) seekTo(0);
    else loadTrack(b, i - 1, 0, s.playing);
  }, [loadTrack, seekTo]);

  const cycleRate = useCallback(() => {
    const next = RATES[(RATES.indexOf(live.current.rate) + 1) % RATES.length];
    setRate(next);
    player.shouldCorrectPitch = true;
    player.setPlaybackRate(next);
  }, [player]);

  const controls = useMemo<PlayerControls>(
    () => ({ book, trackIndex, rate, open, toggle, pause, seekBy, seekTo, nextTrack, prevTrack, cycleRate }),
    [book, trackIndex, rate, open, toggle, pause, seekBy, seekTo, nextTrack, prevTrack, cycleRate]
  );

  return (
    <ControlsContext.Provider value={controls}>
      <StatusContext.Provider value={status}>{children}</StatusContext.Provider>
    </ControlsContext.Provider>
  );
}

/** Player controls and the loaded book. Does not re-render on playback ticks. */
export function usePlayer(): PlayerControls {
  const ctx = useContext(ControlsContext);
  if (!ctx) throw new Error('usePlayer must be used inside PlayerProvider');
  return ctx;
}

/** Live playback status (position, playing, duration). Re-renders twice a second while playing. */
export function usePlayerStatus(): AudioStatus {
  const ctx = useContext(StatusContext);
  if (!ctx) throw new Error('usePlayerStatus must be used inside PlayerProvider');
  return ctx;
}

export function formatTime(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
}
