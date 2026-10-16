import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/music_audio_handler.dart';
import '../services/music_player_service.dart';
import '../services/speaker_play_guard.dart';
import '../services/music_playlist_service.dart';
import 'estimated_progress_bar.dart';
import 'lyrics_view.dart';
import 'music_player_page.dart' show showAddToPlaylistSheet;
import 'music_mini_player_bar.dart'
    show SwitchSessionButton, switchSessionAndShow;
import 'playback_speed_sheet.dart';
import 'queue_page.dart';
import 'sleep_timer_sheet.dart';
import 'subpage_app_bar.dart';
import 'track_metadata_page.dart';

/// Full-screen "now playing" view. Swipe up on the artwork/title area to
/// favorite the current track, swipe down to mark it disliked and skip —
/// the "Tinder for songs" gesture pair the user asked for, on top of the
/// regular transport controls.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  /// How many Now Playing pages are open — [MusicMiniPlayerBar] hides while
  /// this is above zero, since the page already shows the same controls.
  static final ValueNotifier<int> openCount = ValueNotifier(0);

  /// Whether the ⓘ panel is open: the artwork and title shrink to a
  /// header at the top, the controls stay where they can be reached, and
  /// the bottom half shows the Lyrics / Info tabs ([_DetailsPanel]). Kept
  /// while the app runs, so the next Now Playing opens the same way.
  static final ValueNotifier<bool> showDetails = ValueNotifier(false);

  /// The panel's last tab (0 = Lyrics, 1 = Info).
  static int detailsTab = 0;

  /// Route name, so "Back to music" can find an open Now Playing page
  /// instead of stacking a second one ([showSessionScreen]).
  static const routeName = '/now-playing';

  static Route<void> route() => MaterialPageRoute(
      settings: const RouteSettings(name: routeName),
      builder: (_) => const NowPlayingPage());

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  double _dragOffset = 0;
  String? _flashLabel;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    // Deferred: listeners (the mini player) can't rebuild mid-build/dispose.
    Future.microtask(() => NowPlayingPage.openCount.value++);
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    Future.microtask(() => NowPlayingPage.openCount.value--);
    super.dispose();
  }

  void _flash(String label) {
    _flashTimer?.cancel();
    setState(() => _flashLabel = label);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flashLabel = null);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    const threshold = 250.0;
    if (velocity < -threshold || _dragOffset < -80) {
      MusicPlayerService.handler.swipeUpCurrent();
      _flash('Added to Liked songs');
    } else if (velocity > threshold || _dragOffset > 80) {
      MusicPlayerService.handler.dislikeCurrentAndSkip();
      _flash("Skipped, won't come up as much");
    }
    setState(() => _dragOffset = 0);
  }

  @override
  Widget build(BuildContext context) {
    final handler = MusicPlayerService.handler;
    return Scaffold(
      // Only the menu button up here: every control sits at the bottom,
      // within thumb reach (_ToolsRow, _Transport).
      appBar:
          buildSubpageAppBar(context, title: 'Now Playing', showBack: false),
      body: StreamBuilder<MediaItem?>(
        stream: handler.mediaItem,
        builder: (context, itemSnapshot) {
          final item = itemSnapshot.data;
          if (item == null) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                const Expanded(child: Center(child: Text('Nothing playing'))),
                _ToolsRow(handler: handler),
              ]),
            );
          }
          final track = handler.currentTrack;
          final isFavorite = track != null &&
              MusicPlaylistService.instance.isFavorite(track.id);
          final isLiked =
              track != null && MusicPlaylistService.instance.isLiked(track.id);
          return ValueListenableBuilder<bool>(
            valueListenable: NowPlayingPage.showDetails,
            builder: (context, details, _) {
              final controls = <Widget>[
                  // One tap back to the last song / last video.
                  ValueListenableBuilder<PlaybackSession?>(
                    valueListenable: handler.otherSession,
                    builder: (context, other, _) {
                      if (other == null) return const SizedBox.shrink();
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: ActionChip(
                          key: const ValueKey('nowPlayingSwitchSession'),
                          avatar: Icon(other.isVideo
                              ? Icons.smart_display_outlined
                              : Icons.library_music_outlined),
                          label: Text(SwitchSessionButton.labelFor(other),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onPressed: () => switchSessionAndShow(
                              handler, Navigator.of(context)),
                        ),
                      );
                    },
                  ),
                _ProgressBar(handler: handler),
                const SizedBox(height: 8),
                _Transport(handler: handler, isFavorite: isFavorite),
                _ToolsRow(handler: handler),
              ];
              final loading = StreamBuilder<PlaybackState>(
                stream: handler.playbackState,
                initialData: handler.playbackState.valueOrNull,
                builder: (context, snapshot) {
                  final state = snapshot.data?.processingState;
                  return EstimatedProgressBar(
                    active: state == AudioProcessingState.loading ||
                        state == AudioProcessingState.buffering,
                    expected: const Duration(seconds: 5),
                  );
                },
              );
              if (details) {
                // Header, controls, then the scrollable tabs: the controls
                // never scroll away. Swipes only on the header, so the
                // tabs can scroll.
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      loading,
                      GestureDetector(
                        onVerticalDragUpdate: (d) =>
                            setState(() => _dragOffset += d.delta.dy),
                        onVerticalDragEnd: _onVerticalDragEnd,
                        child: _CompactHeader(
                          item: item,
                          isFavorite: isFavorite,
                          isLiked: isLiked,
                          flash: _flashLabel,
                        ),
                      ),
                      ...controls,
                      const Divider(height: 1),
                      Expanded(
                        child: track == null
                            ? const SizedBox.shrink()
                            : _DetailsPanel(track: track),
                      ),
                    ],
                  ),
                );
              }
              return GestureDetector(
                onVerticalDragUpdate: (d) =>
                    setState(() => _dragOffset += d.delta.dy),
                onVerticalDragEnd: _onVerticalDragEnd,
                child: Container(
                  color: Colors.transparent,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      loading,
                      Expanded(
                        child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          transform: Matrix4.translationValues(
                              0, _dragOffset.clamp(-120, 120), 0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (item.artUri != null)
                                // A Subscriptions-feed video's thumbnail.
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxHeight: 220),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.network(
                                      item.artUri.toString(),
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => Icon(
                                        Icons.music_note,
                                        size: 120,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Icon(
                                  Icons.music_note,
                                  size: 120,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.5),
                                ),
                              const SizedBox(height: 24),
                              Text(
                                item.title,
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                                textAlign: TextAlign.center,
                              ),
                              if ((item.artist ?? '').isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    item.artist!,
                                    style:
                                        Theme.of(context).textTheme.bodyLarge,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              if (isFavorite || isLiked)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isFavorite)
                                        const Icon(Icons.favorite,
                                            color: Colors.pink,
                                            semanticLabel: 'In Favorites'),
                                      if (isFavorite && isLiked)
                                        const SizedBox(width: 8),
                                      if (isLiked)
                                        Icon(Icons.thumb_up,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            semanticLabel: 'In Liked songs'),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (_flashLabel != null)
                          Positioned(
                            top: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(_flashLabel!),
                            ),
                          ),
                      ],
                    ),
                      ),
                      const Text(
                        'Swipe up to like • swipe down to skip & dislike',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      ...controls,
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// The ⓘ panel's top: a small artwork, the title and artist (and the
/// favourite/liked marks), where the big artwork was. Still takes the
/// swipe up/down (its confirmation shows in place of the title).
class _CompactHeader extends StatelessWidget {
  const _CompactHeader({
    required this.item,
    required this.isFavorite,
    required this.isLiked,
    required this.flash,
  });

  final MediaItem item;
  final bool isFavorite;
  final bool isLiked;
  final String? flash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noteIcon = Icon(Icons.music_note,
        size: 40, color: theme.colorScheme.primary.withValues(alpha: 0.5));
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: item.artUri != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(item.artUri.toString(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => noteIcon),
                  )
                : noteIcon,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(flash ?? item.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (flash == null && (item.artist ?? '').isNotEmpty)
                  Text(item.artist!,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (isFavorite)
            const Icon(Icons.favorite,
                color: Colors.pink, semanticLabel: 'In Favorites'),
          if (isLiked)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.thumb_up,
                  color: theme.colorScheme.primary,
                  semanticLabel: 'In Liked songs'),
            ),
        ],
      ),
    );
  }
}

