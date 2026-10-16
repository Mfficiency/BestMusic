import 'package:best_music/models/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Duration t(int s, [int ms = 0]) => Duration(seconds: s, milliseconds: ms);

  group('Lyrics.parseLrc', () {
    test('reads timed lines, skipping tag lines', () {
      final lyrics = Lyrics.parseLrc('''
[ar:Someone]
[ti:A Song]
[00:12.30]First line
[00:15.80]Second line
''', source: 'test');
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.lines, [
        LyricLine(t(12, 300), 'First line'),
        LyricLine(t(15, 800), 'Second line'),
      ]);
      expect(lyrics.plain, 'First line\nSecond line');
      expect(lyrics.source, 'test');
    });

    test('reads every timestamp format', () {
      final lyrics = Lyrics.parseLrc('''
[00:01]a
[00:02.5]b
[00:03.05]c
[00:04.005]d
[00:05:50]e
[01:02.00]f
''');
      expect(lyrics.lines.map((l) => l.time), [
        t(1),
        t(2, 500),
        t(3, 50),
        t(4, 5),
        t(5, 500),
        t(62),
      ]);
    });

    test('a line with several timestamps is sung at each, in time order', () {
      final lyrics = Lyrics.parseLrc('''
[00:10.00][00:30.00]Chorus
[00:20.00]Verse
''');
      expect(lyrics.lines, [
        LyricLine(t(10), 'Chorus'),
        LyricLine(t(20), 'Verse'),
        LyricLine(t(30), 'Chorus'),
      ]);
    });

    test('applies [offset:] (positive = earlier), never below zero', () {
      final lyrics = Lyrics.parseLrc('''
[offset:+500]
[00:00.20]Start
[00:10.00]Later
''');
      expect(lyrics.lines,
          [LyricLine(Duration.zero, 'Start'), LyricLine(t(9, 500), 'Later')]);
    });

    test('drops word-by-word timestamps', () {
      final lyrics = Lyrics.parseLrc(
          '[00:19.10]<00:19.10>Word <00:19.60>by <00:19.90>word');
      expect(lyrics.lines.single.text, 'Word by word');
    });

    test('keeps empty lines between, drops leading empty lines', () {
      final lyrics = Lyrics.parseLrc('''
[00:01.00]
[00:05.00]Sung
[00:09.00]
[00:20.00]Again
''');
      expect(lyrics.lines.map((l) => l.text), ['Sung', '', 'Again']);
      expect(lyrics.plain, 'Sung\n\nAgain');
    });

    test('text without timestamps is plain lyrics', () {
      final lyrics = Lyrics.parseLrc('\nJust words\r\nNo times\n\n');
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.plain, 'Just words\nNo times');
      expect(lyrics.isEmpty, isFalse);
      expect(Lyrics.parseLrc('[ar:x]\n\n').isEmpty, isTrue);
    });
  });

  group('following the song', () {
    final lyrics = Lyrics.parseLrc('''
[00:10.00]One
[00:20.00]A rather long line that keeps going
[00:21.00]Short gap before this
''');

    test('indexAt is the last line that has started', () {
      expect(lyrics.indexAt(t(0)), -1);
      expect(lyrics.indexAt(t(9, 999)), -1);
      expect(lyrics.indexAt(t(10)), 0);
      expect(lyrics.indexAt(t(15)), 0);
      expect(lyrics.indexAt(t(20, 500)), 1);
      expect(lyrics.indexAt(t(500)), 2);
    });

    test('progressAt fills a line over its estimated length', () {
      // "One": the 1.5 s minimum.
      expect(lyrics.progressAt(0, t(10)), 0);
      expect(lyrics.progressAt(0, t(10, 750)), closeTo(0.5, 0.001));
      // Not stretched over the long gap after it.
      expect(lyrics.progressAt(0, t(12)), 1);
      // Cut short by the next line starting 1 s later.
      expect(lyrics.progressAt(1, t(20, 500)), closeTo(0.5, 0.001));
      expect(lyrics.progressAt(-1, t(0)), 0);
    });
  });

  test('toJson/fromJson round-trips', () {
    final lyrics = Lyrics.parseLrc('[00:01.00]a\n[00:02.00]b', source: 'LRCLIB');
    final back = Lyrics.fromJson(lyrics.toJson());
    expect(back.lines, lyrics.lines);
    expect(back.plain, lyrics.plain);
    expect(back.source, 'LRCLIB');
    expect(Lyrics.fromJson(const {'instrumental': true}).instrumental, isTrue);
    expect(Lyrics.fromJson(const {'lines': 'junk'}).isEmpty, isTrue);
  });
}
