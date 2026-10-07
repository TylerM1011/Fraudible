/**
 * Search across free, legal catalogues:
 *  - LibriVox (via the Internet Archive) for human-narrated public-domain audiobooks
 *  - Project Gutenberg (via the Gutendex API) for public-domain ebooks read aloud with text-to-speech
 */
import type { SearchResult, Track } from './types';

const ARCHIVE = 'https://archive.org';
const GUTENDEX = 'https://gutendex.com/books/';

function first(value: unknown): string | undefined {
  if (Array.isArray(value)) return value.length ? String(value[0]) : undefined;
  return value == null ? undefined : String(value);
}

/** Strip characters that have meaning in Lucene query syntax. */
function cleanQuery(q: string): string {
  return q.replace(/[\\+\-!(){}\[\]^"~*?:/&|]/g, ' ').replace(/\s+/g, ' ').trim();
}

/** Gutenberg stores names as "Stoker, Bram"; show them as "Bram Stoker". */
function displayName(name: string): string {
  const parts = name.split(',').map((p) => p.trim());
  return parts.length === 2 && parts[1] ? `${parts[1]} ${parts[0]}` : name;
}

const LANG_CODES: Record<string, string> = {
  english: 'en', french: 'fr', german: 'de', spanish: 'es', italian: 'it',
  dutch: 'nl', portuguese: 'pt', russian: 'ru', chinese: 'zh', japanese: 'ja',
};

const TIMEOUT_MS = 20000;
const cache = new Map<string, unknown>();

/** Fetch JSON with a timeout, cancellation, and an in-memory cache for repeat searches. */
async function getJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  if (cache.has(url)) return cache.get(url) as T;
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  signal?.addEventListener('abort', onAbort);
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { Accept: 'application/json' } });
    if (!res.ok) throw new Error(`Request failed (${res.status})`);
    const data = (await res.json()) as T;
    cache.set(url, data);
    return data;
  } catch (e) {
    if (timedOut) throw new Error('The catalogue took too long to respond');
    throw e;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }
}

// ---------- LibriVox audiobooks ----------

interface ArchiveSearchResponse {
  response: {
    docs: {
      identifier: string;
      title?: string | string[];
      creator?: string | string[];
      runtime?: string | string[];
      language?: string | string[];
      downloads?: number;
    }[];
  };
}

export async function searchAudiobooks(query: string, signal?: AbortSignal): Promise<SearchResult[]> {
  const q = cleanQuery(query);
  if (!q) return [];
  const params = new URLSearchParams();
  params.set('q', `collection:librivoxaudio AND mediatype:audio AND (${q})`);
  for (const f of ['identifier', 'title', 'creator', 'runtime', 'language', 'downloads']) params.append('fl[]', f);
  params.append('sort[]', 'downloads desc');
  params.set('rows', '25');
  params.set('output', 'json');

  const data = await getJson<ArchiveSearchResponse>(`${ARCHIVE}/advancedsearch.php?${params}`, signal);
  return data.response.docs.map((d) => {
    const lang = first(d.language)?.toLowerCase();
    return {
      key: `librivox:${d.identifier}`,
      kind: 'audiobook' as const,
      source: 'librivox' as const,
      sourceId: d.identifier,
      title: (first(d.title) ?? d.identifier).replace(/\s*\(LibriVox\)\s*$/i, ''),
      author: first(d.creator) ?? 'Unknown',
      coverUrl: `${ARCHIVE}/services/img/${encodeURIComponent(d.identifier)}`,
      language: lang ? LANG_CODES[lang] ?? lang.slice(0, 2) : undefined,
      runtime: first(d.runtime),
      downloads: d.downloads,
    };
  });
}

interface ArchiveMetadata {
  files?: {
    name: string;
    format?: string;
    title?: string;
    track?: string;
    length?: string;
    source?: string;
  }[];
}

function parseLength(length?: string): number | undefined {
  if (!length) return undefined;
  if (length.includes(':')) {
    return length.split(':').map(Number).reduce((acc, n) => acc * 60 + n, 0);
  }
  const n = Number(length);
  return Number.isFinite(n) ? n : undefined;
}

function trackNumber(track?: string): number {
  const n = parseInt((track ?? '').split('/')[0], 10);
  return Number.isFinite(n) ? n : Number.MAX_SAFE_INTEGER;
}

/** List the chapter MP3s of a LibriVox item, preferring the smaller 64kbps encodes. */
export async function getAudiobookTracks(identifier: string, signal?: AbortSignal): Promise<Track[]> {
  const meta = await getJson<ArchiveMetadata>(`${ARCHIVE}/metadata/${encodeURIComponent(identifier)}`, signal);
  const files = meta.files ?? [];
  let mp3s = files.filter((f) => f.format === '64Kbps MP3');
  if (!mp3s.length) mp3s = files.filter((f) => f.format === 'VBR MP3' || f.format === '128Kbps MP3');
  if (!mp3s.length) mp3s = files.filter((f) => f.name.toLowerCase().endsWith('.mp3'));
  if (!mp3s.length) throw new Error('No MP3 files found for this audiobook.');

  mp3s.sort((a, b) => trackNumber(a.track) - trackNumber(b.track) || a.name.localeCompare(b.name));

  return mp3s.map((f, i) => ({
    title: f.title?.trim() || `Chapter ${i + 1}`,
    url: `${ARCHIVE}/download/${encodeURIComponent(identifier)}/${f.name.split('/').map(encodeURIComponent).join('/')}`,
    duration: parseLength(f.length),
  }));
}

/**
 * The Internet Archive publishes a .torrent for every item, LibriVox included.
 * Offered as an alternative for people who prefer to fetch the files with a torrent client.
 */
export function audiobookTorrentUrl(identifier: string): string {
  const id = encodeURIComponent(identifier);
  return `${ARCHIVE}/download/${id}/${id}_archive.torrent`;
}

// ---------- Gutenberg ebooks (text-to-speech) ----------

interface GutendexResponse {
  results: {
    id: number;
    title: string;
    authors: { name: string }[];
    languages: string[];
    copyright: boolean | null;
    media_type: string;
    formats: Record<string, string>;
    download_count: number;
  }[];
}

/** Pick the best format we can turn into plain text. */
export function pickTextFormat(formats: Record<string, string>): { url: string; isHtml: boolean } | undefined {
  const entries = Object.entries(formats).filter(([, url]) => !url.endsWith('.zip'));
  const plain =
    entries.find(([type]) => type.startsWith('text/plain') && type.includes('utf-8')) ??
    entries.find(([type]) => type.startsWith('text/plain'));
  if (plain) return { url: plain[1], isHtml: false };
  const html = entries.find(([type]) => type.startsWith('text/html'));
  if (html) return { url: html[1], isHtml: true };
  return undefined;
}

export async function searchEbooks(query: string, signal?: AbortSignal): Promise<SearchResult[]> {
  const q = query.trim();
  if (!q) return [];
  const data = await getJson<GutendexResponse>(`${GUTENDEX}?search=${encodeURIComponent(q)}`, signal);
  return data.results
    .filter((b) => b.media_type === 'Text' && b.copyright !== true && pickTextFormat(b.formats))
    .slice(0, 25)
    .map((b) => ({
      key: `gutenberg:${b.id}`,
      kind: 'tts' as const,
      source: 'gutenberg' as const,
      sourceId: String(b.id),
      title: b.title,
      author: b.authors.length ? b.authors.map((a) => displayName(a.name)).join(', ') : 'Unknown',
      coverUrl: b.formats['image/jpeg'],
      language: b.languages[0],
      downloads: b.download_count,
      formats: b.formats,
    }));
}
