import 'package:best_music/config.dart';
import 'package:best_music/models/music_playlist.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/ui/music_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = Track.local(filePath: '/fake/a.mp3', title: 'Alpha', artist: 'X');
  final b = Track.local(filePath: '/fake/b.mp3', title: 'Bravo', artist: 'X');
  final c = Track.local(filePath: '/fake/c.mp3', title: 'Charlie', artist: 'X');

  setUp(() {
    // Title A→Z, so rows are Alpha, Bravo, Charlie.
    Config.musicTrackSortField = 'title';
    Config.musicTrackSortAscending = true;
    MusicLibraryService.instance.resetForTest();
    MusicLibraryService.instance.tracks.value = [a, b, c];
    MusicPlaylistService.instance.resetForTest();
    MusicPlaylistService.instance.playlists.value = [
      MusicPlaylist.favorites(),
      MusicPlaylist.disliked(),
      MusicPlaylist(id: 'p1', name: 'Road trip'),
    ];
  });

  tearDown(() {
    Config.musicTrackSortField = 'deviceDate';
    Config.musicTrackSortAscending = false;
  });

  Future<void> showList(WidgetTester tester,
      {void Function(Track)? onRemove}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TrackListView(tracks: [a, b, c], onRemove: onRemove))));
    await tester.pumpAndSettle();
  }

  /// Lets a tapped action's real file write (the playlist save) finish —
  /// dart:io never completes inside testWidgets' fake-async zone on its own
  /// (CLAUDE.md, "Real file I/O hangs inside testWidgets").
  Future<void> drainIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  Finder row(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  /// Taps the music icon of [title]'s row.
  Future<void> tapIcon(WidgetTester tester, String title) async {
    await tester.tap(find.descendant(of: row(title), matching: find.byTooltip('Select')));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping a music icon selects; then rows tap to select',
      (tester) async {
    await showList(tester);
    expect(find.byTooltip('Sort tracks'), findsOneWidget);

    await tapIcon(tester, 'Alpha');
    expect(find.text('1 selected'), findsOneWidget);
    // The sort/play row gives way to the selection bar.
    expect(find.byTooltip('Sort tracks'), findsNothing);
    expect(find.byTooltip('Play selected'), findsOneWidget);

    // While selecting, a row tap selects instead of playing…
    await tester.tap(find.text('Bravo'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    // …and unselects again.
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(find.byTooltip('Sort tracks'), findsOneWidget);
  });

  testWidgets('long-press selects; Select all, then Select none',
      (tester) async {
    await showList(tester);

    await tester.longPress(find.text('Charlie'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

    await tester.tap(find.byTooltip('Select none'));
    await tester.pumpAndSettle();
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('back ends the selection instead of leaving', (tester) async {
    await showList(tester);
    await tapIcon(tester, 'Alpha');

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('Add selected to playlist adds them all to the picked one',
      (tester) async {
    await showList(tester);
    await tapIcon(tester, 'Alpha');
    await tester.tap(find.text('Charlie'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add selected to playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Add 2 songs to'), findsOneWidget);
    await tester.tap(find.text('Road trip'));
    await drainIo(tester);

    // In list order, and the selection is done.
    expect(MusicPlaylistService.instance.byId('p1')!.trackIds, [a.id, c.id]);
    expect(find.text('Added 2 songs to Road trip'), findsOneWidget);
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('More → Add to Favorites', (tester) async {
    await showList(tester);
    await tapIcon(tester, 'Bravo');
    await tester.tap(find.text('Charlie'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More for selected'));
    await tester.pumpAndSettle();
    // Not in a playlist: no "Remove from playlist".
    expect(find.text('Remove from playlist'), findsNothing);
    expect(find.text('Move to folder'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Add to Favorites'));
    await drainIo(tester);

    expect(MusicPlaylistService.instance.favorites.trackIds, [b.id, c.id]);
    expect(find.text('Added 2 songs to Favorites'), findsOneWidget);
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('inside a playlist: Remove from playlist removes each',
      (tester) async {
    final removed = <String>[];
    await showList(tester, onRemove: (t) => removed.add(t.id));
    await tapIcon(tester, 'Alpha');
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More for selected'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist'));
    await tester.pumpAndSettle();

    expect(removed, [a.id, b.id, c.id]);
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('Delete asks first; Cancel keeps the selection',
      (tester) async {
    await showList(tester);
    await tapIcon(tester, 'Alpha');
    await tester.tap(find.text('Bravo'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More for selected'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 songs?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  test('addAllToFavorites also takes them out of "Don\'t really like"',
      () async {
    MusicPlaylistService.instance.disliked.trackIds.add(a.id);
    await MusicPlaylistService.instance.addAllToFavorites([a.id, b.id]);
    expect(MusicPlaylistService.instance.favorites.trackIds, [a.id, b.id]);
    expect(MusicPlaylistService.instance.isDisliked(a.id), isFalse);
  });
}
