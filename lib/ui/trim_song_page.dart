import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/track.dart';
import '../services/audio_trimmer.dart';
import '../services/music_library_service.dart';
import '../services/track_trimmer.dart';
import 'subpage_app_bar.dart';

/// "1:05.3".
String formatTrimTime(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  final tenth = (d.inMilliseconds % 1000) ~/ 100;
  return '$m:${s.toString().padLeft(2, '0')}.$tenth';
}

/// "Shorten song": pick a start and an end to the tenth of a second
/// (slider snapping to 0.1 s plus ±0.1 s steps, previews of both edges), then [TrackTrimmer.trim] cuts the file itself
/// — in place with Undo, or as a new song next to it.
class TrimSongPage extends StatefulWidget {
  const TrimSongPage({super.key, required this.trackId});

  final String trackId;

  @override
  State<TrimSongPage> createState() => _TrimSongPageState();
}

class _TrimSongPageState extends State<TrimSongPage> {
  Duration? _length;
  String? _error;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;
  bool _keepOriginal = false;
  bool _working = false;
  ja.AudioPlayer? _preview;

  /// What ± moves an edge by, and what the slider snaps to.
  static const _step = Duration(milliseconds: 100);

  /// The shortest song Shorten leaves.
  static const _minKeep = Duration(seconds: 1);
  static const _previewLength = Duration(seconds: 5);

  Track? get _track => MusicLibraryService.instance.byId(widget.trackId);

  @override
  void initState() {
    super.initState();
    _loadLength();
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _loadLength() async {
    final path = _track?.filePath;
    if (path == null) {
      setState(() => _error = 'Song not found');
      return;
    }
    try {
      final length = await AudioTrimmer.durationOf(path);
      if (!mounted) return;
      setState(() {
        _length = length;
        _end = length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setStart(Duration d) {
    final length = _length!;
    setState(() => _start = _clamp(d, Duration.zero, _end - _minKeep));
    assert(_start <= length);
  }

  void _setEnd(Duration d) =>
      setState(() => _end = _clamp(d, _start + _minKeep, _length!));

  static Duration _clamp(Duration d, Duration lo, Duration hi) =>
      d < lo ? lo : (d > hi ? hi : d);

  /// [ms] rounded to the nearest 0.1 s, within the song.
  Duration _snap(double ms) {
    final step = _step.inMilliseconds;
    final snapped = Duration(milliseconds: (ms / step).round() * step);
    return snapped > _length! ? _length! : snapped;
  }

  Future<void> _play(Duration from, Duration to) async {
    final path = _track?.filePath;
    if (path == null) return;
    try {
      final player = _preview ??= ja.AudioPlayer();
      await player.setAudioSource(
          ja.ClippingAudioSource(
            child: ja.AudioSource.uri(Uri.file(path)),
            start: from,
            end: to,
          ),
          preload: true);
      unawaited(player.play());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't play: $e")));
      }
    }
  }

  Future<void> _shorten() async {
    final track = _track;
    if (track == null) return;
    await _preview?.stop();
    setState(() => _working = true);
    try {
      final result = await TrackTrimmer.trim(track, _start, _end,
          keepOriginal: _keepOriginal);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(result);
      messenger.showSnackBar(SnackBar(
        content: Text(_keepOriginal
            ? 'Saved "${result.track.title}" (${formatTrimTime(result.newDuration)})'
            : 'Shortened to ${formatTrimTime(result.newDuration)}'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => TrackTrimmer.undo(result, track),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _working = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't shorten it: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final length = _length;
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: 'Shorten song'),
      body: _error != null
          ? Center(
              child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, textAlign: TextAlign.center),
            ))
          : length == null || track == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(track.displayTitle,
                        style: Theme.of(context).textTheme.titleMedium),
                    Text('Now ${formatTrimTime(length)} · keeps '
                        '${formatTrimTime(_end - _start)}'),
                    const SizedBox(height: 16),
                    RangeSlider(
                      values: RangeValues(_start.inMilliseconds.toDouble(),
                          _end.inMilliseconds.toDouble()),
                      max: length.inMilliseconds.toDouble(),
                      labels: RangeLabels(
                          formatTrimTime(_start), formatTrimTime(_end)),
                      onChanged: _working
                          ? null
                          : (v) => setState(() {
                                _start = _snap(v.start);
                                _end = _snap(v.end);
                                if (_end - _start < _minKeep) {
                                  _end = _start + _minKeep > length
                                      ? length
                                      : _start + _minKeep;
                                  _start = _end - _minKeep;
                                }
                              }),
                    ),
                    _edgeRow(
                      label: 'Start',
                      value: _start,
                      onMinus: () => _setStart(_start - _step),
                      onPlus: () => _setStart(_start + _step),
                      onPlay: () => _play(
                          _start,
                          _start + _previewLength > _end
                              ? _end
                              : _start + _previewLength),
                      playTooltip: 'Play from the start',
                    ),
                    _edgeRow(
                      label: 'End',
                      value: _end,
                      onMinus: () => _setEnd(_end - _step),
                      onPlus: () => _setEnd(_end + _step),
                      onPlay: () => _play(
                          _end - _previewLength < _start
                              ? _start
                              : _end - _previewLength,
                          _end),
                      playTooltip: 'Play the last seconds',
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _keepOriginal,
                      onChanged: _working
                          ? null
                          : (v) => setState(() => _keepOriginal = v),
                      title: const Text('Save as a new song'),
                      subtitle: const Text(
                          'Keeps the original and adds "(short)" next to it'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _working ? null : _shorten,
                      icon: _working
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.content_cut),
                      label: const Text('Shorten'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _keepOriginal
                          ? 'The song itself stays as it is.'
                          : 'This changes the file itself. Undo is offered '
                              'right after, and the original is kept for '
                              '${TrackTrimmer.backupDays} days in the app.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
    );
  }

  Widget _edgeRow({
    required String label,
    required Duration value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required VoidCallback onPlay,
    required String playTooltip,
  }) {
    return Row(
      children: [
        SizedBox(width: 48, child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove),
          tooltip: '$label 0.1 second earlier',
          onPressed: _working ? null : onMinus,
        ),
        Text(formatTrimTime(value), key: ValueKey('trim$label')),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: '$label 0.1 second later',
          onPressed: _working ? null : onPlus,
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.play_circle_outline),
          tooltip: playTooltip,
          onPressed: _working ? null : onPlay,
        ),
      ],
    );
  }
}
