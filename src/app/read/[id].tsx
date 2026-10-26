/**
 * Kokoro reader: synthesizes the whole book's audio up front (as soon as the voice is
 * ready), independent of how far you've read, then just plays through the pre-built
 * segments. Highlights each paragraph and remembers where you stopped.
 *
 * How it works: as soon as the voice engine is ready, a background pass walks every
 * chunk of the book in order and synthesizes it to a small WAV file, as fast as Kokoro
 * can go (it only runs one synthesis at a time). Playback just plays through whichever
 * segments already exist; if you get ahead of the builder it shows "Preparing audio…"
 * until the next one lands. Because every chunk is already a file on disk, skipping
 * backward or forward never needs to re-synthesize anything.
 */
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import { Directory, File, Paths } from 'expo-file-system';
import { Stack, useLocalSearchParams } from 'expo-router';
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import type { KokoroTextToSpeech } from 'react-native-executorch';
import { Button, ProgressBar, RoundButton } from '@/components/ui';
import { registerReader } from '@/lib/audioFocus';
import { findVoice, KOKORO_VOICES, useKokoro, VOICE_DOWNLOAD_SIZE } from '@/lib/kokoro';
import { useLibrary } from '@/lib/library';
import { usePlayer } from '@/lib/player';
import { loadBookParagraphs } from '@/lib/storage';
import { chunkParagraphs, type Chunk } from '@/lib/text';
import { fonts, glyph, useTheme, type Colors } from '@/lib/theme';
import { encodeWav } from '@/lib/wav';

const RATES = [0.8, 1, 1.25, 1.5, 1.75, 2];

type Segment = { paragraph: number; chunkIndex: number; file: File };
type Styles = ReturnType<typeof makeStyles>;

/** Memoised so moving to the next paragraph only re-renders the two rows whose highlight changed. */
const Paragraph = memo(function Paragraph({
  text,
  index,
  active,
  onPress,
  styles,
}: {
  text: string;
  index: number;
  active: boolean;
  onPress: (index: number) => void;
  styles: Styles;
}) {
  return (
    <Pressable onPress={() => onPress(index)}>
      <Text style={[styles.paragraph, active && styles.current]}>{text}</Text>
    </Pressable>
  );
});

/** The index of the first chunk belonging to a paragraph. */
function firstChunkForParagraph(chunks: Chunk[], paragraph: number): number {
  const i = chunks.findIndex((c) => c.paragraph === paragraph);
  return i >= 0 ? i : 0;
}

/** The index of the first built segment for a chunk, or -1 if the builder hasn't reached it yet. */
function firstSegmentForChunk(segments: Segment[], chunkIndex: number): number {
  return segments.findIndex((s) => s.chunkIndex === chunkIndex);
}

