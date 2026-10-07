/** Search LibriVox audiobooks and Gutenberg ebooks; each result says how it will be read. */
import { router } from 'expo-router';
import { memo, useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, SectionList, StyleSheet, Text, TextInput, View } from 'react-native';
import { MiniPlayer } from '@/components/MiniPlayer';
import { Button, Cover, KindBadge, ProgressBar } from '@/components/ui';
import { searchAudiobooks, searchEbooks } from '@/lib/catalog';
import { useLibrary } from '@/lib/library';
import { usePlayer } from '@/lib/player';
import { idFromKey } from '@/lib/storage';
import { colors, kindColor } from '@/lib/theme';
import type { BookKind, BookStatus, LibraryBook, SearchResult } from '@/lib/types';

type Filter = 'all' | BookKind;
type Action = 'download' | 'retry' | 'open';

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'audiobook', label: 'Audiobooks' },
  { value: 'tts', label: 'Text-to-speech' },
];

const SECTION_INFO: Record<BookKind, { title: string; note: string }> = {
  audiobook: { title: 'Audiobooks', note: 'Read by human volunteers · LibriVox' },
  tts: { title: 'Text-to-speech', note: 'Ebooks read aloud by your phone · Project Gutenberg' },
};

const SEARCHERS: Record<BookKind, (q: string, signal: AbortSignal) => Promise<SearchResult[]>> = {
  audiobook: searchAudiobooks,
  tts: searchEbooks,
};

const ERROR_TEXT: Record<BookKind, string> = {
  audiobook: 'Couldn’t reach LibriVox right now.',
  tts: 'Couldn’t reach Project Gutenberg right now.',
};

interface SourceState {
  results: SearchResult[];
  loading: boolean;
  error?: string;
}

const EMPTY: SourceState = { results: [], loading: false };

/**
 * One result row. Memoised and given only primitive props for its library state,
 * so a download progressing on one row doesn't re-render every other row.
 */
const ResultRow = memo(function ResultRow({
  item,
  status,
  progress,
  onAction,
}: {
  item: SearchResult;
  status?: BookStatus;
  progress: number;
  onAction: (item: SearchResult, action: Action) => void;
}) {
  let action: React.ReactNode;
  if (!status) action = <Button small label="Download" onPress={() => onAction(item, 'download')} />;
  else if (status === 'downloading')
    action = (
      <View style={{ width: 84, gap: 6, alignItems: 'center' }}>
        <Text style={styles.meta}>{Math.round(progress * 100)}%</Text>
        <ProgressBar value={progress} color={kindColor[item.kind]} />
      </View>
    );
  else if (status === 'error') action = <Button small variant="danger" label="Retry" onPress={() => onAction(item, 'retry')} />;
  else action = <Button small variant="ghost" label={item.kind === 'audiobook' ? 'Listen' : 'Read'} onPress={() => onAction(item, 'open')} />;

  return (
    <View style={styles.row}>
      <Cover uri={item.coverUrl} title={item.title} size={48} />
      <View style={{ flex: 1, gap: 4 }}>
        <KindBadge kind={item.kind} />
        <Text style={styles.title} numberOfLines={2}>{item.title}</Text>
        <Text style={styles.author} numberOfLines={1}>{item.author}</Text>
        <Text style={styles.meta}>
          {[item.runtime && `${item.runtime} long`, item.language?.toUpperCase()].filter(Boolean).join(' · ')}
        </Text>
      </View>
      {action}
    </View>
  );
});

