import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:mfficiency_updates/mfficiency_updates.dart'
    show RemainingTime, formatHms;

import '../services/music_metadata_enricher.dart';

/// A small "00:01:23 remaining" line to put below a progress bar or a
/// progress text. Rough on purpose: it only gives an indication.
///
/// Shows nothing unless the whole job looks longer than 30 s (time so far
/// plus time left; [RemainingTime.longerThan]), nothing for the first 3 s
/// while the estimate settles, and nothing when there is nothing to go on.
/// With [done] (0..1) the time left is extrapolated from the time so far;
/// without it, [typical] (how long the same work usually takes) counts
/// down. It disappears instead of showing 00:00:00 when the work runs over.
///
/// [startedAt] is when the work began, for work that outlives this widget
/// (a download started on another page, a feed refresh that was running
/// before the page opened); without it the clock starts when [active]
/// turns true. The line refreshes once a second while [active].
class RemainingTimeText extends StatefulWidget {
  const RemainingTimeText({
    super.key,
    this.active = true,
    this.done,
    this.typical,
    this.startedAt,
    this.clock,
    this.style,
    this.textAlign,
    this.padding = const EdgeInsets.only(top: 2),
  });

  final bool active;

  /// How far the work is, 0..1, when it can tell.
  final double? done;

  /// How long the work usually takes, when [done] is unknown.
  final Duration? typical;

  final DateTime? startedAt;

  /// For tests.
  final DateTime Function()? clock;

  /// Defaults to the theme's `bodySmall`.
  final TextStyle? style;
  final TextAlign? textAlign;
  final EdgeInsetsGeometry padding;

  @override
  State<RemainingTimeText> createState() => _RemainingTimeTextState();
}

class _RemainingTimeTextState extends State<RemainingTimeText> {
  RemainingTime? _eta;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.active) _begin();
  }

  @override
  void didUpdateWidget(RemainingTimeText old) {
    super.didUpdateWidget(old);
    if (!widget.active) {
      _end();
    } else if (!old.active || widget.startedAt != old.startedAt) {
      _begin();
    }
  }

  @override
  void dispose() {
    _end();
    super.dispose();
  }

  void _begin() {
    final now = widget.clock ?? DateTime.now;
    final started = widget.startedAt;
    // RemainingTime.start() reads the clock once: hand it [startedAt] for
    // that first read, the real time afterwards.
    var first = started != null;
    _eta = RemainingTime(clock: () {
      if (first) {
        first = false;
        return started!;
      }
      return now();
    })
      ..start();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _end() {
    _tick?.cancel();
    _tick = null;
    _eta = null;
  }

  @override
  Widget build(BuildContext context) {
    final done = widget.done;
    final left = widget.active
        ? _eta?.estimate(done == null ? null : done.clamp(0.0, 1.0),
            typical: widget.typical)
        : null;
    if (left == null || left <= Duration.zero) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: Text(
        '${formatHms(left)} remaining',
        key: const ValueKey('remainingTime'),
        textAlign: widget.textAlign,
        style: widget.style ?? Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// The [RemainingTimeText] for the background song-info lookup / BPM
/// detection ([MusicMetadataEnricher.progress]), below its status line.
class EnrichmentRemainingText extends StatelessWidget {
  const EnrichmentRemainingText({super.key, this.textAlign, this.enricher});

  final TextAlign? textAlign;

  /// Defaults to [MusicMetadataEnricher.instance]; for tests.
  final MusicMetadataEnricher? enricher;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EnrichmentProgress?>(
      valueListenable: (enricher ?? MusicMetadataEnricher.instance).progress,
      builder: (context, p, _) => RemainingTimeText(
        active: p != null,
        done: p?.done,
        startedAt: p?.startedAt,
        textAlign: textAlign,
      ),
    );
  }
}
