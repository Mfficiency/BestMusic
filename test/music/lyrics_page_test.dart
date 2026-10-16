import 'package:best_music/config.dart';
import 'package:best_music/models/lyrics.dart';
import 'package:best_music/models/music_playlist.dart';
import 'package:best_music/models/track.dart';
import 'package:best_music/services/lyrics_service.dart';
import 'package:best_music/services/music_library_service.dart';
import 'package:best_music/services/music_player_service.dart';
import 'package:best_music/services/music_playlist_service.dart';
import 'package:best_music/ui/lyrics_page.dart';
import 'package:best_music/ui/now_playing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers straight away with [lookup], no files or network.
class _FakeLyrics extends LyricsService {
  _FakeLyrics(this.lookup);

  LyricsLookup lookup;
  final List<(String, bool)> calls = [];

  @override
  Future<LyricsLookup> lyricsFor(Track track,
      {Duration? duration, bool refresh = false}) async {
    calls.add((track.id, refresh));
    return lookup;
  }
}

void main() {
  final song = Track.local(
      filePath: '/fake/song.mp3', title: 'Song', artist: 'Singer');

  setUp(() async {
    Config.musicFolder = '';
    Config.musicExcludedSubfolders = [];
    Config.mp3DownloadFolder = '';
    MusicLibraryService.instance.resetForTest();
    MusicPlaylistService.instance.resetForTest();
    MusicPlaylistService.instance.playlists.value = [
      MusicPlaylist.favorites(),
      MusicPlaylist.disliked(),
    ];
    if (!MusicPlayerService.isReady) {
      await MusicPlayerService.init();
    }
    MusicLibraryService.instance.tracks.value = [song];
  });

  Lyrics synced() => Lyrics.parseLrc('''
[00:05.00]First line
[00:10.00]Second line
[00:15.00]Third line
''', source: 'LRCLIB');

  testWidgets('Now Playing has a Lyrics button for songs that opens the page',
      (tester) async {
    final fake = _FakeLyrics(LyricsLookup(LyricsStatus.found, synced()));
    final before = LyricsService.instance;
    LyricsService.instance = fake;
    addTearDown(() => LyricsService.instance = before);
    MusicPlayerService.handler.restore([song]);

    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pumpAndSettle();

    expect(find.byType(LyricsPage), findsOneWidget);
    expect(find.text('Second line'), findsOneWidget);
    expect(fake.calls.single, (song.id, false));
  });

  testWidgets('synced lyrics: the line being sung is the bright one',
      (tester) async {
    // Paused 11 s in: the second line is being sung.
    MusicPlayerService.handler
        .restore([song], position: const Duration(seconds: 11));
    final fake = _FakeLyrics(LyricsLookup(LyricsStatus.found, synced()));

    await tester.pumpWidget(MaterialApp(home: LyricsPage(service: fake)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Song · Singer'), findsOneWidget);
    expect(find.text('Lyrics from LRCLIB'), findsOneWidget);
    expect(find.text('First line'), findsOneWidget);
    expect(find.text('Third line'), findsOneWidget);
    // The sung line fills in: 1 s into a line sung over 1.5 s, two thirds
    // of it ("Second ") is in the sung colour, the rest still to come.
    final sung = tester.widget<Text>(find.text('Second line'));
    final parts = (sung.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(parts.map((p) => p.text), ['Second ', 'line']);
    expect(parts.first.style!.color, isNot(parts.last.style!.color));
    // The others are plain text.
    expect(tester.widget<Text>(find.text('First line')).textSpan, isNull);
  });

  testWidgets('plain lyrics are shown with a note', (tester) async {
    MusicPlayerService.handler.restore([song]);
    final fake = _FakeLyrics(LyricsLookup(LyricsStatus.found,
        const Lyrics(plain: 'Some words\nMore words', source: 'LRCLIB')));

    await tester.pumpWidget(MaterialApp(home: LyricsPage(service: fake)));
    await tester.pumpAndSettle();

    expect(find.text('Some words\nMore words'), findsOneWidget);
    expect(find.textContaining("aren't timed"), findsOneWidget);
  });

  testWidgets('nothing found offers Search again, which skips the cache',
      (tester) async {
    MusicPlayerService.handler.restore([song]);
    final fake = _FakeLyrics(const LyricsLookup(LyricsStatus.notFound));

    await tester.pumpWidget(MaterialApp(home: LyricsPage(service: fake)));
    await tester.pumpAndSettle();
    expect(find.text('No lyrics found for this song.'), findsOneWidget);

    fake.lookup = LyricsLookup(LyricsStatus.found, synced());
    await tester.tap(find.text('Search again'));
    await tester.pumpAndSettle();

    expect(fake.calls, [(song.id, false), (song.id, true)]);
    expect(find.text('First line'), findsOneWidget);
  });

  testWidgets('offline and instrumental get their own message',
      (tester) async {
    MusicPlayerService.handler.restore([song]);
    final fake = _FakeLyrics(const LyricsLookup(LyricsStatus.unavailable));

    await tester.pumpWidget(MaterialApp(home: LyricsPage(service: fake)));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't reach"), findsOneWidget);

    fake.lookup = const LyricsLookup(LyricsStatus.instrumental);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Instrumental'), findsOneWidget);
  });

  testWidgets('follows the song: the next song gets its own lyrics',
      (tester) async {
    final other = Track.local(filePath: '/fake/other.mp3', title: 'Other');
    MusicPlayerService.handler.restore([song]);
    final fake = _FakeLyrics(const LyricsLookup(LyricsStatus.notFound));

    await tester.pumpWidget(MaterialApp(home: LyricsPage(service: fake)));
    await tester.pumpAndSettle();
    MusicPlayerService.handler.restore([other]);
    await tester.pumpAndSettle();

    expect(fake.calls.map((c) => c.$1), [song.id, other.id]);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('on a narrow phone every Now Playing button still fits',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MusicPlayerService.handler.restore([song]);

    await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
    await tester.pumpAndSettle();

    // An overflowing Row would have thrown a layout error by now.
    expect(tester.takeException(), isNull);
    for (final tooltip in ['Repeat off', 'Lyrics', 'Queue', 'Track info']) {
      final center = tester.getCenter(find.byTooltip(tooltip));
      expect(center.dx, inInclusiveRange(0, 320), reason: tooltip);
    }
  });
}
