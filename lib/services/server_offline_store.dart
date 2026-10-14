import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'background_work.dart';
import 'log_service.dart';
import 'server_catalog.dart';
import 'subsonic_client.dart';

/// How much of a server folder or song is on this phone.
enum OfflineState {
  /// Streams from the server only.
  online,

  /// Chosen to keep; still downloading.
  pending,

  /// Kept and fully downloaded: plays without the server.
  kept,

  /// A folder with some songs kept and some not.
  partly,
}

/// "Always keep on this device" / "Free up space" for music server songs,
/// like OneDrive: rules on folders and songs (`server_offline.json`), the
/// nearest rule above a song wins, so a folder can be kept with one
/// subfolder freed. Kept songs are downloaded as the original file into
/// `<app documents>/server_music/<server path>` and play from there
/// (`MusicAudioHandler`); new songs in a kept folder download after the next
/// sync. Downloads run one at a time with a notification.
class ServerOfflineStore {
  ServerOfflineStore._();

  static final ServerOfflineStore instance = ServerOfflineStore._();

  static const _fileName = 'server_offline.json';
  static const _folderName = 'server_music';

  /// Rules: server path (folder or song, '' = everything) -> keep or not.
  final Map<String, bool> _rules = {};

  /// Song id -> downloaded file path.
  final Map<String, String> _files = {};

  /// Bumped on every change (the Server tab listens).
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// While downloading: "3 of 12 · Song title"; null otherwise.
  final ValueNotifier<String?> progress = ValueNotifier<String?>(null);

  bool _loaded = false;
  bool _syncing = false;
  bool _again = false;

  @visibleForTesting
  http.Client? httpClient;

  @visibleForTesting
  BackgroundWork background = const BackgroundWork();

  @visibleForTesting
  ServerCatalog catalog = ServerCatalog.instance;

  Future<Directory> _docs() => getApplicationDocumentsDirectory();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${(await _docs()).path}/$_fileName');
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      (data['rules'] as Map? ?? {}).forEach((k, v) {
        if (v is bool) _rules['$k'] = v;
      });
      (data['files'] as Map? ?? {}).forEach((k, v) {
        if (v is String) _files['$k'] = v;
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    changes.value++;
    try {
      final f = File('${(await _docs()).path}/$_fileName');
      await f.writeAsString(jsonEncode({'rules': _rules, 'files': _files}),
          flush: true);
    } catch (_) {}
  }

  /// The server path of a song (its real path, or folder + id).
  static String pathOf(Track song) =>
      song.remotePath ??
      '${ServerCatalog.folderOf(song)}/${song.remoteId}'
          .replaceFirst(RegExp(r'^/'), '');

  /// Whether the nearest rule above [path] says keep.
  bool wantsKept(String path) {
    var p = path;
    while (true) {
      final rule = _rules[p];
      if (rule != null) return rule;
      if (p.isEmpty) return false;
      final slash = p.lastIndexOf('/');
      p = slash > 0 ? p.substring(0, slash) : '';
    }
  }

  /// The downloaded copy of server song [songId], if there is one.
  String? localFileFor(String songId) {
    final path = _files[songId];
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  OfflineState stateOfSong(Track song) {
    if (!wantsKept(pathOf(song))) return OfflineState.online;
    return localFileFor(song.remoteId!) != null
        ? OfflineState.kept
        : OfflineState.pending;
  }

  OfflineState stateOfSongs(List<Track> songs) {
    if (songs.isEmpty) return OfflineState.online;
    var kept = 0, wanted = 0;
    for (final s in songs) {
      if (wantsKept(pathOf(s))) {
        wanted++;
        if (localFileFor(s.remoteId!) != null) kept++;
      }
    }
    if (wanted == 0) return OfflineState.online;
    if (wanted < songs.length) return OfflineState.partly;
    return kept == wanted ? OfflineState.kept : OfflineState.pending;
  }

  /// Keep [path] (a folder or a song's [pathOf]) on this device.
  Future<void> keep(String path) => _setRule(path, true);

  /// Stop keeping [path] and delete the downloaded copies under it.
  Future<void> freeUp(String path) => _setRule(path, false);

  Future<void> _setRule(String path, bool keep) async {
    await load();
    // Rules below this one no longer apply: the folder decides for all of it.
    _rules.removeWhere(
        (k, _) => path.isEmpty || k == path || k.startsWith('$path/'));
    // Only store what differs from the folder above.
    final parent = path.isEmpty
        ? null
        : path.contains('/')
            ? path.substring(0, path.lastIndexOf('/'))
            : '';
    if (parent == null ? keep : wantsKept(parent) != keep) _rules[path] = keep;
    await _save();
    await sync();
  }

  /// Downloads what should be kept and deletes what shouldn't, one file at a
  /// time. Called after every rule change and every library sync.
  Future<void> sync() async {
    await load();
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
    } finally {
      _syncing = false;
      progress.value = null;
    }
  }

  Future<void> _syncOnce() async {
    final songs = catalog.songs.value;
    final byId = {for (final s in songs) s.remoteId!: s};
    // Delete copies of songs no longer kept (or gone from the server).
    for (final id in _files.keys.toList()) {
      final song = byId[id];
      if (song == null || !wantsKept(pathOf(song))) {
        try {
          await File(_files[id]!).delete();
        } catch (_) {}
        _files.remove(id);
      }
    }
    await _save();
    final todo = [
      for (final s in songs)
        if (wantsKept(pathOf(s)) && localFileFor(s.remoteId!) == null) s,
    ];
    if (todo.isEmpty || !SubsonicClient.instance.isConfigured) return;
    final root = '${(await _docs()).path}/$_folderName';
    final client = httpClient ?? http.Client();
    await background.start(
        'Keeping music on this phone', '0 of ${todo.length}');
    try {
      for (var i = 0; i < todo.length; i++) {
        if (_again) return; // a rule changed: start over with the new list
        final song = todo[i];
        final label = '${i + 1} of ${todo.length} · ${song.title}';
        progress.value = label;
        await background.update(label);
        final file = File('$root/${pathOf(song)}');
        if (await _download(client, song, file)) {
          _files[song.remoteId!] = file.path;
          await _save();
        }
      }
    } finally {
      await background.stop();
      if (httpClient == null) client.close();
    }
  }

  Future<bool> _download(http.Client client, Track song, File file) async {
    final part = File('${file.path}.part');
    try {
      await file.parent.create(recursive: true);
      final response = await client
          .send(http.Request(
              'GET', SubsonicClient.instance.downloadUri(song.remoteId!)))
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        LogService.add(
            'Music', 'keep: ${song.title} HTTP ${response.statusCode}');
        return false;
      }
      final sink = part.openWrite();
      await response.stream.pipe(sink);
      await part.rename(file.path);
      return true;
    } catch (e) {
      LogService.add('Music', 'keep: ${song.title} failed: $e');
      try {
        await part.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Forgets every rule and deletes every downloaded copy (server removed).
  Future<void> clear() async {
    await load();
    _rules.clear();
    for (final p in _files.values) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    _files.clear();
    await _save();
  }

  @visibleForTesting
  void resetForTest() {
    _rules.clear();
    _files.clear();
    _loaded = false;
    _syncing = false;
    _again = false;
    progress.value = null;
  }
}
