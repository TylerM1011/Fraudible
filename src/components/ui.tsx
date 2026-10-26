import { Image, Pressable, StyleSheet, Text, View, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';
import { fonts, glyph, kindColors, kindLabel, useTheme } from '@/lib/theme';
import type { BookKind } from '@/lib/types';

/** Labels a result as an audiobook or a text-to-speech ebook. */
export function KindBadge({ kind }: { kind: BookKind }) {
  const { colors } = useTheme();
  const color = kindColors(colors)[kind];
  return (
    <View style={[styles.badge, { borderColor: color, backgroundColor: `${color}22` }]}>
      <Text style={[styles.badgeText, { color }]}>{kind === 'audiobook' ? '♫ ' : '“ '}{kindLabel[kind]}</Text>
    </View>
  );
}

export function Cover({ uri, title, size = 56 }: { uri?: string; title: string; size?: number }) {
  const { colors } = useTheme();
  const style = { width: size, height: size * 1.4, borderRadius: 4, borderWidth: 2, borderColor: colors.border };
  if (uri) return <Image source={{ uri }} style={[style, { backgroundColor: colors.surfaceHigh }]} resizeMode="cover" />;
  return (
    <View style={[style, { backgroundColor: colors.surfaceHigh, alignItems: 'center', justifyContent: 'center' }]}>
      <Text style={{ color: colors.muted, fontWeight: '700', fontFamily: fonts.mono, fontSize: size * 0.45 }}>
        {title.trim().charAt(0).toUpperCase() || '?'}
      </Text>
    </View>
  );
}

export function ProgressBar({ value, color, height = 4 }: { value: number; color?: string; height?: number }) {
  const { colors } = useTheme();
  const fill = color ?? colors.accent;
  return (
    <View style={[styles.track, { height, backgroundColor: colors.surfaceHigh, borderColor: colors.border }]}>
      <View style={{ width: `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%`, backgroundColor: fill, height }} />
    </View>
  );
}

type ButtonProps = PressableProps & {
  label: string;
  variant?: 'primary' | 'ghost' | 'danger';
  small?: boolean;
  style?: StyleProp<ViewStyle>;
};

export function Button({ label, variant = 'primary', small, style, ...rest }: ButtonProps) {
  const { colors } = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      {...rest}
      style={({ pressed }) => [
        styles.button,
        { borderColor: colors.border },
        small && styles.buttonSmall,
        variant === 'primary' && { backgroundColor: colors.accent },
        variant === 'ghost' && { backgroundColor: colors.surface },
        variant === 'danger' && { backgroundColor: colors.surface, borderColor: colors.danger },
        pressed && !rest.disabled && styles.buttonPressed,
        rest.disabled && { opacity: 0.5 },
        style,
      ]}
    >
      <Text
        style={[
          styles.buttonText,
          { fontFamily: fonts.mono },
          small && { fontSize: 12 },
          { color: variant === 'primary' ? colors.accentText : variant === 'danger' ? colors.danger : colors.text },
        ]}
      >
        {label}
      </Text>
    </Pressable>
  );
}

/** Round transport button used by both players. */
export function RoundButton({ label, onPress, big, accessibilityLabel }: { label: string; onPress: () => void; big?: boolean; accessibilityLabel: string }) {
  const { colors } = useTheme();
  const size = big ? 76 : 52;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      onPress={onPress}
      hitSlop={8}
      style={({ pressed }) => [
        styles.round,
        { width: size, height: size, borderRadius: size / 2, borderWidth: 2, borderColor: colors.border },
        big ? { backgroundColor: colors.accent } : { backgroundColor: colors.surfaceHigh },
        pressed && { transform: [{ scale: 0.94 }] },
      ]}
    >
      <Text style={{ color: big ? colors.accentText : colors.text, fontSize: big ? 26 : 16, fontWeight: '700', fontFamily: fonts.mono }}>{label}</Text>
    </Pressable>
  );
}

/** Small header-right control that flips between the light ("paper") and dark ("screen") themes. */
export function ThemeToggle() {
  const { colors, scheme, setMode } = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={scheme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
      hitSlop={10}
      onPress={() => setMode(scheme === 'dark' ? 'light' : 'dark')}
      style={[styles.themeToggle, { borderColor: colors.border, backgroundColor: colors.surfaceHigh }]}
    >
      <Text style={{ fontSize: 15, color: colors.text }}>{scheme === 'dark' ? glyph.sun : glyph.moon}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  badge: { alignSelf: 'flex-start', borderWidth: 2, borderRadius: 3, paddingHorizontal: 8, paddingVertical: 2 },
  badgeText: { fontSize: 11, fontWeight: '700', letterSpacing: 0.3 },
  track: { overflow: 'hidden', width: '100%', borderWidth: 1 },
  button: { borderWidth: 2, borderRadius: 5, paddingHorizontal: 18, paddingVertical: 11, alignItems: 'center', justifyContent: 'center' },
  buttonSmall: { paddingHorizontal: 14, paddingVertical: 7 },
  buttonPressed: { transform: [{ translateY: 1 }] },
  buttonText: { fontSize: 14, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  round: { alignItems: 'center', justifyContent: 'center' },
  themeToggle: { width: 32, height: 32, borderRadius: 4, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
});
