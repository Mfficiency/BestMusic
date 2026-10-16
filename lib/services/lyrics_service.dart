import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:id3_codec/id3_codec.dart';
import 'package:path_provider/path_provider.dart';

import '../models/lyrics.dart';
import '../models/track.dart';
import 'log_service.dart';
import 'music_online_metadata.dart';
import 'safe_file.dart';

/// What [LyricsService.lyricsFor] found for a song.
enum LyricsStatus {
  /// [LyricsLookup.lyrics] holds synced or plain lyrics.
  found,

  /// LRCLIB knows the song and says it has no words.
  instrumental,

  /// Looked everywhere, nothing.
  notFound,

  /// LRCLIB couldn't be reached (offline, timeout, server trouble) — try
  /// again later; nothing is remembered.
  unavailable,

  /// Subscriptions videos: they have a transcript instead.
  notASong,
}

class LyricsLookup {
  const LyricsLookup(this.status, [this.lyrics, this.reason, this.saved = false]);

  final LyricsStatus status;
  final Lyrics? lyrics;

  /// For [LyricsStatus.unavailable]: what went wrong, in a few words
  /// ("no answer within 15 s", "server error 503", ...).
  final String? reason;

  /// The lyrics came from the copy kept on the phone (no connection used).
  final bool saved;
}

/// Lyrics for Now Playing's lyrics page, looked for in this order:
///
/// 1. an `.lrc` file next to a local song (`Song.mp3` → `Song.lrc`);
/// 2. lyrics stored in a local mp3's tags (ID3 `USLT`, synced if it holds
///    LRC text);
/// 3. what an earlier lookup saved (`lyrics/<sha1 of track id>.json` in the
///    app documents dir — found lyrics for good, "nothing found" for
///    [notFoundRetryAfter]);
/// 4. [LRCLIB](https://lrclib.net) — free, no account: first an exact
///    title/artist/album/length match (`/api/get`), then a search
///    (`/api/search`) scored like the metadata lookup does
///    ([matchScore]), synced lyrics preferred.
///
/// Only looked up when the lyrics page is open, so playing music costs no
/// extra data. Errors are swallowed like everywhere else.
class LyricsService {
  LyricsService({
    http.Client? client,
    Future<Directory> Function()? cacheDir,
    DateTime Function()? clock,
    Duration? timeout,
    Future<void> Function(Duration)? sleep,
  })  : _client = client ?? http.Client(),
        _cacheDir = cacheDir ?? _defaultCacheDir,
        _clock = clock ?? DateTime.now,
        _timeout = timeout ?? const Duration(seconds: 20),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  static LyricsService instance = LyricsService();

  static const String lrclibHost = 'lrclib.net';
  static const String userAgent =
      'BestMusic/1.0 ( https://github.com/mfficiency/BestMusic )';

  /// How long "LRCLIB had nothing" is believed before asking again
  /// (lyrics get added there all the time).
  static const Duration notFoundRetryAfter = Duration(days: 7);

  /// How much of an mp3's start is read for a lyrics tag, at most — the
  /// tag size from the header decides, but a broken header mustn't make
  /// this read a whole file.
  static const int tagReadCap = 8 * 1024 * 1024;

  final http.Client _client;
  final Future<Directory> Function() _cacheDir;
  final DateTime Function() _clock;
  final Duration _timeout;
  final Future<void> Function(Duration) _sleep;

