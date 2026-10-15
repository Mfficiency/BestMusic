import 'dart:convert';
import 'dart:io';

import 'package:best_music/models/track.dart';
import 'package:best_music/services/play_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  late Directory tempDir;
  final history = PlayHistoryService.instance;
  final song = Track.local(filePath: '/m/a.mp3', title: 'Song A', artist: 'X');
  final other = Track.local(filePath: '/m/b.mp3', title: 'Song B');
  final video = Track.youtube(videoId: 'v1', title: 'A video', artist: 'Chan');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    history.resetForTest();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('record keeps newest first with title, artist and kind', () async {
    await history.load();
    await history.record(song, now: DateTime(2026, 10, 1, 9));
    await history.record(Track.youtube(videoId: 'v1', title: 'A video'),
        now: DateTime(2026, 10, 1, 10));

    final entries = history.entries.value;
    expect(entries.map((e) => e.title), ['A video', 'Song A']);
    expect(entries.last.artist, 'X');
    expect(entries.last.isVideo, isFalse);
    expect(entries.last.trackId, song.id);
  });

  test('the same track again within 30 minutes is one entry, later is two',
      () async {
    await history.load();
    final start = DateTime(2026, 10, 1, 9);
    await history.record(song, now: start);
    await history.record(song, now: start.add(const Duration(minutes: 10)));
    expect(history.entries.value, hasLength(1));

    await history.record(song, now: start.add(const Duration(minutes: 45)));
    expect(history.entries.value, hasLength(2));

    // A different track in between always counts.
    await history.record(other, now: start.add(const Duration(minutes: 46)));
    await history.record(song, now: start.add(const Duration(minutes: 47)));
    expect(history.entries.value, hasLength(4));
  });

  test('entries older than 90 days are dropped on load and on record',
      () async {
    final now = DateTime(2026, 10, 15, 12);
    await File('${tempDir.path}/${PlayHistoryService.fileName}')
        .writeAsString(jsonEncode([
      PlayHistoryEntry(
              id: 'old',
              trackId: song.id,
              title: 'Old',
              playedAt: now.subtract(const Duration(days: 91)))
          .toJson(),
      PlayHistoryEntry(
              id: 'recent',
              trackId: song.id,
              title: 'Recent',
              playedAt: now.subtract(const Duration(days: 89)))
          .toJson(),
    ]));

    await history.load(now: now);
    expect(history.entries.value.map((e) => e.id), ['recent']);

    // Two days on, "recent" is past 90 days too.
    await history.record(other, now: now.add(const Duration(days: 2)));
    expect(history.entries.value.map((e) => e.title), ['Song B']);
  });

  test('delete, deleteDay and clear, all persisted', () async {
    await history.load();
    await history.record(song, now: DateTime(2026, 10, 1, 9));
    await history.record(other, now: DateTime(2026, 10, 1, 10));
    await history.record(video, now: DateTime(2026, 10, 2, 8));
    await history.record(song, now: DateTime(2026, 10, 3, 8));

    final videoEntry =
        history.entries.value.firstWhere((e) => e.trackId == video.id);
    await history.delete(videoEntry.id);
    await history.deleteDay(DateTime(2026, 10, 1));
    expect(history.entries.value.map((e) => e.playedAt),
        [DateTime(2026, 10, 3, 8)]);

    history.resetForTest();
    await history.load(now: DateTime(2026, 10, 4));
    expect(history.entries.value, hasLength(1));

    await history.clear();
    history.resetForTest();
    await history.load();
    expect(history.entries.value, isEmpty);
  });
}
