/** Text clean-up and chunking for text-to-speech. */

/** Max characters per utterance. Android's engine refuses anything over ~4000, and shorter chunks make pausing/skipping feel snappier. */
export const MAX_CHUNK = 1000;

/** Remove the Project Gutenberg licence header and footer, keeping only the book itself. */
export function stripGutenbergBoilerplate(text: string): string {
  const start = text.search(/\*{3}\s*START OF (THE|THIS) PROJECT GUTENBERG E-?BOOK[^*]*\*{3}/i);
  let body = text;
  if (start >= 0) {
    const afterStart = text.indexOf('***', start + 3);
    body = text.slice(afterStart + 3);
  }
  const end = body.search(/\*{3}\s*END OF (THE|THIS) PROJECT GUTENBERG E-?BOOK/i);
  if (end >= 0) body = body.slice(0, end);
  return body;
}

/** Very small HTML-to-text converter, used when only an HTML edition is available. */
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|h[1-6]|li|blockquote|tr|section|article)>/gi, '\n\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;|&rsquo;|&lsquo;/g, "'")
    .replace(/&rdquo;|&ldquo;/g, '"')
    .replace(/&mdash;/g, '—')
    .replace(/&ndash;/g, '–')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));
}

/**
 * Kokoro's native phonemizer parses digit runs with `std::stoi`, which throws
 * ("stoi: out of range") on anything over ~10 digits and aborts synthesis entirely.
 * PDF text extraction often loses the whitespace between visually separate numbers
 * (page numbers, table cells, serial numbers), so break up long runs defensively.
 */
function breakLongDigitRuns(text: string): string {
  return text.replace(/\d{7,}/g, (run) => run.replace(/(\d{3})(?=\d)/g, '$1 '));
}

/**
 * Turn raw text into clean paragraphs: hard-wrapped lines are joined,
 * blank lines separate paragraphs, decorative lines are dropped.
 */
export function toParagraphs(text: string): string[] {
  return text
    .replace(/\r\n?/g, '\n')
    .split(/\n[ \t]*\n+/)
    .map((p) =>
      p
        .replace(/-\n(?=[a-z])/g, '') // re-join words hyphenated across lines
        .replace(/\s*\n\s*/g, ' ')
        .replace(/_/g, '') // Gutenberg marks italics with underscores
        .replace(/\s+/g, ' ')
        .trim()
    )
    .map(breakLongDigitRuns)
    // Drop separator lines such as "* * *" that contain no letters or digits.
    .filter((p) => /[A-Za-z0-9À-￿]/.test(p));
}

function splitSentences(paragraph: string): string[] {
  const parts = paragraph.match(/[^.!?…]+(?:[.!?…]+["'”’)\]]*|$)\s*/g);
  return parts ? parts.map((s) => s.trim()).filter(Boolean) : [paragraph];
}

function hardSplit(sentence: string, max: number): string[] {
  const out: string[] = [];
  let current = '';
  for (const word of sentence.split(' ')) {
    if (current && current.length + word.length + 1 > max) {
      out.push(current);
      current = word;
    } else {
      current = current ? `${current} ${word}` : word;
    }
  }
  if (current) out.push(current);
  return out;
}

/** A speakable unit for the TTS engine, tagged with the paragraph it was split from. */
export interface Chunk {
  text: string;
  /** Index into the paragraph array. Several chunks can share one paragraph when it was split. */
  paragraph: number;
}

/**
 * Split paragraphs into speakable chunks of at most `max` characters, tagging each
 * with its source paragraph so playback/skip can stay at paragraph granularity even
 * when a long paragraph had to be split into several chunks for synthesis.
 * Deterministic, so a saved paragraph index always points at the same place.
 */
export function chunkParagraphs(paragraphs: string[], max = MAX_CHUNK): Chunk[] {
  const chunks: Chunk[] = [];
  paragraphs.forEach((p, paragraph) => {
    if (p.length <= max) {
      chunks.push({ text: p, paragraph });
      return;
    }
    let current = '';
    for (const sentence of splitSentences(p)) {
      const pieces = sentence.length > max ? hardSplit(sentence, max) : [sentence];
      for (const piece of pieces) {
        if (current && current.length + piece.length + 1 > max) {
          chunks.push({ text: current, paragraph });
          current = piece;
        } else {
          current = current ? `${current} ${piece}` : piece;
        }
      }
    }
    if (current) chunks.push({ text: current, paragraph });
  });
  return chunks;
}
