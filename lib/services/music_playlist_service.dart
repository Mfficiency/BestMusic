import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/music_playlist.dart';
import '../models/playlist_rule.dart';
import '../models/track.dart';
import 'music_library_service.dart';

/// Owns every [MusicPlaylist] — the two system playlists that back the
/// Now Playing swipe gesture (Favorites = swipe up, "Don't really like" =
/// swipe down) plus any imported or hand-made playlist — and the weighted
/// shuffle used to build a play queue from them: favorited tracks come up
/// more, disliked tracks far less (never fully excluded, so a mood can
/// still change), without ever repeating a track twice in one pass.
class MusicPlaylistService {
  MusicPlaylistService._();

  static final MusicPlaylistService instance = MusicPlaylistService._();

  static const _fileName = 'music_playlists.json';

  static const double favoriteWeight = 3.0;
  static const double likedWeight = 2.0;
  static const double dislikedWeight = 0.05;
  static const double normalWeight = 1.0;

  final ValueNotifier<List<MusicPlaylist>> playlists =
      ValueNotifier<List<MusicPlaylist>>([]);
  bool _loaded = false;
  final _random = Random();

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    List<MusicPlaylist> loaded = [];
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final List<dynamic> data = jsonDecode(await file.readAsString());
        loaded = data
            .whereType<Map>()
            .map((e) => MusicPlaylist.fromJson(Map<String, dynamic>.from(e)))
            .where((p) => p.id.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    if (loaded.where((p) => p.id == MusicPlaylist.favoritesId).isEmpty) {
      loaded.insert(0, MusicPlaylist.favorites());
    }
    if (loaded.where((p) => p.id == MusicPlaylist.likedId).isEmpty) {
      // New in 0.3.52: start it with the songs already swiped up (counted
      // since 0.3.45; until now a swipe up went into Favorites).
      loaded.insert(
          1,
          MusicPlaylist.liked()
            ..trackIds.addAll([
              for (final t in MusicLibraryService.instance.tracks.value)
                if (t.upSwipeCount > 0) t.id,
            ]));
    }
    if (loaded.where((p) => p.id == MusicPlaylist.dislikedId).isEmpty) {
      loaded.insert(2, MusicPlaylist.disliked());
    }
    playlists.value = loaded;
    await _save();
  }

  /// Re-reads the playlists from disk (after a backup restore).
  Future<void> reload() async {
    _loaded = false;
    await load();
  }

  Future<void> _save() async {
    try {
      final file = await _getFile();
      final jsonString =
          jsonEncode(playlists.value.map((p) => p.toJson()).toList());
      await file.writeAsString(jsonString, flush: true);
    } catch (_) {}
  }

  MusicPlaylist? byId(String id) {
    for (final p in playlists.value) {
      if (p.id == id) return p;
    }
    return null;
  }

  MusicPlaylist get favorites => byId(MusicPlaylist.favoritesId)!;
  MusicPlaylist get disliked => byId(MusicPlaylist.dislikedId)!;
  MusicPlaylist get liked => byId(MusicPlaylist.likedId)!;

  // Tolerant of the playlists not being loaded yet (false, not a crash).
  bool isFavorite(String trackId) =>
      byId(MusicPlaylist.favoritesId)?.trackIds.contains(trackId) ?? false;
  bool isLiked(String trackId) =>
      byId(MusicPlaylist.likedId)?.trackIds.contains(trackId) ?? false;
  bool isDisliked(String trackId) =>
      byId(MusicPlaylist.dislikedId)?.trackIds.contains(trackId) ?? false;

  Future<void> toggleFavorite(String trackId) async {
    if (isFavorite(trackId)) {
      await removeFrom(MusicPlaylist.favoritesId, trackId);
    } else {
      await addTo(MusicPlaylist.favoritesId, trackId);
      // A track can't be both loved and disliked at once.
      await removeFrom(MusicPlaylist.dislikedId, trackId);
    }
  }

