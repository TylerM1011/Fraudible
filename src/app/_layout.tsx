import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { KokoroProvider } from '@/lib/kokoro';
import { LibraryProvider } from '@/lib/library';
import { PlayerProvider } from '@/lib/player';
import { colors } from '@/lib/theme';

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <LibraryProvider>
        <PlayerProvider>
          <KokoroProvider>
            <StatusBar style="light" />
            <Stack
              screenOptions={{
                headerStyle: { backgroundColor: colors.bg },
                headerTintColor: colors.text,
                headerShadowVisible: false,
                contentStyle: { backgroundColor: colors.bg },
              }}
            >
              <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
              <Stack.Screen name="listen/[id]" options={{ title: 'Now playing', presentation: 'modal' }} />
              <Stack.Screen name="read/[id]" options={{ title: 'Reader' }} />
            </Stack>
          </KokoroProvider>
        </PlayerProvider>
      </LibraryProvider>
    </SafeAreaProvider>
  );
}
