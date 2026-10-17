import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/track.dart';
import 'log_service.dart';
import 'music_library_service.dart';
import 'music_playlist_service.dart';
import 'server_catalog.dart';
import 'server_upload_service.dart';
import 'subsonic_client.dart';
import 'lyrics_service.dart';
import 'music_player_service.dart';

/// Deleting a song and moving it to another folder, from a song's ⋮ menu.
///
/// A phone song ([TrackSource.local]) is a file under [Config.musicFolder]:
/// it is deleted or renamed right here, and its library entry, playlists and
/// favourites follow (a moved file gets a new `local:<path>` id, so every
/// playlist is rewritten to it).
///
/// A server song ([TrackSource.subsonic]) lives on the MagicMirror Pi. The
/// Subsonic API can't delete or move files, so these go to the Pi's upload
/// service (`mirror-music-upload`, [ServerUploadService.base]) with the same
/// login as everything else:
///
///  * `POST /api/music/delete`, JSON `{"id": <song id>, "path": <path>}` →
///    200 when the file is gone.
///  * `POST /api/music/move`, JSON `{"id", "path", "to": <folder>}` → 200
///    with `{"path": <new path>}`.
///
/// `path` is the song's path as Navidrome reports it, without a leading
/// slash; `to` is a folder in the same form ('' = the top). An older Pi
/// without these endpoints answers 404, which comes back as
/// [notSupportedMessage].
class TrackFileActions {
  TrackFileActions._();

  static final TrackFileActions instance = TrackFileActions._();

  static const String notSupportedMessage =
      'The music server can\'t do this yet — its upload service on the Pi '
      'needs an update';

  @visibleForTesting
  http.Client? httpClient;

  /// Whether [track] can be deleted or moved at all (phone files and server
  /// songs; not YouTube streams).
  static bool canManage(Track track) =>
      (track.source == TrackSource.local && track.filePath != null) ||
      (track.source == TrackSource.subsonic && track.remoteId != null);

  /// The folder [track] is in: relative to the music folder for a phone
  /// song, the server folder for a server song ('' = the top).
  static String folderOf(Track track) {
    if (track.source == TrackSource.subsonic) {
      return ServerCatalog.folderOf(track);
    }
    final rel = _relativeToRoot(track.filePath ?? '');
    final slash = rel.lastIndexOf('/');
    return slash > 0 ? rel.substring(0, slash) : '';
  }

  /// The folders [track] could move to: every folder of the music folder
  /// (or of the server) plus the top ('').
  Future<List<String>> foldersFor(Track track) async {
    final Set<String> folders = {''};
    if (track.source == TrackSource.subsonic) {
      for (final song in ServerCatalog.instance.songs.value) {
        var f = ServerCatalog.folderOf(song);
        while (f.isNotEmpty) {
          folders.add(f);
          final slash = f.lastIndexOf('/');
          f = slash > 0 ? f.substring(0, slash) : '';
        }
      }
    } else {
      folders.addAll(await MusicLibraryService.instance.listSubfolders());
    }
    return folders.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  static String _root() =>
      MusicLibraryService.normalizePath(Config.musicFolder.trim())
          .replaceAll(RegExp(r'/+$'), '');

  static String _relativeToRoot(String filePath) {
    final p = MusicLibraryService.normalizePath(filePath);
    final root = _root();
    if (root.isNotEmpty && p.startsWith('$root/')) {
      return p.substring(root.length + 1);
    }
    return p.substring(p.lastIndexOf('/') + 1);
  }

  /// A folder name typed by hand, made safe: forward slashes, no leading or
  /// trailing slash, no `.`/`..` parts.
  static String cleanFolder(String folder) => MusicLibraryService.normalizePath(
          folder.trim())
      .split('/')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty && p != '.' && p != '..')
      .join('/');

  /// Deletes [track]; returns null when done, else what went wrong.
  Future<String?> delete(Track track) async {
    if (!canManage(track)) return 'This song can\'t be deleted';
    if (track.source == TrackSource.local) {
      try {
        final file = File(track.filePath!);
        if (await file.exists()) await file.delete();
      } catch (e) {
        LogService.add('Music', 'delete ${track.filePath} failed: $e');
        return 'Could not delete the file: $e';
      }
      await MusicLibraryService.instance.removeTracks({track.id});
      await MusicPlaylistService.instance.removeTrackEverywhere(track.id);
      LogService.add('Music', 'deleted ${track.filePath}');
      return null;
    }
    final result = await _server('/api/music/delete', track);
    if (result.error != null) return result.error;
    await ServerCatalog.instance.replace([
      for (final s in ServerCatalog.instance.songs.value)
        if (s.id != track.id) s
    ]);
    await MusicLibraryService.instance.removeTracks({track.id});
    await MusicPlaylistService.instance.removeTrackEverywhere(track.id);
    LogService.add('Music', 'deleted from the server: ${track.remotePath}');
    return null;
  }

  /// Moves [track] into [folder] ('' = the top); returns null when done,
  /// else what went wrong.
  Future<String?> move(Track track, String folder) async {
    if (!canManage(track)) return 'This song can\'t be moved';
    final to = cleanFolder(folder);
    if (to == folderOf(track)) return null;
    if (track.source == TrackSource.local) return _moveLocal(track, to);

    final result = await _server('/api/music/move', track, to: to);
    if (result.error != null) return result.error;
    final name = (track.remotePath ?? track.title).split('/').last;
    final newPath = (result.body?['path'] as String?)
            ?.replaceFirst(RegExp(r'^/+'), '') ??
        (to.isEmpty ? name : '$to/$name');
    final moved = _withPaths(track, remotePath: newPath);
    await ServerCatalog.instance.replace([
      for (final s in ServerCatalog.instance.songs.value)
        s.id == track.id ? moved : s
    ]);
    await MusicLibraryService.instance.replaceTrack(track.id, moved);
    LogService.add('Music', 'moved on the server: ${track.remotePath} → $newPath');
    return null;
  }

