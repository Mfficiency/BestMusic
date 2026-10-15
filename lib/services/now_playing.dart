import 'package:flutter/foundation.dart';

/// The id of the track the player currently holds (playing or paused), or
/// null when nothing is loaded. Set by [MusicAudioHandler]; every song and
/// video list listens to it to highlight that row. A plain static so lists
/// work (and tests run) without an audio handler.
class NowPlaying {
  NowPlaying._();

  static final ValueNotifier<String?> trackId = ValueNotifier<String?>(null);
}
