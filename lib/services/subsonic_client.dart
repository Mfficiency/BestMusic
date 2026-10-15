import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/track.dart';

/// Thin client for a self-hosted Subsonic/OpenSubsonic-compatible server
/// (Navidrome, Airsonic, Gonic, …; e.g. the Navidrome on the MagicMirror Pi),
/// configured in Settings → Music server.
/// Auth follows the Subsonic API's token scheme: `token =
/// md5(password + salt)`, sent alongside a fresh random `salt` on every
/// request, so the plaintext password never goes on the wire.
///
/// Small on purpose: ping, search, a paged list of every song (for
/// `SubsonicLibrarySync`) and a streaming URL. Streams ask for the file as it
/// is (`format=raw`), so a small server like a Raspberry Pi never transcodes.
class SubsonicClient {
  SubsonicClient._();

  static final SubsonicClient instance = SubsonicClient._();

  /// Songs per `search3` page when listing the whole library.
  static const int pageSize = 500;

  /// The HTTP client; tests swap in a `MockClient`.
  @visibleForTesting
  http.Client httpClient = http.Client();

  static const String apiVersion = '1.16.1';
  static const String clientName = 'bestmusic';

  bool get isConfigured =>
      Config.subsonicServerUrl.trim().isNotEmpty &&
      Config.subsonicUsername.trim().isNotEmpty;