  /// Marks [trackId] as disliked (swipe-down on Now Playing). Idempotent —
  /// safe to call even if it's already in the list.
  Future<void> markDisliked(String trackId) async {
    await addTo(MusicPlaylist.dislikedId, trackId);
    await removeFrom(MusicPlaylist.favoritesId, trackId);
    await removeFrom(MusicPlaylist.likedId, trackId);
  }

  /// Swipe up on Now Playing: into Liked songs (idempotent), and out of
  /// "Don't really like".
  Future<void> markLiked(String trackId) async {
    await addTo(MusicPlaylist.likedId, trackId);
    await removeFrom(MusicPlaylist.dislikedId, trackId);
  }

  Future<void> addTo(String playlistId, String trackId) async {
    final playlist = byId(playlistId);
    if (playlist == null || playlist.trackIds.contains(trackId)) return;
    playlist.trackIds.add(trackId);
    playlists.value = [...playlists.value];
    await _save();
  }

  Future<void> removeFrom(String playlistId, String trackId) async {
    final playlist = byId(playlistId);
    if (playlist == null || !playlist.trackIds.remove(trackId)) return;
    playlists.value = [...playlists.value];
    await _save();
  }

  /// Adds every id in [trackIds] not already in [playlistId] — one save and
  /// one notify for the whole batch, unlike calling [addTo] in a loop. Used
  /// by the playlist detail page's "+" multi-select add-songs flow.
  Future<void> addAllTo(String playlistId, Iterable<String> trackIds) async {
    final playlist = byId(playlistId);
    if (playlist == null) return;
    var changed = false;
    for (final trackId in trackIds) {
      if (!playlist.trackIds.contains(trackId)) {
        playlist.trackIds.add(trackId);
        changed = true;
      }
    }
    if (!changed) return;
    playlists.value = [...playlists.value];
    await _save();
  }

  /// Takes [trackId] out of every playlist (a deleted song).
  Future<void> removeTrackEverywhere(String trackId) async {
    var changed = false;
    for (final p in playlists.value) {
      if (!p.trackIds.contains(trackId)) continue;
      while (p.trackIds.remove(trackId)) {
        changed = true;
      }
    }
    if (!changed) return;
    playlists.value = [...playlists.value];
    await _save();
  }

  /// Points every playlist entry for [oldId] at [newId] (a moved phone
  /// song, whose id follows its path), keeping its place in the list.
  Future<void> renameTrackId(String oldId, String newId) async {
    if (oldId == newId) return;
    var changed = false;
    for (final p in playlists.value) {
      if (!p.trackIds.contains(oldId)) continue;
      for (var i = 0; i < p.trackIds.length; i++) {
        if (p.trackIds[i] == oldId) {
          p.trackIds[i] = newId;
          changed = true;
        }
      }
      // Never twice in one list.
      final seen = <String>{};
      p.trackIds.retainWhere(seen.add);
    }
    if (!changed) return;
    playlists.value = [...playlists.value];
    await _save();
  }

  /// Creates a new (non-system) playlist, e.g. from an M3U import. Returns
  /// the created playlist.
  Future<MusicPlaylist> createPlaylist(String name, List<String> trackIds,
      {String? id}) async {
    final playlist = MusicPlaylist(
      id: id ?? 'playlist_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      trackIds: [...trackIds],
    );
    playlists.value = [...playlists.value, playlist];
    await _save();
    return playlist;
  }

  /// Renames a hand-built, imported or rule playlist. No-op for a system
  /// playlist or a blank name.
  Future<void> renamePlaylist(String id, String name) async {
    final playlist = byId(id);
    final trimmed = name.trim();
    if (playlist == null || playlist.isSystem || trimmed.isEmpty) return;
    playlist.name = trimmed;
    playlists.value = [...playlists.value];
    await _save();
  }

