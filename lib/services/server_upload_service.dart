import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/track.dart';
import 'background_work.dart';
import 'log_service.dart';
import 'music_library_service.dart';
import 'subsonic_client.dart';

/// A phone song the server doesn't have yet.
class PendingUpload {
  const PendingUpload(
      {required this.track, required this.path, required this.size});

  final Track track;

  /// Its path under the phone's music folder (`Artist/Album/Song.mp3`); the
  /// server stores it as `Phone/<path>`.
  final String path;
  final int size;
}

/// Sends the songs on this phone to the music server, for the MagicMirror
/// Pi's upload service (`mirror-music-upload`, the music server's address
/// with port [port]). Same login as listening: every request carries the
/// Subsonic token, which the Pi checks with Navidrome. The Pi stores them in
/// its `Phone/` folder; they show up after its nightly scan, and its nightly
/// clean-up removes duplicates.
class ServerUploadService {
  ServerUploadService._();

  static final ServerUploadService instance = ServerUploadService._();

  static const int port = 4534;

  /// While uploading: "3 of 12 · Song title"; null otherwise.
  final ValueNotifier<String?> progress = ValueNotifier<String?>(null);

  bool _cancel = false;

  @visibleForTesting
  http.Client? httpClient;

  @visibleForTesting
  BackgroundWork background = const BackgroundWork();

  bool get running => progress.value != null;

  /// The upload service's address: the music server's host on [port].
  Uri? get base {
    final server = Uri.tryParse(Config.subsonicServerUrl.trim());
    if (server == null || server.host.isEmpty) return null;
    return Uri(scheme: server.scheme, host: server.host, port: port);
  }

  Uri _uri(String path, [Map<String, String>? extra]) => base!.replace(
      path: path,
      queryParameters: {...SubsonicClient.instance.authParams(), ...?extra});

  /// Path of [track] relative to the phone's music folder.
  static String? relativePathOf(Track track) {
    final file = track.filePath;
    if (file == null) return null;
    final root = MusicLibraryService.normalizePath(Config.musicFolder.trim())
        .replaceAll(RegExp(r'/+$'), '');
    final p = MusicLibraryService.normalizePath(file);
    if (root.isNotEmpty && p.startsWith('$root/'))
      return p.substring(root.length + 1);
    return p.substring(p.lastIndexOf('/') + 1);
  }

  /// The phone's songs the server doesn't have. Null when the server can't be
  /// reached or the login is wrong.
  Future<List<PendingUpload>?> pending() async {
    if (base == null || !SubsonicClient.instance.isConfigured) return null;
    final candidates = <PendingUpload>[];
    for (final t in MusicLibraryService.instance.tracks.value) {
      if (t.source != TrackSource.local) continue;
      final rel = relativePathOf(t);
      if (rel == null) continue;
      try {
        candidates.add(PendingUpload(
            track: t, path: rel, size: await File(t.filePath!).length()));
      } catch (_) {}
    }
    if (candidates.isEmpty) return const [];
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(_uri('/api/music/check'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'files': [
                  for (final c in candidates) {'path': c.path, 'size': c.size}
                ]
              }))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        LogService.add('Music', 'upload check: HTTP ${response.statusCode}');
        return null;
      }
      final have = {
        ...((jsonDecode(response.body) as Map)['have'] as List? ?? [])
            .map((e) => '$e')
      };
      return [
        for (final c in candidates)
          if (!have.contains(c.path)) c
      ];
    } catch (e) {
      LogService.add('Music', 'upload check failed: $e');
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  void cancel() => _cancel = true;

  /// Uploads [songs] one at a time; returns how many the server stored.
  Future<int> upload(List<PendingUpload> songs) async {
    if (running || songs.isEmpty || base == null) return 0;
    _cancel = false;
    var stored = 0;
    final client = httpClient ?? http.Client();
    progress.value = '0 of ${songs.length}';
    await background.start('Uploading music to the server', progress.value!);
    try {
      for (var i = 0; i < songs.length && !_cancel; i++) {
        final song = songs[i];
        final label = '${i + 1} of ${songs.length} · ${song.track.title}';
        progress.value = label;
        await background.update(label);
        if (await _send(client, song)) stored++;
      }
    } finally {
      progress.value = null;
      await background.stop();
      if (httpClient == null) client.close();
    }
    LogService.add('Music', 'upload: $stored of ${songs.length} stored');
    return stored;
  }

  Future<bool> _send(http.Client client, PendingUpload song) async {
    try {
      final file = File(song.track.filePath!);
      final request = http.StreamedRequest(
          'PUT', _uri('/api/music/upload', {'path': song.path}))
        ..contentLength = song.size;
      unawaited(file.openRead().pipe(request.sink));
      final response =
          await client.send(request).timeout(const Duration(minutes: 10));
      final body = await response.stream.bytesToString();
      if (response.statusCode == 201) return true;
      if (response.statusCode != 200) {
        LogService.add(
            'Music', 'upload ${song.path}: HTTP ${response.statusCode} $body');
      }
      return false;
    } catch (e) {
      LogService.add('Music', 'upload ${song.path} failed: $e');
      return false;
    }
  }
}