export default function ReaderScreen() {
  const { colors } = useTheme();
  const styles = useMemo(() => makeStyles(colors), [colors]);
  const { id } = useLocalSearchParams<{ id: string }>();
  const { getBook, update } = useLibrary();
  const audiobook = usePlayer();
  const kokoro = useKokoro();
  const book = getBook(id);

  const [paragraphs, setParagraphs] = useState<string[] | null>(null);
  const [chunks, setChunks] = useState<Chunk[] | null>(null);
  const [loadError, setLoadError] = useState<string>();
  const [index, setIndex] = useState(book?.ttsPosition ?? 0);
  const [reading, setReading] = useState(false); // a read-aloud session is active (it may be paused)
  const [buffering, setBuffering] = useState(false); // waiting for the builder to reach the segment we want
  const [builtCount, setBuiltCount] = useState(0); // how many chunks the background builder has finished
  const [buildTrigger, setBuildTrigger] = useState(0); // bumped once to opt in to downloading/building
  const [rate, setRate] = useState(book?.ttsRate ?? 1);
  const [voiceId, setVoiceId] = useState(findVoice(book?.ttsVoice).id);
  const [voicePicker, setVoicePicker] = useState(false);

  const voice = findVoice(voiceId);
  const player = useAudioPlayer(null, { updateInterval: 500 });
  const status = useAudioPlayerStatus(player);
  const listRef = useRef<FlatList<string>>(null);

  // ---- Playback/build state lives in refs so async code always sees the latest values ----
  const session = useRef(0); // bumped whenever the builder must restart (voice change, unmount)
  const segments = useRef<Segment[]>([]); // every chunk already synthesized, in order
  const playPos = useRef(0); // index into `segments` currently loaded into the player
  const playingParagraph = useRef<number | undefined>(undefined);
  const pendingAction = useRef<(() => boolean) | null>(null); // retried each time the builder adds a segment
  const readingRef = useRef(false);
  const chunksRef = useRef<Chunk[] | null>(null);
  chunksRef.current = chunks;
  const builtCountRef = useRef(0);
  builtCountRef.current = builtCount;
  const settings = useRef({ rate, voiceId });
  settings.current = { rate, voiceId };
  const kokoroRef = useRef(kokoro);
  kokoroRef.current = kokoro;

  const audioDir = useRef<Directory | null>(null);
  const getAudioDir = () => {
    if (!audioDir.current) {
      audioDir.current = new Directory(Paths.cache, 'kokoro', id);
      if (!audioDir.current.exists) audioDir.current.create({ intermediates: true, idempotent: true });
    }
    return audioDir.current;
  };

  const setReadingBoth = (value: boolean) => {
    readingRef.current = value;
    setReading(value);
  };

  useEffect(() => {
    if (!book?.textFile) return;
    loadBookParagraphs(book.textFile)
      .then((paras) => {
        setParagraphs(paras);
        setChunks(chunkParagraphs(paras));
      })
      .catch((e) => setLoadError((e as Error).message));
  }, [book?.textFile]);

  const savePosition = useCallback((i: number) => update(id, { ttsPosition: i }), [id, update]);
  const saveChunkPosition = useCallback((i: number) => update(id, { ttsChunkPosition: i }), [id, update]);

  // expo-audio's pause()/setPlaybackRate() throw natively if nothing has been loaded
  // into the player yet; swallow that so a speed change never interrupts reading.
  const safePause = useCallback(() => {
    try {
      player.pause();
    } catch {
      // nothing loaded; already "paused"
    }
  }, [player]);

  const safeSetRate = useCallback(
    (value: number) => {
      try {
        player.shouldCorrectPitch = true;
        player.setPlaybackRate(value);
      } catch {
        // nothing loaded yet; the rate is applied when the next segment starts playing
      }
    },
    [player]
  );

  const loadAndPlay = (seg: Segment) => {
    setBuffering(false);
    if (seg.paragraph !== playingParagraph.current) {
      playingParagraph.current = seg.paragraph;
      setIndex(seg.paragraph);
      savePosition(seg.paragraph);
    }
    saveChunkPosition(seg.chunkIndex);
    player.replace({ uri: seg.file.uri });
    safeSetRate(settings.current.rate);
    player.play();
  };

  /** Play from a chunk once it's built; if the builder hasn't reached it yet, wait for it. */
  const playFromChunk = (targetChunk: number) => {
    safePause();
    const i = firstSegmentForChunk(segments.current, targetChunk);
    if (i >= 0) {
      pendingAction.current = null;
      playPos.current = i;
      loadAndPlay(segments.current[i]);
    } else {
      pendingAction.current = () => {
        const idx = firstSegmentForChunk(segments.current, targetChunk);
        if (idx < 0) return false;
        playPos.current = idx;
        loadAndPlay(segments.current[idx]);
        return true;
      };
      setBuffering(true);
    }
  };

  /** Move to a paragraph (optionally resuming at an exact chunk within it) and start playing it. */
  const seekToParagraph = (paragraph: number, resumeChunk?: number) => {
    const all = chunksRef.current ?? [];
    const targetChunk =
      resumeChunk !== undefined && all[resumeChunk]?.paragraph === paragraph
        ? resumeChunk
        : firstChunkForParagraph(all, paragraph);
    playFromChunk(targetChunk);
  };

  // Advance to the next segment when the current one finishes; wait for the builder if it's not ready yet.
  const advanceRef = useRef(() => {});
  advanceRef.current = () => {
    const next = playPos.current + 1;
    if (next < segments.current.length) {
      playPos.current = next;
      loadAndPlay(segments.current[next]);
      return;
    }
    const all = chunksRef.current;
    if (all && builtCountRef.current >= all.length) {
      setReadingBoth(false); // the builder is done and there is truly nothing more
      setBuffering(false);
      return;
    }
    pendingAction.current = () => {
      const n = playPos.current + 1;
      if (n >= segments.current.length) return false;
      playPos.current = n;
      loadAndPlay(segments.current[n]);
      return true;
    };
    setBuffering(true);
  };

  useEffect(() => {
    const sub = player.addListener('playbackStatusUpdate', (s) => {
      if (s.didJustFinish) advanceRef.current();
    });
    return () => sub.remove();
  }, [player]);

  /** Opt in to downloading the voice and/or building this book's audio, if not already under way. */
  const ensureBuildStarted = () => {
    if (!(kokoro.isDownloaded(voice.pack) || buildTrigger > 0)) setBuildTrigger((n) => n + 1);
  };

  // ---- Builder: synthesizes every chunk of the book in order, independent of playback position ----
  useEffect(() => {
    if (!chunks || !chunks.length) return;
    if (!(kokoro.isDownloaded(voice.pack) || buildTrigger > 0)) return; // wait for explicit opt-in
    const sess = ++session.current;
    segments.current = [];
    playPos.current = 0;
    builtCountRef.current = 0;
    setBuiltCount(0);
    let tts: KokoroTextToSpeech<string> | undefined;

    (async () => {
      try {
        tts = await kokoroRef.current.ensure(voice.pack);
      } catch {
        return; // surfaced via the engine-card UI below
      }
      for (let i = 0; i < chunks.length; i++) {
        if (sess !== session.current) return;
        try {
          for await (const audio of tts.synthesize(chunks[i].text, { voice: voice.id })) {
            if (sess !== session.current) return;
            const file = new File(getAudioDir(), `${sess}-${i}-${segments.current.length}.wav`);
            file.write(encodeWav(audio.audio, audio.sampleRate));
            segments.current.push({ paragraph: chunks[i].paragraph, chunkIndex: i, file });
            if (pendingAction.current?.()) pendingAction.current = null;
          }
        } catch (e) {
          if (sess === session.current) {
            setReadingBoth(false);
            setBuffering(false);
            Alert.alert('Couldn’t read aloud', (e as Error).message);
          }
          return;
        }
        if (sess === session.current) {
          builtCountRef.current = i + 1;
          setBuiltCount(i + 1);
        }
      }
      if (sess === session.current && pendingAction.current) {
        // Something was waiting for more and there truly isn't any: that's the end of the book.
        pendingAction.current = null;
        setReadingBoth(false);
        setBuffering(false);
      }
    })();

    return () => {
      session.current++;
      tts?.synthesizeStop();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chunks, voiceId, buildTrigger]);

  /** Start (or restart) reading from a paragraph. */
  const start = (from: number, resumeChunk?: number) => {
    audiobook.pause(); // don't talk over an audiobook
    setIndex(from);
    savePosition(from);
    setReadingBoth(true);
    seekToParagraph(from, resumeChunk);
  };

  /** End the session entirely (leaving the screen, or an audiobook started). */
  const stopAll = useCallback(() => {
    pendingAction.current = null;
    safePause();
    setReadingBoth(false);
    setBuffering(false);
  }, [safePause]);

  // Let the audiobook player stop us, and clean up the audio cache when leaving the screen.
  useEffect(() => registerReader(stopAll), [stopAll]);
  useEffect(
    () => () => {
      stopAll();
      try {
        audioDir.current?.delete();
      } catch {
        // best-effort
      }
    },
    [] // eslint-disable-line react-hooks/exhaustive-deps
  );

  const togglePlay = () => {
    if (!reading) {
      ensureBuildStarted();
      return start(index, book?.ttsChunkPosition);
    }
    if (status.playing) safePause();
    else {
      audiobook.pause();
      player.play();
    }
  };

  const jump = (delta: number) => {
    if (!paragraphs) return;
    const next = Math.max(0, Math.min(paragraphs.length - 1, index + delta));
    if (reading) start(next);
    else {
      setIndex(next);
      savePosition(next);
    }
  };

  // Stable handler for paragraph taps (reads the latest state through a ref).
  const pressRef = useRef<(i: number) => void>(() => {});
  pressRef.current = (i: number) => {
    if (readingRef.current) start(i);
    else {
      setIndex(i);
      savePosition(i);
    }
  };
  const onParagraphPress = useCallback((i: number) => pressRef.current(i), []);

  const cycleRate = () => {
    const next = RATES[(RATES.indexOf(rate) + 1) % RATES.length] ?? 1;
    setRate(next);
    safeSetRate(next); // applies instantly; no need to regenerate the audio, and reading never stops for it
    update(id, { ttsRate: next });
  };

  const chooseVoice = (newId: string) => {
    setVoicePicker(false);
    if (newId === voiceId) return;
    setVoiceId(newId);
    settings.current = { ...settings.current, voiceId: newId };
    update(id, { ttsVoice: newId });
    if (readingRef.current) seekToParagraph(index); // resume this paragraph once the new voice builds it
  };

  // Keep the current paragraph in view.
  useEffect(() => {
    if (paragraphs?.length) listRef.current?.scrollToIndex({ index, animated: true, viewPosition: 0.3 });
  }, [index, paragraphs?.length]);

  if (!book) {
    return (
      <View style={styles.center}>
        <Text style={styles.muted}>This book isn’t in your library any more.</Text>
      </View>
    );
  }

  const thisPack = kokoro.pack === voice.pack;
  const engineBusy = thisPack && (kokoro.status === 'downloading' || kokoro.status === 'loading');
  const engineFailed = thisPack && kokoro.status === 'error';
  const engaged = kokoro.isDownloaded(voice.pack) || buildTrigger > 0;
  const needsDownload = !kokoro.isDownloaded(voice.pack) && !(thisPack && kokoro.status === 'ready');
  const totalChunks = chunks?.length ?? 0;
  const buildingAudio = engaged && !engineBusy && !engineFailed && builtCount < totalChunks;
  const progress = paragraphs?.length ? Math.round(((index + 1) / paragraphs.length) * 100) : 0;
  const isPlaying = reading && status.playing;

  return (
    <View style={styles.screen}>
      <Stack.Screen options={{ title: book.title }} />

      {loadError ? (
        <View style={styles.center}>
          <Text style={styles.muted}>Couldn’t open this book: {loadError}</Text>
        </View>
      ) : !paragraphs ? (
        <View style={styles.center}>
          <ActivityIndicator color={colors.tts} />
        </View>
      ) : (
        <FlatList
          ref={listRef}
          data={paragraphs}
          keyExtractor={(_, i) => String(i)}
          initialNumToRender={20}
          windowSize={11}
          extraData={index}
          removeClippedSubviews
          contentContainerStyle={{ padding: 20, paddingBottom: 40 }}
          onScrollToIndexFailed={({ index: target, averageItemLength }) => {
            listRef.current?.scrollToOffset({ offset: target * averageItemLength, animated: false });
            setTimeout(() => listRef.current?.scrollToIndex({ index: target, animated: false, viewPosition: 0.3 }), 120);
          }}
          renderItem={({ item, index: i }) => (
            <Paragraph text={item} index={i} active={i === index} onPress={onParagraphPress} styles={styles} />
          )}
        />
      )}

      <View style={styles.dock}>
        {engineBusy ? (
          <View style={styles.engineCard}>
            <Text style={styles.engineTitle}>
              {kokoro.status === 'downloading'
                ? `Downloading the ${voice.accent} voice… ${Math.round(kokoro.progress * 100)}%`
                : 'Loading voice…'}
            </Text>
            <ProgressBar value={kokoro.status === 'downloading' ? kokoro.progress : 1} color={colors.tts} />
            {kokoro.status === 'downloading' ? (
              <View style={styles.engineRow}>
                <Text style={[styles.muted, { flex: 1 }]}>One-time download. Wi-Fi recommended.</Text>
                <Button small variant="ghost" label="Cancel" onPress={kokoro.cancelDownload} />
              </View>
            ) : null}
          </View>
        ) : engineFailed && !reading ? (
          <View style={styles.engineCard}>
            <Text style={[styles.engineTitle, { color: colors.danger }]}>The voice didn’t load</Text>
            <Text style={styles.muted}>{kokoro.error}</Text>
            <Button label="Try again" onPress={() => setBuildTrigger((n) => n + 1)} />
          </View>
        ) : needsDownload && !reading ? (
          <View style={styles.engineCard}>
            <Text style={styles.engineTitle}>Download the Kokoro voice</Text>
            <Text style={styles.muted}>
              A natural-sounding AI voice that runs on your phone, fully offline. One-time download of {VOICE_DOWNLOAD_SIZE}.
            </Text>
            <Button label={`Download ${voice.accent} voice`} onPress={ensureBuildStarted} />
          </View>
        ) : buildingAudio ? (
          <View style={styles.engineCard}>
            <Text style={styles.engineTitle}>
              Preparing audio… {totalChunks ? Math.round((builtCount / totalChunks) * 100) : 0}%
            </Text>
            <ProgressBar value={totalChunks ? builtCount / totalChunks : 0} color={colors.tts} />
          </View>
        ) : null}

        <Text style={styles.status}>
          {reading && buffering ? 'Preparing audio… · ' : ''}Paragraph {index + 1} of {paragraphs?.length ?? '…'} · {progress}%
        </Text>
        <View style={styles.controls}>
          <RoundButton label={glyph.prev} onPress={() => jump(-1)} accessibilityLabel="Previous paragraph" />
          <RoundButton
            big
            label={isPlaying || (reading && buffering) ? glyph.pause : glyph.play}
            onPress={togglePlay}
            accessibilityLabel={isPlaying ? 'Pause' : 'Read aloud'}
          />
          <RoundButton label={glyph.next} onPress={() => jump(1)} accessibilityLabel="Next paragraph" />
        </View>
        <View style={styles.options}>
          <Pressable onPress={cycleRate} style={styles.pill}>
            <Text style={styles.pillText}>{rate}× speed</Text>
          </Pressable>
          <Pressable onPress={() => setVoicePicker(true)} style={styles.pill}>
            <Text style={styles.pillText}>
              {voice.name} · {voice.accent}
            </Text>
          </Pressable>
        </View>
      </View>

      <Modal visible={voicePicker} transparent animationType="slide" onRequestClose={() => setVoicePicker(false)}>
        <Pressable style={styles.backdrop} onPress={() => setVoicePicker(false)} />
        <View style={styles.sheet}>
          <Text style={styles.sheetTitle}>Choose a voice</Text>
          <Text style={styles.muted}>
            Kokoro voices run on your phone. British and American voices come in separate packs; once you have one, the
            other is a much smaller extra download.
          </Text>
          <FlatList
            data={KOKORO_VOICES}
            keyExtractor={(v) => v.id}
            style={{ marginTop: 12 }}
            renderItem={({ item }) => {
              const selected = item.id === voiceId;
              return (
                <Pressable onPress={() => chooseVoice(item.id)} style={styles.voiceRow}>
                  <Text style={[styles.voiceName, selected && { color: colors.tts }]}>
                    {selected ? '✓ ' : ''}
                    {item.name}
                  </Text>
                  <Text style={styles.muted}>
                    {item.accent} · {item.gender}
                    {kokoro.isDownloaded(item.pack) ? '' : ' · needs download'}
                  </Text>
                </Pressable>
              );
            }}
          />
        </View>
      </Modal>
    </View>
  );
}

const makeStyles = (colors: Colors) =>
  StyleSheet.create({
    screen: { flex: 1, backgroundColor: colors.bg },
    center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24 },
    muted: { color: colors.muted, fontSize: 13, lineHeight: 18 },
    paragraph: { color: colors.muted, fontSize: 17, lineHeight: 27, marginBottom: 14, padding: 6, borderRadius: 4 },
    current: { color: colors.text, backgroundColor: `${colors.tts}1F` },
    dock: {
      backgroundColor: colors.surface,
      borderTopWidth: 2,
      borderTopColor: colors.border,
      paddingHorizontal: 20,
      paddingTop: 10,
      paddingBottom: 28,
      gap: 12,
    },
    engineCard: { backgroundColor: colors.surfaceHigh, borderRadius: 5, borderWidth: 2, borderColor: colors.border, padding: 14, gap: 8 },
    engineRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
    engineTitle: { color: colors.text, fontWeight: '700', fontSize: 15, fontFamily: fonts.mono },
    status: { color: colors.faint, fontSize: 12, textAlign: 'center' },
    controls: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 28 },
    options: { flexDirection: 'row', justifyContent: 'center', gap: 10, flexWrap: 'wrap' },
    pill: { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 4, borderWidth: 2, borderColor: colors.border },
    pillText: { color: colors.text, fontWeight: '700', fontSize: 13, fontFamily: fonts.mono },
    backdrop: { flex: 1, backgroundColor: '#0008' },
    sheet: { maxHeight: '65%', backgroundColor: colors.surface, padding: 20, paddingBottom: 36, borderTopWidth: 2, borderColor: colors.border },
    sheetTitle: { color: colors.text, fontSize: 18, fontWeight: '800', marginBottom: 6, fontFamily: fonts.mono },
    voiceRow: { paddingVertical: 12, borderBottomWidth: 2, borderBottomColor: colors.border },
    voiceName: { color: colors.text, fontSize: 15, fontWeight: '600' },
  });
