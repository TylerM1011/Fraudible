/**
 * Lets the audiobook player and the Kokoro reader stop each other,
 * so two things never talk at once.
 */
let stopReader: (() => void) | null = null;

/** The reader registers how to stop itself; returns an unregister function. */
export function registerReader(stop: () => void): () => void {
  stopReader = stop;
  return () => {
    if (stopReader === stop) stopReader = null;
  };
}

/** Called by the audiobook player before it starts playing. */
export function stopReaderPlayback() {
  stopReader?.();
}
