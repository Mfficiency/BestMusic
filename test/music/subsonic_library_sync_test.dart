import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/server_catalog.dart';
import 'package:best_music/services/subsonic_client.dart';
import 'package:best_music/services/subsonic_library_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Map<String, dynamic> _song(int i) => {
      'id': 'song-$i',
      'title': 'Song $i',
      'artist': 'Artist',
      'album': 'Album',
      'genre': 'Rock',
      'year': 1999,
      'duration': 200,
      'bpm': i.isEven ? 120 : 0,
    };

/// A fake Navidrome holding [total] songs, answering paged `search3`.
MockClient _server(int total, {List<Uri>? log, bool failSecondPage = false}) {
  return MockClient((request) async {
    log?.add(request.url);
    final q = request.url.queryParameters;
    if (request.url.path.endsWith('/rest/ping')) {
      return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'}
          }),
          200);
    }
    final count = int.parse(q['songCount'] ?? '20');
    final offset = int.parse(q['songOffset'] ?? '0');
    if (failSecondPage && offset > 0) return http.Response('boom', 500);
    final songs = [
      for (var i = offset; i < total && i < offset + count; i++) _song(i)
    ];
    return http.Response(
        jsonEncode({
          'subsonic-response': {
            'status': 'ok',
            'searchResult3': {'song': songs},
          }
        }),
        200);
  });
}

void main() {
  late Directory appDocsDir;
  final client = SubsonicClient.instance;
  final sync = SubsonicLibrarySync.instance;
  final library = MusicLibraryService.instance;

  setUp(() async {
    appDocsDir = await Directory.systemTemp.createTemp('bestmusic_sync_');
    PathProviderPlatform.instance = _FakePathProvider(appDocsDir.path);
    Config.musicFolder = '';
    Config.subsonicServerUrl = 'http://hally.local:4533';
    Config.subsonicUsername = 'me';
    Config.subsonicPassword = 'secret';
    Config.subsonicSyncWindow = Config.defaultSubsonicSyncWindow;
    Config.subsonicLastSync = null;
    library.resetForTest();
    ServerCatalog.instance.resetForTest();
    sync.syncOffline = false;
  });

  tearDown(() async {
    client.httpClient = http.Client();
    Config.subsonicServerUrl = '';
    Config.subsonicUsername = '';
    Config.subsonicPassword = '';
    Config.subsonicLastSync = null;
    await appDocsDir.delete(recursive: true);
  });

  group('SubsonicClient', () {
    test('streams the original file: format=raw, never a transcode', () {
      final uri = client.streamUri('song-1');
      expect(uri.queryParameters['format'], 'raw');
      expect(uri.queryParameters.containsKey('maxBitRate'), isFalse);
    });

    test('allSongs pages through the whole library', () async {
      final log = <Uri>[];
      client.httpClient = _server(SubsonicClient.pageSize + 20, log: log);
      final songs = await client.allSongs();
      expect(songs, hasLength(SubsonicClient.pageSize + 20));
      expect(log, hasLength(2));
      expect(
          log.last.queryParameters['songOffset'], '${SubsonicClient.pageSize}');
      expect(log.first.queryParameters['query'], '');
      final first = songs!.first;
      expect(first.source, TrackSource.subsonic);
      expect(first.id, 'subsonic:song-0');
      expect(first.genre, 'Rock');
      expect(first.year, 1999);
      expect(first.bpm, 120);
      expect(songs[1].bpm, isNull); // 0 = unknown
      expect(first.durationMs, 200000);
    });

    test('allSongs returns null when a page fails (no half lists)', () async {
      client.httpClient =
          _server(SubsonicClient.pageSize + 5, failSecondPage: true);
      expect(await client.allSongs(), isNull);
    });

    test('ping is true against a server answering ok', () async {
      client.httpClient = _server(0);
      expect(await client.ping(), isTrue);
    });
  });

  group('night window', () {
    DateTime at(int h, int m) => DateTime(2026, 10, 14, h, m);

    test('inside/outside a normal window', () {
      expect(SubsonicLibrarySync.inWindow('01:00-06:00', at(1, 0)), isTrue);
      expect(SubsonicLibrarySync.inWindow('01:00-06:00', at(5, 59)), isTrue);
      expect(SubsonicLibrarySync.inWindow('01:00-06:00', at(6, 0)), isFalse);
      expect(SubsonicLibrarySync.inWindow('01:00-06:00', at(20, 0)), isFalse);
    });

    test('a window can cross midnight', () {
      expect(SubsonicLibrarySync.inWindow('23:00-07:00', at(23, 30)), isTrue);
      expect(SubsonicLibrarySync.inWindow('23:00-07:00', at(3, 0)), isTrue);
      expect(SubsonicLibrarySync.inWindow('23:00-07:00', at(12, 0)), isFalse);
    });

    test('validation', () {
      expect(SubsonicLibrarySync.isValidWindow('01:00-06:00'), isTrue);
      expect(SubsonicLibrarySync.isValidWindow('1-6'), isFalse);
      expect(SubsonicLibrarySync.isValidWindow('25:00-06:00'), isFalse);
    });

    test('isDue only in the window, once per night, with a server', () {
      expect(sync.isDue(at(14, 0)), isFalse);
      expect(sync.isDue(at(2, 0)), isTrue);
      Config.subsonicLastSync = at(1, 30);
      expect(sync.isDue(at(2, 0)), isFalse);
      Config.subsonicServerUrl = '';
      Config.subsonicLastSync = null;
      expect(sync.isDue(at(2, 0)), isFalse);
    });

    test('maybeSync does nothing during the day', () async {
      final log = <Uri>[];
      client.httpClient = _server(3, log: log);
      expect(await sync.maybeSync(now: DateTime(2026, 10, 14, 14)), isNull);
      expect(log, isEmpty);
    });
  });

  group('sync into the library', () {
    test('adds server songs, keeps play counts, drops removed songs', () async {
      client.httpClient = _server(3);
      expect(await sync.syncNow(), 3);
      expect(library.tracks.value, hasLength(3));
      expect(Config.subsonicLastSync, isNotNull);

      await library.incrementPlayCount('subsonic:song-1');
      client.httpClient = _server(2);
      expect(await sync.syncNow(), 2);
      expect(library.tracks.value.map((t) => t.id),
          unorderedEquals(['subsonic:song-0', 'subsonic:song-1']));
      expect(library.byId('subsonic:song-1')!.playCount, 1);
    });

    test('a failed sync keeps the library as it was', () async {
      client.httpClient = _server(2);
      await sync.syncNow();
      client.httpClient = MockClient((_) async => http.Response('down', 503));
      expect(await sync.syncNow(), isNull);
      expect(library.tracks.value, hasLength(2));
    });

    test('a folder rescan keeps the server songs', () async {
      final musicDir =
          await Directory.systemTemp.createTemp('bestmusic_music_');
      try {
        await File('${musicDir.path}/local.mp3').writeAsBytes([0, 0, 0]);
        client.httpClient = _server(2);
        await sync.syncNow();
        Config.musicFolder = musicDir.path;
        final tracks = await library.rescan();
        expect(tracks.where((t) => t.source == TrackSource.subsonic),
            hasLength(2));
        expect(
            tracks.where((t) => t.source == TrackSource.local), hasLength(1));

        Config.musicFolder = '';
        expect(await library.rescan(), hasLength(2));

        await library.removeServerTracks();
        expect(library.tracks.value, isEmpty);
      } finally {
        Config.musicFolder = '';
        await musicDir.delete(recursive: true);
      }
    });
  });
}