/// The ⓘ panel's tabs, filling the bottom half: Lyrics ([LyricsView]) and
/// Info ([TrackInfoView]), each scrolling on its own. Remembers the last
/// tab ([NowPlayingPage.detailsTab]).
class _DetailsPanel extends StatefulWidget {
  const _DetailsPanel({required this.track});

  final Track track;

  @override
  State<_DetailsPanel> createState() => _DetailsPanelState();
}

class _DetailsPanelState extends State<_DetailsPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
      length: 2, vsync: this, initialIndex: NowPlayingPage.detailsTab)
    ..addListener(() => NowPlayingPage.detailsTab = _tabs.index);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
            controller: _tabs,
            tabs: const [Tab(text: 'Lyrics'), Tab(text: 'Info')]),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              const LyricsView(),
              TrackInfoView(trackId: widget.track.id, fallback: widget.track),
            ],
          ),
        ),
      ],
    );
  }
}

/// The rest of the controls, under the transport: speed (videos), sleep
/// timer, shuffle, repeat, queue, add to playlist (songs) and ⓘ (the
/// Lyrics / Info panel). On a phone too narrow for all of them at full size the
/// row shrinks to fit rather than overflow.
class _ToolsRow extends StatelessWidget {
  const _ToolsRow({required this.handler});