  /// Puts [ordered] (track ids, e.g. after a drag on the edit page) as the
  /// playlist's order. Ids of the playlist missing from [ordered] (songs no
  /// longer in the library, so not shown) stay, at the end; ids not in the
  /// playlist are ignored.
  Future<void> setTrackOrder(String id, List<String> ordered) async {
    final playlist = byId(id);
    if (playlist == null || playlist.kind != PlaylistKind.list) return;
    final current = playlist.trackIds.toSet();
    final front = [for (final t in ordered) if (current.contains(t)) t];
    final shown = front.toSet();
    playlist.trackIds = [
      ...front,
      for (final t in playlist.trackIds) if (!shown.contains(t)) t,
    ];
    playlists.value = [...playlists.value];
    await _save();
  }

  Future<void> deletePlaylist(String id) async {
    final playlist = byId(id);
    if (playlist == null || playlist.isSystem) return;
    playlists.value = playlists.value.where((p) => p.id != id).toList();
    await _save();
  }

  /// Creates a new rule-based playlist (an AND/OR/NOT [ruleSet] over track
  /// metadata, evaluated live — never a stored track list). Returns the
  /// created playlist.
  Future<MusicPlaylist> createRulePlaylist(String name, PlaylistRuleSet ruleSet,
      {String? id}) async {
    final playlist = MusicPlaylist(
      id: id ?? 'rule_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      kind: PlaylistKind.rule,
      ruleSet: ruleSet,
    );
    playlists.value = [...playlists.value, playlist];
    await _save();
    return playlist;
  }

  /// Updates an existing rule playlist's name and/or rules in place. No-op
  /// if [id] isn't a rule playlist.
  Future<void> updateRulePlaylist(String id,
      {String? name, PlaylistRuleSet? ruleSet}) async {
    final index = playlists.value.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final existing = playlists.value[index];
    if (existing.kind != PlaylistKind.rule) return;
    final updated = MusicPlaylist(
      id: existing.id,
      name: name ?? existing.name,
      kind: PlaylistKind.rule,
      ruleSet: ruleSet ?? existing.ruleSet,
    );
    final list = List<MusicPlaylist>.of(playlists.value);
    list[index] = updated;
    playlists.value = list;
    await _save();
  }

  static const String lastAddedId = 'smart_last_added';
  static const String mostPlayedId = 'smart_most_played';

  /// How many tracks a computed ("smart") playlist shows at most.
  static const int smartPlaylistLimit = 50;

