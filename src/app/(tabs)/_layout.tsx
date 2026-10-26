import { Tabs } from 'expo-router';
import { Text, View, type ColorValue } from 'react-native';
import { ThemeToggle } from '@/components/ui';
import { fonts, useTheme } from '@/lib/theme';

function TabIcon({ glyph, color }: { glyph: string; color: ColorValue }) {
  return <Text style={{ color, fontSize: 20, fontWeight: '700', fontFamily: fonts.mono }}>{glyph}</Text>;
}

export default function TabsLayout() {
  const { colors } = useTheme();
  return (
    <Tabs
      screenOptions={{
        headerStyle: { backgroundColor: colors.bg },
        headerTintColor: colors.text,
        headerShadowVisible: false,
        headerTitleStyle: { fontFamily: fonts.mono, fontWeight: '800' },
        headerRight: () => (
          <View style={{ marginRight: 16 }}>
            <ThemeToggle />
          </View>
        ),
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border, borderTopWidth: 2 },
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.muted,
        tabBarLabelStyle: { fontFamily: fonts.mono, fontWeight: '700', textTransform: 'uppercase', fontSize: 11 },
        sceneStyle: { backgroundColor: colors.bg },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{ title: 'Search', headerTitle: 'Fraudible', tabBarIcon: ({ color }) => <TabIcon glyph={'⌕'} color={color} /> }}
      />
      <Tabs.Screen
        name="library"
        options={{ title: 'Library', tabBarIcon: ({ color }) => <TabIcon glyph={'≡'} color={color} /> }}
      />
    </Tabs>
  );
}
