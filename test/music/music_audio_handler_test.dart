import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_audio_handler.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/services/now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The handler builds a real just_audio player, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MusicLibraryService.instance.resetForTest();
    MusicPlaylistService.instance.resetForTest();
  });

  Track track(String id) =>
      Track.local(filePath: '/fake/$id.mp3', title: id);

  /// A queue of a, b, c with a current — set via [MusicAudioHandler.restore]
  /// so no audio is loaded (there's no just_audio platform in tests; loading
  /// would fail and hang the test).
  MusicAudioHandler handlerWithQueue() =>
      MusicAudioHandler()..restore([track('a'), track('b'), track('c')]);

  List<String> ids(MusicAudioHandler h) =>
      h.currentQueueTracks.map((t) => t.id).toList();

  test('reorderQueue moves a track to its new position', () {
    final handler = handlerWithQueue();

    // ReorderableListView convention (what QueuePage passes): dropping the
    // first row below the last one reports newIndex == length.
    handler.reorderQueue(0, 3);
    expect(ids(handler),
        ['local:/fake/b.mp3', 'local:/fake/c.mp3', 'local:/fake/a.mp3']);
    // The playing track keeps playing, now at its new position.
    expect(handler.currentTrack!.id, 'local:/fake/a.mp3');

    // Dropping the last row above the first: newIndex 0.
    handler.reorderQueue(2, 0);
    expect(ids(handler),
        ['local:/fake/a.mp3', 'local:/fake/b.mp3', 'local:/fake/c.mp3']);
    expect(handler.currentTrack!.id, 'local:/fake/a.mp3');
  });

  test('toggleShuffle flips shuffleEnabled and restores order on toggle off',
      () async {
    final handler = handlerWithQueue();
    final order = ids(handler);

    expect(handler.shuffleEnabled.value, isFalse);

    await handler.toggleShuffle();
    expect(handler.shuffleEnabled.value, isTrue);
    expect(ids(handler).toSet(), order.toSet());
    // Only the upcoming tail is shuffled; the playing track stays first.
    expect(ids(handler).first, order.first);

    await handler.toggleShuffle();
    expect(handler.shuffleEnabled.value, isFalse);
    expect(ids(handler), order);
  });

  test('the track the player holds is published to NowPlaying', () {
    NowPlaying.trackId.value = null;
    final handler = handlerWithQueue();
    expect(NowPlaying.trackId.value, 'local:/fake/a.mp3');
    expect(handler.currentTrack!.id, NowPlaying.trackId.value);
  });

  test('swipe up counts every swipe and puts the song in Liked songs, '
      'not Favorites', () async {
    await MusicPlaylistService.instance.load();
    final handler = handlerWithQueue();
    MusicLibraryService.instance.tracks.value = handler.currentQueueTracks;
    const id = 'local:/fake/a.mp3';

    await handler.swipeUpCurrent();
    await handler.swipeUpCurrent();

    expect(MusicPlaylistService.instance.isLiked(id), isTrue);
    expect(MusicPlaylistService.instance.liked.trackIds, [id]);
    expect(MusicPlaylistService.instance.isFavorite(id), isFalse);
    expect(MusicLibraryService.instance.byId(id)!.upSwipeCount, 2);
  });

  group('addToMusicQueue', () {
    test('play next goes right after the playing song, add to queue at '
        'the end', () async {
      final handler = handlerWithQueue(); // a (playing), b, c
      await handler.addToMusicQueue(track('x'), playNext: true);
      await handler.addToMusicQueue(track('y'));
      expect(ids(handler), [
        'local:/fake/a.mp3',
        'local:/fake/x.mp3',
        'local:/fake/b.mp3',
        'local:/fake/c.mp3',
        'local:/fake/y.mp3',
      ]);
      expect(handler.currentTrack!.id, 'local:/fake/a.mp3');
    });

    test('with nothing loaded the song becomes the paused queue', () async {
      final handler = MusicAudioHandler();
      await handler.addToMusicQueue(track('x'));
      expect(handler.currentTrack!.id, 'local:/fake/x.mp3');
    });

    test('while a video plays it goes to the music session to come back to',
        () async {
      final handler = MusicAudioHandler()
        ..restore([Track.youtube(videoId: 'v1', title: 'Talk')]);
      await handler.addToMusicQueue(track('x'));
      await handler.addToMusicQueue(track('y'), playNext: true);
      expect(handler.currentTrack!.remoteId, 'v1');
      final other = handler.otherSession.value!;
      expect(other.isVideo, isFalse);
      expect(other.queue.map((t) => t.id),
          ['local:/fake/x.mp3', 'local:/fake/y.mp3']);
    });
  });
}
