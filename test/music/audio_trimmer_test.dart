import 'dart:io';
import 'dart:typed_data';

import 'package:best_music/models/track.dart';
import 'package:best_music/services/audio_trimmer.dart';
import 'package:best_music/services/media_scanner_service.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/track_trimmer.dart';
import 'package:best_music/ui/trim_song_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// Shortening songs by cutting the file itself (SPEC.md "Shorten song").
/// The fixtures are 5 s tones made with ffmpeg (2 s for the WAV); the
/// results were also checked with ffprobe/ffmpeg when this was written.
void main() {
  const fixtures = 'test/fixtures/audio';
  Uint8List read(String name) => File('$fixtures/$name').readAsBytesSync();
  int ms(Duration d) => d.inMilliseconds;

  group('AudioTrimmer', () {
    test('reads each format\'s length', () {
      expect(ms(AudioTrimmer.durationOfBytes(read('cbr.mp3'), 'mp3')),
          closeTo(5067, 30));
      expect(ms(AudioTrimmer.durationOfBytes(read('vbr.mp3'), 'mp3')),
          closeTo(5067, 30));
      expect(ms(AudioTrimmer.durationOfBytes(read('tone.m4a'), 'm4a')),
          closeTo(5046, 30));
      expect(ms(AudioTrimmer.durationOfBytes(read('tone.wav'), 'wav')), 2000);
    });

    for (final (name, ext) in [
      ('cbr.mp3', 'mp3'),
      ('vbr.mp3', 'mp3'),
      ('tone.m4a', 'm4a'),
    ]) {
      test('$name: keeps 1.0-3.5 s, and the result reads back', () {
        final out = AudioTrimmer.trimBytes(read(name), ext,
            const Duration(milliseconds: 1000),
            const Duration(milliseconds: 3500));
        expect(ms(AudioTrimmer.durationOfBytes(out, ext)), closeTo(2500, 60));
        expect(out.length, lessThan(read(name).length));
        // Trimming the result again works too (the output is well-formed).
        final again = AudioTrimmer.trimBytes(out, ext, Duration.zero,
            const Duration(milliseconds: 1000));
        expect(ms(AudioTrimmer.durationOfBytes(again, ext)), closeTo(1000, 60));
      });
    }

    test('mp3 keeps its ID3 tag; m4a keeps its metadata', () {
      final mp3 = AudioTrimmer.trimBytes(read('cbr.mp3'), 'mp3',
          const Duration(seconds: 1), const Duration(seconds: 2));
      expect(String.fromCharCodes(mp3.sublist(0, 3)), 'ID3');
      expect(String.fromCharCodes(mp3), contains('Tone CBR'));
      final m4a = AudioTrimmer.trimBytes(read('tone.m4a'), 'm4a',
          const Duration(seconds: 1), const Duration(seconds: 2));
      expect(String.fromCharCodes(m4a), contains('Tone AAC'));
    });

    test('the VBR header gets the new frame count', () {
      final out = AudioTrimmer.trimBytes(read('vbr.mp3'), 'mp3',
          const Duration(seconds: 1), const Duration(seconds: 2));
      final text = String.fromCharCodes(out);
      final at = text.indexOf('Xing') >= 0 ? text.indexOf('Xing') : text.indexOf('Info');
      expect(at, greaterThan(0));
      final frames = (out[at + 8] << 24) | (out[at + 9] << 16) |
          (out[at + 10] << 8) | out[at + 11];
      // 22.05 kHz MPEG-2 layer III: 576 samples a frame, ~26 ms.
      expect(frames * 576 / 22050, closeTo(1.0, 0.06));
    });

    test('wav is cut on whole samples', () {
      final out = AudioTrimmer.trimBytes(read('tone.wav'), 'wav',
          const Duration(milliseconds: 500), const Duration(milliseconds: 1500));
      expect(ms(AudioTrimmer.durationOfBytes(out, 'wav')), 1000);
    });

    test('bad ranges and other formats are refused', () {
      expect(
          () => AudioTrimmer.trimBytes(read('cbr.mp3'), 'mp3',
              const Duration(seconds: 3), const Duration(seconds: 2)),
          throwsA(isA<AudioTrimException>()));
      expect(
          () => AudioTrimmer.trimBytes(Uint8List(10), 'webm', Duration.zero,
              const Duration(seconds: 1)),
          throwsA(isA<AudioTrimException>()
              .having((e) => e.message, 'message', contains('.webm'))));
      expect(AudioTrimmer.supports('/a/b.M4A'), isTrue);
      expect(AudioTrimmer.supports('/a/b.flac'), isFalse);
    });
  });

  group('TrackTrimmer', () {
    late Directory dir;
    final scanned = <String>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trim');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      MusicLibraryService.instance.resetForTest();
      MediaScannerService.scanOverride = (path) async => scanned.add(path);
      TrackTrimmer.backupDirOverride =
          () async => Directory('${dir.path}/backups');
    });

    tearDown(() async {
      MediaScannerService.scanOverride = null;
      TrackTrimmer.backupDirOverride = null;
      await dir.delete(recursive: true);
    });

    Future<Track> songIn(String name) async {
      final path = '${dir.path}/$name';
      await File('$fixtures/$name').copy(path);
      final track = Track.local(filePath: path, title: 'Tone', durationMs: 5000)
          .copyWith(playCount: 4);
      MusicLibraryService.instance.tracks.value = [track];
      return track;
    }

    test('in place: the file is shortened, the original kept for Undo',
        () async {
      final track = await songIn('cbr.mp3');
      final before = await File(track.filePath!).length();

      final result = await TrackTrimmer.trim(track,
          const Duration(seconds: 1), const Duration(seconds: 3));

      expect(ms(result.newDuration), closeTo(2000, 60));
      expect(await File(track.filePath!).length(), lessThan(before));
      expect(await File(result.backupPath!).length(), before);
      final inLibrary = MusicLibraryService.instance.byId(track.id)!;
      expect(inLibrary.durationMs, closeTo(2000, 60));
      expect(inLibrary.playCount, 4); // same song, counters kept
      expect(scanned, contains(track.filePath));

      await TrackTrimmer.undo(result, track);
      expect(await File(track.filePath!).length(), before);
      expect(MusicLibraryService.instance.byId(track.id)!.durationMs, 5000);
    });

    test('as a new song: the original stays, "(short)" is added next to it',
        () async {
      final track = await songIn('tone.m4a');
      final before = await File(track.filePath!).readAsBytes();

      final result = await TrackTrimmer.trim(track,
          const Duration(seconds: 2), const Duration(seconds: 4),
          keepOriginal: true);

      expect(result.track.filePath, '${dir.path}/tone (short).m4a');
      expect(result.track.title, 'Tone (short)');
      expect(result.track.playCount, 0);
      expect(await File(track.filePath!).readAsBytes(), before);
      expect(MusicLibraryService.instance.tracks.value.map((t) => t.id),
          containsAll([track.id, result.track.id]));

      await TrackTrimmer.undo(result, track);
      expect(await File(result.track.filePath!).exists(), isFalse);
      expect(MusicLibraryService.instance.tracks.value.map((t) => t.id),
          [track.id]);
    });

    test('only phone songs in a supported format can be shortened', () {
      expect(TrackTrimmer.canTrim(Track.local(filePath: '/m/a.mp3', title: 'a')),
          isTrue);
      expect(TrackTrimmer.canTrim(Track.local(filePath: '/m/a.webm', title: 'a')),
          isFalse);
      expect(TrackTrimmer.canTrim(Track.youtube(videoId: 'v', title: 'a')),
          isFalse);
    });
  });

  group('TrimSongPage', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trimpage');
      MusicLibraryService.instance.resetForTest();
      MediaScannerService.scanOverride = (path) async {};
      TrackTrimmer.backupDirOverride =
          () async => Directory('${dir.path}/backups');
    });

    tearDown(() async {
      MediaScannerService.scanOverride = null;
      TrackTrimmer.backupDirOverride = null;
      await dir.delete(recursive: true);
    });

    Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    testWidgets('pick a start and an end with the steps, then Shorten',
        (tester) async {
      final path = '${dir.path}/song.mp3';
      await tester.runAsync(() => File('$fixtures/cbr.mp3').copy(path));
      final track = Track.local(filePath: path, title: 'Song');
      MusicLibraryService.instance.tracks.value = [track];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TrimSongPage(trackId: track.id))),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await pumpUntil(tester, () => find.byType(RangeSlider).evaluate().isNotEmpty);

      expect(find.text('Now 0:05.0 · keeps 0:05.0'), findsOneWidget);
      await tester.tap(find.byTooltip('Start 1 second later'));
      await tester.tap(find.byTooltip('Start 1 second later'));
      await tester.tap(find.byTooltip('End 1 second earlier'));
      await tester.pump();
      expect(find.text('0:02.0'), findsOneWidget);
      expect(find.text('Now 0:05.0 · keeps 0:02.0'), findsOneWidget);

      await tester.tap(find.text('Shorten'));
      await pumpUntil(tester, () => find.text('open').evaluate().isNotEmpty &&
          find.byType(RangeSlider).evaluate().isEmpty);
      await tester.pump();

      expect(find.textContaining('Shortened to 0:02'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      final length = await tester.runAsync(() => AudioTrimmer.durationOf(path));
      // 2.0 s to 4.07 s (the tone is 5.07 s long; the end moved back 1 s).
      expect(length!.inMilliseconds, closeTo(2067, 40));
    });
  });
}