  /// Built-in computed playlists — "Last Added" and "Most Played" (overall,
  /// plus one per genre present in the library). Never persisted or
  /// deletable: recomputed from [MusicLibraryService.instance.tracks] on
  /// every read, so a rescan or a finished play immediately shows up.
  List<MusicPlaylist> get smartPlaylists {
    final libraryTracks = MusicLibraryService.instance.tracks.value;
    if (libraryTracks.isEmpty) return const [];
    final lastAdded = MusicPlaylist(
      id: lastAddedId,
      name: 'Last Added',
      isSystem: true,
      kind: PlaylistKind.lastAdded,
    );
    final mostPlayed = MusicPlaylist(
      id: mostPlayedId,
      name: 'Most Played',
      isSystem: true,
      kind: PlaylistKind.mostPlayed,
    );
    final genres = libraryTracks
        .map((t) => t.genre.trim())
        .where((g) => g.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final mostPlayedByGenre = [
      for (final genre in genres)
        MusicPlaylist(
          id: 'smart_most_played_$genre',
          name: 'Most Played: $genre',
          isSystem: true,
          kind: PlaylistKind.mostPlayed,
          genreFilter: genre,
        ),
    ];
    return [lastAdded, mostPlayed, ...mostPlayedByGenre];
  }

  /// The tracks a playlist currently resolves to: [MusicPlaylist.trackIds]
  /// looked up in the library for [PlaylistKind.list], or computed live for
  /// every other kind.
  List<Track> resolvedTracks(MusicPlaylist playlist) {
    final libraryTracks = MusicLibraryService.instance.tracks.value;
    switch (playlist.kind) {
      case PlaylistKind.list:
        return playlist.trackIds
            .map((id) => MusicLibraryService.instance.byId(id))
            .whereType<Track>()
            .toList();
      case PlaylistKind.lastAdded:
        final sorted = [...libraryTracks]..sort((a, b) {
            final aDate = a.dateAdded;
            final bDate = b.dateAdded;
            if (aDate == null && bDate == null) return 0;
            if (aDate == null) return 1;
            if (bDate == null) return -1;
            return bDate.compareTo(aDate);
          });
        return sorted.take(smartPlaylistLimit).toList();
      case PlaylistKind.mostPlayed:
        final genreFilter = playlist.genreFilter;
        final scoped = (genreFilter == null || genreFilter.isEmpty)
            ? libraryTracks
            : libraryTracks.where((t) => t.genre == genreFilter).toList();
        final played = scoped.where((t) => t.playCount > 0).toList()
          ..sort((a, b) => b.playCount.compareTo(a.playCount));
        return played.take(smartPlaylistLimit).toList();
      case PlaylistKind.rule:
        final ruleSet = playlist.ruleSet;
        if (ruleSet == null) return const [];
        return libraryTracks.where(ruleSet.matches).toList();
    }
  }

  double weightOf(String trackId) {
    if (isDisliked(trackId)) return dislikedWeight;
    if (isFavorite(trackId)) return favoriteWeight;
    if (isLiked(trackId)) return likedWeight;
    return normalWeight;
  }

  /// Bounds of [listeningFactor], so no history makes a song (nearly)
  /// certain or (nearly) impossible on its own.
  static const double minListeningFactor = 0.25;
  static const double maxListeningFactor = 4.0;

  /// How [track]'s listening history scales its shuffle weight: plays and
  /// swipes up count for it (a swipe up twice a play), skips and swipes
  /// down against it (a swipe down three times a skip), as the square root
  /// of the ratio — `sqrt((plays + 2·ups + 2) / (skips + 3·downs + 2))`,
  /// kept within [minListeningFactor]..[maxListeningFactor]. A song with
  /// no history is 1.0; one played 100 times and skipped 10 is ~2.9; one
  /// only ever skipped 5 times is ~0.53. It's a ratio, so a well-loved
  /// song that gets skipped now and then still ranks high.
  static double listeningFactor(Track track) {
    final positive = track.playCount + 2 * track.upSwipeCount + 2;
    final negative = track.skipCount + 3 * track.downSwipeCount + 2;
    return sqrt(positive / negative)
        .clamp(minListeningFactor, maxListeningFactor)
        .toDouble();
  }

  /// [track]'s full shuffle weight: Favorites/"Don't really like"/normal
  /// ([weightOf]) times its [listeningFactor].
  double weightFor(Track track) => weightOf(track.id) * listeningFactor(track);

  /// Builds a shuffled play order over [source] using weighted random
  /// sampling without replacement (Efraimidis–Spirakis A-Res): each track
  /// gets a key of `random()^(1/weight)` and the result is sorted
  /// descending by key, with [weightFor] as the weight. Higher-weight
  /// tracks (favorites, often played/swiped up) tend to land earlier;
  /// lower-weight tracks (disliked, often skipped/swiped down) tend to
  /// land much later — every track can still appear, just far less often.
  List<Track> weightedShuffle(List<Track> source) {
    if (source.length <= 1) return [...source];
    final keyed = source.map((t) {
      final w = max(weightFor(t), 0.0001);
      final r = _random.nextDouble().clamp(0.0001, 1.0);
      final key = pow(r, 1 / w).toDouble();
      return MapEntry(key, t);
    }).toList();
    keyed.sort((a, b) => b.key.compareTo(a.key));
    return keyed.map((e) => e.value).toList();
  }

  /// Resets in-memory state (for tests).
  @visibleForTesting
  void resetForTest() {
    playlists.value = [];
    _loaded = false;
  }
}
