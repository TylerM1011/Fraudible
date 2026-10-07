import { Image, Pressable, StyleSheet, Text, View, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';
import { colors, kindColor, kindLabel } from '@/lib/theme';
import type { BookKind } from '@/lib/types';

/** Labels a result as an audiobook or a text-to-speech ebook. */
export function KindBadge({ kind }: { kind: BookKind }) {
  const color = kindColor[kind];
  return (
    <View style={[styles.badge, { borderColor: color, backgroundColor: `${color}22` }]}>
      <Text style={[styles.badgeText, { color }]}>{kind === 'audiobook' ? '♫ ' : '“ '}{kindLabel[kind]}</Text>
    </View>
  );
}

export function Cover({ uri, title, size = 56 }: { uri?: string; title: string; size?: number }) {
  const style = { width: size, height: size * 1.4, borderRadius: 6 };
  if (uri) return <Image source={{ uri }} style={[style, styles.coverBg]} resizeMode="cover" />;
  return (
    <View style={[style, styles.coverBg, styles.coverFallback]}>
      <Text style={[styles.coverLetter, { fontSize: size * 0.45 }]}>{title.trim().charAt(0).toUpperCase() || '?'}</Text>
    </View>
  );
}

export function ProgressBar({ value, color = colors.accent, height = 4 }: { value: number; color?: string; height?: number }) {
  return (
    <View style={[styles.track, { height, borderRadius: height / 2 }]}>
      <View style={{ width: `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%`, backgroundColor: color, height, borderRadius: height / 2 }} />
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
  return (
    <Pressable
      accessibilityRole="button"
      {...rest}
      style={({ pressed }) => [
        styles.button,
        small && styles.buttonSmall,
        variant === 'primary' && { backgroundColor: colors.accent },
        variant === 'ghost' && { borderColor: colors.border, borderWidth: 1 },
        variant === 'danger' && { borderColor: colors.danger, borderWidth: 1 },
        (pressed || rest.disabled) && { opacity: 0.6 },
        style,
      ]}
    >
      <Text
        style={[
          styles.buttonText,
          small && { fontSize: 13 },
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
  const size = big ? 76 : 52;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      onPress={onPress}
      hitSlop={8}
      style={({ pressed }) => [
        styles.round,
        { width: size, height: size, borderRadius: size / 2 },
        big ? { backgroundColor: colors.accent } : { backgroundColor: colors.surfaceHigh },
        pressed && { transform: [{ scale: 0.94 }] },
      ]}
    >
      <Text style={{ color: big ? colors.accentText : colors.text, fontSize: big ? 28 : 17, fontWeight: '700' }}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  badge: { alignSelf: 'flex-start', borderWidth: 1, borderRadius: 999, paddingHorizontal: 8, paddingVertical: 2 },
  badgeText: { fontSize: 11, fontWeight: '700', letterSpacing: 0.3 },
  coverBg: { backgroundColor: colors.surfaceHigh },
  coverFallback: { alignItems: 'center', justifyContent: 'center' },
  coverLetter: { color: colors.muted, fontWeight: '700' },
  track: { backgroundColor: colors.border, overflow: 'hidden', width: '100%' },
  button: { borderRadius: 999, paddingHorizontal: 18, paddingVertical: 11, alignItems: 'center', justifyContent: 'center' },
  buttonSmall: { paddingHorizontal: 14, paddingVertical: 7 },
  buttonText: { fontSize: 15, fontWeight: '700' },
  round: { alignItems: 'center', justifyContent: 'center' },
});
