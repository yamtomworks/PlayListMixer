import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'src/home_screen.dart';
import 'src/repositories/music_library_repository.dart';
import 'src/repositories/platform_music_library_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS) {
    MobileAds.instance.initialize();
  }
  runApp(const PlaylistMixerApp());
}

class PlaylistMixerApp extends StatelessWidget {
  const PlaylistMixerApp({super.key, this.repository});

  final MusicLibraryRepository? repository;

  @override
  Widget build(BuildContext context) {
    const cobalt = Color(0xFF075DFF);
    const indigo = Color(0xFF07146F);
    const cyan = Color(0xFF10D8FF);
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: cobalt,
          brightness: Brightness.light,
        ).copyWith(
          primary: cobalt,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFDCE8FF),
          onPrimaryContainer: const Color(0xFF00145F),
          secondary: cyan,
          onSecondary: const Color(0xFF001A26),
          secondaryContainer: const Color(0xFFD7F7FF),
          surface: const Color(0xFFF6F8FF),
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFFFFFFF),
          surfaceContainer: const Color(0xFFEAF0FF),
          outline: const Color(0xFF9BAEE8),
          outlineVariant: const Color(0xFFD2DBFF),
        );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Playlist Mixer',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF07146F),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Color(0xFF07146F),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: cobalt,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: indigo,
            side: BorderSide(color: colorScheme.outline),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return cobalt;
              }
              return Colors.white;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return Colors.white;
              }
              return indigo;
            }),
            side: WidgetStatePropertyAll(
              BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
        ),
      ),
      home: HomeScreen(
        repository: repository ?? const PlatformMusicLibraryRepository(),
      ),
    );
  }
}