  /// Waits before the 2nd and 3rd try of a request that timed out, lost its
  /// connection or got a server error (LRCLIB has slow moments): what you
  /// used to do by tapping "Try again" a few times.
  static const List<Duration> retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  static Future<Directory> _defaultCacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/lyrics');
  }

  /// The lyrics for [track]. [duration] is the song's length if the player
  /// knows it better than the library does. [refresh] skips what was saved
  /// and asks LRCLIB again ("Search again").
  Future<LyricsLookup> lyricsFor(Track track,
      {Duration? duration, bool refresh = false}) async {
    if (track.isFeedVideo) return const LyricsLookup(LyricsStatus.notASong);
    final onDisk = await _fromSongFiles(track);
    if (onDisk != null) return LyricsLookup(LyricsStatus.found, onDisk);
    // Lyrics found once are kept on the phone for good: no connection
    // needed the next time.
    final cached = await _readCache(track.id);
    if (!refresh && cached != null) return cached;
    final LyricsLookup found;
    try {
      found = await _fromLrclib(track, duration);
    } on _Unavailable catch (e) {
      LogService.add('Lyrics',
          'LRCLIB unreachable for "${track.displayTitle}": ${e.reason}');
      // "Search again" while offline: keep showing what was saved.
      if (cached?.status == LyricsStatus.found) return cached!;
      return LyricsLookup(LyricsStatus.unavailable, null, e.reason);
    }
    // "Search again" finding nothing doesn't throw away saved lyrics.
    if (found.status != LyricsStatus.found &&
        cached?.status == LyricsStatus.found) {
      return cached!;
    }
    await _writeCache(track.id, found);
    return found;
  }

  // --- 1 & 2: files on the phone ---------------------------------------

  Future<Lyrics?> _fromSongFiles(Track track) async {
    final path = track.filePath;
    if (track.source != TrackSource.local || path == null) return null;
    try {
      final dot = path.lastIndexOf('.');
      final slash = path.lastIndexOf(RegExp(r'[\\/]'));
      final base = dot > slash ? path.substring(0, dot) : path;
      for (final ext in const ['.lrc', '.LRC']) {
        final lrc = File('$base$ext');
        if (await lrc.exists()) {
          final lyrics = Lyrics.parseLrc(await _readText(lrc),
              source: "the song's .lrc file");
          if (!lyrics.isEmpty) return lyrics;
        }
      }
      if (path.toLowerCase().endsWith('.mp3')) {
        final text = await _readTagLyrics(File(path));
        if (text != null) {
          final lyrics = Lyrics.parseLrc(text, source: "the song's tags");
          if (!lyrics.isEmpty) return lyrics;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<String> _readText(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// The `USLT` (lyrics) frame of [file]'s ID3v2 tag, or null.
  static Future<String?> _readTagLyrics(File file) async {
    final raf = await file.open();
    try {
      final header = await raf.read(10);
      if (header.length < 10 ||
          String.fromCharCodes(header.sublist(0, 3)) != 'ID3') {
        return null;
      }
      // Syncsafe size: 7 bits per byte.
      final size = (header[6] << 21) |
          (header[7] << 14) |
          (header[8] << 7) |
          header[9];
      await raf.setPosition(0);
      final tag = await raf.read(math.min(10 + size, tagReadCap));
      return decodeLyricsTag(tag);
    } finally {
      await raf.close();
    }
  }

  /// The lyrics text in an ID3 tag's `USLT` frame ([tagBytes] = the start
  /// of an mp3), or null.
  static String? decodeLyricsTag(Uint8List tagBytes) {
    try {
      for (final info in ID3Decoder(tagBytes).decodeSync()) {
        final frames = info.toTagMap()['Frames'];
        if (frames is! List) continue;
        for (final frame in frames) {
          if (frame is! Map) continue;
          final id = frame['Frame ID'];
          if (id != 'USLT' && id != 'ULT') continue;
          final content = frame['Content'];
          final text = content is Map ? content['Lyrics/text'] : null;
          if (text is String && text.trim().isNotEmpty) return text;
        }
      }
    } catch (_) {}
    return null;
  }

  // --- 3: what earlier lookups found -----------------------------------

  Future<File> _cacheFile(String trackId) async {
    final dir = await _cacheDir();
    final name = sha1.convert(utf8.encode(trackId)).toString();
    return File('${dir.path}/$name.json');
  }

  Future<LyricsLookup?> _readCache(String trackId) async {
    try {
      final file = await _cacheFile(trackId);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic> || json['trackId'] != trackId) {
        return null;
      }
      switch (json['status']) {
        case 'found':
          final lyrics = Lyrics.fromJson(
              (json['lyrics'] as Map?)?.cast<String, dynamic>() ?? const {});
          return lyrics.isEmpty
              ? null
              : LyricsLookup(LyricsStatus.found, lyrics, null, true);
        case 'instrumental':
          return const LyricsLookup(LyricsStatus.instrumental);
        case 'notFound':
          final checked = json['checkedAt'];
          if (checked is! num) return null;
          final age = _clock().difference(
              DateTime.fromMillisecondsSinceEpoch(checked.round()));
          return age < notFoundRetryAfter
              ? const LyricsLookup(LyricsStatus.notFound)
              : null;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeCache(String trackId, LyricsLookup found) async {
    try {
      final file = await _cacheFile(trackId);
      await file.parent.create(recursive: true);
      await SafeFile.writeString(
          file,
          jsonEncode({
            'trackId': trackId,
            'status': found.status.name,
            'checkedAt': _clock().millisecondsSinceEpoch,
            if (found.lyrics != null) 'lyrics': found.lyrics!.toJson(),
          }));
    } catch (_) {}
  }

  // --- 4: LRCLIB ------------------------------------------------------

  Future<LyricsLookup> _fromLrclib(Track track, Duration? duration) async {
    final durationMs = duration?.inMilliseconds ?? track.durationMs;
    final (artist, title) = splitForLyrics(track.displayArtist, track.displayTitle);
    final variants = queryVariants(TrackQuery(
      title: title,
      artist: artist,
      durationMs: durationMs,
    ));
    if (variants.isEmpty) return const LyricsLookup(LyricsStatus.notFound);

    // Exact match first: cheap for LRCLIB, and right for well-tagged songs.
    // A request that fails (after its retries) doesn't end the lookup: the
    // others may still get through. Only when none does is LRCLIB
    // "unreachable", with the last failure as the reason.
    _Unavailable? failed;
    var answered = false;
    Future<Object?> ask(Uri uri) async {
      try {
        final result = await _getJson(uri);
        answered = true;
        return result;
      } on _Unavailable catch (e) {
        failed = e;
        return null;
      }
    }

    final first = variants.first;
    if (first.artist.isNotEmpty) {
      final exact = await ask(Uri.https(lrclibHost, '/api/get', {
        'track_name': first.title,
        'artist_name': first.artist,
        if (track.album.trim().isNotEmpty) 'album_name': track.album.trim(),
        if (durationMs != null && durationMs > 0)
          'duration': '${(durationMs / 1000).round()}',
      }));
      if (exact is Map<String, dynamic>) {
        final hit = _lookupFrom(exact);
        if (hit != null) return hit;
      }
    }

    // Then a search per spelling; the best-scoring record wins, a synced
    // one beating an equally good plain one.
    _Candidate? best;
    for (final q in variants) {
      final results = await ask(Uri.https(lrclibHost, '/api/search', {
        'track_name': q.title,
        if (q.artist.isNotEmpty) 'artist_name': q.artist,
      }));
      if (results is! List) continue;
      for (final r in results.whereType<Map<String, dynamic>>()) {
        final secs = r['duration'];
        final score = matchScore(
          q,
          r['trackName'] as String? ?? '',
          r['artistName'] as String? ?? '',
          secs is num ? (secs * 1000).round() : null,
        );
        if (score < MusicOnlineMetadataLookup.minMatchScore) continue;
        final synced = (r['syncedLyrics'] as String? ?? '').trim().isNotEmpty;
        final rank = score + (synced ? 0.05 : 0);
        if (best == null || rank > best.rank) best = _Candidate(rank, r);
      }
      if (best != null) break;
    }
    if (best != null) {
      final hit = _lookupFrom(best.record);
      if (hit != null) return hit;
    }
    if (!answered && failed != null) throw failed!;
    return const LyricsLookup(LyricsStatus.notFound);
  }

  /// Artist and title to search for: as given, or — with no artist — from
  /// a name like "Artist ●● Song", "Artist • Song", "Artist | Song" or
  /// "Artist: Song" (YouTube uploads; "Artist - Song" is already split by
  /// `Track.displayTitle`).
  static (String, String) splitForLyrics(String artist, String title) {
    if (artist.trim().isNotEmpty) return (artist, title);
    final m = RegExp(r'^(.+?)\s*(?:[●•·]+|\||:)\s*(.+)$').firstMatch(title);
    if (m == null) return (artist, title);
    return (m.group(1)!.trim(), m.group(2)!.trim());
  }

  static LyricsLookup? _lookupFrom(Map<String, dynamic> record) {
    if (record['instrumental'] == true) {
      return const LyricsLookup(LyricsStatus.instrumental);
    }
    final synced = (record['syncedLyrics'] as String? ?? '').trim();
    if (synced.isNotEmpty) {
      final lyrics = Lyrics.parseLrc(synced, source: 'LRCLIB');
      if (!lyrics.isEmpty) return LyricsLookup(LyricsStatus.found, lyrics);
    }
    final plain = (record['plainLyrics'] as String? ?? '').trim();
    if (plain.isNotEmpty) {
      return LyricsLookup(
          LyricsStatus.found, Lyrics(plain: plain, source: 'LRCLIB'));
    }
    return null;
  }

  /// The decoded JSON, or null for "not there" (404 and other client
  /// errors). A timeout, lost connection, 429 or server error is tried
  /// again ([retryDelays]); after the last try it throws [_Unavailable]
  /// saying what actually happened.
  Future<Object?> _getJson(Uri uri) async {
    final tries = retryDelays.length + 1;
    String reason = '';
    for (var attempt = 0; attempt < tries; attempt++) {
      if (attempt > 0) await _sleep(retryDelays[attempt - 1]);
      try {
        final response = await _client.get(uri, headers: {
          'User-Agent': userAgent,
          'Lrclib-Client': userAgent,
          'Accept': 'application/json',
        }).timeout(_timeout);
        final code = response.statusCode;
        if (code == 429) {
          reason = 'LRCLIB is busy (too many requests)';
          continue;
        }
        if (code >= 500) {
          reason = 'LRCLIB server error $code';
          continue;
        }
        if (code != 200) return null;
        try {
          return jsonDecode(utf8.decode(response.bodyBytes));
        } catch (_) {
          return null;
        }
      } on TimeoutException {
        reason = "LRCLIB didn't answer within ${_timeout.inSeconds} s";
      } on SocketException catch (e) {
        reason = _socketReason(e);
      } on HandshakeException catch (e) {
        reason = 'Secure connection to lrclib.net failed (${_short(e)})';
      } on http.ClientException catch (e) {
        reason = _clientReason(e.message);
      } catch (e) {
        reason = _short(e);
      }
    }
    throw _Unavailable('$reason (tried $tries times)');
  }

  static String _socketReason(SocketException e) {
    final message = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (message.contains('host lookup') || message.contains('no address')) {
      return 'No internet: lrclib.net could not be found';
    }
    if (message.contains('unreachable')) return 'No internet: network unreachable';
    if (message.contains('refused')) return 'lrclib.net refused the connection';
    if (message.contains('reset') || message.contains('closed')) {
      return 'The connection to lrclib.net was cut off';
    }
    return 'Connection to lrclib.net failed (${_short(e)})';
  }

  static String _clientReason(String message) {
    final m = message.toLowerCase();
    if (m.contains('host lookup')) return 'No internet: lrclib.net could not be found';
    if (m.contains('reset') || m.contains('closed')) {
      return 'The connection to lrclib.net was cut off';
    }
    return 'Connection to lrclib.net failed ($message)';
  }
}

class _Candidate {
  _Candidate(this.rank, this.record);

  final double rank;
  final Map<String, dynamic> record;
}

class _Unavailable implements Exception {
  const _Unavailable(this.reason);

  final String reason;
}

/// The first line of an error, without Dart's exception class prefix.
String _short(Object e) {
  final text = '$e'.split('\n').first.trim();
  final colon = text.indexOf(': ');
  final shown = colon > 0 && colon < 40 ? text.substring(colon + 2) : text;
  return shown.length > 120 ? '${shown.substring(0, 120)}…' : shown;
}
