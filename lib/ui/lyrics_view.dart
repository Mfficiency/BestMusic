import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../models/lyrics.dart';
import '../services/lyrics_service.dart';
import '../services/music_audio_handler.dart';
import '../services/music_player_service.dart';

/// Now Playing's Lyrics tab (tap ⓘ): the playing song's words, following
/// the song. Synced lyrics light up line by line (the current line fills
/// in as it's sung) and scroll along; tapping a line jumps the song there.
/// Scrolling by hand pauses the following for a few seconds. Plain lyrics
/// are just shown. Moves on with the song when the next one starts.
/// Lyrics come from [LyricsService].
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, this.service, this.handler});

  /// Defaults to [LyricsService.instance] / [MusicPlayerService.handler];
  /// tests pass their own.
  final LyricsService? service;
  final MusicAudioHandler? handler;

  /// How long a hand scroll stops the page from following the song.
  static const Duration manualScrollPause = Duration(seconds: 4);

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  late final MusicAudioHandler _handler =
      widget.handler ?? MusicPlayerService.handler;
  late final LyricsService _service = widget.service ?? LyricsService.instance;

  StreamSubscription<MediaItem?>? _itemSub;
  Timer? _ticker;
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ScrollController _scroll = ScrollController();

  String? _trackId;
  LyricsLookup? _lookup;
  bool _loading = false;
  int _load = 0;
  int _current = -1;
  List<GlobalKey> _lineKeys = const [];
  DateTime? _manualUntil;

  @override
  void initState() {
    super.initState();
    _itemSub = _handler.mediaItem.listen((_) => _onTrack());
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    _onTrack();
  }

  @override
  void dispose() {
    _itemSub?.cancel();
    _ticker?.cancel();
    _position.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTrack() {
    final id = _handler.currentTrack?.id;
    if (id == _trackId) return;
    _trackId = id;
    _fetch();
  }

  Future<void> _fetch({bool refresh = false}) async {
    final track = _handler.currentTrack;
    final load = ++_load;
    setState(() {
      _lookup = null;
      _current = -1;
      _lineKeys = const [];
      _loading = track != null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (track == null) return;
    final lookup = await _service.lyricsFor(track,
        duration: _handler.mediaItem.valueOrNull?.duration, refresh: refresh);
    // A newer song (or "Search again") started meanwhile.
    if (!mounted || load != _load) return;
    setState(() {
      _lookup = lookup;
      _loading = false;
      final lines = lookup.lyrics?.lines ?? const <LyricLine>[];
      _lineKeys = [for (var i = 0; i < lines.length; i++) GlobalKey()];
    });
    _tick();
  }

  void _tick() {
    final lyrics = _lookup?.lyrics;
    if (lyrics == null || !lyrics.isSynced) return;
    final position =
        _handler.playbackState.valueOrNull?.position ?? Duration.zero;
    _position.value = position;
    final index = lyrics.indexAt(position);
    if (index != _current) {
      setState(() => _current = index);
      _follow();
    }
  }

  /// Scrolls the current line to a bit above the middle, unless the user
  /// is scrolling around themselves.
  void _follow({bool force = false}) {
    final until = _manualUntil;
    if (!force && until != null && DateTime.now().isBefore(until)) return;
    final index = _current < 0 ? 0 : _current;
    if (index >= _lineKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _lineKeys[index].currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(context,
          alignment: 0.4,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut);
    });
  }

  Future<void> _seekTo(LyricLine line) async {
    _manualUntil = null;
    await _handler.seek(line.time);
    _tick();
    _follow(force: true);
  }

  @override
  Widget build(BuildContext context) => _body(context);

  /// Under the lyrics: where they came from, and "Search lyrics again"
  /// (skips the saved copy — for wrong or missing lyrics).
  Widget _footer(BuildContext context, Lyrics lyrics) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(children: [
          Expanded(
            child: Text(
                lyrics.source.isEmpty ? '' : 'Lyrics from ${lyrics.source}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Search lyrics again',
            onPressed: () => _fetch(refresh: true),
          ),
        ]),
      );

  Widget _body(BuildContext context) {
    if (_handler.currentTrack == null) {
      return const _Message(icon: Icons.music_off, text: 'Nothing playing');
    }
    final lookup = _lookup;
    if (_loading || lookup == null) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Looking for lyrics…'),
        ]),
      );
    }
    switch (lookup.status) {
      case LyricsStatus.notASong:
        return const _Message(
          icon: Icons.smart_display_outlined,
          text: "Videos don't have lyrics. A video's transcript is in its "
              'menu in Subscriptions.',
        );
      case LyricsStatus.instrumental:
        return const _Message(
          icon: Icons.piano_outlined,
          text: 'Instrumental: no words to this one.',
        );
      case LyricsStatus.notFound:
        return _Message(
          icon: Icons.lyrics_outlined,
          text: 'No lyrics found for this song.',
          action: 'Search again',
          onAction: () => _fetch(refresh: true),
        );
      case LyricsStatus.unavailable:
        return _Message(
          icon: Icons.cloud_off_outlined,
          text: "Couldn't reach the lyrics service (LRCLIB). Check the "
              'connection and try again.'
              '${lookup.reason == null ? '' : '\n\n(${lookup.reason})'}',
          action: 'Try again',
          onAction: () => _fetch(refresh: true),
        );
      case LyricsStatus.found:
        final lyrics = lookup.lyrics!;
        return lyrics.isSynced ? _synced(context, lyrics) : _plain(context, lyrics);
    }
  }

  Widget _synced(BuildContext context, Lyrics lyrics) {
    final theme = Theme.of(context);
    final base = theme.textTheme.headlineSmall!
        .copyWith(fontWeight: FontWeight.w700, height: 1.3);
    final bright = theme.colorScheme.onSurface;
    final dim = bright.withValues(alpha: 0.35);
    final screen = MediaQuery.sizeOf(context).height;
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _manualUntil = DateTime.now().add(LyricsView.manualScrollPause);
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(24, 16, 24, screen * 0.2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lyrics.lines.length; i++)
              InkWell(
                key: _lineKeys[i],
                borderRadius: BorderRadius.circular(8),
                onTap: () => _seekTo(lyrics.lines[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: i == _current
                      ? ValueListenableBuilder<Duration>(
                          valueListenable: _position,
                          builder: (context, position, _) => _SungLine(
                            text: _shown(lyrics.lines[i].text),
                            progress: lyrics.progressAt(i, position),
                            style: base,
                            sung: theme.colorScheme.primary,
                            toSing: bright.withValues(alpha: 0.6),
                          ),
                        )
                      : Text(
                          _shown(lyrics.lines[i].text),
                          style: base.copyWith(color: dim),
                        ),
                ),
              ),
            _footer(context, lyrics),
          ],
        ),
      ),
    );
  }

  /// An empty LRC line marks an instrumental break.
  static String _shown(String text) => text.isEmpty ? '♪' : text;

  Widget _plain(BuildContext context, Lyrics lyrics) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "These lyrics aren't timed to the song, so they don't scroll "
            'along.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SelectableText(
            lyrics.plain,
            style: theme.textTheme.titleLarge!.copyWith(height: 1.5),
          ),
          _footer(context, lyrics),
        ],
      ),
    );
  }
}

/// The line being sung: the part already sung in [sung], the rest in
/// [toSing], so it fills in as it goes (character by character, which
/// wraps naturally when the line takes two rows).
class _SungLine extends StatelessWidget {
  const _SungLine({
    required this.text,
    required this.progress,
    required this.style,
    required this.sung,
    required this.toSing,
  });

  final String text;
  final double progress;
  final TextStyle style;
  final Color sung;
  final Color toSing;

  @override
  Widget build(BuildContext context) {
    final chars = text.characters;
    final done = (chars.length * progress).round();
    return Text.rich(
      TextSpan(style: style, children: [
        TextSpan(text: chars.take(done).string, style: TextStyle(color: sung)),
        TextSpan(text: chars.skip(done).string, style: TextStyle(color: toSing)),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(action!)),
          ],
        ]),
      ),
    );
  }
}
