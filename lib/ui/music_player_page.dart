import 'dart:async' show Timer, unawaited;
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/music_playlist.dart';
import '../models/track.dart';
import '../services/m3u_playlist_service.dart';
import '../services/mp3_downloader_service.dart';
import '../services/music_library_service.dart';
import '../services/server_catalog.dart';
import '../services/music_player_service.dart';
import '../services/speaker_play_guard.dart';
import '../services/subsonic_client.dart';
import '../services/track_file_actions.dart';
import '../services/music_playlist_service.dart';
import '../services/music_youtube_fallback.dart';
import '../utils/artist_utils.dart';
import 'app_logs_page.dart';
import 'best_music_logo.dart';
import 'bpm_range_page.dart';
import 'changelog_page.dart';
import 'estimated_progress_bar.dart';
import 'fast_scroll_list.dart';
import 'home_scaffold_key.dart';
import 'mp3_downloader_page.dart';
import 'music_about_page.dart';
import 'music_metadata_scan_page.dart';
import 'music_mini_player_bar.dart';
import 'music_settings_page.dart';
import 'music_wishlist_page.dart';
import 'now_playing_highlight.dart';
import 'now_playing_page.dart';
import 'play_history_page.dart';
import 'playlist_edit.dart';
import 'rule_playlist_editor_page.dart';
import 'startup_times_page.dart';
import 'server_tab.dart';
import 'subpage_app_bar.dart';
import 'track_file_menu.dart';
import 'track_selection_bar.dart';
import 'track_metadata_page.dart';
import 'trim_song_page.dart';
import '../services/track_trimmer.dart';
import 'youtube_feed_page.dart';

/// Tools → Music Player: browse/play tracks scanned from
/// [Config.musicFolder] (and, once configured, a Subsonic server), manage
/// Favorites/"Don't really like" and imported playlists, and import an
/// M3U/M3U8 playlist (e.g. shared out of Samsung Music).
///
/// Also the Best Music app's home page ([standalone]: true), where it is the
/// root route rather than a BestToDo Tools subpage: [homeScaffoldKey] +
/// [_buildDrawer] give it the same drawer-based menu as BestToDo's own home
/// page (Settings, Subscriptions, Tools → Songs by BPM / MP3 Downloader /
/// Wishlist, Changelog, Startup Times, App Logs, About), in place of
/// BestToDo's task-list-specific entries.
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key, this.standalone = false});

  final bool standalone;

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _pickingFolder = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    // The MP3 Downloader's folder is the common case for where music already
    // lives, so default straight to it instead of asking the user to pick
    // the same folder twice.
    if (Config.musicFolder.isEmpty && Config.mp3DownloadFolder.isNotEmpty) {
      Config.musicFolder = Config.mp3DownloadFolder;
      unawaited(Config.save());
    }
    // Also rescan a library cached before 0.2.87, whose local tracks don't
    // know when their file arrived on the device yet ([Track.deviceDate]).
    final cached = MusicLibraryService.instance.tracks.value;
    if (Config.musicFolder.isNotEmpty &&
        (cached.isEmpty ||
            cached.any((t) =>
                t.source == TrackSource.local && t.deviceDate == null))) {
      unawaited(MusicLibraryService.instance
          .ensureFolderPermission()
          .then((_) => MusicLibraryService.instance.rescan()));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    setState(() => _pickingFolder = true);
    try {
      await MusicLibraryService.instance.ensureFolderPermission();
      final directory = await getDirectoryPath();
      if (directory != null) {
        Config.musicFolder = directory;
        await Config.save();
        await MusicLibraryService.instance.rescan();
      }
    } finally {
      if (mounted) setState(() => _pickingFolder = false);
    }
  }

  Future<void> _rescan() async {
    final messenger = ScaffoldMessenger.of(context);
    await MusicLibraryService.instance.rescan();
    if (!mounted) return;
    final count = MusicLibraryService.instance.tracks.value.length;
    messenger.showSnackBar(SnackBar(content: Text('Found $count tracks')));
  }

  Future<void> _importM3u() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Playlist', extensions: ['m3u', 'm3u8']),
    ]);
    if (file == null) return;
    final result = await M3uPlaylistService.importFile(File(file.path));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(result.unmatchedEntries.isEmpty
          ? 'Imported "${result.playlist.name}": ${result.matchedCount} tracks'
          : 'Imported "${result.playlist.name}": ${result.matchedCount} matched, '
              '${result.unmatchedEntries.length} not found in your library'),
    ));
  }

  /// [standalone] mode is the Best Music app's root page: a real [Drawer]
  /// (matching BestToDo's own home page — see [homeScaffoldKey]) stands in
  /// for the Tools menu + About page, so [buildSubpageAppBar]'s "Menu"
  /// button (used by every page this drawer pushes) has something to open.
  PreferredSizeWidget _appBar(
    BuildContext context, {
    required String title,
    PreferredSizeWidget? bottom,
    List<Widget> actions = const [],
  }) {
    if (!widget.standalone) {
      return buildSubpageAppBar(context,
          title: title, bottom: bottom, actions: actions);
    }
    return AppBar(title: Text(title), bottom: bottom, actions: actions);
  }

  void _pushStandalonePage(Widget Function() builder) {
    Navigator.of(context).pop(); // close the drawer
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => builder()));
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          FutureBuilder<void>(
            future: Config.ensureVersionLoaded(),
            builder: (context, snapshot) {
              return Container(
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.primary,
                child: Row(
                  children: [
                    const BestMusicLogo(size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Best Music v${Config.version}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimary,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Same order as BestToDo's drawer: Home · Settings · app entries ·
          // Changelog · About · App Logs · Startup Times.
          ListTile(
            leading: const Icon(Icons.home),
            title: const Text('Home'),
            onTap: () => Navigator.of(context).pop(), // the player is home
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () =>
                _pushStandalonePage(() => const MusicSettingsPage()),
          ),
          ListTile(
            leading: const Icon(Icons.subscriptions_outlined),
            title: const Text('Subscriptions'),
            onTap: () {
              Navigator.of(context).pop(); // close the drawer
              Navigator.of(context).push(YoutubeFeedPage.route());
            },
          ),
          // Tools: the less-used helper pages, collapsed by default.
          ExpansionTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Tools'),
            childrenPadding: const EdgeInsets.only(left: 16),
            children: [
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Songs by BPM'),
                onTap: () => _pushStandalonePage(() => const BpmRangePage()),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('MP3 Downloader'),
                onTap: () =>
                    _pushStandalonePage(() => const Mp3DownloaderPage()),
              ),
              ListTile(
                leading: const Icon(Icons.star_border),
                title: const Text('Wishlist'),
                onTap: () =>
                    _pushStandalonePage(() => const MusicWishlistPage()),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Play history'),
                onTap: () =>
                    _pushStandalonePage(() => const PlayHistoryPage()),
              ),
            ],
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Changelog'),
            onTap: () => _pushStandalonePage(() => const ChangelogPage()),
          ),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('About'),
            onTap: () => _pushStandalonePage(() => const MusicAboutPage()),
          ),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('App Logs'),
            onTap: () => _pushStandalonePage(() => const AppLogsPage()),
          ),
          ListTile(
            leading: const Icon(Icons.show_chart),
            title: const Text('Startup Times'),
            onTap: () =>
                _pushStandalonePage(() => const StartupTimesPage()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Config.musicFolder.isEmpty) {
      return Scaffold(
        key: widget.standalone ? homeScaffoldKey : null,
        drawer: widget.standalone ? _buildDrawer(context) : null,
        appBar: _appBar(context,
            title: widget.standalone ? 'Best Music' : 'Music Player'),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_open, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'Choose the folder your music lives in. Every subfolder is '
                  'included automatically — you can exclude specific ones '
                  'from Settings → Music Player.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _pickingFolder ? null : _pickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose music folder'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      key: widget.standalone ? homeScaffoldKey : null,
      drawer: widget.standalone ? _buildDrawer(context) : null,
      appBar: _appBar(
        context,
        title: widget.standalone ? 'Best Music' : 'Music Player',
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search music',
            onPressed: () => showSearch(
              context: context,
              delegate: _MusicSearchDelegate(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.shuffle),
            tooltip: 'Shuffle play',
            onPressed: () async {
              if (!await SpeakerPlayGuard.confirmPlay(context)) return;
              await MusicPlayerService.playLibraryShuffled();
              if (mounted) {
                Navigator.of(context).push(
                    NowPlayingPage.route());
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Import M3U/M3U8 playlist',
            onPressed: _importM3u,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan library',
            onPressed: _rescan,
          ),
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'Metadata scan',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const MusicMetadataScanPage(),
            )),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Favourites'),
            Tab(text: 'Playlists'),
            Tab(text: 'Tracks'),
            Tab(text: 'Artists'),
            Tab(text: 'Tags'),
            Tab(text: 'Folders'),
            Tab(text: 'Server'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                _FavouritesTab(),
                _PlaylistsTab(),
                _TracksTab(),
                _ArtistsTab(),
                _TagsTab(),
                _FoldersTab(),
                ServerTab(),
              ],
            ),
          ),
          // Best Music shows its mini player below every screen instead
          // (main.dart); BestToDo's Music Player tool keeps its own.
          if (!widget.standalone) const MusicMiniPlayerBar(),
        ],
      ),
    );
  }
}

