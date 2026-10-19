import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/services/builtin_charts.dart';
import 'package:best_music/services/chart_lookup_service.dart';
import 'package:best_music/services/mp3_download_manager.dart';
import 'package:best_music/services/mp3_downloader_service.dart';
import 'package:best_music/ui/mp3_downloader_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// MP3 Downloader → "Top songs from the charts" (SPEC.md "Charts in the MP3
/// Downloader"): Claude + web search finds the chart, each song is looked
/// up on YouTube, the list opens in the playlist picker.
void main() {
  final service = ChartLookupService.instance;

  http.Response reply(Map<String, Object?> body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json'});

  Map<String, Object?> submitted(List<List<String>> songs) => {
        'stop_reason': 'tool_use',
        'content': [
          {'type': 'text', 'text': 'Here it is.'},
          {
            'type': 'tool_use',
            'id': 'tu1',
            'name': 'submit_songs',
            'input': {
              'songs': [
                for (final s in songs)
                  {'artist': s[0], 'title': s[1], 'note': '#${songs.indexOf(s) + 1}'},
              ],
              'summary': 'Ultratop year chart',
            },
          },
        ],
      };

  tearDown(() {
    service.client = null;
    Config.claudeApiKey = '';
    BuiltInCharts.instance.resetForTest();
    DeezerCharts.instance.client = null;
  });

  // A small stand-in for the built-in asset.
  void fakeBuiltIn() {
    BuiltInCharts.instance.loadOverride = () async => jsonEncode({
          'Belgium': {
            '2005': [
              ['Crazy Frog', 'Axel F', 'Dance / Electronic'],
              ['James Blunt', "You're Beautiful", 'Pop'],
              ['Gorillaz', 'Feel Good Inc.', 'Rock'],
              ['Mariah Carey', 'We Belong Together', 'R&B / Soul'],
              ['Shakira', 'La Tortura', 'Latin'],
              ['Kelly Clarkson', 'Since U Been Gone', 'Pop'],
            ],
          },
        });
  }

  MockClient fakeDeezer(List<String> requested) => MockClient((request) async {
        requested.add(request.url.toString());
        if (request.url.path.endsWith('/search/playlist')) {
          return reply({
            'data': [
              {'id': 1, 'title': 'Top Belgium', 'user': {'name': 'Someone'}},
              {'id': 99, 'title': 'Top Belgium', 'user': {'name': 'Deezer Charts'}},
            ],
          });
        }
        return reply({
          'data': [
            {'title_short': 'Hit One', 'title': 'Hit One (Radio Edit)',
              'artist': {'name': 'Band A'}},
            {'title_short': 'Hit Two', 'artist': {'name': 'Band B'}},
          ],
        });
      });

  group('ChartQuery', () {
    test('title and prompt follow the picks; Pop is the default style', () {
      const q = ChartQuery(year: 2024, country: 'Belgium', count: 10);
      expect(q.style, 'Pop');
      expect(q.title, 'Top 10 Pop · Belgium · 2024');
      final prompt = q.prompt(now: DateTime(2026, 10, 17));
      expect(prompt, contains('top 10 Pop songs of 2024 in Belgium'));
      expect(prompt, contains('year-end'));
      expect(prompt, contains('Ultratop'));

      const all = ChartQuery(
          year: 2026, country: 'Worldwide', style: ChartQuery.allStyles, count: 20);
      expect(all.title, 'Top 20 · Worldwide · 2026');
      final now = all.prompt(now: DateTime(2026, 10, 17));
      expect(now, contains('top 20 songs of 2026 worldwide'));
      expect(now, contains('not over yet'));
      expect(now, isNot(contains('Only')));
    });
  });

  group('ChartLookupService', () {
    test('without a key: the built-in list, filtered to the style and cut '
        'to the count', () async {
      fakeBuiltIn();
      final pop = await service.lookup(
          const ChartQuery(year: 2005, country: 'Belgium', count: 10));
      expect(pop.source, ChartSource.builtIn);
      expect(pop.songs.map((s) => s.title),
          ["You're Beautiful", 'Since U Been Gone']);
      expect(pop.summary, contains('2 in the built-in top 6'));

      final all = await service.lookup(const ChartQuery(
          year: 2005, country: 'Belgium', style: ChartQuery.allStyles, count: 3));
      expect(all.songs.map((s) => s.artist),
          ['Crazy Frog', 'James Blunt', 'Gorillaz']);
      expect(all.songs.first.style, 'Dance / Electronic');
    });

    test("without a key, this year's chart comes from Deezer", () async {
      final requested = <String>[];
      DeezerCharts.instance.client = fakeDeezer(requested);
      final result = await service.lookup(
          const ChartQuery(year: 2026, country: 'Belgium', count: 2),
          now: DateTime(2026, 10, 17));
      expect(result.source, ChartSource.deezer);
      expect(result.songs.map((s) => s.searchQuery),
          ['Band A - Hit One', 'Band B - Hit Two']);
      expect(requested.last, contains('/playlist/99/tracks?limit=2'));
      expect(result.summary, contains('Deezer charts have no style'));
    });

    test('without a key, an uncovered past year says what is covered',
        () async {
      fakeBuiltIn();
      await expectLater(
          service.lookup(const ChartQuery(year: 2010, country: 'Italy'),
              now: DateTime(2026, 10, 17)),
          throwsA(isA<ChartLookupException>().having((e) => e.message,
              'message', allOf(contains('built in'), contains('Claude API key')))));
    });

    test('the shipped built-in charts cover 7 countries, 2000-2025, with '
        'known styles', () {
      final data = jsonDecode(
              File(BuiltInCharts.assetPath).readAsStringSync())
          as Map<String, dynamic>;
      expect(data.keys.toSet(), BuiltInCharts.countries.toSet());
      for (final country in BuiltInCharts.countries) {
        final years = data[country] as Map<String, dynamic>;
        for (var y = BuiltInCharts.firstYear; y <= BuiltInCharts.lastYear; y++) {
          final songs = years['$y'] as List?;
          expect(songs, isNotNull, reason: '$country $y');
          expect(songs!.length, greaterThanOrEqualTo(15), reason: '$country $y');
          for (final s in songs) {
            expect(s, hasLength(3), reason: '$country $y $s');
            expect((s as List)[0].toString().trim(), isNotEmpty);
            expect(s[1].toString().trim(), isNotEmpty);
            expect(ChartQuery.styles, contains(s[2]), reason: '$country $y $s');
          }
        }
      }
    });

    test('asks Claude with web search, resumes after pause_turn and reads '
        'submit_songs', () async {
      Config.claudeApiKey = 'sk-test';
      final requests = <Map<String, dynamic>>[];
      final headers = <Map<String, String>>[];
      service.client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        headers.add(request.headers);
        if (requests.length == 1) {
          return reply({
            'stop_reason': 'pause_turn',
            'content': [
              {'type': 'server_tool_use', 'id': 's1', 'name': 'web_search',
                'input': {'query': 'ultratop jaaroverzicht 2024'}},
            ],
          });
        }
        return reply(submitted([
          ['Artist One', 'Song One'],
          ['Artist Two', 'Song Two'],
        ]));
      });

      final result = await service
          .lookup(const ChartQuery(year: 2024, country: 'Belgium', count: 2));

      expect(result.songs.map((s) => s.searchQuery),
          ['Artist One - Song One', 'Artist Two - Song Two']);
      expect(result.songs.first.note, '#1');
      expect(result.summary, 'Ultratop year chart');

      final first = requests.first;
      expect(first['model'], 'claude-opus-5-5');
      expect(first['fallbacks'], 'default');
      expect((first['tools'] as List).first['type'], 'web_search_20260209');
      expect((first['tools'] as List)[1]['name'], 'submit_songs');
      expect((first['tools'] as List)[1]['strict'], isTrue);
      expect(first.containsKey('tool_choice'), isFalse);
      expect(headers.first['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(headers.first['x-api-key'], 'sk-test');
      // The paused turn goes back as the assistant's message.
      final resumed = requests[1]['messages'] as List;
      expect(resumed, hasLength(2));
      expect(resumed[1]['role'], 'assistant');
      expect((resumed[1]['content'] as List).first['type'], 'server_tool_use');
    });

    test('a refusal or an API error becomes a readable message', () async {
      Config.claudeApiKey = 'sk-test';
      service.client = MockClient(
          (request) async => reply({'stop_reason': 'refusal', 'content': []}));
      await expectLater(
          service.lookup(const ChartQuery(year: 2024, country: 'Belgium')),
          throwsA(isA<ChartLookupException>()
              .having((e) => e.message, 'message', contains('declined'))));

      service.client = MockClient((request) async => http.Response(
          jsonEncode({'error': {'message': 'invalid x-api-key'}}), 401));
      await expectLater(
          service.lookup(const ChartQuery(year: 2024, country: 'Belgium')),
          throwsA(isA<ChartLookupException>().having(
              (e) => e.message, 'message', 'Claude API error 401: invalid x-api-key')));
    });
  });

  group('MP3 Downloader charts panel', () {
    tearDown(() {
      Mp3DownloaderService.instance
        ..searchOverride = null
        ..downloadOverride = null;
      Mp3DownloadManager.instance.resetForTest();
      Config.mp3DownloadFolder = '';
      Config.mp3CompareFolder = '';
    });

    Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
    }

    testWidgets("defaults to Pop; works without a key (this year's chart "
        'from Deezer)', (tester) async {
      late Directory tempDir;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('mp3_charts_nokey');
        Config.mp3DownloadFolder = tempDir.path;
      });
      addTearDown(() => tempDir.delete(recursive: true));
      DeezerCharts.instance.client = fakeDeezer([]);
      Mp3DownloaderService.instance.searchOverride = (query, limit) async => [
            Mp3SearchResult(
                videoId: query, title: query, channel: 'C', duration: null),
          ];

      await tester.pumpWidget(const MaterialApp(home: Mp3DownloaderPage()));
      await tester.tap(find.text('Top songs from the charts'));
      await tester.pumpAndSettle();
      final year = DateTime.now().year;
      expect(find.text('Top 10 Pop · Belgium · $year'), findsOneWidget);

      await tester.tap(find.text('Find chart songs'));
      final marker = find.text('Top 10 Pop · Belgium · $year · 2 of 2 selected');
      await pumpUntil(tester, marker);
      expect(marker, findsOneWidget);
      expect(find.textContaining("Deezer's chart for Belgium right now"),
          findsOneWidget);
    });

    testWidgets('finds the chart, a video per song, then lists them to '
        'download one by one or all at once', (tester) async {
      late Directory tempDir;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('mp3_charts');
        Config.mp3DownloadFolder = tempDir.path;
      });
      addTearDown(() => tempDir.delete(recursive: true));
      Config.claudeApiKey = 'sk-test';
      service.client = MockClient((request) async => reply(submitted([
            ['Artist One', 'Song One'],
            ['Artist Two', 'Song Two'],
            ['Nobody', 'Not On YouTube'],
          ])));
      final searched = <String>[];
      Mp3DownloaderService.instance.searchOverride = (query, limit) async {
        searched.add(query);
        if (query.startsWith('Nobody')) return const [];
        // Song One has a lyric video (picked over the explicit one listed
        // first); Song Two only has the official video.
        if (query == 'Artist One - Song One lyrics') {
          return const [
            Mp3SearchResult(
                videoId: 'v1x', title: 'Artist One - Song One (Explicit)',
                channel: 'C', duration: null),
            Mp3SearchResult(
                videoId: 'v1', title: 'Artist One - Song One (Lyrics)',
                channel: 'C', duration: null),
          ];
        }
        if (query.endsWith(' lyrics')) {
          return const [
            Mp3SearchResult(
                videoId: 'other', title: 'Someone Else - Other Song (Lyrics)',
                channel: 'C', duration: null),
          ];
        }
        return [
          Mp3SearchResult(
              videoId: 'v2', title: '$query (Official Video)', channel: 'C',
              duration: null),
        ];
      };
      final downloaded = <String>[];
      Mp3DownloaderService.instance.downloadOverride =
          (result, dir, onProgress) async {
        downloaded.add(result.videoId);
        return '$dir/${result.videoId}.m4a';
      };

      await tester.pumpWidget(const MaterialApp(home: Mp3DownloaderPage()));
      await tester.tap(find.text('Top songs from the charts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find chart songs'));
      final year = DateTime.now().year;
      final marker = find.text('Top 10 Pop · Belgium · $year · 2 of 2 selected');
      await pumpUntil(tester, marker);
      expect(marker, findsOneWidget);
      expect(searched, [
        'Artist One - Song One lyrics',
        'Artist Two - Song Two lyrics', 'Artist Two - Song Two',
        'Nobody - Not On YouTube lyrics', 'Nobody - Not On YouTube',
      ]);
      expect(find.textContaining('1 · Artist One - Song One'), findsOneWidget);
      expect(find.textContaining('No video found for: Nobody - Not On YouTube'),
          findsOneWidget);

      // One by one…
      await tester.tap(find.byTooltip('Download this one').first);
      await tester.pump();
      expect(find.text('Top 10 Pop · Belgium · $year · 1 of 2 selected'),
          findsOneWidget);
      for (var i = 0; i < 60 && downloaded.isEmpty; i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(downloaded, ['v1']);

      // …or the rest in bulk.
      await tester.tap(find.text('Download 1'));
      for (var i = 0; i < 60 && downloaded.length < 2; i++) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(downloaded, ['v1', 'v2']);
    });
  });
}