  Future<String?> _moveLocal(Track track, String to) async {
    final root = _root();
    if (root.isEmpty) return 'No music folder is set';
    final name = MusicLibraryService.normalizePath(track.filePath!)
        .split('/')
        .last;
    var dir = to.isEmpty ? root : '$root/$to';
    var target = '$dir/$name';
    if (track.filePath!.contains(r'\')) {
      // Same separators as a rescan writes, so the id stays the same.
      dir = dir.replaceAll('/', r'\');
      target = target.replaceAll('/', r'\');
    }
    try {
      if (await File(target).exists()) {
        return 'There is already a "$name" in that folder';
      }
      await Directory(dir).create(recursive: true);
      await _renameOrCopy(File(track.filePath!), target);
    } catch (e) {
      LogService.add('Music', 'move ${track.filePath} failed: $e');
      return 'Could not move the file: $e';
    }
    final moved = _withPaths(track, filePath: target);
    await MusicLibraryService.instance.replaceTrack(track.id, moved);
    await MusicPlaylistService.instance.renameTrackId(track.id, moved.id);
    await LyricsService.instance.moveSaved(track.id, moved.id);
    if (MusicPlayerService.isReady) {
      MusicPlayerService.handler.replaceTrack(track.id, moved);
    }
    LogService.add('Music', 'moved ${track.filePath} → $target');
    return null;
  }

  /// Whether [track]'s file can be renamed here: phone songs (the music
  /// server has no rename).
  static bool canRename(Track track) =>
      track.source == TrackSource.local && track.filePath != null;

  /// [track]'s file name without folder and extension.
  static String baseNameOf(Track track) {
    final name =
        MusicLibraryService.normalizePath(track.filePath ?? '').split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Characters a file name can't have on Android/Windows.
  static final RegExp _badNameChars = RegExp(r'[\\/:*?"<>|]');

  /// Renames [track]'s file to [newBaseName] (no extension: the old one is
  /// kept) in the same folder. Its playlists, play counts and saved lyrics
  /// follow it, and an `.lrc` file next to it is renamed too. Returns null
  /// when done (or nothing to change), else what went wrong.
  Future<String?> rename(Track track, String newBaseName) async {
    if (!canRename(track)) return 'Only songs on this phone can be renamed';
    final base = newBaseName.trim();
    if (base.isEmpty) return 'The file name can\'t be empty';
    if (_badNameChars.hasMatch(base)) {
      return 'A file name can\'t contain \\ / : * ? " < > |';
    }
    if (base == baseNameOf(track)) return null;
    final path = track.filePath!;
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
    final name = path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final target = '$dir$base$ext';
    try {
      // Only a change of upper/lower case may "exist" already (the same
      // file on a case-insensitive storage).
      if (await File(target).exists() &&
          target.toLowerCase() != path.toLowerCase()) {
        return 'There is already a "$base$ext" in that folder';
      }
      await File(path).rename(target);
    } catch (e) {
      LogService.add('Music', 'rename $path failed: $e');
      return 'Could not rename the file: $e';
    }
    final oldBase = dot > 0 ? '$dir${name.substring(0, dot)}' : '$dir$name';
    for (final lrcExt in const ['.lrc', '.LRC']) {
      try {
        final lrc = File('$oldBase$lrcExt');
        if (await lrc.exists()) await lrc.rename('$dir$base$lrcExt');
      } catch (_) {}
    }
    final renamed = _withPaths(track, filePath: target);
    await MusicLibraryService.instance.replaceTrack(track.id, renamed);
    await MusicPlaylistService.instance.renameTrackId(track.id, renamed.id);
    await LyricsService.instance.moveSaved(track.id, renamed.id);
    if (MusicPlayerService.isReady) {
      MusicPlayerService.handler.replaceTrack(track.id, renamed);
    }
    LogService.add('Music', 'renamed $path → $target');
    return null;
  }

  /// A rename, or copy + delete where a rename can't cross storage volumes.
  static Future<void> _renameOrCopy(File from, String to) async {
    try {
      await from.rename(to);
    } on FileSystemException {
      await from.copy(to);
      await from.delete();
    }
  }

  /// [track] at another place: a phone song's id follows its path.
  static Track _withPaths(Track track,
      {String? filePath, String? remotePath}) {
    final json = track.toJson();
    if (filePath != null) {
      json['filePath'] = filePath;
      json['id'] = 'local:$filePath';
    }
    if (remotePath != null) json['remotePath'] = remotePath;
    return Track.fromJson(json);
  }

  Future<({String? error, Map<String, dynamic>? body})> _server(
      String path, Track track,
      {String? to}) async {
    final base = ServerUploadService.instance.base;
    if (base == null || !SubsonicClient.instance.isConfigured) {
      return (error: 'No music server is set up', body: null);
    }
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            base.replace(
                path: path,
                queryParameters: SubsonicClient.instance.authParams()),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': track.remoteId,
              'path': track.remotePath ?? '',
              if (to != null) 'to': to,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 404) {
        LogService.add('Music', '$path: HTTP 404 ${response.body}');
        return (error: notSupportedMessage, body: null);
      }
      if (response.statusCode != 200) {
        LogService.add(
            'Music', '$path: HTTP ${response.statusCode} ${response.body}');
        return (
          error: 'The server refused (HTTP ${response.statusCode})',
          body: null
        );
      }
      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {}
      return (error: null, body: body);
    } catch (e) {
      LogService.add('Music', '$path failed: $e');
      return (error: 'The server could not be reached', body: null);
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
