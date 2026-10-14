import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/server_catalog.dart';
import 'package:best_music/services/server_offline_store.dart';
import 'package:best_music/services/server_upload_service.dart';
import 'package:best_music/services/subsonic_library_sync.dart';
import 'package:best_music/ui/server_tab.dart';
import 'package:flutter/material.dart';
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

Track song(String id, String path,
        {String title = '', String artist = 'Kygo', int ms = 200000}) =>
    Track.subsonic(
        remoteId: id,
        remotePath: path,
        title: title.isEmpty ? id : title,
        artist: artist,
        durationMs: ms,
        sizeBytes: 5);

void main() {
  late Directory docs;
  late Directory musicDir;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('bestmusic_server_');
    musicDir = await Directory.systemTemp.createTemp('bestmusic_phone_');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    Config.musicFolder = musicDir.path;
    Config.subsonicServerUrl = 'http://hally.local:4533';
    Config.subsonicUsername = 'me';
    Config.subsonicPassword = 'secret';
    Config.subsonicLastSync = null;
    MusicLibraryService.instance.resetForTest();
    ServerCatalog.instance.resetForTest();
    ServerOfflineStore.instance.resetForTest();
    ServerOfflineStore.instance.httpClient = null;
    ServerUploadService.instance.httpClient = null;
    SubsonicLibrarySync.instance.syncOffline = false;
  });

  tearDown(() async {
    Config.musicFolder = '';
    Config.subsonicServerUrl = '';
    Config.subsonicUsername = '';
    Config.subsonicPassword = '';
    SubsonicLibrarySync.instance.syncOffline = true;
    await docs.delete(recursive: true);
    await musicDir.delete(recursive: true);
  });

  group('ServerCatalog', () {
    final all = [
      song('1', 'Chill/Stay.mp3'),
      song('2', 'Chill/Deep/Firestone.mp3'),
      song('3', 'Phone/Rock/Song.mp3'),
      song('4', 'Loose.mp3'),
    ];

    test('folders and songs of one folder', () {
      final top = ServerCatalog.folder(all, '');
      expect(top.folders.map((f) => f.name), ['Chill', 'Phone']);
      expect(top.folders.first.songs, hasLength(2));
      expect(top.songs.map((s) => s.remoteId), ['4']);
      final chill = ServerCatalog.folder(all, 'Chill');
      expect(chill.folders.map((f) => f.path), ['Chill/Deep']);
      expect(chill.songs.map((s) => s.remoteId), ['1']);
      expect(ServerCatalog.songsUnder(all, 'Chill'), hasLength(2));
    });

    test('sameSong: tags written differently, or the same file name', () {
      final tagged = song('a', 'Chill/x.mp3',
          title: 'This Girl',
          artist: 'Kungs vs Cookin’ on 3 Burners',
          ms: 197540);
      final untagged = song('b', 'Chill/y.mp3',
          title: 'Kungs vs Cookinâ on 3 Burners - This Girl',
          artist: 'Kungs vs Cookin_ on 3 Burners',
          ms: 195660);
      expect(sameSong(tagged, untagged), isTrue);
      final live = song('c', 'Chill/z.mp3',
          title: 'This Girl',
          artist: 'Kungs vs Cookin’ on 3 Burners',
          ms: 230000);
      expect(sameSong(tagged, live), isFalse);
      final phone = Track.local(filePath: '/sdcard/Music/x.mp3', title: 'x');
      expect(sameSong(phone, tagged), isTrue);
    });
  });

  test('the library leaves out server songs that are on the phone', () async {
    await File('${musicDir.path}/Stay.mp3').writeAsBytes([0, 0, 0]);
    await MusicLibraryService.instance.rescan();
    final count = await MusicLibraryService.instance.replaceServerTracks(
        [song('1', 'Phone/Stay.mp3'), song('2', 'Chill/Firestone.mp3')]);
    expect(count, 1);
    final ids = MusicLibraryService.instance.tracks.value.map((t) => t.id);
    expect(ids, contains('subsonic:2'));
    expect(ids, isNot(contains('subsonic:1')));
  });

  group('ServerOfflineStore', () {
    final store = ServerOfflineStore.instance;

    setUp(() async {
      await ServerCatalog.instance.replace([
        song('1', 'Chill/Stay.mp3'),
        song('2', 'Chill/Deep/Firestone.mp3'),
        song('3', 'Rock/Song.mp3'),
      ]);
      store.catalog = ServerCatalog.instance;
      store.httpClient = MockClient((request) async {
        expect(request.url.path, '/rest/download');
        return http.Response('file-${request.url.queryParameters['id']}', 200);
      });
    });

    test('keep a folder downloads its songs; the nearest rule wins', () async {
      await store.keep('Chill');
      expect(store.localFileFor('1'), isNotNull);
      expect(store.localFileFor('2'), isNotNull);
      expect(store.localFileFor('3'), isNull);
      expect(await File(store.localFileFor('1')!).readAsString(), 'file-1');
      final chill =
          ServerCatalog.songsUnder(ServerCatalog.instance.songs.value, 'Chill');
      expect(store.stateOfSongs(chill), OfflineState.kept);

      await store.freeUp('Chill/Deep');
      expect(store.localFileFor('2'), isNull);
      expect(store.wantsKept('Chill/Stay.mp3'), isTrue);
      expect(store.stateOfSongs(chill), OfflineState.partly);

      final kept = store.localFileFor('1')!;
      await store.freeUp('Chill');
      expect(store.localFileFor('1'), isNull);
      expect(File(kept).existsSync(), isFalse);
      expect(store.stateOfSongs(chill), OfflineState.online);
    });

    test('keep one song only', () async {
      await store.keep('Rock/Song.mp3');
      expect(store.localFileFor('3'), isNotNull);
      expect(store.localFileFor('1'), isNull);
    });
  });

  group('ServerUploadService', () {
    final upload = ServerUploadService.instance;

    test('asks the Pi on port 4534 and uploads only what it lacks', () async {
      await Directory('${musicDir.path}/Rock').create();
      await File('${musicDir.path}/Rock/New.mp3').writeAsBytes([1, 2, 3]);
      await File('${musicDir.path}/Old.mp3').writeAsBytes([4, 5]);
      await MusicLibraryService.instance.rescan();

      final puts = <String, List<int>>{};
      upload.httpClient = MockClient((request) async {
        expect(request.url.port, ServerUploadService.port);
        expect(request.url.host, 'hally.local');
        expect(request.url.queryParameters['u'], 'me');
        expect(request.url.queryParameters['t'], isNotEmpty);
        if (request.url.path == '/api/music/check') {
          final files = (jsonDecode(request.body) as Map)['files'] as List;
          expect(files.map((f) => f['path']),
              containsAll(['Rock/New.mp3', 'Old.mp3']));
          return http.Response(
              jsonEncode({
                'have': ['Old.mp3']
              }),
              200);
        }
        expect(request.method, 'PUT');
        puts[request.url.queryParameters['path']!] = request.bodyBytes;
        return http.Response(jsonEncode({'stored': 'Phone/x'}), 201);
      });

      final pending = await upload.pending();
      expect(pending!.map((p) => p.path), ['Rock/New.mp3']);
      expect(await upload.upload(pending), 1);
      expect(puts['Rock/New.mp3'], [1, 2, 3]);
      expect(upload.progress.value, isNull);
    });

    test('pending is null when the Pi refuses the login', () async {
      await File('${musicDir.path}/A.mp3').writeAsBytes([1]);
      await MusicLibraryService.instance.rescan();
      upload.httpClient = MockClient((_) async => http.Response('{}', 401));
      expect(await upload.pending(), isNull);
    });
  });

  test('a sync fills the catalog with every server song', () async {
    SubsonicLibrarySync.instance.client.httpClient =
        MockClient((request) async {
      return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'searchResult3': {
                'song': [
                  {
                    'id': '9',
                    'title': 'Gold',
                    'artist': 'Bondax',
                    'path': 'Chill/Gold.mp3',
                    'size': 7
                  }
                ]
              }
            }
          }),
          200);
    });
    addTearDown(
        () => SubsonicLibrarySync.instance.client.httpClient = http.Client());
    expect(await SubsonicLibrarySync.instance.syncNow(), 1);
    final s = ServerCatalog.instance.songs.value.single;
    expect(s.remotePath, 'Chill/Gold.mp3');
    expect(s.sizeBytes, 7);
  });

  group('Server tab', () {
    testWidgets('without a server it asks for the login', (tester) async {
      Config.subsonicUsername = '';
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: ServerTab())));
      await tester.pump();
      expect(find.text('Connect your music server'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('shows folders, then the songs inside', (tester) async {
      ServerCatalog.instance.songs.value = [
        song('1', 'Chill/Stay.mp3', title: 'Stay'),
        song('2', 'Chill/Firestone.mp3', title: 'Firestone'),
      ];
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: ServerTab())));
      await tester.pump();
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Upload phone music'), findsOneWidget);
      expect(find.text('Chill'), findsOneWidget);
      expect(find.text('2 songs'), findsOneWidget);
      expect(find.byTooltip('Online only'), findsOneWidget);

      await tester.tap(find.text('Chill'));
      await tester.pumpAndSettle();
      expect(find.text('Stay'), findsOneWidget);
      expect(find.text('Firestone'), findsOneWidget);
    });
  });
}
