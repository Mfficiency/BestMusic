import 'package:best_music/models/track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Track', () {
    test('local factory builds a stable path-prefixed id', () {
      final track = Track.local(
        filePath: '/storage/emulated/0/Music/Song.mp3',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        durationMs: 12345,
      );

      expect(track.id, 'local:/storage/emulated/0/Music/Song.mp3');
      expect(track.source, TrackSource.local);
      expect(track.remoteId, isNull);
    });

    test('subsonic factory builds a remoteId-prefixed id', () {
      final track = Track.subsonic(remoteId: 'abc123', title: 'Remote Song');

      expect(track.id, 'subsonic:abc123');
      expect(track.source, TrackSource.subsonic);
      expect(track.filePath, isNull);
    });

    test('fileBaseName strips directory and extension', () {
      final windowsStyle = Track.local(
        filePath: r'C:\Music\Sub\My Song.mp3',
        title: 'x',
      );
      final posixStyle = Track.local(
        filePath: '/music/sub/My Song.mp3',
        title: 'x',
      );

      expect(windowsStyle.fileBaseName, 'My Song');
      expect(posixStyle.fileBaseName, 'My Song');
    });

    test('toJson/fromJson round-trips every field', () {
      final track = Track.local(
        filePath: '/a/b.mp3',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        durationMs: 9000,
        genre: 'Rock',
        year: 2021,
        // Local, as fromJson restores it (fromMillisecondsSinceEpoch).
        dateAdded: DateTime(2024, 3, 1, 12),
        deviceDate: DateTime(2023, 5, 6, 7, 8),
        playCount: 4,
        metadataEdited: true,
        tags: ['Wedding songs', 'Belgian Top Charts'],
      ).copyWith(skipCount: 2, upSwipeCount: 3, downSwipeCount: 1);

      final restored = Track.fromJson(track.toJson());

      expect(restored.id, track.id);
      expect(restored.source, track.source);
      expect(restored.filePath, track.filePath);
      expect(restored.title, track.title);
      expect(restored.artist, track.artist);
      expect(restored.album, track.album);
      expect(restored.durationMs, track.durationMs);
      expect(restored.genre, 'Rock');
      expect(restored.year, 2021);
      expect(restored.dateAdded, track.dateAdded);
      expect(restored.deviceDate, track.deviceDate);
      expect(restored.playCount, 4);
      expect(restored.skipCount, 2);
      expect(restored.upSwipeCount, 3);
      expect(restored.downSwipeCount, 1);
      expect(restored.metadataEdited, isTrue);
      expect(restored.tags, ['Wedding songs', 'Belgian Top Charts']);
    });

    test('fromJson tolerates missing keys', () {
      final restored = Track.fromJson({'id': 'local:/x.mp3'});

      expect(restored.id, 'local:/x.mp3');
      expect(restored.source, TrackSource.local);
      expect(restored.title, '');
      expect(restored.artist, '');
      expect(restored.album, '');
      expect(restored.durationMs, isNull);
      expect(restored.genre, '');
      expect(restored.year, isNull);
      expect(restored.dateAdded, isNull);
      expect(restored.playCount, 0);
      expect(restored.metadataEdited, isFalse);
      expect(restored.tags, isEmpty);
    });

    test('copyWith replaces only the given fields', () {
      final track = Track.local(filePath: '/a.mp3', title: 'Original', genre: 'Pop');

      final updated = track.copyWith(
          playCount: 3, genre: 'Rock', metadataEdited: true, tags: ['Tag']);

      expect(updated.id, track.id);
      expect(updated.title, 'Original');
      expect(updated.genre, 'Rock');
      expect(updated.playCount, 3);
      expect(updated.metadataEdited, isTrue);
      expect(updated.tags, ['Tag']);
      // The original is untouched — Track is immutable.
      expect(track.playCount, 0);
      expect(track.genre, 'Pop');
      expect(track.metadataEdited, isFalse);
      expect(track.tags, isEmpty);
    });

    test('equality/hashCode is based on id alone', () {
      final a = Track.local(filePath: '/a.mp3', title: 'A');
      final b = Track.local(filePath: '/a.mp3', title: 'Different title');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('displayTitle / displayArtist', () {
    Track local(String file, {String title = '', String artist = ''}) =>
        Track.local(filePath: '/Music/$file', title: title, artist: artist);

    test('an "Artist - Song" file name shows the song, the artist below', () {
      final t = local('Kygo - Firestone.m4a', title: 'Kygo - Firestone');
      expect(t.displayTitle, 'Firestone');
      expect(t.displayArtist, 'Kygo');
      final noTitle = local('Angèle – Balance ton quoi.m4a');
      expect(noTitle.displayTitle, 'Balance ton quoi');
      expect(noTitle.displayArtist, 'Angèle');
    });

    test('the artist repeated in the title is dropped from the title', () {
      final t = local('x.mp3', title: 'Stromae - Santé', artist: 'Stromae');
      expect(t.displayTitle, 'Santé');
      expect(t.displayArtist, 'Stromae');
    });

    test('a title with a dash after a different artist is left alone', () {
      final t = local('x.mp3',
          title: 'Hey Jude - Remastered 2015', artist: 'The Beatles');
      expect(t.displayTitle, 'Hey Jude - Remastered 2015');
      expect(t.displayArtist, 'The Beatles');
      final plain = local('x.mp3', title: 'Firestone', artist: 'Kygo');
      expect((plain.displayTitle, plain.displayArtist), ('Firestone', 'Kygo'));
    });

    test('a video keeps its own title', () {
      final video = Track.youtube(videoId: 'v', title: 'Vlog - Day 1');
      expect(video.displayTitle, 'Vlog - Day 1');
      final song = Track.youtube(videoId: 's', title: 'Kygo - Stay', song: true);
      expect(song.displayTitle, 'Stay');
      expect(song.displayArtist, 'Kygo');
    });

    test('server songs too', () {
      final t = Track.subsonic(remoteId: '1', title: 'Dua Lipa - Levitating');
      expect((t.displayTitle, t.displayArtist), ('Levitating', 'Dua Lipa'));
    });
  });
}