  final MusicAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final track = handler.currentTrack;
    final video = track?.isFeedVideo ?? false;
    final buttons = <Widget>[
      // Feed videos only: speed is a podcast/talk thing, not a
      // local-music one.
      PlaybackSpeedButton(visible: video),
      // (No volume button: the phone's volume keys do that; the music and
      // video volumes are set in Settings.)
      const SleepTimerButton(),
      ValueListenableBuilder<bool>(
        valueListenable: handler.shuffleEnabled,
        builder: (context, shuffleOn, _) => IconButton(
          icon: const Icon(Icons.shuffle),
          tooltip: shuffleOn ? 'Shuffle on' : 'Shuffle off',
          color: shuffleOn ? Theme.of(context).colorScheme.primary : null,
          onPressed: () => handler.toggleShuffle(),
        ),
      ),
      ValueListenableBuilder<MusicRepeatMode>(
        valueListenable: handler.repeatMode,
        builder: (context, mode, _) => IconButton(
          icon: Icon(
              mode == MusicRepeatMode.one ? Icons.repeat_one : Icons.repeat),
          tooltip: switch (mode) {
            MusicRepeatMode.off => 'Repeat off',
            MusicRepeatMode.all => 'Repeat all',
            MusicRepeatMode.one => 'Repeat one',
          },
          color: mode == MusicRepeatMode.off
              ? null
              : Theme.of(context).colorScheme.primary,
          onPressed: () => handler.cycleRepeat(),
        ),
      ),
      IconButton(
        icon: const Icon(Icons.queue_music),
        tooltip: 'Queue',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const QueuePage()),
        ),
      ),
      // Songs only: Subscriptions videos aren't library tracks.
      if (track != null && !video)
        IconButton(
          icon: const Icon(Icons.playlist_add),
          tooltip: 'Add to playlist',
          onPressed: () => showAddToPlaylistSheet(context, track),
        ),
      // Opens/closes the Lyrics / Info panel under the controls.
      ValueListenableBuilder<bool>(
        valueListenable: NowPlayingPage.showDetails,
        builder: (context, open, _) => IconButton(
          icon: Icon(open ? Icons.info : Icons.info_outline),
          tooltip: open ? 'Hide track info' : 'Track info',
          color: open ? Theme.of(context).colorScheme.primary : null,
          onPressed: track == null
              ? null
              : () => NowPlayingPage.showDetails.value = !open,
        ),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      // Every button is 48 wide; the speed button takes none for songs.
      final needed = 48.0 * (buttons.length - (video ? 0 : 1));
      final width = constraints.maxWidth;
      final row = Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: buttons,
      );
      if (!width.isFinite || width >= needed) return row;
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(width: needed, child: row),
      );
    });
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.handler});

  final MusicAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final position = state?.position ?? Duration.zero;
        final item = handler.mediaItem.valueOrNull;
        final duration = item?.duration ?? Duration.zero;
        final known = duration.inMilliseconds > 0;
        final max = known ? duration.inMilliseconds.toDouble() : 1.0;
        // Until the length is known the bar stays empty rather than full.
        final value = known
            ? position.inMilliseconds.clamp(0, max.round()).toDouble()
            : 0.0;
        final timeStyle = Theme.of(context).textTheme.bodySmall;
        // One line: elapsed time, the bar, total time.
        return Row(
          children: [
            Text(_format(position), style: timeStyle),
            Expanded(
              child: Slider(
                value: value,
                max: max,
                onChanged: known
                    ? (v) => handler.seek(Duration(milliseconds: v.round()))
                    : null,
              ),
            ),
            Text(known ? _format(duration) : '--:--', style: timeStyle),
          ],
        );
      },
    );
  }

  static String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.handler, required this.isFavorite});

  final MusicAudioHandler handler;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final playing = snapshot.data?.playing ?? false;
        // A feed video swaps Favorite/"Don't really like" (library-song
        // things) for back/forward 10 seconds.
        final video = handler.currentTrack?.isFeedVideo ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (video)
              IconButton(
                icon: const Icon(Icons.replay_10),
                tooltip: 'Back 10 seconds',
                iconSize: 32,
                onPressed: () => handler.rewind(),
              )
            else
              IconButton(
                icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
                tooltip: 'Favorite',
                color: isFavorite ? Colors.pink : null,
                onPressed: () => handler.favoriteCurrent(),
              ),
            IconButton(
              icon: const Icon(Icons.skip_previous),
              tooltip: 'Previous',
              iconSize: 36,
              onPressed: () => handler.skipToPrevious(),
            ),
            IconButton(
              icon: Icon(playing
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled),
              tooltip: playing ? 'Pause' : 'Play',
              iconSize: 56,
              onPressed: () async {
                if (playing) {
                  await handler.pause();
                } else if (await SpeakerPlayGuard.confirmPlay(context)) {
                  await handler.play();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              tooltip: 'Next',
              iconSize: 36,
              onPressed: () => handler.skipToNext(),
            ),
            if (video)
              IconButton(
                icon: const Icon(Icons.forward_10),
                tooltip: 'Forward 10 seconds',
                iconSize: 32,
                onPressed: () => handler.fastForward(),
              )
            else
              IconButton(
                icon: const Icon(Icons.thumb_down_alt_outlined),
                tooltip: "Don't really like",
                onPressed: () => handler.dislikeCurrentAndSkip(),
              ),
          ],
        );
      },
    );
  }
}
