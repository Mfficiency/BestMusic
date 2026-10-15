/// Where a [Track]'s audio bytes come from.
enum TrackSource { local, subsonic, youtube }

/// A single playable song, either a file under the user's configured music
/// folder ([TrackSource.local]), a song on a connected Subsonic/
/// OpenSubsonic server ([TrackSource.subsonic]), or a YouTube video's audio
/// streamed from the Subscriptions feed ([TrackSource.youtube]).
///
/// [id] is stable and unique across all sources: `local:<absolute path>`
/// for local files, `subsonic:<server song id>` for Subsonic ones,
/// `youtube:<video id>` for YouTube videos — used as
/// the key everywhere a track needs to be referenced (favorites, disliked,
/// playlists, the now-playing queue) without holding the whole object.
class Track {
  final String id;
  final TrackSource source;

  /// Absolute file path. Only set for [TrackSource.local].
  final String? filePath;

  /// Subsonic song id on the configured server ([TrackSource.subsonic]),
  /// or the 11-character YouTube video id ([TrackSource.youtube]).
  final String? remoteId;

  /// Where a [TrackSource.subsonic] song lives on the server, relative to
  /// its music folder (`Chill/Kygo - Stay.mp3`) — the server tab's folders.
  /// Null for other sources and servers that don't report real paths.
  final String? remotePath;

  /// File size in bytes, when the server reported it ([TrackSource.subsonic]).
  final int? sizeBytes;

  /// Cover art URL (the video thumbnail for [TrackSource.youtube]); shown
  /// on Now Playing and handed to the system media notification. Null for
  /// local/Subsonic tracks, whose art isn't surfaced yet.
  final String? artUrl;

  /// A [TrackSource.youtube] track that is a *song* (picked from the
  /// library search's YouTube fallback) rather than a Subscriptions-feed
  /// video. Songs follow music playback rules — always 1x speed, the music
  /// volume, no feed resume/played bookkeeping — see [isFeedVideo].
  final bool youtubeSong;

  /// True for a Subscriptions-feed video: plays at the feed's speed and
  /// volume (with optional boost), resumes where it stopped, gets marked
  /// played. Everything else — local, Subsonic, YouTube songs — is music.
  bool get isFeedVideo => source == TrackSource.youtube && !youtubeSong;

  final String title;
  final String artist;
  final String album;

  /// Track length in milliseconds, when known (from ID3 tags or the server).
  final int? durationMs;

  /// Genre, when known (from an mp3's `TCON` ID3 tag). Empty when unknown —
  /// used to build "most played per genre" smart playlists and genre rule
  /// conditions.
  final String genre;

  /// Release year, when known (from an mp3's `TDRC`/`TYER`/`TDOR` ID3 tag).
  final int? year;

  /// Tempo in beats per minute, when known — from an mp3's `TBPM` ID3
  /// tag, a metadata CSV import or the Track info page. Backs the BPM
  /// range page.
  final int? bpm;

  /// When this track was first seen by a library scan. Preserved across
  /// later rescans (a file that's still there doesn't get a new "added"
  /// date just because the library was refreshed) — backs the "Last Added"
  /// smart playlist.
  final DateTime? dateAdded;

  /// When the file itself arrived on this phone/computer, read from the
  /// file system on every scan (`FileStat.changed`: the creation time on
  /// Windows, the inode change time on Android/Linux — set when the file
  /// was copied/downloaded there). Unlike [dateAdded] it is independent of
  /// when Best Music first scanned it. Null for Subsonic tracks and for
  /// libraries not rescanned since 0.2.87.
  final DateTime? deviceDate;

  /// How many times this track has been played to completion. Backs the
  /// "Most Played" smart playlists; bumped by [MusicAudioHandler], not by a
  /// manual skip.
  final int playCount;