/// Every track whose [Track.title]/[Track.artist] (or filename, as a
/// fallback) contains [query], case-insensitively. Used by
/// [_MusicSearchDelegate].
List<Track> _filterTracks(List<Track> tracks, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return tracks;
  return tracks
      .where((t) =>
          t.title.toLowerCase().contains(q) ||
          t.fileBaseName.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q))
      .toList();
}

/// Library-wide search reached from the app bar's search icon — Samsung
/// Music style: type to filter by title or artist, tap a result to start
/// playing it from that point. When nothing in the library matches, it
/// searches YouTube instead ([YoutubeSearchFallback]).
class _MusicSearchDelegate extends SearchDelegate<void> {
  Widget _buildTrackResults(BuildContext context) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const Center(child: Text('Search by title or artist'));
    }
    return LibrarySearchResults(key: ValueKey(trimmed), query: trimmed);
  }

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'Clear search',
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const BackButtonIcon(),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _buildTrackResults(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildTrackResults(context);
}

/// The leading icon of a song row: a cloud for a song on the music server,
/// a note for everything else.
Widget trackSourceIcon(Track track) => track.source == TrackSource.subsonic
    ? const Tooltip(
        message: 'On the music server', child: Icon(Icons.cloud_outlined))
    : const Icon(Icons.music_note);

/// The library search's results for [query]: the library's matches (server
/// songs already synced among them, with a cloud icon) plus — when a music
/// server is set up — whatever the server itself finds that the library
/// doesn't have yet (after a short pause in typing). When neither has
/// anything, it falls back to YouTube ([YoutubeSearchFallback]).
class LibrarySearchResults extends StatefulWidget {
  const LibrarySearchResults({super.key, required this.query});

  final String query;

  /// Pause after the last keystroke before asking the server.
  static const Duration debounce = Duration(milliseconds: 400);

  @override
  State<LibrarySearchResults> createState() => _LibrarySearchResultsState();
}

class _LibrarySearchResultsState extends State<LibrarySearchResults> {
  Timer? _debounce;
  bool _searchingServer = false;
  List<Track> _fromServer = const [];

