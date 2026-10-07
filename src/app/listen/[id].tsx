/** Full audiobook player: chapters, seeking, speed, and the torrent link for LibriVox items. */
import { Stack, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { FlatList, Pressable, Share, StyleSheet, Text, View, type LayoutChangeEvent } from 'react-native';
import { Cover, RoundButton } from '@/components/ui';
import { audiobookTorrentUrl } from '@/lib/catalog';
import { useLibrary } from '@/lib/library';
import { formatTime, usePlayer, usePlayerStatus } from '@/lib/player';
import { colors, glyph } from '@/lib/theme';

export default function ListenScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { getBook } = useLibrary();
  const p = usePlayer();
  const status = usePlayerStatus();
  const book = getBook(id);
  const [barWidth, setBarWidth] = useState(1);

  // Opened directly (e.g. from a deep link): load this book.
  useEffect(() => {
    if (book?.status === 'ready' && p.book?.id !== book.id) p.open(book);
  }, [book?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!book) {
    return (
      <View style={styles.center}>
        <Text style={styles.muted}>This book isn’t in your library any more.</Text>
      </View>
    );
  }

  const isCurrent = p.book?.id === book.id;
  const track = book.tracks?.[isCurrent ? p.trackIndex : book.audioPosition?.track ?? 0];
  const current = isCurrent ? status.currentTime : book.audioPosition?.seconds ?? 0;
  const duration = (isCurrent && status.duration) || track?.duration || 0;
  const fraction = duration ? Math.min(1, current / duration) : 0;

  const shareTorrent = () => {
    if (book.source !== 'librivox' || !book.origin) return;
    Share.share({ message: audiobookTorrentUrl(book.origin.sourceId), title: `${book.title} (torrent)` });
  };

  return (
    <View style={styles.screen}>
      <Stack.Screen
        options={{
          headerRight: () =>
            book.source === 'librivox' ? (
              <Pressable onPress={shareTorrent} hitSlop={10}>
                <Text style={{ color: colors.accent, fontWeight: '600' }}>Torrent</Text>
              </Pressable>
            ) : null,
        }}
      />
      <View style={styles.top}>
        <Cover uri={book.coverUrl} title={book.title} size={150} />
        <Text style={styles.title} numberOfLines={2}>{book.title}</Text>
        <Text style={styles.author}>{book.author}</Text>
        <Text style={styles.chapter} numberOfLines={1}>{track?.title}</Text>
      </View>

      <Pressable
        onLayout={(e: LayoutChangeEvent) => setBarWidth(e.nativeEvent.layout.width)}
        onPress={(e) => duration && p.seekTo((e.nativeEvent.locationX / barWidth) * duration)}
        style={styles.seekArea}
        accessibilityLabel="Seek"
      >
        <View style={styles.seekTrack}>
          <View style={[styles.seekFill, { width: `${fraction * 100}%` }]} />
        </View>
        <View style={[styles.seekThumb, { left: fraction * barWidth - 7 }]} />
      </Pressable>
      <View style={styles.times}>
        <Text style={styles.time}>{formatTime(current)}</Text>
        <Text style={styles.time}>-{formatTime(Math.max(0, duration - current))}</Text>
      </View>

      <View style={styles.controls}>
        <RoundButton label={glyph.prev} onPress={p.prevTrack} accessibilityLabel="Previous chapter" />
        <RoundButton label="-30" onPress={() => p.seekBy(-30)} accessibilityLabel="Back 30 seconds" />
        <RoundButton
          big
          label={isCurrent && status.playing ? glyph.pause : glyph.play}
          onPress={() => (isCurrent ? p.toggle() : p.open(book))}
          accessibilityLabel={isCurrent && status.playing ? 'Pause' : 'Play'}
        />
        <RoundButton label="+30" onPress={() => p.seekBy(30)} accessibilityLabel="Forward 30 seconds" />
        <RoundButton label={glyph.next} onPress={p.nextTrack} accessibilityLabel="Next chapter" />
      </View>

      <Pressable onPress={p.cycleRate} style={styles.rate} accessibilityLabel="Change speed">
        <Text style={styles.rateText}>{p.rate}× speed</Text>
      </Pressable>

      <Text style={styles.listHeading}>Chapters</Text>
      <FlatList
        data={book.tracks ?? []}
        keyExtractor={(_, i) => String(i)}
        renderItem={({ item, index }) => {
          const active = isCurrent && index === p.trackIndex;
          return (
            <Pressable onPress={() => p.open(book, index, 0)} style={[styles.chapterRow, active && styles.chapterActive]}>
              <Text style={[styles.chapterNum, active && { color: colors.accent }]}>{index + 1}</Text>
              <Text style={[styles.chapterTitle, active && { color: colors.accent }]} numberOfLines={1}>{item.title}</Text>
              {item.duration ? <Text style={styles.time}>{formatTime(item.duration)}</Text> : null}
            </Pressable>
          );
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg, paddingHorizontal: 20 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.bg },
  muted: { color: colors.muted },
  top: { alignItems: 'center', gap: 6, paddingTop: 8 },
  title: { color: colors.text, fontSize: 20, fontWeight: '800', textAlign: 'center', marginTop: 10 },
  author: { color: colors.muted, fontSize: 14 },
  chapter: { color: colors.audiobook, fontSize: 14, fontWeight: '600', marginTop: 4 },
  seekArea: { height: 32, justifyContent: 'center', marginTop: 16 },
  seekTrack: { height: 4, borderRadius: 2, backgroundColor: colors.border, overflow: 'hidden' },
  seekFill: { height: 4, backgroundColor: colors.accent },
  seekThumb: { position: 'absolute', width: 14, height: 14, borderRadius: 7, backgroundColor: colors.accent, top: 9 },
  times: { flexDirection: 'row', justifyContent: 'space-between' },
  time: { color: colors.faint, fontSize: 12, fontVariant: ['tabular-nums'] },
  controls: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: 16 },
  rate: { alignSelf: 'center', marginTop: 14, paddingHorizontal: 14, paddingVertical: 6, borderRadius: 999, borderWidth: 1, borderColor: colors.border },
  rateText: { color: colors.text, fontWeight: '700', fontSize: 13 },
  listHeading: { color: colors.muted, fontSize: 12, fontWeight: '800', textTransform: 'uppercase', letterSpacing: 0.8, marginTop: 20, marginBottom: 6 },
  chapterRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 10, paddingHorizontal: 8, borderRadius: 8 },
  chapterActive: { backgroundColor: colors.surface },
  chapterNum: { color: colors.faint, width: 24, fontVariant: ['tabular-nums'] },
  chapterTitle: { color: colors.text, flex: 1 },
});
