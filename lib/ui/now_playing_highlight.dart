import 'package:flutter/material.dart';

import '../services/now_playing.dart';

/// Rebuilds [builder] whenever the playing track changes, telling it
/// whether [trackId] is the one playing. Inside, [ListTile]s get the
/// highlight colours for `selected: true`, so a list row only has to pass
/// `selected: isCurrent` (and may swap its icon for [nowPlayingIcon]).
class NowPlayingHighlight extends StatelessWidget {
  const NowPlayingHighlight({
    super.key,
    required this.trackId,
    required this.builder,
  });

  final String trackId;
  final Widget Function(BuildContext context, bool isCurrent) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: NowPlaying.trackId,
      builder: (context, playingId, _) {
        final scheme = Theme.of(context).colorScheme;
        return ListTileTheme.merge(
          selectedColor: scheme.onPrimaryContainer,
          selectedTileColor: scheme.primaryContainer,
          child: builder(context, playingId == trackId),
        );
      },
    );
  }
}

/// The leading icon a highlighted row shows instead of its usual one.
const Widget nowPlayingIcon =
    Icon(Icons.graphic_eq, semanticLabel: 'Now playing');
