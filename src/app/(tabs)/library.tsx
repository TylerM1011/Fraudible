/** Downloaded books, download progress, and importing your own PDF/EPUB/TXT files. */
import * as DocumentPicker from 'expo-document-picker';
import { File } from 'expo-file-system';
import { router } from 'expo-router';
import { memo, useCallback, useRef, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { ImportExtractor, type ExtractJob, type ExtractResult } from '@/components/ImportExtractor';
import { MiniPlayer } from '@/components/MiniPlayer';
import { Button, Cover, KindBadge, ProgressBar } from '@/components/ui';
import { useLibrary } from '@/lib/library';
import { formatTime, usePlayer } from '@/lib/player';
import { colors, kindColor } from '@/lib/theme';
import type { LibraryBook } from '@/lib/types';

function titleFromFileName(name: string): string {
  return name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ').trim() || 'Imported book';
}

function statusLine(book: LibraryBook): string {
  if (book.status === 'downloading') return `Downloading… ${Math.round(book.progress * 100)}%`;
  if (book.status === 'error') return book.error ?? 'Download failed. Tap to retry.';
  if (book.kind === 'audiobook') {
    const count = book.tracks?.length ?? 0;
    const pos = book.audioPosition;
    const where = pos && (pos.track > 0 || pos.seconds > 5) ? ` · Chapter ${pos.track + 1}, ${formatTime(pos.seconds)}` : '';
    return `${count} chapters${where}`;
  }
  const total = book.ttsChunks ?? 0;
  const at = book.ttsPosition ?? 0;
  return total ? `${Math.round((at / total) * 100)}% read` : 'Ready';
}

/** Memoised: a progressing download only re-renders its own row. */
const LibraryRow = memo(function LibraryRow({
  book,
  onPress,
  onLongPress,
}: {
  book: LibraryBook;
  onPress: (book: LibraryBook) => void;
  onLongPress: (book: LibraryBook) => void;
}) {
  return (
    <Pressable
      onPress={() => onPress(book)}
      onLongPress={() => onLongPress(book)}
      style={({ pressed }) => [styles.row, pressed && { backgroundColor: colors.surface }]}
    >
      <Cover uri={book.coverUrl} title={book.title} size={52} />
      <View style={{ flex: 1, gap: 4 }}>
        <KindBadge kind={book.kind} />
        <Text style={styles.title} numberOfLines={2}>{book.title}</Text>
        <Text style={styles.author} numberOfLines={1}>{book.author}</Text>
        <Text style={[styles.meta, book.status === 'error' && { color: colors.danger }]} numberOfLines={2}>
          {statusLine(book)}
        </Text>
        {book.status === 'downloading' ? <ProgressBar value={book.progress} color={kindColor[book.kind]} /> : null}
      </View>
    </Pressable>
  );
});

export default function LibraryScreen() {
  const library = useLibrary();
  const player = usePlayer();
  const [job, setJob] = useState<ExtractJob | null>(null);
  const [importProgress, setImportProgress] = useState(0);
  const [importing, setImporting] = useState(false);

  const finishImport = (result: ExtractResult, fileName: string) => {
    try {
      const book = library.addImported({
        title: result.title || titleFromFileName(fileName),
        author: result.author,
        text: result.text,
      });
      router.push(`/read/${book.id}`);
    } catch (e) {
      Alert.alert('Import failed', (e as Error).message);
    } finally {
      setJob(null);
      setImporting(false);
    }
  };

  const pickFile = async () => {
    const picked = await DocumentPicker.getDocumentAsync({
      type: ['application/pdf', 'application/epub+zip', 'text/plain'],
      copyToCacheDirectory: true,
    });
    if (picked.canceled || !picked.assets?.length) return;
    const asset = picked.assets[0];
    const lower = asset.name.toLowerCase();
    const type = lower.endsWith('.pdf') || asset.mimeType === 'application/pdf'
      ? 'pdf'
      : lower.endsWith('.epub') || asset.mimeType === 'application/epub+zip'
        ? 'epub'
        : 'txt';

    setImporting(true);
    setImportProgress(0);
    try {
      const file = new File(asset.uri);
      if (type === 'txt') {
        finishImport({ text: await file.text() }, asset.name);
      } else {
        setJob({ base64: await file.base64(), type, fileName: asset.name });
      }
    } catch (e) {
      setImporting(false);
      Alert.alert('Import failed', (e as Error).message);
    }
  };

  const onPressBook = (book: LibraryBook) => {
    if (book.status === 'error') return library.retry(book.id);
    if (book.status !== 'ready') return;
    if (book.kind === 'audiobook') {
      player.open(book);
      router.push(`/listen/${book.id}`);
    } else {
      router.push(`/read/${book.id}`);
    }
  };

  const onLongPressBook = (book: LibraryBook) => {
    const actions: { text: string; style?: 'cancel' | 'destructive'; onPress?: () => void }[] = [];
    if (book.status === 'downloading') actions.push({ text: 'Cancel download', onPress: () => library.cancel(book.id) });
    actions.push({
      text: 'Delete from device',
      style: 'destructive',
      onPress: () => {
        if (player.book?.id === book.id) player.pause();
        library.remove(book.id);
      },
    });
    actions.push({ text: 'Keep', style: 'cancel' });
    Alert.alert(book.title, 'This removes the downloaded files from your phone.', actions);
  };

  // Stable row handlers that always use the latest state.
  const handlers = useRef({ onPressBook, onLongPressBook });
  handlers.current = { onPressBook, onLongPressBook };
  const onRowPress = useCallback((b: LibraryBook) => handlers.current.onPressBook(b), []);
  const onRowLongPress = useCallback((b: LibraryBook) => handlers.current.onLongPressBook(b), []);

  const sorted = [...library.books].sort((a, b) => b.addedAt - a.addedAt);

  return (
    <View style={styles.screen}>
      <View style={styles.header}>
        <Text style={styles.headerText}>
          {library.books.length} {library.books.length === 1 ? 'book' : 'books'} on this device
        </Text>
        <Button small variant="ghost" label="+ Import PDF / EPUB" onPress={pickFile} disabled={importing} />
      </View>

      {importing ? (
        <View style={styles.importing}>
          <ActivityIndicator color={colors.tts} />
          <View style={{ flex: 1, gap: 6 }}>
            <Text style={styles.meta}>Extracting text… {Math.round(importProgress * 100)}%</Text>
            <ProgressBar value={importProgress} color={colors.tts} />
          </View>
        </View>
      ) : null}

      {job ? (
        <ImportExtractor
          job={job}
          onProgress={setImportProgress}
          onDone={(result) => finishImport(result, job.fileName)}
          onError={(message) => {
            setJob(null);
            setImporting(false);
            Alert.alert('Import failed', message);
          }}
        />
      ) : null}

      <FlatList
        data={sorted}
        keyExtractor={(b) => b.id}
        contentContainerStyle={{ paddingBottom: 24, flexGrow: 1 }}
        ListEmptyComponent={
          library.loaded ? (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>Nothing here yet</Text>
              <Text style={styles.emptyText}>
                Download a book from Search, or import a PDF, EPUB or text file you own to have it read aloud.
              </Text>
            </View>
          ) : null
        }
        renderItem={({ item }) => <LibraryRow book={item} onPress={onRowPress} onLongPress={onRowLongPress} />}
      />
      {library.books.length > 0 ? <Text style={styles.hint}>Long-press a book to delete it.</Text> : null}
      <MiniPlayer />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 8 },
  headerText: { color: colors.muted, fontSize: 13 },
  importing: { flexDirection: 'row', alignItems: 'center', gap: 12, marginHorizontal: 16, marginBottom: 8, padding: 12, borderRadius: 12, backgroundColor: colors.surface },
  row: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 16, paddingVertical: 10 },
  title: { color: colors.text, fontWeight: '700', fontSize: 15 },
  author: { color: colors.muted, fontSize: 13 },
  meta: { color: colors.faint, fontSize: 12 },
  hint: { color: colors.faint, fontSize: 11, textAlign: 'center', paddingVertical: 6 },
  empty: { padding: 24, paddingTop: 40 },
  emptyTitle: { color: colors.text, fontSize: 22, fontWeight: '800', marginBottom: 10 },
  emptyText: { color: colors.muted, fontSize: 15, lineHeight: 22 },
});