export default function SearchScreen() {
  const library = useLibrary();
  const { open } = usePlayer();
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [sources, setSources] = useState<Record<BookKind, SourceState>>({ audiobook: EMPTY, tts: EMPTY });
  const [searched, setSearched] = useState('');
  const abortRef = useRef<AbortController | null>(null);

  // Keep the latest library in a ref so the row callback can stay stable.
  const libraryRef = useRef(library);
  libraryRef.current = library;

  const runSearch = useCallback(() => {
    const q = query.trim();
    if (!q) return;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setSearched(q);
    setSources({ audiobook: { results: [], loading: true }, tts: { results: [], loading: true } });

    // Each catalogue fills in its own section as soon as it answers.
    (Object.keys(SEARCHERS) as BookKind[]).forEach((kind) => {
      SEARCHERS[kind](q, controller.signal)
        .then((results) => {
          if (!controller.signal.aborted) setSources((s) => ({ ...s, [kind]: { results, loading: false } }));
        })
        .catch((e: Error) => {
          if (controller.signal.aborted) return;
          const detail = e.message?.includes('too long') ? `${ERROR_TEXT[kind]} It took too long to respond.` : ERROR_TEXT[kind];
          setSources((s) => ({ ...s, [kind]: { results: [], loading: false, error: detail } }));
        });
    });
  }, [query]);

  const onAction = useCallback(
    (item: SearchResult, action: Action) => {
      const lib = libraryRef.current;
      if (action === 'download') return lib.download(item);
      const book = lib.findByKey(item.key);
      if (!book) return;
      if (action === 'retry') return lib.retry(book.id);
      openBook(book);
    },
    [] // eslint-disable-line react-hooks/exhaustive-deps
  );

  const openBook = (book: LibraryBook) => {
    if (book.kind === 'audiobook') {
      open(book);
      router.push(`/listen/${book.id}`);
    } else {
      router.push(`/read/${book.id}`);
    }
  };

  // Library state per result key, so rows only re-render when their own book changes.
  const bookByKey = useMemo(() => new Map(library.books.map((b) => [b.id, b])), [library.books]);

  const sections = useMemo(() => {
    const kinds: BookKind[] = filter === 'all' ? ['audiobook', 'tts'] : [filter];
    return kinds.map((kind) => ({ kind, data: sources[kind].results }));
  }, [filter, sources]);

  return (
    <View style={styles.screen}>
      <View style={styles.searchBox}>
        <TextInput
          value={query}
          onChangeText={setQuery}
          onSubmitEditing={runSearch}
          placeholder="Search titles or authors, e.g. Sherlock Holmes"
          placeholderTextColor={colors.faint}
          returnKeyType="search"
          autoCorrect={false}
          style={styles.input}
        />
        <View style={styles.filters}>
          {FILTERS.map((f) => {
            const active = f.value === filter;
            const tint = f.value === 'all' ? colors.accent : kindColor[f.value];
            return (
              <Pressable
                key={f.value}
                onPress={() => setFilter(f.value)}
                style={[styles.chip, active && { backgroundColor: `${tint}26`, borderColor: tint }]}
              >
                <Text style={[styles.chipText, active && { color: tint }]}>{f.label}</Text>
              </Pressable>
            );
          })}
        </View>
      </View>

      {!searched ? (
        <View style={styles.empty}>
          <Text style={styles.emptyTitle}>Find something to listen to</Text>
          <Text style={styles.emptyText}>
            Results are labelled <Text style={{ color: colors.audiobook, fontWeight: '700' }}>Audiobook</Text> (human
            narration) or <Text style={{ color: colors.tts, fontWeight: '700' }}>Text-to-speech</Text> (an ebook read
            aloud by your phone). Everything downloads for offline listening.
          </Text>
          <Text style={[styles.emptyText, { marginTop: 12 }]}>
            The catalogue is public-domain books, so think classics: Austen, Dickens, Doyle, Shelley, Twain…
          </Text>
        </View>
      ) : (
        <SectionList
          sections={sections}
          keyExtractor={(item) => item.key}
          stickySectionHeadersEnabled={false}
          contentContainerStyle={{ paddingBottom: 24 }}
          keyboardDismissMode="on-drag"
          keyboardShouldPersistTaps="handled"
          initialNumToRender={8}
          windowSize={7}
          removeClippedSubviews
          extraData={bookByKey}
          renderSectionHeader={({ section }) => {
            const src = sources[section.kind];
            return (
              <View style={styles.sectionHeader}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Text style={[styles.sectionTitle, { color: kindColor[section.kind] }]}>
                    {SECTION_INFO[section.kind].title}
                    {src.loading ? '' : ` · ${section.data.length}`}
                  </Text>
                  {src.loading ? <ActivityIndicator size="small" color={kindColor[section.kind]} /> : null}
                </View>
                <Text style={styles.sectionNote}>{SECTION_INFO[section.kind].note}</Text>
                {src.error ? <Text style={styles.error}>{src.error}</Text> : null}
                {!src.loading && !src.error && section.data.length === 0 ? (
                  <Text style={styles.sectionNote}>No matches for “{searched}”.</Text>
                ) : null}
              </View>
            );
          }}
          renderItem={({ item }) => {
            const book = bookByKey.get(idFromKey(item.key));
            return <ResultRow item={item} status={book?.status} progress={book?.progress ?? 0} onAction={onAction} />;
          }}
        />
      )}
      <MiniPlayer />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg },
  searchBox: { paddingHorizontal: 16, paddingBottom: 8, gap: 10 },
  input: {
    backgroundColor: colors.surface,
    color: colors.text,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    borderWidth: 1,
    borderColor: colors.border,
  },
  filters: { flexDirection: 'row', gap: 8 },
  chip: { borderWidth: 1, borderColor: colors.border, borderRadius: 999, paddingHorizontal: 12, paddingVertical: 6 },
  chipText: { color: colors.muted, fontWeight: '600', fontSize: 13 },
  sectionHeader: { paddingHorizontal: 16, paddingTop: 18, paddingBottom: 6, gap: 2 },
  sectionTitle: { fontSize: 13, fontWeight: '800', textTransform: 'uppercase', letterSpacing: 0.8 },
  sectionNote: { color: colors.faint, fontSize: 12 },
  error: { color: colors.danger, fontSize: 13, marginTop: 4 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 16, paddingVertical: 10 },
  title: { color: colors.text, fontWeight: '700', fontSize: 15 },
  author: { color: colors.muted, fontSize: 13 },
  meta: { color: colors.faint, fontSize: 12 },
  empty: { padding: 24, paddingTop: 40 },
  emptyTitle: { color: colors.text, fontSize: 22, fontWeight: '800', marginBottom: 10 },
  emptyText: { color: colors.muted, fontSize: 15, lineHeight: 22 },
});