  @override
  void initState() {
    super.initState();
    if (SubsonicClient.instance.isConfigured) {
      _searchingServer = true;
      _debounce = Timer(LibrarySearchResults.debounce, _searchServer);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchServer() async {
    final found = await SubsonicClient.instance.search(widget.query);
    if (!mounted) return;
    setState(() {
      _fromServer = found;
      _searchingServer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, library, _) {
        final local = _filterTracks(library, widget.query);
        final known = {for (final t in library) t.id};
        // A server song that is also on the phone is already in the library
        // as the phone's copy; show that one only.
        final onPhone = SameSongIndex(
            library.where((t) => t.source == TrackSource.local));
        final extra = [
          for (final t in _fromServer)
            if (!known.contains(t.id) && onPhone.match(t) == null) t
        ];
        final tracks = [...local, ...extra];
        if (tracks.isEmpty) {
          if (_searchingServer) {
            return const Align(
                alignment: Alignment.topCenter,
                child: EstimatedProgressBar(active: true));
          }
          if (!Mp3DownloaderService.instance.isSupported) {
            return Center(child: Text('No matches for "${widget.query}"'));
          }
          return YoutubeSearchFallback(
              key: ValueKey(widget.query), query: widget.query);
        }
        return Column(children: [
          if (_searchingServer) const EstimatedProgressBar(active: true),
          Expanded(child: TrackListView(tracks: tracks)),
        ]);
      },
    );
  }
}

/// Shown by the library search when nothing matches [query]: searches
/// YouTube for it automatically (after a short pause in typing, so every
/// keystroke doesn't fire a request) and lists the results under a clear
/// "Not in your library" banner, each tagged YouTube, so they can't be
/// mistaken for local songs. Tapping one starts playing it straight away
/// while it silently downloads in the background
/// ([MusicYoutubeFallback.playAndDownload]).
class YoutubeSearchFallback extends StatefulWidget {
  const YoutubeSearchFallback({super.key, required this.query});

  final String query;

  /// Pause after the last keystroke before searching.
  static const Duration debounce = Duration(milliseconds: 600);

  @override
  State<YoutubeSearchFallback> createState() => _YoutubeSearchFallbackState();
}

class _YoutubeSearchFallbackState extends State<YoutubeSearchFallback> {
  Timer? _debounce;
  bool _searching = true;
  String? _error;
  List<Mp3SearchResult>? _results;

  @override
  void initState() {
    super.initState();
    _debounce = Timer(YoutubeSearchFallback.debounce, _search);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results =
          await Mp3DownloaderService.instance.search(widget.query, limit: 10);
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted) return;
      // Show what actually went wrong — "check your connection" alone hid a
      // consent-page parsing failure on a perfectly good connection.
      setState(() => _error = e is Mp3DownloadException
          ? e.message
          : 'YouTube search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _play(Mp3SearchResult result) async {
    if (!await SpeakerPlayGuard.confirmPlay(context)) return;
    await MusicYoutubeFallback.playAndDownload(result);
    if (mounted) {
      Navigator.of(context)
          .push(NowPlayingPage.route());
    }
  }

  static String _formatDuration(Duration? d) {
    if (d == null) return '';
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _banner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.cloud_outlined, color: scheme.onSecondaryContainer),
        title: Text(
          'Not in your library',
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: scheme.onSecondaryContainer),
        ),
        subtitle: Text(
          _searching
              ? 'Searching YouTube for "${widget.query}"...'
              : 'Results from YouTube, not songs on your phone. Tap one to '
                  'stream it — it\'s saved to your library in the background.',
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _results;
    return ListView(
      children: [
        EstimatedProgressBar(active: _searching),
        _banner(context),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error)),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          )
        else if (results != null && results.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Nothing on YouTube for "${widget.query}" either',
                textAlign: TextAlign.center),
          )
        else if (results != null)
          for (final result in results)
            NowPlayingHighlight(
              trackId: 'youtube:${result.videoId}',
              builder: (context, isCurrent) => ListTile(
              selected: isCurrent,
              leading: isCurrent
                  ? nowPlayingIcon
                  : const Icon(Icons.smart_display_outlined),
              title: Text(result.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                ['YouTube', result.channel, _formatDuration(result.duration)]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.cloud_download_outlined,
                  size: 20, color: scheme.outline),
              onTap: () => _play(result),
            ),
            ),
      ],
    );
  }
}

class _TracksTab extends StatelessWidget {
  const _TracksTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, tracks, _) {
        if (tracks.isEmpty) {
          return const Center(child: Text('No tracks found. Tap refresh to rescan.'));
        }
        return TrackListView(tracks: tracks);
      },
    );
  }
}

/// Shortcut tab straight to the Favorites system playlist — the same track
/// list also reachable from Playlists → Favorites, just one tap away like
/// Samsung Music's own Favourites tab.
class _FavouritesTab extends StatelessWidget {
  const _FavouritesTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, _, __) {
        return ValueListenableBuilder<List<MusicPlaylist>>(
          valueListenable: MusicPlaylistService.instance.playlists,
          builder: (context, __, ___) {
            final tracks = MusicPlaylistService.instance
                .resolvedTracks(MusicPlaylistService.instance.favorites);
            if (tracks.isEmpty) {
              return const Center(
                child: Text(
                    'No favorites yet. Tap the heart on a track to add one.'),
              );
            }
            return TrackListView(tracks: tracks);
          },
        );
      },
    );
  }
}

/// Every artist present in the library, grouped by [splitArtistCredit]'s
/// main artist so "49th & Main" and "49th & Main feat. SKYLAR" land under
/// one "49th & Main" entry rather than two (an empty [Track.artist] groups
/// under "Unknown artist"), sorted alphabetically with "Unknown artist"
/// last. Tapping one opens its own filtered track list; an entry whose
/// tracks include a featuring credit shows who's featured on the right.
class _ArtistsTab extends StatelessWidget {
  const _ArtistsTab();

