import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/models/music_playlist.dart';
import 'package:best_music/models/playlist_rule.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/ui/music_player_page.dart';
import 'package:best_music/ui/playlist_edit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// Rename, edit and delete playlists (SPEC.md "Playlists: rename, edit,
/// delete").
void main() {
  late Directory tempDir;
  final service = MusicPlaylistService.instance;
  final a = Track.local(filePath: '/m/a.mp3', title: 'Song A');
  final b = Track.local(filePath: '/m/b.mp3', title: 'Song B');
  final c = Track.local(filePath: '/m/c.mp3', title: 'Song C');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    Config.musicFolder = '/does/not/matter';
    Config.musicTrackSortField = 'deviceDate';
    Config.musicTrackSortAscending = false;
    MusicLibraryService.instance.resetForTest();
    MusicLibraryService.instance.tracks.value = [a, b, c];
    service.resetForTest();
    service.playlists.value = [
      MusicPlaylist.favorites(),
      MusicPlaylist.disliked(),
      MusicPlaylist(id: 'p1', name: 'Road trip', trackIds: [a.id, b.id, c.id]),
      MusicPlaylist(
          id: 'r1',
          name: 'Rock',
          kind: PlaylistKind.rule,
          ruleSet: const PlaylistRuleSet(conditions: [])),
    ];
  });

  tearDown(() async {
    Config.musicFolder = '';
    await tempDir.delete(recursive: true);
  });

  Future<void> drainIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  group('service', () {
    test('renamePlaylist renames list and rule playlists, never system ones',
        () async {
      await service.renamePlaylist('p1', '  Summer  ');
      await service.renamePlaylist('r1', 'Hard rock');
      await service.renamePlaylist(MusicPlaylist.favoritesId, 'Nope');
      await service.renamePlaylist('p1', '   ');

      expect(service.byId('p1')!.name, 'Summer');
      expect(service.byId('r1')!.name, 'Hard rock');
      expect(service.favorites.name, 'Favorites');
    });

    test('setTrackOrder reorders, keeping hidden (missing) songs at the end',
        () async {
      service.byId('p1')!.trackIds.add('local:/gone.mp3');
      await service.setTrackOrder('p1', [c.id, a.id, b.id, 'not-in-it']);
      expect(service.byId('p1')!.trackIds,
          [c.id, a.id, b.id, 'local:/gone.mp3']);
    });
  });

  Future<void> openPlaylistsTab(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MusicPlayerPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
  }

  Finder optionsOf(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
      matching: find.byTooltip('Playlist options'));

  testWidgets('only hand-made and rule playlists get the options menu',
      (tester) async {
    await openPlaylistsTab(tester);
    expect(optionsOf('Road trip'), findsOneWidget);
    expect(optionsOf('Rock'), findsOneWidget);
    expect(optionsOf('Favorites'), findsNothing);
    expect(optionsOf('Last Added'), findsNothing);
  });

  testWidgets('Rename from the Playlists tab, pre-filled with the old name',
      (tester) async {
    await openPlaylistsTab(tester);
    await tester.tap(optionsOf('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Rename playlist'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Road trip'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Summer 2026');
    await tester.tap(find.text('Save'));
    await drainIo(tester);
    await tester.pumpAndSettle();

    expect(service.byId('p1')!.name, 'Summer 2026');
    expect(find.text('Summer 2026'), findsOneWidget);
  });

  testWidgets('Delete asks first; Cancel keeps it, Delete removes it',
      (tester) async {
    await openPlaylistsTab(tester);
    await tester.tap(optionsOf('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Road trip"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.byId('p1'), isNotNull);

    await tester.tap(optionsOf('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await drainIo(tester);

    expect(service.byId('p1'), isNull);
    expect(find.text('Road trip'), findsNothing);
    // The songs themselves stay.
    expect(MusicLibraryService.instance.tracks.value, hasLength(3));
  });

  testWidgets('deleting from the playlist page closes the page',
      (tester) async {
    await openPlaylistsTab(tester);
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    expect(find.text('Song A'), findsOneWidget);

    await tester.tap(find.byTooltip('Playlist options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await drainIo(tester);
    await tester.pumpAndSettle();

    expect(service.byId('p1'), isNull);
    expect(find.text('Song A'), findsNothing);
    expect(find.text('New playlist'), findsOneWidget); // back on the tab
  });

  testWidgets('Edit songs lists the songs in order and removes one',
      (tester) async {
    await openPlaylistsTab(tester);
    await tester.tap(optionsOf('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit songs'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Road trip'), findsOneWidget);
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Song A'), lessThan(y('Song B')));
    expect(y('Song B'), lessThan(y('Song C')));
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));

    await tester.tap(find.descendant(
        of: find.ancestor(
            of: find.text('Song B'), matching: find.byType(ListTile)),
        matching: find.byTooltip('Remove from playlist')));
    await drainIo(tester);
    expect(service.byId('p1')!.trackIds, [a.id, c.id]);
    expect(find.text('Song B'), findsNothing);
  });

  testWidgets('Edit rules opens the rules editor for a rule playlist',
      (tester) async {
    await openPlaylistsTab(tester);
    await tester.tap(optionsOf('Rock'));
    await tester.pumpAndSettle();
    expect(find.text('Edit songs'), findsNothing);
    await tester.tap(find.text('Edit rules'));
    await tester.pumpAndSettle();
    expect(find.byType(EditPlaylistSongsPage), findsNothing);
    expect(find.widgetWithText(TextField, 'Rock'), findsOneWidget);
  });
}
