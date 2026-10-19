import 'package:best_music/models/track.dart';
import 'package:best_music/services/music_widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MusicWidgetService.artSourceFor', () {
    test('a local song: its file, for the embedded picture', () {
      final track = Track.local(filePath: '/music/Song.mp3', title: 'Song');
      final art = MusicWidgetService.artSourceFor(track, null);
      expect(art.audioFile, '/music/Song.mp3');
      expect(art.imageUrl, isNull);
    });

    test('an http(s) or file art URI is the image', () {
      final art = MusicWidgetService.artSourceFor(
          null, Uri.parse('https://i.ytimg.com/vi/abc/hqdefault.jpg'));
      expect(art.audioFile, isNull);
      expect(art.imageUrl, 'https://i.ytimg.com/vi/abc/hqdefault.jpg');
      expect(
          MusicWidgetService.artSourceFor(null, Uri.parse('file:///a/b.jpg'))
              .imageUrl,
          'file:///a/b.jpg');
    });

    test('other schemes and nothing playing give no cover', () {
      final art = MusicWidgetService.artSourceFor(
          null, Uri.parse('content://media/1'));
      expect(art.audioFile, isNull);
      expect(art.imageUrl, isNull);
    });
  });
}
