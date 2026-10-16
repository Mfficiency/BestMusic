import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:best_music/models/track.dart';
import 'package:best_music/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;
  late List<Uri> requests;
  late http.Response Function(Uri) answer;
  var now = DateTime(2026, 10, 16);

  LyricsService service() => LyricsService(
        client: MockClient((request) async {
          requests.add(request.url);
          return answer(request.url);
        }),
        cacheDir: () async => Directory('${tempDir.path}/lyrics'),
        clock: () => now,
        sleep: (_) async {},
      );

  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)), status,
      headers: {'content-type': 'application/json'});

  final song = Track.local(
    filePath: '/nowhere/Daft Punk - One More Time.mp3',
    title: 'One More Time',
    artist: 'Daft Punk',
    album: 'Discovery',
    durationMs: 320000,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lyrics_test');
    requests = [];
    now = DateTime(2026, 10, 16);
    answer = (_) => http.Response('', 404);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('an exact LRCLIB match is used and saved', () async {
    answer = (uri) => uri.path == '/api/get'
        ? json({
            'trackName': 'One More Time',
            'artistName': 'Daft Punk',
            'syncedLyrics': '[00:01.00]One more time\n[00:05.00]Celebration',
            'plainLyrics': 'One more time\nCelebration',
          })
        : http.Response('', 404);

    final found = await service().lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.isSynced, isTrue);
    expect(found.lyrics!.lines.map((l) => l.text),
        ['One more time', 'Celebration']);
    expect(found.lyrics!.source, 'LRCLIB');
    final get = requests.single;
    expect(get.host, 'lrclib.net');
    expect(get.queryParameters, {
      'track_name': 'One More Time',
      'artist_name': 'Daft Punk',
      'album_name': 'Discovery',
      'duration': '320',
    });

    // Second time: from the saved copy, no request.
    requests.clear();
    final again = await service().lyricsFor(song);
    expect(again.status, LyricsStatus.found);
    expect(again.lyrics!.lines.length, 2);
    expect(requests, isEmpty);
  });

  test('falls back to a search and picks the best-matching synced record',
      () async {
    answer = (uri) {
      if (uri.path == '/api/get') return http.Response('', 404);
      return json([
        {
          'trackName': 'Something Else',
          'artistName': 'Daft Punk',
          'duration': 320,
          'syncedLyrics': '[00:01.00]Wrong song',
        },
        {
          'trackName': 'One More Time',
          'artistName': 'Daft Punk',
          'duration': 321,
          'plainLyrics': 'Plain only',
        },
        {
          'trackName': 'One More Time (Radio Edit)',
          'artistName': 'Daft Punk',
          'duration': 319,
          'syncedLyrics': '[00:02.00]Right song',
        },
      ]);
    };

    final found = await service().lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.lines.single.text, 'Right song');
    expect(requests.map((u) => u.path), ['/api/get', '/api/search']);
  });

  test('nothing found is remembered for a week; "Search again" asks anyway',
      () async {
    final first = await service().lyricsFor(song);
    expect(first.status, LyricsStatus.notFound);
    final asked = requests.length;
    expect(asked, greaterThan(0));

    now = now.add(const Duration(days: 6));
    expect((await service().lyricsFor(song)).status, LyricsStatus.notFound);
    expect(requests.length, asked);

    expect((await service().lyricsFor(song, refresh: true)).status,
        LyricsStatus.notFound);
    expect(requests.length, 2 * asked);

    // A week after that last look, LRCLIB is asked again by itself.
    now = now.add(const Duration(days: 8));
    await service().lyricsFor(song);
    expect(requests.length, 3 * asked);
  });

  test('an instrumental is reported and remembered', () async {
    answer = (uri) => json({
          'trackName': 'One More Time',
          'artistName': 'Daft Punk',
          'instrumental': true,
        });
    expect((await service().lyricsFor(song)).status, LyricsStatus.instrumental);
    requests.clear();
    expect((await service().lyricsFor(song)).status, LyricsStatus.instrumental);
    expect(requests, isEmpty);
  });

  test('LRCLIB unreachable: reported, not remembered', () async {
    answer = (_) => http.Response('down', 503);
    expect((await service().lyricsFor(song)).status, LyricsStatus.unavailable);

    answer = (_) => json({
          'trackName': 'One More Time',
          'artistName': 'Daft Punk',
          'plainLyrics': 'Back up',
        });
    final found = await service().lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.isSynced, isFalse);
    expect(found.lyrics!.plain, 'Back up');
  });

  test('an .lrc file next to the song wins, without asking LRCLIB', () async {
    final mp3 = File('${tempDir.path}/Song.mp3')..writeAsBytesSync([0, 0, 0]);
    File('${tempDir.path}/Song.lrc')
        .writeAsStringSync('[00:03.00]From the file');
    final local = Track.local(filePath: mp3.path, title: 'Song');

    final found = await service().lyricsFor(local);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.lines.single.text, 'From the file');
    expect(found.lyrics!.source, "the song's .lrc file");
    expect(requests, isEmpty);
  });

  test("lyrics in an mp3's tags are used, without asking LRCLIB", () async {
    final mp3 = File('${tempDir.path}/Tagged.mp3')
      ..writeAsBytesSync([..._id3WithLyrics('[00:04.00]From the tag'), 0, 0]);
    final local = Track.local(filePath: mp3.path, title: 'Tagged');

    final found = await service().lyricsFor(local);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.lines.single.text, 'From the tag');
    expect(found.lyrics!.source, "the song's tags");
    expect(requests, isEmpty);
  });

  test('decodeLyricsTag reads USLT, null without one', () {
    expect(LyricsService.decodeLyricsTag(_id3WithLyrics('Plain words')),
        'Plain words');
    expect(LyricsService.decodeLyricsTag(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('Subscriptions videos are not songs', () async {
    final video = Track.youtube(
      videoId: 'abc',
      title: 'A video',
      artist: 'A channel',
    );
    expect((await service().lyricsFor(video)).status, LyricsStatus.notASong);
    expect(requests, isEmpty);
  });

  test('a slow or failed first request is tried once more', () async {
    var calls = 0;
    final svc = LyricsService(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) throw http.ClientException('Connection reset');
        return json({
          'trackName': 'One More Time',
          'artistName': 'Daft Punk',
          'plainLyrics': 'Second try',
        });
      }),
      cacheDir: () async => Directory('${tempDir.path}/lyrics'),
      clock: () => now,
      sleep: (_) async {},
    );
    final found = await svc.lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.plain, 'Second try');
    expect(calls, 2);
  });

  test('still unreachable after 3 tries: says exactly why', () async {
    final svc = LyricsService(
      client: MockClient(
          (request) async => throw http.ClientException('Failed host lookup')),
      cacheDir: () async => Directory('${tempDir.path}/lyrics'),
      clock: () => now,
      sleep: (_) async {},
    );
    final found = await svc.lyricsFor(song);
    expect(found.status, LyricsStatus.unavailable);
    expect(found.reason,
        'No internet: lrclib.net could not be found (tried 3 times)');

    answer = (_) => http.Response('down', 503);
    expect((await service().lyricsFor(song)).reason,
        'LRCLIB server error 503 (tried 3 times)');
  });

  test('"Artist ●● Song" names are searched as artist and song', () async {
    expect(LyricsService.splitForLyrics('', 'RÜFÜS DU SOL ●● Underwater'),
        ('RÜFÜS DU SOL', 'Underwater'));
    expect(LyricsService.splitForLyrics('', 'Artist • Song'), ('Artist', 'Song'));
    expect(LyricsService.splitForLyrics('', 'Artist | Song'), ('Artist', 'Song'));
    expect(LyricsService.splitForLyrics('Tagged', 'A ●● B'), ('Tagged', 'A ●● B'));
    expect(LyricsService.splitForLyrics('', 'Just a title'), ('', 'Just a title'));

    final video = Track.local(
        filePath: '/nowhere/x.m4a',
        title: 'RÜFÜS DU SOL ●● Underwater [Official Audio]');
    await service().lyricsFor(video);
    final search =
        requests.firstWhere((u) => u.path == '/api/get' || u.path == '/api/search');
    expect(search.queryParameters['artist_name'], 'RÜFÜS DU SOL');
    expect(search.queryParameters['track_name'], 'Underwater');
  });

  test('server hiccups are retried before giving up', () async {
    var calls = 0;
    answer = (uri) {
      calls++;
      if (calls <= 2) return http.Response('busy', 502);
      return json({
        'trackName': 'One More Time',
        'artistName': 'Daft Punk',
        'plainLyrics': 'Third time lucky',
      });
    };
    final found = await service().lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.plain, 'Third time lucky');
  });

  test('one failing request does not sink the lookup', () async {
    // The exact match keeps failing; the search answers.
    answer = (uri) => uri.path == '/api/get'
        ? http.Response('down', 503)
        : json([
            {
              'trackName': 'One More Time',
              'artistName': 'Daft Punk',
              'duration': 320,
              'syncedLyrics': '[00:01.00]Found by search',
            }
          ]);
    final found = await service().lyricsFor(song);
    expect(found.status, LyricsStatus.found);
    expect(found.lyrics!.lines.single.text, 'Found by search');
  });

  test('found lyrics are kept on the phone and used offline', () async {
    answer = (_) => json({
          'trackName': 'One More Time',
          'artistName': 'Daft Punk',
          'syncedLyrics': '[00:01.00]Kept',
        });
    final first = await service().lyricsFor(song);
    expect(first.saved, isFalse);

    // Offline from now on.
    answer = (_) => throw http.ClientException('Failed host lookup');
    requests.clear();
    final again = await service().lyricsFor(song);
    expect(again.status, LyricsStatus.found);
    expect(again.saved, isTrue);
    expect(again.lyrics!.lines.single.text, 'Kept');
    expect(requests, isEmpty);

    // "Search again" while offline keeps showing them.
    final refreshed = await service().lyricsFor(song, refresh: true);
    expect(refreshed.status, LyricsStatus.found);
    expect(refreshed.lyrics!.lines.single.text, 'Kept');

    // …and so does a search that finds nothing.
    answer = (_) => http.Response('', 404);
    final none = await service().lyricsFor(song, refresh: true);
    expect(none.lyrics!.lines.single.text, 'Kept');
  });
}

/// An ID3v2.3 tag holding one USLT frame with [text] (ISO-8859-1).
Uint8List _id3WithLyrics(String text) {
  final body = <int>[
    0, // encoding: ISO-8859-1
    ...ascii.encode('eng'),
    0, // empty content descriptor
    ...latin1.encode(text),
  ];
  final frame = <int>[
    ...ascii.encode('USLT'),
    (body.length >> 24) & 0xff,
    (body.length >> 16) & 0xff,
    (body.length >> 8) & 0xff,
    body.length & 0xff,
    0, 0, // flags
    ...body,
  ];
  final size = frame.length;
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3, 0, // v2.3.0
    0, // flags
    (size >> 21) & 0x7f,
    (size >> 14) & 0x7f,
    (size >> 7) & 0x7f,
    size & 0x7f,
    ...frame,
  ]);
}