  /// True once title/artist/album/genre/year were set by hand (the Track
  /// info page's "fill in missing metadata"), rather than read from the
  /// file's tags. A later [MusicLibraryService.rescan] keeps those fields
  /// as-is instead of overwriting them with a fresh (possibly still empty)
  /// tag read.
  final bool metadataEdited;

  /// Free-form labels the user assigns by hand (e.g. "Belgian Top Charts",
  /// "Wedding songs") to group tracks by occasion/playlist-worthiness in
  /// ways artist/genre/folder don't capture — see the Tags tab. Never read
  /// from a file's tags; always set via [MusicLibraryService.updateTrackMetadata]
  /// or a metadata CSV import, so it survives a rescan the same way other
  /// manually-edited fields do.
  final List<String> tags;

  const Track({
    required this.id,
    required this.source,
    this.filePath,
    this.remoteId,
    this.remotePath,
    this.sizeBytes,
    this.artUrl,
    this.youtubeSong = false,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationMs,
    this.genre = '',
    this.year,
    this.bpm,
    this.dateAdded,
    this.deviceDate,
    this.playCount = 0,
    this.metadataEdited = false,
    this.tags = const [],
  });

  factory Track.local({
    required String filePath,
    required String title,
    String artist = '',
    String album = '',
    int? durationMs,
    String genre = '',
    int? year,
    int? bpm,
    DateTime? dateAdded,
    DateTime? deviceDate,
    int playCount = 0,
    bool metadataEdited = false,
    List<String> tags = const [],
  }) {
    return Track(
      id: 'local:$filePath',
      source: TrackSource.local,
      filePath: filePath,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      genre: genre,
      year: year,
      bpm: bpm,
      dateAdded: dateAdded,
      deviceDate: deviceDate,
      playCount: playCount,
      metadataEdited: metadataEdited,
      tags: tags,
    );
  }

  factory Track.subsonic({
    required String remoteId,
    String? remotePath,
    int? sizeBytes,
    required String title,
    String artist = '',
    String album = '',
    int? durationMs,
    String genre = '',
    int? year,
    int? bpm,
  }) {
    return Track(
      id: 'subsonic:$remoteId',
      source: TrackSource.subsonic,
      remoteId: remoteId,
      remotePath: remotePath,
      sizeBytes: sizeBytes,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      genre: genre,
      year: year,
      bpm: bpm,
    );
  }

  /// A YouTube video's audio, played from the Subscriptions feed. [artist]
  /// is the channel name; [artUrl] the video thumbnail. [song]: a song
  /// streamed from the library search's YouTube fallback instead
  /// ([youtubeSong]).
  factory Track.youtube({
    required String videoId,
    required String title,
    String artist = '',
    int? durationMs,
    String? artUrl,
    bool song = false,
  }) {
    return Track(
      id: 'youtube:$videoId',
      source: TrackSource.youtube,
      remoteId: videoId,
      artUrl: artUrl,
      youtubeSong: song,
      title: title,
      artist: artist,
      durationMs: durationMs,
    );
  }

  /// The file's base name without extension, used as a fallback title and
  /// for fuzzy-matching M3U playlist entries.
  String get fileBaseName {
    final path = filePath ?? '';
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final name = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// The song's name as lists show it: the title (or, without one, the file
  /// name), minus a leading "Artist - " — files are often named
  /// "Artist - Song.m4a", and the artist goes on the line below
  /// ([displayArtist]).
  String get displayTitle => _displayParts.$2;

  /// The artist shown under [displayTitle]: the tag, or the "Artist" part of
  /// an "Artist - Song" name when the tag is empty. '' when unknown.
  String get displayArtist => _displayParts.$1;

  (String, String) get _displayParts {
    final name = title.trim().isNotEmpty ? title.trim() : fileBaseName;
    // A video's title is the video's, not a file name.
    if (source == TrackSource.youtube && !youtubeSong) return (artist, name);
    final split = splitArtistAndSong(name);
    if (split == null) return (artist, name);
    final (left, right) = split;
    if (artist.trim().isEmpty) return (left, right);
    return _sameName(left, artist) ? (artist, right) : (artist, name);
  }

  static final RegExp _artistSongPattern = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$');

  /// "Artist - Song" (also with – or —) split into (artist, song); null when
  /// [name] has no such separator.
  static (String, String)? splitArtistAndSong(String name) {
    final m = _artistSongPattern.firstMatch(name.trim());
    if (m == null) return null;
    final left = m.group(1)!.trim(), right = m.group(2)!.trim();
    if (left.isEmpty || right.isEmpty) return null;
    return (left, right);
  }

  static bool _sameName(String a, String b) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return n(a).isNotEmpty && n(a) == n(b);
  }

