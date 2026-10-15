import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/services/server_catalog.dart';
import 'package:best_music/services/track_file_actions.dart';
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

/// Deleting and moving songs from their ⋮ menu (TrackFileActions).
void main() {
  late Directory docs;
  late Directory musicDir;
  final actions = TrackFileActions.instance;
  final library = MusicLibraryService.instance;
  final playlists = MusicPlaylistService.instance;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('bestmusic_actions_');
    musicDir = await Directory.systemTemp.createTemp('bestmusic_music_');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    Config.musicFolder = musicDir.path;
    Config.musicExcludedSubfolders = [];
    Config.subsonicServerUrl = 'http://hally.local:4533';
    Config.subsonicUsername = 'me';
    Config.subsonicPassword = 'secret';
    library.resetForTest();
    playlists.resetForTest();
    await playlists.load();
    ServerCatalog.instance.resetForTest();
    actions.httpClient = null;
  });

  tearDown(() async {
    actions.httpClient = null;
    Config.musicFolder = '';
    Config.subsonicServerUrl = '';
    Config.subsonicUsername = '';
    Config.subsonicPassword = '';
    await docs.delete(recursive: true);
    await musicDir.delete(recursive: true);
  });

  String norm(String p) => MusicLibraryService.normalizePath(p);

  Future<Track> phoneSong(String rel) async {
    final file = File('${musicDir.path}/$rel');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([0, 1, 2]);
    final tracks = await library.rescan();
    return tracks.firstWhere((t) => norm(t.filePath!).endsWith('/$rel'));
  }

  group('phone songs', () {
    test('delete removes the file, the library entry and playlist entries',
        () async {
      final track = await phoneSong('Chill/Woof.mp3');
      await playlists.toggleFavorite(track.id);

      expect(await actions.delete(track), isNull);
      expect(await File(track.filePath!).exists(), isFalse);
      expect(library.byId(track.id), isNull);
      expect(playlists.isFavorite(track.id), isFalse);
    });

    test('move renames the file into another folder; playlists follow',
        () async {
      final track = await phoneSong('Chill/Woof.mp3');
      await playlists.toggleFavorite(track.id);
      expect(TrackFileActions.folderOf(track), 'Chill');

      expect(await actions.move(track, 'Party/2026'), isNull);
      final target = File('${musicDir.path}/Party/2026/Woof.mp3');
      expect(await target.exists(), isTrue);
      expect(await File(track.filePath!).exists(), isFalse);
      expect(library.byId(track.id), isNull);
      final moved = library.tracks.value.single;
      expect(norm(moved.filePath!), norm(target.path));
      expect(moved.id, 'local:${moved.filePath}');
      expect(playlists.isFavorite(moved.id), isTrue);
      expect(playlists.favorites.trackIds, isNot(contains(track.id)));
    });

    test('move refuses to overwrite a file with the same name', () async {
      final track = await phoneSong('Chill/Woof.mp3');
      await File('${musicDir.path}/Woof.mp3').writeAsBytes([9]);
      expect(await actions.move(track, ''), contains('already'));
      expect(await File(track.filePath!).exists(), isTrue);
    });

    test('the folder list holds the top and every subfolder', () async {
      final track = await phoneSong('Chill/Woof.mp3');
      await Directory('${musicDir.path}/Rock/Old').create(recursive: true);
      expect(await actions.foldersFor(track),
          containsAll(['', 'Chill', 'Rock', 'Rock/Old']));
    });
  });

  group('server songs', () {
    final serverSong = Track.subsonic(
        remoteId: '9', remotePath: 'music/Chill/Gold.mp3', title: 'Gold');

    setUp(() async {
      await ServerCatalog.instance.replace([serverSong]);
      await library.replaceServerTracks([serverSong]);
    });

    test('delete asks the Pi and drops the song everywhere', () async {
      late http.Request sent;
      actions.httpClient = MockClient((request) async {
        sent = request;
        return http.Response('{"deleted": true}', 200);
      });

      expect(await actions.delete(serverSong), isNull);
      expect(sent.url.port, 4534);
      expect(sent.url.path, '/api/music/delete');
      expect(sent.url.queryParameters['u'], 'me');
      expect(jsonDecode(sent.body),
          {'id': '9', 'path': 'music/Chill/Gold.mp3'});
      expect(ServerCatalog.instance.songs.value, isEmpty);
      expect(library.byId(serverSong.id), isNull);
    });

    test('move sends the target folder and takes the new path', () async {
      late http.Request sent;
      actions.httpClient = MockClient((request) async {
        sent = request;
        return http.Response('{"path": "/music/Party/Gold.mp3"}', 200);
      });

      expect(await actions.move(serverSong, 'music/Party'), isNull);
      expect(sent.url.path, '/api/music/move');
      expect(jsonDecode(sent.body)['to'], 'music/Party');
      expect(ServerCatalog.instance.songs.value.single.remotePath,
          'music/Party/Gold.mp3');
      expect(library.byId(serverSong.id)!.remotePath, 'music/Party/Gold.mp3');
    });

    test('a Pi without the endpoints says it needs an update', () async {
      actions.httpClient =
          MockClient((_) async => http.Response('Not Found', 404));
      expect(await actions.delete(serverSong),
          TrackFileActions.notSupportedMessage);
      expect(ServerCatalog.instance.songs.value, hasLength(1));
    });

    test('folders come from the server catalog', () async {
      expect(await actions.foldersFor(serverSong),
          containsAll(['', 'music', 'music/Chill']));
    });
  });

  test('cleanFolder drops slashes and dot parts', () {
    expect(TrackFileActions.cleanFolder(' /Chill//Deep/ '), 'Chill/Deep');
    expect(TrackFileActions.cleanFolder('../x/./y'), 'x/y');
    expect(TrackFileActions.cleanFolder(r'a\b'), 'a/b');
  });

  test('YouTube streams cannot be deleted or moved', () {
    expect(
        TrackFileActions.canManage(
            Track.youtube(videoId: 'abc', title: 'Video')),
        isFalse);
  });
}