  String _randomSalt() {
    final rand = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Fresh token auth (`u`, `t`, `s`, `v`, `c`, `f`) for one request — also
  /// what the MagicMirror Pi's upload service checks (`ServerUploadService`).
  Map<String, String> authParams() => _authParams();

  Map<String, String> _authParams() {
    final salt = _randomSalt();
    final token =
        md5.convert(utf8.encode('${Config.subsonicPassword}$salt')).toString();
    return {
      'u': Config.subsonicUsername,
      't': token,
      's': salt,
      'v': apiVersion,
      'c': clientName,
      'f': 'json',
    };
  }

  String get _base =>
      Config.subsonicServerUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _buildUri(String endpoint, [Map<String, String>? extra]) {
    return Uri.parse('$_base/rest/$endpoint').replace(queryParameters: {
      ..._authParams(),
      ...?extra,
    });
  }

  /// The URL a track can be streamed from, for [Track.subsonic] tracks: the
  /// original file (`format=raw`), never a transcode.
  Uri streamUri(String songId) =>
      _buildUri('stream', {'id': songId, 'format': 'raw'});

  /// The original file, for keeping a song on the device
  /// (`ServerOfflineStore`).
  Uri downloadUri(String songId) => _buildUri('download', {'id': songId});

  /// The `subsonic-response` of [endpoint], or null on any failure (network,
  /// HTTP status, wrong password — Subsonic answers those with `status:
  /// failed`).
  Future<Map<String, dynamic>?> _get(String endpoint,
      [Map<String, String>? extra,
      Duration timeout = const Duration(seconds: 15)]) async {
    try {
      final response =
          await httpClient.get(_buildUri(endpoint, extra)).timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
      final r = body['subsonic-response'] as Map<String, dynamic>?;
      return r?['status'] == 'ok' ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Verifies the server is reachable and the credentials are valid.
  Future<bool> ping() async {
    if (!isConfigured) return false;
    return await _get('ping', null, const Duration(seconds: 10)) != null;
  }

  /// Full-text search across the server's library (artists/albums/songs),
  /// returning just the matching songs as [Track]s.
  Future<List<Track>> search(String query, {int count = 40}) async {
    if (!isConfigured || query.trim().isEmpty) return [];
    final r = await _get('search3',
        {'query': query, 'songCount': '$count', 'artistCount': '0', 'albumCount': '0'});
    return _songs(r);
  }

  /// Every song on the server, [pageSize] at a time (`search3` with an empty
  /// query, which OpenSubsonic servers like Navidrome answer with the whole
  /// library). Null when the server can't be reached or a page fails, so a
  /// half-finished list never replaces a complete one.
  ///
  /// [onPage] gets the number of songs fetched so far after each page.
  Future<List<Track>?> allSongs({void Function(int fetched)? onPage}) async {
    if (!isConfigured) return null;
    final all = <Track>[];
    for (var offset = 0;; offset += pageSize) {
      final r = await _get(
          'search3',
          {
            'query': '',
            'songCount': '$pageSize',
            'songOffset': '$offset',
            'artistCount': '0',
            'albumCount': '0',
          },
          const Duration(seconds: 60));
      if (r == null) return null;
      final page = _songs(r);
      all.addAll(page);
      onPage?.call(all.length);
      if (page.length < pageSize) return all;
    }
  }

  /// Every song on the server walked album by album (`getAlbumList2` +
  /// `getAlbum`): slower than [allSongs] (a request per album), so only the
  /// fallback for servers whose empty-query `search3` returns less than the
  /// whole library. Null when the server can't be reached or a page fails.
  Future<List<Track>?> allSongsByAlbum(
      {void Function(int fetched)? onPage}) async {
    if (!isConfigured) return null;
    final albumIds = <String>[];
    for (var offset = 0;; offset += pageSize) {
      final r = await _get(
          'getAlbumList2',
          {
            'type': 'alphabeticalByName',
            'size': '$pageSize',
            'offset': '$offset',
          },
          const Duration(seconds: 60));
      if (r == null) return null;
      final list = r['albumList2'] as Map<String, dynamic>?;
      final albums = (list?['album'] as List<dynamic>? ?? []).whereType<Map>();
      albumIds.addAll([
        for (final a in albums)
          if (a['id'] != null) a['id'].toString(),
      ]);
      if (albums.length < pageSize) break;
    }
    final all = <Track>[];
    final seen = <String>{};
    for (final id in albumIds) {
      final r = await _get('getAlbum', {'id': id});
      if (r == null) return null;
      final album = r['album'] as Map<String, dynamic>?;
      final songs = (album?['song'] as List<dynamic>? ?? []).whereType<Map>();
      for (final song in songs) {
        final track = _songToTrack(Map<String, dynamic>.from(song));
        if (track.remoteId!.isNotEmpty && seen.add(track.remoteId!)) {
          all.add(track);
        }
      }
      onPage?.call(all.length);
    }
    return all;
  }

  /// What the server's own library scan knows (`getScanStatus`), or null
  /// when it can't be reached or doesn't say.
  Future<ServerScanStatus?> scanStatus() async {
    if (!isConfigured) return null;
    final r = await _get('getScanStatus', null, const Duration(seconds: 10));
    final status = r?['scanStatus'];
    if (status is! Map) return null;
    return ServerScanStatus(
      scanning: status['scanning'] == true,
      count: (status['count'] as num?)?.round(),
      lastScan: status['lastScan'] is String
          ? DateTime.tryParse(status['lastScan'] as String)?.toLocal()
          : null,
    );
  }

  /// Asks the server to scan its music folder for new files (`startScan`;
  /// Navidrome only lets admin accounts do this). False when refused or the
  /// server can't be reached.
  Future<bool> startScan() async {
    if (!isConfigured) return false;
    return await _get('startScan', null, const Duration(seconds: 15)) != null;
  }

  List<Track> _songs(Map<String, dynamic>? r) {
    final result = r?['searchResult3'] as Map<String, dynamic>?;
    final songs = result?['song'] as List<dynamic>? ?? [];
    return songs
        .whereType<Map>()
        .map((s) => _songToTrack(Map<String, dynamic>.from(s)))
        .where((t) => t.remoteId!.isNotEmpty)
        .toList();
  }

  Track _songToTrack(Map<String, dynamic> song) {
    final durationSeconds = song['duration'] as num?;
    // OpenSubsonic servers (Navidrome, ...) send the song's BPM; 0 = unknown.
    final bpm = (song['bpm'] as num?)?.round();
    // The real folder path when the server reports it (Navidrome:
    // [Subsonic] DefaultReportRealPath). Absolute paths ("/music/...") lose
    // the leading slash, which would otherwise make a nameless top folder.
    final path = (song['path'] as String?)
        ?.replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    return Track.subsonic(
      remoteId: song['id']?.toString() ?? '',
      remotePath: path != null && path.isNotEmpty ? path : null,
      sizeBytes: (song['size'] as num?)?.round(),
      title: song['title'] as String? ?? '',
      artist: song['artist'] as String? ?? '',
      album: song['album'] as String? ?? '',
      durationMs:
          durationSeconds != null ? (durationSeconds * 1000).round() : null,
      genre: song['genre'] as String? ?? '',
      year: (song['year'] as num?)?.round(),
      bpm: bpm != null && bpm > 0 ? bpm : null,
    );
  }
}

/// The server's own library scan, as `getScanStatus` reports it.
class ServerScanStatus {
  const ServerScanStatus({required this.scanning, this.count, this.lastScan});

  /// Whether the server is scanning its music folder right now.
  final bool scanning;

  /// How many songs the server's scan found; null when it doesn't say.
  final int? count;

  /// When the last scan finished (Navidrome); null when unknown.
  final DateTime? lastScan;
}