  /// Returns a copy with the given fields replaced. Used to update
  /// per-scan metadata while preserving [dateAdded]/[playCount] across a
  /// rescan, and to bump [playCount] on playback.
  Track copyWith({
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? genre,
    int? year,
    int? bpm,
    DateTime? dateAdded,
    DateTime? deviceDate,
    int? playCount,
    bool? metadataEdited,
    List<String>? tags,
  }) {
    return Track(
      id: id,
      source: source,
      filePath: filePath,
      remoteId: remoteId,
      remotePath: remotePath,
      sizeBytes: sizeBytes,
      artUrl: artUrl,
      youtubeSong: youtubeSong,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      genre: genre ?? this.genre,
      year: year ?? this.year,
      bpm: bpm ?? this.bpm,
      dateAdded: dateAdded ?? this.dateAdded,
      deviceDate: deviceDate ?? this.deviceDate,
      playCount: playCount ?? this.playCount,
      metadataEdited: metadataEdited ?? this.metadataEdited,
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.name,
        if (filePath != null) 'filePath': filePath,
        if (remoteId != null) 'remoteId': remoteId,
        if (remotePath != null) 'remotePath': remotePath,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (artUrl != null) 'artUrl': artUrl,
        if (youtubeSong) 'youtubeSong': true,
        'title': title,
        'artist': artist,
        'album': album,
        if (durationMs != null) 'durationMs': durationMs,
        if (genre.isNotEmpty) 'genre': genre,
        if (year != null) 'year': year,
        if (bpm != null) 'bpm': bpm,
        if (dateAdded != null) 'dateAdded': dateAdded!.millisecondsSinceEpoch,
        if (deviceDate != null)
          'deviceDate': deviceDate!.millisecondsSinceEpoch,
        if (playCount != 0) 'playCount': playCount,
        if (metadataEdited) 'metadataEdited': metadataEdited,
        if (tags.isNotEmpty) 'tags': tags,
      };

  factory Track.fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String?;
    final source = TrackSource.values.firstWhere(
      (s) => s.name == sourceName,
      orElse: () => TrackSource.local,
    );
    final dateAddedMs = json['dateAdded'];
    final deviceDateMs = json['deviceDate'];
    return Track(
      id: json['id'] as String? ?? '',
      source: source,
      filePath: json['filePath'] as String?,
      remoteId: json['remoteId'] as String?,
      remotePath: json['remotePath'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.round(),
      artUrl: json['artUrl'] as String?,
      youtubeSong: json['youtubeSong'] as bool? ?? false,
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.round(),
      genre: json['genre'] as String? ?? '',
      year: (json['year'] as num?)?.round(),
      bpm: (json['bpm'] as num?)?.round(),
      dateAdded: dateAddedMs is num
          ? DateTime.fromMillisecondsSinceEpoch(dateAddedMs.round())
          : null,
      deviceDate: deviceDateMs is num
          ? DateTime.fromMillisecondsSinceEpoch(deviceDateMs.round())
          : null,
      playCount: (json['playCount'] as num?)?.round() ?? 0,
      metadataEdited: json['metadataEdited'] as bool? ?? false,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
