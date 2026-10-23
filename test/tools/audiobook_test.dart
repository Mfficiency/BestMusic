import 'dart:convert';
import 'dart:io';

import 'package:best_music/services/audiobook_service.dart';
import 'package:best_music/ui/audiobooks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tools → Audiobooks (SPEC.md §10.6aj): LibriVox search and the
/// chapter-by-chapter download queue, against a fake LibriVox.
void main() {
  final service = AudiobookService.instance;
  final manager = AudiobookDownloadManager.instance;

  Map<String, Object?> bookJson(String id, String title, {int sections = 2}) =>
      {
        'id': id,
        'title': '$title <i>(abridged)</i>',
        'description': '<p>A tale &amp; more.</p>',
        'language': 'English',
        'copyright_year': '1892',
        'totaltimesecs': 3900,
        'url_zip_file': 'http://www.archive.org/download/b$id/b$id.zip',
        'url_librivox': 'https://librivox.org/b$id/',
        'authors': [
          {'first_name': 'Arthur Conan', 'last_name': 'Doyle'},
        ],
        'sections': [
          for (var i = sections; i >= 1; i--)
            {
              'section_number': '$i',
              'title': 'Part $i: A/B?',
              'listen_url': 'http://www.archive.org/download/b$id/ch$i.mp3',
              'playtime': '${i * 60}',
              'readers': [
                {'display_name': 'Reader $i'},
              ],
            },
        ],
      };

  http.Response json(Object body, [int status = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), status,
          headers: {'content-type': 'application/json'});

  late Directory temp;
  final requested = <Uri>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('audiobooks');
    requested.clear();
    manager.resetForTest();
    service.client = MockClient((request) async {
      requested.add(request.url);
      final params = request.url.queryParameters;
      if (request.url.host == 'librivox.org') {
        if (params['title'] == 'adventures') {
          return json({
            'books': [bookJson('1', 'Adventures'), bookJson('3', 'Empty', sections: 0)]
          });
        }
        if (params['author'] == 'adventures') {
          return json({'books': [bookJson('1', 'Adventures')]});
        }
        if (params['author'] == 'doyle') {
          return json({'books': [bookJson('2', 'Hound')]});
        }
        return json({'error': 'Audiobooks could not be found'}, 404);
      }
      if (request.url.path.endsWith('ch2.mp3') &&
          request.url.path.contains('fail')) {
        return http.Response('nope', 500);
      }
      return http.Response.bytes(List<int>.filled(1000, 7), 200);
    });
  });

  tearDown(() {
    service.client = null;
    manager.resetForTest();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('parses LibriVox books: authors, chapters in order, https, plain text',
      () {
    final book = Audiobook.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(bookJson('1', 'X')))));
    expect(book.title, 'X (abridged)');
    expect(book.description, 'A tale & more.');
    expect(book.authorLine, 'Arthur Conan Doyle');
    expect(book.totalTime, const Duration(seconds: 3900));
    expect(book.year, 1892);
    expect(book.zipUrl, startsWith('https://'));
    expect(book.chapters.map((c) => c.number), [1, 2]);
    expect(book.chapters.first.url,
        'https://www.archive.org/download/b1/ch1.mp3');
    expect(book.chapters.first.duration, const Duration(minutes: 1));
    expect(book.chapters.first.reader, 'Reader 1');
  });

  test('search merges title and author matches and skips books without '
      'chapters', () async {
    final books = await service.search('  adventures ');
    expect(books.map((b) => b.id), ['1']);
    expect(requested.first.queryParameters['extended'], '1');
    expect(requested.first.queryParameters['format'], 'json');

    final byAuthor = await service.search('Conan doyle');
    expect(byAuthor.map((b) => b.id), ['2']);

    expect(await service.search('nothing like this'), isEmpty);
    expect(await service.search('   '), isEmpty);
  });

  test('search reports a server error', () async {
    service.client = MockClient((_) async => http.Response('down', 503));
    expect(service.search('x'), throwsA(isA<AudiobookException>()));
  });

  test('file and folder names are safe and numbered to sort', () {
    expect(safeFileName('a/b: c?  d.'), 'a b c d');
    expect(safeFileName('???'), 'Untitled');
    const chapter = AudiobookChapter(number: 3, title: 'The End', url: 'u');
    expect(audiobookChapterFileName(chapter, 9), '03 - The End.mp3');
    expect(audiobookChapterFileName(chapter, 120), '003 - The End.mp3');
    final book = Audiobook.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(bookJson('1', 'Hound')))));
    expect(
      audiobookFolder(temp.path, book),
      '${temp.path}${Platform.pathSeparator}Audiobooks'
      '${Platform.pathSeparator}Arthur Conan Doyle - Hound (abridged)',
    );
    expect(formatAudiobookDuration(const Duration(minutes: 65)), '1h 05m');
    expect(formatAudiobookDuration(const Duration(minutes: 42)), '42m');
  });

  test('downloads every chapter into the book folder, skipping ones already '
      'there', () async {
    final book = Audiobook.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(bookJson('1', 'Hound')))));
    final folder = Directory(audiobookFolder(temp.path, book))
      ..createSync(recursive: true);
    final existing = File(
        '${folder.path}${Platform.pathSeparator}01 - Part 1 A B.mp3')
      ..writeAsStringSync('already here');

    final job = manager.enqueue(book, temp.path);
    await manager.idle();

    expect(job.status, AudiobookDownloadStatus.completed);
    expect(job.chaptersDone, 2);
    expect(job.progress, 1);
    expect(existing.readAsStringSync(), 'already here');
    final second =
        File('${folder.path}${Platform.pathSeparator}02 - Part 2 A B.mp3');
    expect(second.lengthSync(), 1000);
    expect(folder.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    expect(requested.where((u) => u.path.endsWith('.mp3')).length, 1);
  });

  test('a failing chapter fails the job and leaves no partial file', () async {
    final book = Audiobook.fromJson(Map<String, dynamic>.from(
        jsonDecode(jsonEncode(bookJson('fail', 'Broken')))));
    final job = manager.enqueue(book, temp.path);
    await manager.idle();
    expect(job.status, AudiobookDownloadStatus.failed);
    expect(job.chaptersDone, 1);
    expect(job.error, contains('500'));
    final names = Directory(job.folder)
        .listSync()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toList();
    expect(names, ['01 - Part 1 A B.mp3']);
  });

  testWidgets('the page searches, opens a book and queues a chapter',
      (tester) async {
    manager.rootFolderOverride = () async => temp.path;
    await tester.pumpWidget(const MaterialApp(home: AudiobooksPage()));
    await tester.enterText(find.byType(TextField), 'adventures');
    await tester.tap(find.byTooltip('Search'));
    for (var i = 0; i < 10 && find.text('Adventures (abridged)').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text('Adventures (abridged)'), findsOneWidget);
    expect(find.textContaining('Arthur Conan Doyle · 1h 05m · 2 chapters'),
        findsOneWidget);

    await tester.tap(find.text('Adventures (abridged)'));
    await tester.pumpAndSettle();
    expect(find.text('A tale & more.'), findsOneWidget);
    expect(find.byTooltip('Download chapter'), findsNWidgets(2));
    expect(find.text('Download book'), findsOneWidget);

    await tester.tap(find.byTooltip('Download chapter').last);
    for (var i = 0; i < 20 && manager.jobs.value.isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(manager.jobs.value.single.chapters.single.number, 2);
    // The download's file I/O runs in the widget zone: give it real time.
    for (var i = 0; i < 200 && manager.jobs.value.single.isActive; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(manager.jobs.value.single.status, AudiobookDownloadStatus.completed);
    expect(find.textContaining('Saved in'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // let the snack bar go
  });
}
