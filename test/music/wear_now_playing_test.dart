import 'dart:convert';

import 'package:best_music/services/wear_now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

WearNowPlayingState _state({
  bool hasTrack = true,
  String title = 'Song',
  String artist = 'Band',
  bool playing = true,
  int positionMs = 10000,
  int durationMs = 200000,
  int at = 1000,
}) =>
    WearNowPlayingState(
      hasTrack: hasTrack,
      title: title,
      artist: artist,
      playing: playing,
      positionMs: positionMs,
      durationMs: durationMs,
      at: at,
    );

void main() {
  tearDown(WearNowPlaying.resetForTest);

  test('the JSON the watch reads (wear/.../core/NowPlaying.kt)', () {
    expect(_state().toJson(), {
      'hasTrack': true,
      'title': 'Song',
      'artist': 'Band',
      'playing': true,
      'positionMs': 10000,
      'durationMs': 200000,
      'at': 1000,
    });
  });

  test('a new song, play/pause or length is sent', () {
    final s = _state();
    expect(WearNowPlaying.changed(null, s), isTrue);
    expect(WearNowPlaying.changed(s, _state(title: 'Other')), isTrue);
    expect(WearNowPlaying.changed(s, _state(artist: 'Other')), isTrue);
    expect(WearNowPlaying.changed(s, _state(playing: false)), isTrue);
    expect(WearNowPlaying.changed(s, _state(durationMs: 1)), isTrue);
    expect(WearNowPlaying.changed(s, _state(hasTrack: false)), isTrue);
  });

  test('playing on as the watch expects is not sent, a seek is', () {
    final s = _state();
    // 5 s later, 5 s further: what the watch counted itself.
    expect(WearNowPlaying.changed(s, _state(positionMs: 15000, at: 6000)),
        isFalse);
    // 5 s later but back at the start: a seek.
    expect(WearNowPlaying.changed(s, _state(positionMs: 0, at: 6000)), isTrue);
    // Paused: the position must stay put.
    final paused = _state(playing: false);
    expect(
        WearNowPlaying.changed(
            paused, _state(playing: false, positionMs: 11000, at: 60000)),
        isFalse);
    expect(
        WearNowPlaying.changed(
            paused, _state(playing: false, positionMs: 90000, at: 60000)),
        isTrue);
  });

  test('publish sends only changes, as JSON', () {
    final sent = <String>[];
    WearNowPlaying.publishOverride = sent.add;
    WearNowPlaying.publish(_state());
    WearNowPlaying.publish(_state(positionMs: 12000, at: 3000));
    WearNowPlaying.publish(_state(playing: false, positionMs: 12000, at: 3000));
    expect(sent, hasLength(2));
    expect(jsonDecode(sent.last), containsPair('playing', false));
  });

  test('publish without a native side does nothing and never throws', () {
    expect(() => WearNowPlaying.publish(_state()), returnsNormally);
  });
}