  static const String _unknownArtist = 'Unknown artist';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, tracks, _) {
        if (tracks.isEmpty) {
          return const Center(child: Text('No tracks found. Tap refresh to rescan.'));
        }
        final byArtist = <String, List<Track>>{};
        final featuringByArtist = <String, Set<String>>{};
        for (final track in tracks) {
          final credit = splitArtistCredit(track.displayArtist);
          final artist = credit.mainArtist.isEmpty ? _unknownArtist : credit.mainArtist;
          byArtist.putIfAbsent(artist, () => []).add(track);
          if (credit.featuring.isNotEmpty) {
            featuringByArtist.putIfAbsent(artist, () => <String>{}).add(credit.featuring);
          }
        }
        final artists = byArtist.keys.toList()
          ..sort((a, b) {
            if (a == _unknownArtist) return b == _unknownArtist ? 0 : 1;
            if (b == _unknownArtist) return -1;
            return a.toLowerCase().compareTo(b.toLowerCase());
          });
        return ListView.builder(
          itemCount: artists.length,
          itemBuilder: (context, index) {
            final artist = artists[index];
            final artistTracks = byArtist[artist]!;
            final featuring = featuringByArtist[artist];
            return ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(artist),
              subtitle: Text(
                  '${artistTracks.length} track${artistTracks.length == 1 ? '' : 's'}'),
              trailing: (featuring == null || featuring.isEmpty)
                  ? null
                  : SizedBox(
                      width: 120,
                      child: Text(
                        'feat. ${featuring.join(', ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _FilteredTracksPage(title: artist, tracks: artistTracks),
              )),
            );
          },
        );
      },
    );
  }
}

/// Every tag present in the library — a track with no [Track.tags] groups
/// under "Untagged"; a track with several tags appears under each of them
/// (tags are a many-to-many grouping, unlike Artists/Folders). Tags are
/// user-assigned via the Track info page (e.g. "Wedding songs", "Belgian
/// Top Charts") rather than read from file metadata. Sorted alphabetically
/// with "Untagged" last; tapping one opens its own filtered track list.
class _TagsTab extends StatelessWidget {
  const _TagsTab();

  static const String _untagged = 'Untagged';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, tracks, _) {
        if (tracks.isEmpty) {
          return const Center(child: Text('No tracks found. Tap refresh to rescan.'));
        }
        final byTag = <String, List<Track>>{};
        for (final track in tracks) {
          if (track.tags.isEmpty) {
            byTag.putIfAbsent(_untagged, () => []).add(track);
            continue;
          }
          for (final tag in track.tags) {
            byTag.putIfAbsent(tag, () => []).add(track);
          }
        }
        final tagNames = byTag.keys.toList()
          ..sort((a, b) {
            if (a == _untagged) return b == _untagged ? 0 : 1;
            if (b == _untagged) return -1;
            return a.toLowerCase().compareTo(b.toLowerCase());
          });
        return ListView.builder(
          itemCount: tagNames.length,
          itemBuilder: (context, index) {
            final tag = tagNames[index];
            final tagTracks = byTag[tag]!;
            return ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(tag),
              subtitle:
                  Text('${tagTracks.length} track${tagTracks.length == 1 ? '' : 's'}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _FilteredTracksPage(title: tag, tracks: tagTracks),
              )),
            );
          },
        );
      },
    );
  }
}

/// The folder (relative to [Config.musicFolder]) a local [track] lives in,
/// for grouping in the Folders tab. Tracks right under the music folder
/// itself group under "(Music folder)"; a music server song groups under
/// "Server/<its folder there>", anything else under "Other".
String folderLabelOf(Track track) {
  final path = track.filePath;
  if (track.source == TrackSource.subsonic) {
    final folder = ServerCatalog.folderOf(track);
    return folder.isEmpty ? 'Server' : 'Server/$folder';
  }
  if (path == null) return 'Other';
  final root = MusicLibraryService.normalizePath(Config.musicFolder.trim());
  final normalized = MusicLibraryService.normalizePath(path);
  var rel = normalized.startsWith(root) ? normalized.substring(root.length) : normalized;
  if (rel.startsWith('/')) rel = rel.substring(1);
  final slash = rel.lastIndexOf('/');
  final folder = slash >= 0 ? rel.substring(0, slash) : '';
  return folder.isEmpty ? '(Music folder)' : folder;
}

/// Every folder tracks were scanned from, sorted alphabetically — the
/// leading "(" on "(Music folder)" sorts it ahead of any real subfolder
/// name. Tapping one opens its own filtered track list.
class _FoldersTab extends StatelessWidget {
  const _FoldersTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, tracks, _) {
        if (tracks.isEmpty) {
          return const Center(child: Text('No tracks found. Tap refresh to rescan.'));
        }
        final byFolder = <String, List<Track>>{};
        for (final track in tracks) {
          byFolder.putIfAbsent(folderLabelOf(track), () => []).add(track);
        }
        final folders = byFolder.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return ListView.builder(
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            final folderTracks = byFolder[folder]!;
            return ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder),
              subtitle: Text(
                  '${folderTracks.length} track${folderTracks.length == 1 ? '' : 's'}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _FilteredTracksPage(title: folder, tracks: folderTracks),
              )),
            );
          },
        );
      },
    );
  }
}

/// Plain subpage showing a fixed track list — used by the Artists and
/// Folders tabs to drill into one artist/folder's songs.
class _FilteredTracksPage extends StatelessWidget {
  const _FilteredTracksPage({required this.title, required this.tracks});

