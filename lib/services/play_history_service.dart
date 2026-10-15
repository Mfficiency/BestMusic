import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

/// One song or Subscriptions video that started playing, as remembered by
/// [PlayHistoryService]. Title/artist are copied at play time so an entry
/// still reads right after the song is renamed, moved or deleted.
class PlayHistoryEntry {
  const PlayHistoryEntry({
    required this.id,
    required this.trackId,
    required this.title,
    this.artist = '',
    this.isVideo = false,
    required this.playedAt,
  });

  final String id;
  final String trackId;
  final String title;
  final String artist;
  final bool isVideo;
  final DateTime playedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'trackId': trackId,
        'title': title,
        if (artist.isNotEmpty) 'artist': artist,
        if (isVideo) 'isVideo': true,
        'playedAt': playedAt.millisecondsSinceEpoch,
      };

  static PlayHistoryEntry? fromJson(Map<String, dynamic> json) {
    final playedAt = json['playedAt'];
    final id = json['id'] as String?;
    if (playedAt is! num || id == null || id.isEmpty) return null;
    return PlayHistoryEntry(
      id: id,
      trackId: json['trackId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      isVideo: json['isVideo'] as bool? ?? false,
      playedAt: DateTime.fromMillisecondsSinceEpoch(playedAt.round()),
    );
  }
}

/// Tools → Play history: every song or video that started playing, newest
/// first, kept for [retention] (older entries are dropped on load and on
/// every new play). Persisted in `play_history.json`; errors are swallowed
/// like the other stores.
class PlayHistoryService {
  PlayHistoryService._();

  static final PlayHistoryService instance = PlayHistoryService._();

  static const String fileName = 'play_history.json';

  /// How long an entry is kept.
  static const Duration retention = Duration(days: 90);

  /// Starting the same track again within this window (resuming after a
  /// pause, an app restart or "Back to music") doesn't add a second entry.
  static const Duration repeatWindow = Duration(minutes: 30);

  /// Newest first.
  final ValueNotifier<List<PlayHistoryEntry>> entries =
      ValueNotifier<List<PlayHistoryEntry>>([]);
  bool _loaded = false;
  int _counter = 0;

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<void> load({DateTime? now}) async {
    if (_loaded) return;
    _loaded = true;
    var loaded = <PlayHistoryEntry>[];
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is List) {
          loaded = [
            for (final e in data)
              if (e is Map)
                if (PlayHistoryEntry.fromJson(Map<String, dynamic>.from(e))
                    case final entry?)
                  entry,
          ];
        }
      }
    } catch (_) {}
    loaded.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final pruned = _pruned(loaded, now ?? DateTime.now());
    entries.value = pruned;
    if (pruned.length != loaded.length) await _save();
  }

  /// Re-reads the history from disk (after a backup restore).
  Future<void> reload() async {
    _loaded = false;
    await load();
  }

  Future<void> _save() async {
    try {
      final file = await _getFile();
      await file.writeAsString(
          jsonEncode([for (final e in entries.value) e.toJson()]),
          flush: true);
    } catch (_) {}
  }

  static List<PlayHistoryEntry> _pruned(
      List<PlayHistoryEntry> list, DateTime now) {
    final cutoff = now.subtract(retention);
    return list.where((e) => e.playedAt.isAfter(cutoff)).toList();
  }

  /// Notes that [track] started playing at [now].
  Future<void> record(Track track, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final current = entries.value;
    if (current.isNotEmpty &&
        current.first.trackId == track.id &&
        at.difference(current.first.playedAt) < repeatWindow) {
      return;
    }
    final entry = PlayHistoryEntry(
      id: '${at.microsecondsSinceEpoch}_${_counter++}',
      trackId: track.id,
      title: track.title.isNotEmpty ? track.title : track.fileBaseName,
      artist: track.artist,
      isVideo: track.isFeedVideo,
      playedAt: at,
    );
    entries.value = _pruned([entry, ...current], at);
    await _save();
  }

  Future<void> delete(String entryId) async {
    final next = entries.value.where((e) => e.id != entryId).toList();
    if (next.length == entries.value.length) return;
    entries.value = next;
    await _save();
  }

  /// Deletes every entry played on [day]'s calendar date.
  Future<void> deleteDay(DateTime day) async {
    entries.value = entries.value
        .where((e) =>
            e.playedAt.year != day.year ||
            e.playedAt.month != day.month ||
            e.playedAt.day != day.day)
        .toList();
    await _save();
  }

  Future<void> clear() async {
    entries.value = [];
    await _save();
  }

  @visibleForTesting
  void resetForTest() {
    entries.value = [];
    _loaded = false;
  }
}
