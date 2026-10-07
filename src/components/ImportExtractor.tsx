/**
 * Pulls the text out of a PDF or EPUB the user already owns.
 *
 * React Native has no built-in PDF/EPUB text extraction, so this renders an
 * invisible WebView running pdf.js / JSZip. The libraries load from a CDN, so
 * importing needs a connection once; the extracted text is stored on the device
 * and is read aloud offline afterwards.
 */
import { useRef } from 'react';
import { View } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

export interface ExtractJob {
  base64: string;
  type: 'pdf' | 'epub';
  fileName: string;
}

export interface ExtractResult {
  text: string;
  title?: string;
  author?: string;
}

interface Props {
  job: ExtractJob;
  onProgress: (fraction: number) => void;
  onDone: (result: ExtractResult) => void;
  onError: (message: string) => void;
}

const HTML = `<!doctype html><html><head><meta charset="utf-8">
<script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
</head><body><script>
function send(msg) { window.ReactNativeWebView.postMessage(JSON.stringify(msg)); }

function b64ToBytes(b64) {
  var bin = atob(b64), bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function extractPdf(b64) {
  pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
  var pdf = await pdfjsLib.getDocument({ data: b64ToBytes(b64) }).promise;
  var meta = {};
  try { meta = (await pdf.getMetadata()).info || {}; } catch (e) {}
  var pages = [];
  for (var p = 1; p <= pdf.numPages; p++) {
    var content = await (await pdf.getPage(p)).getTextContent();
    var lines = [], line = '', lastY = null;
    content.items.forEach(function (item) {
      var y = item.transform ? item.transform[5] : null;
      if (lastY !== null && y !== null && Math.abs(y - lastY) > 2 && line) { lines.push(line); line = ''; }
      line += item.str;
      if (item.hasEOL) { lines.push(line); line = ''; }
      lastY = y;
    });
    if (line) lines.push(line);
    pages.push(lines.join('\\n'));
    send({ type: 'progress', value: p / pdf.numPages });
  }
  return { text: pages.join('\\n\\n'), title: meta.Title, author: meta.Author };
}

function resolvePath(base, href) {
  var parts = (base ? base + '/' + href : href).split('/'), out = [];
  parts.forEach(function (s) { if (s === '..') out.pop(); else if (s && s !== '.') out.push(s); });
  return out.join('/');
}

async function extractEpub(b64) {
  var zip = await JSZip.loadAsync(b64, { base64: true });
  var parser = new DOMParser();
  var container = parser.parseFromString(await zip.file('META-INF/container.xml').async('string'), 'application/xml');
  var opfPath = container.getElementsByTagName('rootfile')[0].getAttribute('full-path');
  var opfDir = opfPath.indexOf('/') >= 0 ? opfPath.slice(0, opfPath.lastIndexOf('/')) : '';
  var opf = parser.parseFromString(await zip.file(opfPath).async('string'), 'application/xml');

  var byTag = function (doc, name) { return doc.getElementsByTagNameNS('*', name)[0]; };
  var title = byTag(opf, 'title'), creator = byTag(opf, 'creator');

  var manifest = {};
  Array.prototype.forEach.call(opf.getElementsByTagNameNS('*', 'item'), function (item) {
    manifest[item.getAttribute('id')] = item.getAttribute('href');
  });
  var spine = Array.prototype.map.call(opf.getElementsByTagNameNS('*', 'itemref'), function (ref) {
    return manifest[ref.getAttribute('idref')];
  }).filter(Boolean);

  var chapters = [];
  for (var i = 0; i < spine.length; i++) {
    var path = resolvePath(opfDir, decodeURIComponent(spine[i].split('#')[0]));
    var entry = zip.file(path);
    if (!entry) continue;
    var doc = parser.parseFromString(await entry.async('string'), 'text/html');
    doc.querySelectorAll('script,style').forEach(function (el) { el.remove(); });
    doc.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote,div,br,tr').forEach(function (el) {
      el.appendChild(doc.createTextNode('\\n\\n'));
    });
    chapters.push(doc.body ? doc.body.textContent : '');
    send({ type: 'progress', value: (i + 1) / spine.length });
  }
  return {
    text: chapters.join('\\n\\n'),
    title: title ? title.textContent : undefined,
    author: creator ? creator.textContent : undefined,
  };
}

window.__extract = async function (b64, type) {
  try {
    var result = type === 'pdf' ? await extractPdf(b64) : await extractEpub(b64);
    send({ type: 'done', text: result.text, title: result.title, author: result.author });
  } catch (e) {
    send({ type: 'error', message: String((e && e.message) || e) });
  }
};

function waitForLibs() {
  if (window.pdfjsLib && window.JSZip) send({ type: 'ready' });
  else if (Date.now() - start > 20000) send({ type: 'error', message: 'Could not load the reader libraries. Check your connection and try again.' });
  else setTimeout(waitForLibs, 100);
}
var start = Date.now();
waitForLibs();
</script></body></html>`;

export function ImportExtractor({ job, onProgress, onDone, onError }: Props) {
  const ref = useRef<WebView>(null);
  const started = useRef(false);

  const onMessage = (event: WebViewMessageEvent) => {
    let msg: { type: string; value?: number; text?: string; title?: string; author?: string; message?: string };
    try {
      msg = JSON.parse(event.nativeEvent.data);
    } catch {
      return;
    }
    if (msg.type === 'ready' && !started.current) {
      started.current = true;
      ref.current?.injectJavaScript(`window.__extract(${JSON.stringify(job.base64)}, ${JSON.stringify(job.type)}); true;`);
    } else if (msg.type === 'progress') {
      onProgress(msg.value ?? 0);
    } else if (msg.type === 'done') {
      onDone({ text: msg.text ?? '', title: msg.title?.trim() || undefined, author: msg.author?.trim() || undefined });
    } else if (msg.type === 'error') {
      onError(msg.message ?? 'Could not read this file.');
    }
  };

  return (
    <View style={{ width: 0, height: 0, overflow: 'hidden' }} pointerEvents="none">
      <WebView
        ref={ref}
        source={{ html: HTML, baseUrl: 'https://localhost/' }}
        originWhitelist={['*']}
        javaScriptEnabled
        onMessage={onMessage}
        onError={() => onError('Could not start the file reader.')}
        style={{ width: 1, height: 1 }}
      />
    </View>
  );
}