  final String title;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: title),
      body: TrackListView(tracks: tracks),
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();

  IconData _iconFor(MusicPlaylist playlist) {
    if (playlist.id == MusicPlaylist.favoritesId) return Icons.favorite;
    if (playlist.id == MusicPlaylist.likedId) return Icons.thumb_up;
    if (playlist.id == MusicPlaylist.dislikedId) return Icons.thumb_down_alt;
    switch (playlist.kind) {
      case PlaylistKind.lastAdded:
        return Icons.new_releases_outlined;
      case PlaylistKind.mostPlayed:
        return Icons.trending_up;
      case PlaylistKind.rule:
        return Icons.rule;
      case PlaylistKind.list:
        return Icons.playlist_play;
    }
  }

  Widget? _trailingFor(BuildContext context, MusicPlaylist playlist) {
    // System entries (Favorites/"Don't really like" plus every computed
    // smart playlist) can't be renamed, edited or deleted.
    if (!playlistIsEditable(playlist)) return null;
    return PlaylistOptionsButton(playlist: playlist);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, _, __) {
        return ValueListenableBuilder<List<MusicPlaylist>>(
          valueListenable: MusicPlaylistService.instance.playlists,
          builder: (context, userPlaylists, __) {
            // Hand-made playlists (Favorites/"Don't really like", built,
            // imported or rule playlists) come first; the computed ones
            // follow, with the per-genre "Most Played" lists tucked into a
            // collapsed group so they don't push everything else down.
            final smart = MusicPlaylistService.instance.smartPlaylists;
            final byGenre = smart
                .where((p) => (p.genreFilter ?? '').isNotEmpty)
                .toList();
            final otherSmart = smart
                .where((p) => (p.genreFilter ?? '').isEmpty)
                .toList();
            return ListView(
              children: [
                for (final playlist in userPlaylists)
                  _playlistTile(context, playlist),
                ListTile(
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('New playlist'),
                  onTap: () async {
                    final name = await promptPlaylistName(context);
                    if (name == null || name.trim().isEmpty) return;
                    await MusicPlaylistService.instance
                        .createPlaylist(name.trim(), []);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.rule),
                  title: const Text('New rule playlist'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const RulePlaylistEditorPage(),
                  )),
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('Songs by BPM'),
                  subtitle: const Text(
                      'Pick a BPM range, play it or save it as a playlist'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BpmRangePage(),
                  )),
                ),
                for (final playlist in otherSmart)
                  _playlistTile(context, playlist),
                if (byGenre.isNotEmpty)
                  ExpansionTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Most played by genre'),
                    subtitle: Text(
                        '${byGenre.length} genre${byGenre.length == 1 ? '' : 's'}'),
                    children: [
                      for (final playlist in byGenre)
                        _playlistTile(context, playlist,
                            title: playlist.genreFilter),
                    ],
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _playlistTile(BuildContext context, MusicPlaylist playlist,
      {String? title}) {
    final trackCount =
        MusicPlaylistService.instance.resolvedTracks(playlist).length;
    return ListTile(
      leading: Icon(_iconFor(playlist)),
      title: Text(title ?? playlist.name),
      subtitle: Text('$trackCount tracks'),
      trailing: _trailingFor(context, playlist),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MusicPlaylistDetailPage(playlist: playlist),
      )),
    );
  }
}

class MusicPlaylistDetailPage extends StatelessWidget {
  const MusicPlaylistDetailPage({super.key, required this.playlist});

  final MusicPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MusicPlaylist>>(
      valueListenable: MusicPlaylistService.instance.playlists,
      builder: (context, __, _) {
        // A persisted playlist (list/rule) may have changed since
        // [playlist] was captured (a rule edit, a favorite toggle); a
        // computed smart playlist isn't in this list at all, so falls
        // back to the one passed in — its kind/genreFilter never change.
        final current =
            MusicPlaylistService.instance.byId(playlist.id) ?? playlist;
        // Only a hand-built, non-system playlist has a fixed track list
        // songs can actually be added to or removed from — a smart/rule
        // playlist is recomputed, and Favorites/"Don't really like" are
        // toggled via the heart/dislike gesture instead.
        final editable = current.kind == PlaylistKind.list && !current.isSystem;
        // Liked songs has no "un-swipe": a song leaves it from here.
        final removable =
            editable || current.id == MusicPlaylist.likedId;
        return Scaffold(
          appBar: buildSubpageAppBar(
            context,
            title: current.name,
            actions: [
              if (editable)
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add songs',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AddSongsToPlaylistPage(playlistId: current.id),
                  )),
                ),
              if (playlistIsEditable(current))
                PlaylistOptionsButton(
                  playlist: current,
                  onDeleted: () {
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
            ],
          ),
          body: ValueListenableBuilder<List<Track>>(
            valueListenable: MusicLibraryService.instance.tracks,
            builder: (context, _, __) {
              final tracks = MusicPlaylistService.instance.resolvedTracks(current);
              if (tracks.isEmpty) {
                return Center(
                  child: Text(current.kind == PlaylistKind.rule
                      ? 'No tracks match these rules yet.'
                      : 'No tracks in this playlist yet.'),
                );
              }
              return TrackListView(
                tracks: tracks,
                // Its own order (dragged on Edit songs, or a smart list's
                // computed order) is one of the sort choices.
                listOrder: true,
                onRemove: removable
                    ? (track) =>
                        MusicPlaylistService.instance.removeFrom(current.id, track.id)
                    : null,
              );
            },
          ),
        );
      },
    );
  }
}

/// Multi-select track picker reached from a playlist's "+" app bar button —
/// every library track not already in the playlist, with a checkbox each;
/// "Add" applies the whole selection in one go.
class AddSongsToPlaylistPage extends StatefulWidget {
  const AddSongsToPlaylistPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<AddSongsToPlaylistPage> createState() => _AddSongsToPlaylistPageState();
}

class _AddSongsToPlaylistPageState extends State<AddSongsToPlaylistPage> {
  final Set<String> _selected = {};

