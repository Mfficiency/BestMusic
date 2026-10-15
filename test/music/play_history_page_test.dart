import 'dart:io';

import 'package:best_music/services/now_playing.dart';
import 'package:best_music/services/play_history_service.dart';
import 'package:best_music/ui/play_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// Tools → Play history (SPEC.md "Play history"): grouped per month and
/// day, newest first, entries deletable one by one or per day.
void main() {
  late Directory tempDir;
  final history = PlayHistoryService.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    history.resetForTest();
    NowPlaying.trackId.value = null;
  });

  tearDown(() async {
    NowPlaying.trackId.value = null;
    await tempDir.delete(recursive: true);
  });

  PlayHistoryEntry entry(String id, String title, DateTime at,
          {bool video = false, String artist = ''}) =>
      PlayHistoryEntry(
          id: id,
          trackId: 'local:/m/$id.mp3',
          title: title,
          artist: artist,
          isVideo: video,
          playedAt: at);

  test('day labels: Today, Yesterday, then weekday + date', () {
    final now = DateTime(2026, 10, 15, 20);
    expect(playHistoryDayLabel(DateTime(2026, 10, 15, 1), now: now), 'Today');
    expect(
        playHistoryDayLabel(DateTime(2026, 10, 14, 23), now: now), 'Yesterday');
    expect(playHistoryDayLabel(DateTime(2026, 9, 30, 8), now: now),
        'Wednesday 30 September');
    expect(playHistoryMonthLabel(DateTime(2026, 9, 30)), 'September 2026');
    expect(playHistoryTime(DateTime(2026, 9, 30, 8, 5)), '08:05');
  });

  testWidgets('groups entries under month and day headers with their time',
      (tester) async {
    history.entries.value = [
      entry('c', 'Third', DateTime(2026, 9, 30, 21, 15),
          video: true, artist: 'Channel'),
      entry('b', 'Second', DateTime(2026, 9, 30, 8, 5), artist: 'Band'),
      entry('a', 'First', DateTime(2026, 8, 31, 23, 59)),
    ];

    await tester.pumpWidget(const MaterialApp(home: PlayHistoryPage()));

    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('August 2026'), findsOneWidget);
    expect(find.text('Wednesday 30 September'), findsOneWidget);
    expect(find.text('Monday 31 August'), findsOneWidget);
    expect(find.text('2 played'), findsOneWidget);
    expect(find.text('21:15 · Video · Channel'), findsOneWidget);
    expect(find.text('08:05 · Band'), findsOneWidget);
    // Newest first: September's entries above August's header.
    expect(tester.getTopLeft(find.text('Second')).dy,
        lessThan(tester.getTopLeft(find.text('August 2026')).dy));
  });

  testWidgets('deletes one entry, then a whole day', (tester) async {
    history.entries.value = [
      entry('c', 'Third', DateTime(2026, 9, 30, 21)),
      entry('b', 'Second', DateTime(2026, 9, 30, 8)),
      entry('a', 'First', DateTime(2026, 8, 31, 12)),
    ];
    await tester.pumpWidget(const MaterialApp(home: PlayHistoryPage()));

    final thirdDelete = find.descendant(
        of: find.ancestor(
            of: find.text('Third'), matching: find.byType(ListTile)),
        matching: find.byTooltip('Delete from history'));
    await tester.tap(thirdDelete);
    await tester.pump();
    expect(find.text('Third'), findsNothing);
    expect(find.text('1 played'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Delete this day').first);
    await tester.pump();
    expect(find.text('Second'), findsNothing);
    expect(find.text('September 2026'), findsNothing);
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('Clear history asks first, then empties the list',
      (tester) async {
    history.entries.value = [entry('a', 'First', DateTime(2026, 8, 31, 12))];
    await tester.pumpWidget(const MaterialApp(home: PlayHistoryPage()));

    await tester.tap(find.byTooltip('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing played yet'), findsOneWidget);
  });

  testWidgets('the entry of the playing song is highlighted', (tester) async {
    history.entries.value = [
      entry('b', 'Second', DateTime(2026, 9, 30, 8)),
      entry('a', 'First', DateTime(2026, 9, 30, 7)),
    ];
    NowPlaying.trackId.value = 'local:/m/a.mp3';
    await tester.pumpWidget(const MaterialApp(home: PlayHistoryPage()));

    ListTile tileOf(String title) => tester.widget<ListTile>(
        find.ancestor(of: find.text(title), matching: find.byType(ListTile)));
    expect(tileOf('First').selected, isTrue);
    expect(tileOf('Second').selected, isFalse);
  });
}
