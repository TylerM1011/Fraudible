/** Compact "now playing" bar shown at the bottom of the tab screens. */
import { router } from 'expo-router';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { usePlayer, usePlayerStatus } from '@/lib/player';
import { fonts, glyph, useTheme, type Colors } from '@/lib/theme';
import { Cover, ProgressBar } from './ui';

export function MiniPlayer() {
  const { colors } = useTheme();
  const styles = makeStyles(colors);
  const { book, trackIndex, toggle } = usePlayer();
  const status = usePlayerStatus();
  if (!book) return null;
  const track = book.tracks?.[trackIndex];
  const fraction = status.duration ? status.currentTime / status.duration : 0;

  return (
    <Pressable style={styles.wrap} onPress={() => router.push(`/listen/${book.id}`)} accessibilityLabel="Open player">
      <ProgressBar value={fraction} height={2} />
      <View style={styles.row}>
        <Cover uri={book.coverUrl} title={book.title} size={32} />
        <View style={{ flex: 1 }}>
          <Text style={styles.title} numberOfLines={1}>{book.title}</Text>
          <Text style={styles.sub} numberOfLines={1}>{track?.title}</Text>
        </View>
        <Pressable onPress={toggle} hitSlop={12} style={styles.play} accessibilityLabel={status.playing ? 'Pause' : 'Play'}>
          <Text style={styles.playText}>{status.playing ? glyph.pause : glyph.play}</Text>
        </Pressable>
      </View>
    </Pressable>
  );
}

const makeStyles = (colors: Colors) =>
  StyleSheet.create({
    wrap: { backgroundColor: colors.surfaceHigh, borderTopColor: colors.border, borderTopWidth: 2 },
    row: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 16, paddingVertical: 8 },
    title: { color: colors.text, fontWeight: '700', fontSize: 14 },
    sub: { color: colors.muted, fontSize: 12, marginTop: 2, fontFamily: fonts.mono },
    play: { width: 40, height: 40, borderRadius: 4, borderWidth: 2, borderColor: colors.border, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center' },
    playText: { color: colors.accentText, fontSize: 16, fontWeight: '800' },
  });