  Future<void> _confirm() async {
    await MusicPlaylistService.instance.addAllTo(widget.playlistId, _selected);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = MusicPlaylistService.instance.byId(widget.playlistId);
    final existing = playlist?.trackIds.toSet() ?? <String>{};
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, allTracks, _) {
        final candidates = allTracks.where((t) => !existing.contains(t.id)).toList();
        return Scaffold(
          appBar: buildSubpageAppBar(
            context,
            title: 'Add songs',
            actions: [
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'Add selected',
                onPressed: _selected.isEmpty ? null : _confirm,
              ),
            ],
          ),
          body: candidates.isEmpty
              ? const Center(child: Text('Every track is already in this playlist.'))
              : ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (context, index) {
                    final track = candidates[index];
                    return CheckboxListTile(
                      value: _selected.contains(track.id),
                      title: Text(track.displayTitle),
                      subtitle: track.displayArtist.isNotEmpty
                          ? Text(track.displayArtist)
                          : null,
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(track.id);
                        } else {
                          _selected.remove(track.id);
                        }
                      }),
                    );
                  },
                ),
        );
      },
    );
  }
}

/// Quick ways to reorder a [TrackListView] — mirrors the sort options
/// Samsung Music offers on its Tracks list. Each field sorts either
/// ascending or descending; see [trackSortDefaultAscending]. [deviceDate]
/// is when the file arrived on the phone/computer ([Track.deviceDate]),
/// [dateAdded] when Best Music's scan first saw it ([Track.dateAdded]).
/// [listOrder] is a playlist's own order (as dragged on its Edit songs
/// page) and only offered on playlist pages ([TrackListView.listOrder]).
enum TrackSortField {
  deviceDate,
  dateAdded,
  title,
  artist,
  duration,
  playCount,
  listOrder,
}

String trackSortLabel(TrackSortField field) {
  switch (field) {
    case TrackSortField.deviceDate:
      return 'Added to device';
    case TrackSortField.dateAdded:
      return 'Added to app';
    case TrackSortField.title:
      return 'Title';
    case TrackSortField.artist:
      return 'Artist';
    case TrackSortField.duration:
      return 'Duration';
    case TrackSortField.playCount:
      return 'Times played';
    case TrackSortField.listOrder:
      return 'Playlist order';
  }
}

/// Human wording of a direction for [field] ("A–Z", "Newest first", ...).
String trackSortDirectionLabel(TrackSortField field, bool ascending) {
  switch (field) {
    case TrackSortField.deviceDate:
    case TrackSortField.dateAdded:
      return ascending ? 'Oldest first' : 'Newest first';
    case TrackSortField.title:
    case TrackSortField.artist:
      return ascending ? 'A–Z' : 'Z–A';
    case TrackSortField.duration:
      return ascending ? 'Shortest first' : 'Longest first';
    case TrackSortField.playCount:
      return ascending ? 'Least played first' : 'Most played first';
    case TrackSortField.listOrder:
      return ascending ? 'First to last' : 'Last to first';
  }
}

/// The direction a field starts in when first picked: newest/longest/most
/// played first for dates, durations and play counts, A–Z for text, first
/// to last for a playlist's own order.
bool trackSortDefaultAscending(TrackSortField field) =>
    field == TrackSortField.title ||
    field == TrackSortField.artist ||
    field == TrackSortField.listOrder;

String _trackDisplayTitle(Track t) => t.displayTitle;

DateTime? _trackSortDate(Track t, TrackSortField field) =>
    field == TrackSortField.deviceDate ? t.deviceDate : t.dateAdded;

/// Sorts [tracks] by [field] in the given direction. Tracks with no date
/// for a date field always sink to the bottom, whichever way the list runs; ties
/// fall back to title so the order is stable.
List<Track> sortTracks(List<Track> tracks, TrackSortField field,
    {bool? ascending}) {
  final asc = ascending ?? trackSortDefaultAscending(field);
  // A playlist's own order: as given, or reversed.
  if (field == TrackSortField.listOrder) {
    return asc ? [...tracks] : tracks.reversed.toList();
  }
  final sign = asc ? 1 : -1;
  int byTitle(Track a, Track b) => _trackDisplayTitle(a)
      .toLowerCase()
      .compareTo(_trackDisplayTitle(b).toLowerCase());
  final sorted = [...tracks];
  sorted.sort((a, b) {
    int primary;
    switch (field) {
      case TrackSortField.deviceDate:
      case TrackSortField.dateAdded:
        final aDate = _trackSortDate(a, field);
        final bDate = _trackSortDate(b, field);
        if (aDate == null && bDate == null) return byTitle(a, b);
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        primary = sign * aDate.compareTo(bDate);
        break;
      case TrackSortField.title:
        return sign * byTitle(a, b);
      case TrackSortField.artist:
        primary =
            sign * a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        break;
      case TrackSortField.duration:
        primary = sign * (a.durationMs ?? 0).compareTo(b.durationMs ?? 0);
        break;
      case TrackSortField.playCount:
        primary = sign * a.playCount.compareTo(b.playCount);
        break;
      case TrackSortField.listOrder:
        return 0; // handled above
    }
    return primary != 0 ? primary : byTitle(a, b);
  });
  return sorted;
}

const _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _initialOf(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '#';
  final first = String.fromCharCode(trimmed.runes.first).toUpperCase();
  return RegExp(r'[0-9]').hasMatch(first) ? '#' : first;
}

/// Fast-scroll bubble text for [track] under [field]: the initial letter
/// for title/artist, "Sep 2026" for either date, "3 min" for duration.
String trackSectionLabel(Track track, TrackSortField field) {
  switch (field) {
    case TrackSortField.title:
      return _initialOf(_trackDisplayTitle(track));
    case TrackSortField.artist:
      return _initialOf(track.artist);
    case TrackSortField.deviceDate:
    case TrackSortField.dateAdded:
      final date = _trackSortDate(track, field);
      if (date == null) return '—';
      return '${_monthAbbr[date.month - 1]} ${date.year}';
    case TrackSortField.duration:
      final ms = track.durationMs;
      if (ms == null) return '—';
      return '${ms ~/ 60000} min';
    case TrackSortField.playCount:
      return playCountLabel(track.playCount);
    case TrackSortField.listOrder:
      return '—';
  }
}

