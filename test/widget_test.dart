import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_mixer/main.dart';
import 'package:playlist_mixer/src/repositories/mock_music_library_repository.dart';

void main() {
  testWidgets('shows playlist mixer shell', (tester) async {
    await tester.pumpWidget(
      PlaylistMixerApp(repository: MockMusicLibraryRepository()),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('Playlist Mixer'), findsOneWidget);
    expect(find.text('リスト A'), findsWidgets);
    expect(find.text('リスト B'), findsWidgets);
    expect(find.text('A∩B'), findsOneWidget);
    expect(find.text('A∪B'), findsOneWidget);
    expect(find.text('A-B'), findsOneWidget);
    expect(find.text('B-A'), findsOneWidget);
    expect(find.text('AD'), findsOneWidget);

    await tester.tap(find.byTooltip('設定'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('設定'), findsOneWidget);
    expect(find.text('言語'), findsWidgets);
    expect(find.text('日本語'), findsWidgets);
    expect(find.text('配色パターン'), findsWidgets);
    expect(find.text('Cyan x Violet'), findsWidgets);
  });

  testWidgets('filters collections by search query', (tester) async {
    await tester.pumpWidget(
      PlaylistMixerApp(repository: MockMusicLibraryRepository()),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    await tester.tap(find.text('選択').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('プレイリスト'), findsWidgets);
    expect(find.text('アーティスト'), findsWidgets);
    expect(find.text('アルバム'), findsWidgets);
    expect(find.text('朝のプレイリスト'), findsOneWidget);
    expect(find.text('集中用'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '集中');
    await tester.pump();

    expect(find.text('朝のプレイリスト'), findsNothing);
    expect(find.text('集中用'), findsOneWidget);
  });

  testWidgets('can cancel collection picker without crashing', (tester) async {
    await tester.pumpWidget(
      PlaylistMixerApp(repository: MockMusicLibraryRepository()),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    await tester.tap(find.text('選択').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('朝のプレイリスト'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('朝のプレイリスト'), findsNothing);
    expect(find.text('選択'), findsWidgets);
  });
}
