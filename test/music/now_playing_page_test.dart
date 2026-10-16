import 'package:best_music/config.dart';
import 'package:best_music/models/music_playlist.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_player_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/ui/now_playing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() async {
    Config.musicFolder = '';
    Config.musicExcludedSubfolders = [];
    Config.mp3DownloadFolder = '';
    MusicLibraryService.instance.resetForTest();
    MusicPlaylistService.instance.resetForTest();
    MusicPlaylistService.instance.playlists.value = [
      MusicPlaylist.favorites(),
      MusicPlaylist.disliked(),
    ];
    if (!MusicPlayerService.isReady) {
      await MusicPlayerService.init();
    }
  });

  testWidgets('only the menu button is at the top; the rest is at the bottom',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    final appBar = find.byType(AppBar);
    expect(
        find.descendant(of: appBar, matching: find.byType(IconButton)),
        findsOneWidget);
    expect(find.descendant(of: appBar, matching: find.byTooltip('Menu')),
        findsOneWidget);

    expect(find.byTooltip('Shuffle off'), findsOneWidget);
    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(find.byTooltip('Music volume'), findsOneWidget);
    expect(find.byTooltip('Sleep timer'), findsOneWidget);
    final screenHeight = tester.getSize(find.byType(Scaffold)).height;
    expect(tester.getCenter(find.byTooltip('Queue')).dy,
        greaterThan(screenHeight * 0.75));
  });

  testWidgets('shows a Track info button, disabled while nothing is playing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Track info'), findsOneWidget);
    // byTooltip lands on the Tooltip IconButton wraps itself in.
    final button = tester.widget<IconButton>(find.ancestor(
        of: find.byTooltip('Track info'),
        matching: find.byType(IconButton)));
    expect(button.onPressed, isNull);
  });

  testWidgets('tapping shuffle toggles it on and off', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle off'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Shuffle on'), findsOneWidget);

    await tester.tap(find.byTooltip('Shuffle on'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Shuffle off'), findsOneWidget);
  });

  testWidgets('tapping repeat cycles off, all, one and back to off',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    for (final next in ['Repeat all', 'Repeat one', 'Repeat off']) {
      await tester.tap(find.byTooltip(RegExp('^Repeat ')));
      await tester.pumpAndSettle();
      expect(find.byTooltip(next), findsOneWidget);
    }
  });

  testWidgets('tapping the queue button opens the Queue page',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('Queue is empty'), findsOneWidget);
  });

  testWidgets('Add to playlist opens the playlist sheet for the playing song',
      (tester) async {
    MusicPlaylistService.instance.playlists.value = [
      MusicPlaylist.favorites(),
      MusicPlaylist.disliked(),
      MusicPlaylist(id: 'p1', name: 'Road trip'),
    ];
    final song = Track.local(filePath: '/fake/song.mp3', title: 'Song');
    MusicLibraryService.instance.tracks.value = [song];
    MusicPlayerService.handler.restore([song]);

    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add to playlist'));
    await tester.pumpAndSettle();

    expect(find.text('New playlist'), findsOneWidget);
    expect(find.text('Road trip'), findsOneWidget);
    await tester.tap(find.text('Road trip'));
    await tester.pump();
    expect(MusicPlaylistService.instance.byId('p1')!.trackIds, [song.id]);
  });

  testWidgets('elapsed time, bar and length are on one line', (tester) async {
    final song = Track.local(filePath: '/fake/one-line.mp3', title: 'Song');
    MusicPlayerService.handler.restore([song]);
    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    final slider = tester.getCenter(find.byType(Slider)).dy;
    expect(tester.getCenter(find.text('00:00')).dy, closeTo(slider, 2));
    // Length not known yet: an empty bar, not a full one.
    expect(find.text('--:--'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
  });
}
