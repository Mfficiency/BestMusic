import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

/// Every song on the music server, as the last sync saw it
/// (`server_catalog.json`) — what the Server tab shows as folders. The
/// library gets the same songs minus the ones already on the phone
/// (`MusicLibraryService.replaceServerTracks`), so each song shows up once.
class ServerCatalog {
  ServerCatalog._();

  static final ServerCatalog instance = ServerCatalog._();

  static const _fileName = 'server_catalog.json';

  final ValueNotifier<List<Track>> songs = ValueNotifier<List<Track>>([]);
  bool _loaded = false;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final List<dynamic> data = jsonDecode(await f.readAsString());
        songs.value = data
            .whereType<Map>()
            .map((e) => Track.fromJson(Map<String, dynamic>.from(e)))
            .where((t) => t.remoteId != null)
            .toList();
      }
    } catch (_) {}
  }

  Future<void> replace(List<Track> fresh) async {
    songs.value = List.unmodifiable(fresh);
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(fresh.map((t) => t.toJson()).toList()),
          flush: true);
    } catch (_) {}
  }

  Future<void> clear() => replace(const []);

  @visibleForTesting
  void resetForTest() {
    songs.value = [];
    _loaded = false;
  }

  /// The folder [song] sits in on the server ('' = the top), from its real
  /// path; songs without one group by artist/album like most servers.
  static String folderOf(Track song) {
    final path = song.remotePath;
    if (path == null) {
      final parts = [
        if (song.artist.isNotEmpty) song.artist,
        if (song.album.isNotEmpty) song.album,
      ];
      return parts.join('/');
    }
    final slash = path.lastIndexOf('/');
    return slash > 0 ? path.substring(0, slash) : '';
  }

  /// The view of one folder: its direct subfolders (with how many songs are
  /// under each) and the songs right in it.
  static ServerFolder folder(List<Track> all, String prefix) {
    final sub = <String, List<Track>>{};
    final here = <Track>[];
    for (final song in all) {
      final f = folderOf(song);
      if (f == prefix) {
        here.add(song);
      } else if (prefix.isEmpty || f.startsWith('$prefix/')) {
        final rest = prefix.isEmpty ? f : f.substring(prefix.length + 1);
        final name = rest.split('/').first;
        sub.putIfAbsent(name, () => []).add(song);
      }
    }
    final names = sub.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    here.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return ServerFolder(
      path: prefix,
      folders: [
        for (final n in names)
          ServerSubfolder(
              name: n, path: prefix.isEmpty ? n : '$prefix/$n', songs: sub[n]!),
      ],
      songs: here,
    );
  }

  /// Every song in [prefix] and below.
  static List<Track> songsUnder(List<Track> all, String prefix) => [
        for (final s in all)
          if (prefix.isEmpty ||
              folderOf(s) == prefix ||
              folderOf(s).startsWith('$prefix/'))
            s,
      ];
}

class ServerFolder {
  const ServerFolder(
      {required this.path, required this.folders, required this.songs});

  final String path;
  final List<ServerSubfolder> folders;
  final List<Track> songs;
}

class ServerSubfolder {
  const ServerSubfolder(
      {required this.name, required this.path, required this.songs});

  final String name;
  final String path;

  /// Every song in this folder and below.
  final List<Track> songs;
}

/// Whether two tracks are the same song — the phone's copy of a server song
/// (uploaded from this phone, or the same file copied both places). Same
/// file name and size, or same artist + title (letters and digits only,
/// "Artist - Title" in the title counts too) with lengths within 2 seconds:
/// the same rule the Pi's nightly duplicate clean-up uses.
bool sameSong(Track a, Track b) {
  final da = a.durationMs, db = b.durationMs;
  final closeLength = da == null || db == null || (da - db).abs() <= 2000;
  if (!closeLength) return false;
  final na = fileNameOf(a);
  if (na.isNotEmpty && na == fileNameOf(b)) return true;
  final ka = songKey(a);
  return ka.isNotEmpty && ka == songKey(b);
}

/// Finds, among many tracks, the ones that are [sameSong] as a given one —
/// indexed by file name and [songKey] so a big library stays quick.
class SameSongIndex {
  SameSongIndex(Iterable<Track> tracks) {
    for (final t in tracks) {
      final n = fileNameOf(t);
      if (n.isNotEmpty) _byName.putIfAbsent(n, () => []).add(t);
      final k = songKey(t);
      if (k.isNotEmpty) _byKey.putIfAbsent(k, () => []).add(t);
    }
  }

  final Map<String, List<Track>> _byName = {};
  final Map<String, List<Track>> _byKey = {};

  Track? match(Track t) {
    for (final c in [...?_byName[fileNameOf(t)], ...?_byKey[songKey(t)]]) {
      if (sameSong(t, c)) return c;
    }
    return null;
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Normalised artist + title ('' when there is no artist to go on).
String songKey(Track t) {
  final a = _norm(t.artist), title = _norm(t.title);
  if (title.isEmpty) return '';
  if (a.isNotEmpty && title.startsWith(a) && title.length > a.length) {
    return title;
  }
  return a.isEmpty ? '' : a + title;
}

/// The lower-case file name of a phone file or server song ('' if none).
String fileNameOf(Track t) {
  final p = (t.filePath ?? t.remotePath ?? '').replaceAll('\\', '/');
  final slash = p.lastIndexOf('/');
  return (slash >= 0 ? p.substring(slash + 1) : p).toLowerCase();
}
