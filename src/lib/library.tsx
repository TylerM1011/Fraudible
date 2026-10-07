/** The user's library: downloaded books, download progress and listening positions. */
import AsyncStorage from '@react-native-async-storage/async-storage';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { deleteBookFiles, downloadAudiobook, downloadEbook, idFromKey, saveBookText } from './storage';
import type { LibraryBook, SearchResult } from './types';

const STORAGE_KEY = 'fraudible.library.v1';

interface LibraryContextValue {
  books: LibraryBook[];
  loaded: boolean;
  getBook: (id: string) => LibraryBook | undefined;
  /** Library entry for a search result, if it has been added. */
  findByKey: (key: string) => LibraryBook | undefined;
  download: (result: SearchResult) => void;
  retry: (id: string) => void;
  cancel: (id: string) => void;
  remove: (id: string) => void;
  update: (id: string, patch: Partial<LibraryBook>) => void;
  addImported: (input: { title: string; author?: string; text: string }) => LibraryBook;
}

const LibraryContext = createContext<LibraryContextValue | null>(null);

export function LibraryProvider({ children }: { children: React.ReactNode }) {
  const [books, setBooks] = useState<LibraryBook[]>([]);
  const [loaded, setLoaded] = useState(false);
  const controllers = useRef(new Map<string, AbortController>());

  // Load once at start-up. Anything still "downloading" was interrupted when the app closed.
  useEffect(() => {
    AsyncStorage.getItem(STORAGE_KEY)
      .then((raw) => {
        const saved: LibraryBook[] = raw ? JSON.parse(raw) : [];
        setBooks(
          saved.map((b) =>
            b.status === 'downloading' ? { ...b, status: 'error', error: 'Download interrupted. Tap to retry.' } : b
          )
        );
      })
      .catch(() => setBooks([]))
      .finally(() => setLoaded(true));
  }, []);

  // Persist changes, batched: download progress and listening positions change often,
  // and serialising the whole library on every tick was wasted work.
  // At most one write per second, always with the latest state.
  const latestBooks = useRef(books);
  latestBooks.current = books;
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (!loaded || saveTimer.current) return;
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(latestBooks.current)).catch(() => {});
    }, 1000);
  }, [books, loaded]);

  const update = useCallback((id: string, patch: Partial<LibraryBook>) => {
    setBooks((prev) => prev.map((b) => (b.id === id ? { ...b, ...patch } : b)));
  }, []);

  const run = useCallback(
    async (id: string, result: SearchResult) => {
      const controller = new AbortController();
      controllers.current.set(id, controller);
      let lastPct = -1;
      const onProgress = (fraction: number) => {
        const pct = Math.floor(fraction * 100);
        if (pct !== lastPct) {
          lastPct = pct;
          update(id, { progress: fraction });
        }
      };
      try {
        if (result.kind === 'audiobook') {
          const tracks = await downloadAudiobook(id, result, onProgress, controller.signal);
          update(id, { status: 'ready', progress: 1, tracks, error: undefined });
        } else {
          const { textFile, chunks } = await downloadEbook(id, result, onProgress, controller.signal);
          update(id, { status: 'ready', progress: 1, textFile, ttsChunks: chunks, error: undefined });
        }
      } catch (e) {
        const aborted = controller.signal.aborted;
        update(id, {
          status: 'error',
          error: aborted ? 'Download cancelled. Tap to retry.' : `${(e as Error).message || 'Download failed'}. Tap to retry.`,
        });
      } finally {
        controllers.current.delete(id);
      }
    },
    [update]
  );

  const download = useCallback(
    (result: SearchResult) => {
      const id = idFromKey(result.key);
      setBooks((prev) => {
        if (prev.some((b) => b.id === id)) return prev;
        const book: LibraryBook = {
          id,
          kind: result.kind,
          source: result.source,
          title: result.title,
          author: result.author,
          coverUrl: result.coverUrl,
          language: result.language,
          addedAt: Date.now(),
          status: 'downloading',
          progress: 0,
          origin: result,
        };
        return [book, ...prev];
      });
      run(id, result);
    },
    [run]
  );

  const retry = useCallback(
    (id: string) => {
      const book = books.find((b) => b.id === id);
      if (!book?.origin || controllers.current.has(id)) return;
      update(id, { status: 'downloading', progress: 0, error: undefined });
      run(id, book.origin);
    },
    [books, run, update]
  );

  const cancel = useCallback((id: string) => {
    controllers.current.get(id)?.abort();
  }, []);

  const remove = useCallback((id: string) => {
    controllers.current.get(id)?.abort();
    try {
      deleteBookFiles(id);
    } catch {
      // Files may already be gone; removing the entry is what matters.
    }
    setBooks((prev) => prev.filter((b) => b.id !== id));
  }, []);

  const addImported = useCallback((input: { title: string; author?: string; text: string }) => {
    const id = `import_${Date.now()}`;
    const { textFile, chunks } = saveBookText(id, input.text);
    const book: LibraryBook = {
      id,
      kind: 'tts',
      source: 'import',
      title: input.title,
      author: input.author || 'Imported',
      addedAt: Date.now(),
      status: 'ready',
      progress: 1,
      textFile,
      ttsChunks: chunks,
    };
    setBooks((prev) => [book, ...prev]);
    return book;
  }, []);

  const value = useMemo<LibraryContextValue>(
    () => ({
      books,
      loaded,
      getBook: (id) => books.find((b) => b.id === id),
      findByKey: (key) => books.find((b) => b.id === idFromKey(key)),
      download,
      retry,
      cancel,
      remove,
      update,
      addImported,
    }),
    [books, loaded, download, retry, cancel, remove, update, addImported]
  );

  return <LibraryContext.Provider value={value}>{children}</LibraryContext.Provider>;
}

export function useLibrary(): LibraryContextValue {
  const ctx = useContext(LibraryContext);
  if (!ctx) throw new Error('useLibrary must be used inside LibraryProvider');
  return ctx;
}
