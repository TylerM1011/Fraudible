import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { KokoroProvider } from '@/lib/kokoro';
import { LibraryProvider } from '@/lib/library';
import { PlayerProvider } from '@/lib/player';
import { fonts, ThemeProvider, useTheme } from '@/lib/theme';

function RootStack() {
  const { colors, scheme } = useTheme();
  return (
    <>
      <StatusBar style={scheme === 'dark' ? 'light' : 'dark'} />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: colors.bg },
          headerTintColor: colors.text,
          headerShadowVisible: false,
          headerTitleStyle: { fontFamily: fonts.mono, fontWeight: '800' },
          contentStyle: { backgroundColor: colors.bg },
        }}
      >
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="listen/[id]" options={{ title: 'Now playing', presentation: 'modal' }} />
        <Stack.Screen name="read/[id]" options={{ title: 'Reader' }} />
      </Stack>
    </>
  );
}

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <ThemeProvider>
        <LibraryProvider>
          <PlayerProvider>
            <KokoroProvider>
              <RootStack />
            </KokoroProvider>
          </PlayerProvider>
        </LibraryProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
