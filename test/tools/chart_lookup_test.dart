import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
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
    test('without a Claude API key it says where to set one', () async {
      Config.claudeApiKey = '';
      expect(
          () => service.lookup(
              const ChartQuery(year: 2024, country: 'Belgium')),
          throwsA(isA<ChartLookupException>().having(
              (e) => e.message, 'message', contains('Claude API key'))));
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

    testWidgets('defaults to Pop; without a key it points to Settings',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Mp3DownloaderPage()));
      await tester.tap(find.text('Top songs from the charts'));
      await tester.pumpAndSettle();
      final year = DateTime.now().year;
      expect(find.text('Top 10 Pop · Belgium · $year'), findsOneWidget);

      await tester.tap(find.text('Find chart songs'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Charts need a Claude API key'),
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
        final id = query.startsWith('Artist One') ? 'v1' : 'v2';
        return [
          Mp3SearchResult(
              videoId: id, title: '$query (Official Video)', channel: 'C',
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
      expect(searched, ['Artist One - Song One', 'Artist Two - Song Two',
        'Nobody - Not On YouTube']);
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
