import 'dart:async' show unawaited;
import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

/// What the phone plays, as the Wear OS watch app reads it (wear/ in this
/// repo; field names in its core/NowPlaying.kt).
class WearNowPlayingState {
  const WearNowPlayingState({
    required this.hasTrack,
    required this.title,
    required this.artist,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.at,
  });

  final bool hasTrack;
  final String title;
  final String artist;
  final bool playing;
  final int positionMs;
  final int durationMs;

  /// Milliseconds since the epoch when [positionMs] was read.
  final int at;

  Map<String, Object> toJson() => {
        'hasTrack': hasTrack,
        'title': title,
        'artist': artist,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'at': at,
      };

  /// Where the watch thinks the song is at [now] (it counts on while
  /// playing).
  int expectedPositionAt(int now) {
    final moved = playing && now > at ? now - at : 0;
    return positionMs + moved;
  }
}

/// Publishes the now-playing state to the Wear OS watch app through the
/// native side (channel `besttodo/audio_output`, method
/// `publishWearNowPlaying` -> `WearSync.kt`, a Wearable DataItem). Called by
/// [MusicWidgetService] with every playback change, next to the home-screen
/// widgets. Only sends when something the watch shows changed: song,
/// playing/paused, length, or a jump (seek) the watch can't count on to.
/// Never awaited, never throws; does nothing off Android.
class WearNowPlaying {
  WearNowPlaying._();

  static const MethodChannel _channel = MethodChannel('besttodo/audio_output');

  /// A jump bigger than this (a seek) is sent; smaller drift isn't.
  static const int jumpMs = 3000;

  static WearNowPlayingState? _last;

  /// Tests stand in for the native side here.
  @visibleForTesting
  static void Function(String json)? publishOverride;

  @visibleForTesting
  static void resetForTest() {
    _last = null;
    publishOverride = null;
  }

  /// Whether [next] differs from [previous] in anything the watch shows.
  static bool changed(WearNowPlayingState? previous, WearNowPlayingState next) {
    if (previous == null) return true;
    if (previous.hasTrack != next.hasTrack ||
        previous.title != next.title ||
        previous.artist != next.artist ||
        previous.playing != next.playing ||
        previous.durationMs != next.durationMs) {
      return true;
    }
    final drift = next.positionMs - previous.expectedPositionAt(next.at);
    return drift.abs() > jumpMs;
  }

  static void publish(WearNowPlayingState state) {
    try {
      if (!changed(_last, state)) return;
      _last = state;
      final json = jsonEncode(state.toJson());
      final override = publishOverride;
      if (override != null) {
        override(json);
        return;
      }
      if (kIsWeb || !Platform.isAndroid) return;
      unawaited(_channel
          .invokeMethod<void>('publishWearNowPlaying', {'json': json})
          .catchError((Object _) {}));
    } catch (_) {
      // No watch support (tests, older native side): nothing to do.
    }
  }
}