/// "1 play", "12 plays".
String playCountLabel(int count) => count == 1 ? '1 play' : '$count plays';

/// Shared track list used by the Tracks/Favourites tabs, artist/folder
/// drill-downs, search results and playlist detail pages. Tapping a row
/// plays the whole (sorted) list starting from that track; the header row
/// offers a quick sort menu plus shuffle/play-all, Samsung Music style.
class TrackListView extends StatefulWidget {
  const TrackListView(
      {super.key, required this.tracks, this.onRemove, this.listOrder = false});

  final List<Track> tracks;

  /// [tracks] is a playlist in its own order: offers "Playlist order" in
  /// the sort menu. Elsewhere that choice falls back to "Added to device".
  final bool listOrder;

  /// When set, each row's "more options" menu gets a "Remove from
  /// playlist" entry — only passed by [MusicPlaylistDetailPage] for a
  /// hand-built playlist the track list can actually be edited on.
  final void Function(Track track)? onRemove;

  @override
  State<TrackListView> createState() => _TrackListViewState();
}

/// While songs are selected ([TrackSelection]: tap a row's music icon, or
/// long-press the row) [TrackSelectionBar] replaces the sort/play row.
class _TrackListViewState extends State<TrackListView>
    with TrackSelection<TrackListView> {
  @override
  void didUpdateWidget(TrackListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    keepSelectedIn(widget.tracks);
  }

  TrackSortField _sortField = TrackSortField.values.firstWhere(
    (f) => f.name == Config.musicTrackSortField,
    orElse: () => TrackSortField.deviceDate,
  );
  bool _ascending = Config.musicTrackSortAscending;

  /// Picking the field already in use flips its direction; picking a new
  /// one starts it in that field's natural direction. Remembered in
  /// [Config] so every track list (and the next launch) follows it.
  /// The order this list shows: [_sortField], except "Playlist order" on
  /// a list that isn't a playlist.
  TrackSortField get _shownField =>
      _sortField == TrackSortField.listOrder && !widget.listOrder
          ? TrackSortField.deviceDate
          : _sortField;

  void _selectSort(TrackSortField field) {
    setState(() {
      if (field == _shownField) {
        _sortField = field;
        _ascending = !_ascending;
      } else {
        _sortField = field;
        _ascending = trackSortDefaultAscending(field);
      }
    });
    _persistSort();
  }

  void _toggleDirection() {
    setState(() => _ascending = !_ascending);
    _persistSort();
  }

  void _persistSort() {
    Config.musicTrackSortField = _sortField.name;
    Config.musicTrackSortAscending = _ascending;
    unawaited(Config.save());
  }

  Future<void> _play(List<Track> tracks, {int startIndex = 0}) async {
    if (!await SpeakerPlayGuard.confirmPlay(context)) return;
    await MusicPlayerService.playQueue(tracks, startIndex: startIndex);
    if (context.mounted) {
      Navigator.of(context)
          .push(NowPlayingPage.route());
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = _shownField;
    final tracks = sortTracks(widget.tracks, field, ascending: _ascending);
    final onRemove = widget.onRemove;
    return selectionScope(
      child: Column(
      children: [
        if (selecting)
          selectionBar(tracks,
              onRemove: onRemove == null
                  ? null
                  : (selected) {
                      for (final t in selected) {
                        onRemove(t);
                      }
                    })
        else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Flexible(
                child: PopupMenuButton<TrackSortField>(
                  tooltip: 'Sort tracks',
                  initialValue: field,
                  onSelected: _selectSort,
                  itemBuilder: (context) => [
                    for (final option in TrackSortField.values.where((f) =>
                        f != TrackSortField.listOrder || widget.listOrder))
                      PopupMenuItem(
                        value: option,
                        child: Row(
                          children: [
                            if (option == field)
                              const Icon(Icons.check, size: 18)
                            else
                              const SizedBox(width: 18),
                            const SizedBox(width: 8),
                            Flexible(
                                child: Text(trackSortLabel(option),
                                    overflow: TextOverflow.ellipsis)),
                            if (option == field) ...[
                              const SizedBox(width: 8),
                              Icon(
                                  _ascending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 16),
                            ],
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(trackSortLabel(field),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('sortDirectionButton'),
                onPressed: _toggleDirection,
                icon: Icon(
                    _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18),
                label: Text(trackSortDirectionLabel(field, _ascending)),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.shuffle),
                tooltip: 'Shuffle these tracks',
                onPressed: () => _play(
                    MusicPlaylistService.instance.weightedShuffle(tracks)),
              ),
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Play all',
                onPressed: () => _play(tracks),
              ),
            ],
          ),
        ),
        Expanded(
          child: FastScrollList(
            itemCount: tracks.length,
            labelFor: (index) => trackSectionLabel(tracks[index], field),
            // Every row is one fixed two-line height (long titles ellipsize)
            // so the fast-scroll handle maps exactly onto a row.
            prototypeItem: const ListTile(
              leading: Icon(Icons.music_note),
              title: Text('Title', maxLines: 1),
              subtitle: Text('Artist', maxLines: 1),
              trailing: Icon(Icons.more_vert),
            ),
            itemBuilder: (context, index) {
              final track = tracks[index];
              return NowPlayingHighlight(
                trackId: track.id,
                builder: (context, isCurrent) =>
                    ValueListenableBuilder<List<MusicPlaylist>>(
                valueListenable: MusicPlaylistService.instance.playlists,
                builder: (context, _, __) {
                  final isFavorite =
                      MusicPlaylistService.instance.isFavorite(track.id);
                  return ListTile(
                    selected: isCurrent || isSelected(track),
                    leading: selectionLeading(context, track,
                        isCurrent ? nowPlayingIcon : trackSourceIcon(track)),
                    title: Text(_trackDisplayTitle(track),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    // Always two lines (matching the prototype row height).
                    // Sorted by times played: the count is shown too.
                    subtitle: Text(
                        [
                          track.displayArtist.isNotEmpty
                              ? track.displayArtist
                              : 'Unknown artist',
                          if (field == TrackSortField.playCount)
                            playCountLabel(track.playCount),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'More options',
                      onSelected: (value) async {
                        switch (value) {
                          case 'favorite':
                            await MusicPlaylistService.instance
                                .toggleFavorite(track.id);
                            break;
                          case 'add':
                            if (context.mounted) {
                              await showAddToPlaylistSheet(context, track);
                            }
                            break;
                          case 'remove':
                            widget.onRemove?.call(track);
                            break;
                          case 'info':
                            if (context.mounted) {
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    TrackMetadataPage(trackId: track.id),
                              ));
                            }
                            break;
                          case 'move':
                            if (context.mounted) {
                              await pickFolderAndMove(context, track);
                            }
                            break;
                          case 'trim':
                            if (context.mounted) {
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    TrimSongPage(trackId: track.id),
                              ));
                            }
                            break;
                          case 'delete':
                            if (context.mounted) {
                              await confirmAndDeleteTrack(context, track);
                            }
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'favorite',
                          child: Row(
                            children: [
                              Icon(
                                isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 18,
                                color: isFavorite ? Colors.pink : null,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  isFavorite
                                      ? 'Remove from Favorites'
                                      : 'Add to Favorites',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'add',
                          child: Row(children: [
                            Icon(Icons.playlist_add, size: 18),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text('Add to playlist',
                                    overflow: TextOverflow.ellipsis)),
                          ]),
                        ),
                        if (widget.onRemove != null)
                          const PopupMenuItem(
                            value: 'remove',
                            child: Row(children: [
                              Icon(Icons.remove_circle_outline, size: 18),
                              SizedBox(width: 8),
                              Flexible(
                                  child: Text('Remove from playlist',
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                        const PopupMenuItem(
                          value: 'info',
                          child: Row(children: [
                            Icon(Icons.info_outline, size: 18),
                            SizedBox(width: 8),
                            Flexible(
                                child: Text('Track info',
                                    overflow: TextOverflow.ellipsis)),
                          ]),
                        ),
                        if (TrackFileActions.canManage(track))
                          const PopupMenuItem(
                            value: 'move',
                            child: Row(children: [
                              Icon(Icons.drive_file_move_outline, size: 18),
                              SizedBox(width: 8),
                              Flexible(
                                  child: Text('Move to folder',
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                        if (TrackTrimmer.canTrim(track))
                          const PopupMenuItem(
                            value: 'trim',
                            child: Row(children: [
                              Icon(Icons.content_cut, size: 18),
                              SizedBox(width: 8),
                              Flexible(
                                  child: Text('Shorten song',
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                        if (TrackFileActions.canManage(track))
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(children: [
                              Icon(Icons.delete_outline, size: 18),
                              SizedBox(width: 8),
                              Flexible(
                                  child: Text('Delete',
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                      ],
                    ),
                    onTap: selectionTap(
                        track, () => _play(tracks, startIndex: index)),
                    onLongPress: () => toggleSelected(track),
                  );
                },
                ),
              );
            },
          ),
        ),
      ],
      ),
    );
  }
}

/// Prompts for a playlist name (Cancel/Create). The dialog owns its own
/// [TextEditingController] in a dedicated [StatefulWidget] rather than one
/// disposed right after `showDialog` returns — the exit animation still
/// builds the fields after the pop.
Future<String?> promptPlaylistName(BuildContext context,
    {String title = 'New playlist',
    String initial = '',
    String action = 'Create'}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        _PlaylistNameDialog(title: title, initial: initial, action: action),
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog(
      {required this.title, required this.initial, required this.action});

  final String title;
  final String initial;
  final String action;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Playlist name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

/// Bottom sheet listing every hand-built, non-system playlist with a
/// checkbox for whether [track] is already in it — tapping a row adds or
/// removes it immediately, Samsung Music's "Add to playlist" style. "New
/// playlist" at the top creates one (pre-filled with [track]) without
/// leaving the sheet flow.
Future<void> showAddToPlaylistSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ValueListenableBuilder<List<MusicPlaylist>>(
        valueListenable: MusicPlaylistService.instance.playlists,
        builder: (_, playlists, __) {
          final regular =
              playlists.where((p) => p.kind == PlaylistKind.list && !p.isSystem).toList();
          return ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: () async {
                  // Pop the sheet with its own context, then prompt on the
                  // caller's context (the track row's page) — that context
                  // stays mounted after the sheet closes; the sheet's own
                  // builder contexts do not.
                  Navigator.of(sheetContext).pop();
                  if (!context.mounted) return;
                  final name = await promptPlaylistName(context);
                  if (name == null || name.trim().isEmpty) return;
                  await MusicPlaylistService.instance
                      .createPlaylist(name.trim(), [track.id]);
                },
              ),
              if (regular.isNotEmpty) const Divider(height: 1),
              for (final playlist in regular)
                CheckboxListTile(
                  value: playlist.trackIds.contains(track.id),
                  title: Text(playlist.name),
                  onChanged: (checked) {
                    if (checked == true) {
                      MusicPlaylistService.instance.addTo(playlist.id, track.id);
                    } else {
                      MusicPlaylistService.instance.removeFrom(playlist.id, track.id);
                    }
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}
