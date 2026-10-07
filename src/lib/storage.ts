/** On-device storage: downloaded files live under <documents>/books/<bookId>/. */
import { Directory, File, Paths } from 'expo-file-system';
import { getAudiobookTracks, pickTextFormat } from './catalog';
import { htmlToText, toParagraphs, stripGutenbergBoilerplate } from './text';
import type { SearchResult, Track } from './types';

function booksRoot(): Directory {
  const dir = new Directory(Paths.document, 'books');
  if (!dir.exists) dir.create({ intermediates: true, idempotent: true });
  return dir;
}

export function bookDir(bookId: string): Directory {
  const dir = new Directory(booksRoot(), bookId);
  if (!dir.exists) dir.create({ intermediates: true, idempotent: true });
  return dir;
}

export function deleteBookFiles(bookId: string) {
  const dir = new Directory(booksRoot(), bookId);
  if (dir.exists) dir.delete();
}

/** File-system-safe id from a search key such as "librivox:dracula_librivox". */
export function idFromKey(key: string): string {
  return key.replace(/[^a-zA-Z0-9_-]+/g, '_');
}

type Progress = (fraction: number) => void;

/** Download every chapter MP3 of a LibriVox audiobook, one after another. */
export async function downloadAudiobook(
  bookId: string,
  result: SearchResult,
  onProgress: Progress,
  signal?: AbortSignal
): Promise<Track[]> {
  const tracks = await getAudiobookTracks(result.sourceId, signal);
  const dir = bookDir(bookId);
  const done: Track[] = [];

  for (let i = 0; i < tracks.length; i++) {
    const track = tracks[i];
    const target = new File(dir, `${String(i + 1).padStart(3, '0')}.mp3`);
    if (!target.exists || target.size === 0) {
      await File.downloadFileAsync(track.url, target, {
        idempotent: true,
        signal,
        onProgress: ({ bytesWritten, totalBytes }) => {
          const part = totalBytes > 0 ? bytesWritten / totalBytes : 0;
          onProgress((i + part) / tracks.length);
        },
      });
    }
    done.push({ ...track, file: target.uri });
    onProgress((i + 1) / tracks.length);
  }
  return done;
}

/** Save already-extracted text as a book; returns the file URI and paragraph count. */
export function saveBookText(bookId: string, text: string): { textFile: string; chunks: number } {
  const paragraphs = toParagraphs(text);
  if (!paragraphs.length) throw new Error('No readable text was found in this book.');
  const file = new File(bookDir(bookId), 'book.txt');
  file.write(paragraphs.join('\n\n'));
  return { textFile: file.uri, chunks: paragraphs.length };
}

/** Download a Gutenberg ebook as plain text, ready for text-to-speech. */
export async function downloadEbook(
  bookId: string,
  result: SearchResult,
  onProgress: Progress,
  signal?: AbortSignal
): Promise<{ textFile: string; chunks: number }> {
  const format = pickTextFormat(result.formats ?? {});
  if (!format) throw new Error('This ebook has no plain-text edition.');
  onProgress(0.1);
  const res = await fetch(format.url, { signal });
  if (!res.ok) throw new Error(`Download failed (${res.status})`);
  let text = await res.text();
  onProgress(0.7);
  if (format.isHtml) text = htmlToText(text);
  text = stripGutenbergBoilerplate(text);
  const saved = saveBookText(bookId, text);
  onProgress(1);
  return saved;
}

/** Load the stored paragraphs of a text-to-speech book. Re-chunk with `chunkParagraphs` for synthesis. */
export async function loadBookParagraphs(textFile: string): Promise<string[]> {
  const text = await new File(textFile).text();
  return text.split('\n\n').filter(Boolean);
}
