import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'log_service.dart';
import 'media_scanner_service.dart';
import 'mp3_downloader_service.dart'
    show defaultDownloadFolder, describeFolderProblem;

/// One chapter (LibriVox calls it a section) of an [Audiobook]: one MP3.
class AudiobookChapter {
  const AudiobookChapter({
    required this.number,
    required this.title,
    required this.url,
    this.duration,
    this.reader = '',
  });

  final int number;
  final String title;

  /// The 64 kbps MP3 on archive.org, always https.
  final String url;
  final Duration? duration;
  final String reader;

  static AudiobookChapter? fromJson(Map<String, dynamic> json, int index) {
    final url = _https(json['listen_url'] as String? ?? '');
    if (url.isEmpty) return null;
    final number = int.tryParse('${json['section_number'] ?? ''}') ?? index + 1;
    final title = _clean(json['title'] as String? ?? '');
    final seconds = int.tryParse('${json['playtime'] ?? ''}');
    final readers = json['readers'];
    var reader = '';
    if (readers is List && readers.isNotEmpty && readers.first is Map) {
      reader = '${(readers.first as Map)['display_name'] ?? ''}'.trim();
    }
    return AudiobookChapter(
      number: number,
      title: title.isEmpty ? 'Chapter $number' : title,
      url: url,
      duration: seconds == null || seconds <= 0
          ? null
          : Duration(seconds: seconds),
      reader: reader,
    );
  }
}

/// A free, public-domain audiobook from LibriVox (read by volunteers, the
/// MP3s are hosted on archive.org).
class Audiobook {
  const Audiobook({
    required this.id,
    required this.title,
    required this.authors,
    this.description = '',
    this.language = '',
    this.year,
    this.totalTime,
    this.chapters = const [],
    this.zipUrl = '',
    this.pageUrl = '',
  });

  final String id;
  final String title;
  final List<String> authors;

  /// Plain text (LibriVox sends HTML).
  final String description;
  final String language;
  final int? year;
  final Duration? totalTime;
  final List<AudiobookChapter> chapters;
  final String zipUrl;
  final String pageUrl;

  String get authorLine => authors.isEmpty ? 'Unknown author' : authors.join(', ');

  static Audiobook fromJson(Map<String, dynamic> json) {
    final authors = <String>[];
    final rawAuthors = json['authors'];
    if (rawAuthors is List) {
      for (final a in rawAuthors.whereType<Map>()) {
        final name = '${a['first_name'] ?? ''} ${a['last_name'] ?? ''}'.trim();
        if (name.isNotEmpty) authors.add(name);
      }
    }
    final chapters = <AudiobookChapter>[];
    final rawSections = json['sections'];
    if (rawSections is List) {
      var i = 0;
      for (final s in rawSections.whereType<Map>()) {
        final chapter =
            AudiobookChapter.fromJson(Map<String, dynamic>.from(s), i++);
        if (chapter != null) chapters.add(chapter);
      }
      chapters.sort((a, b) => a.number.compareTo(b.number));
    }
    final seconds = int.tryParse('${json['totaltimesecs'] ?? ''}');
    return Audiobook(
      id: '${json['id'] ?? ''}',
      title: _clean(json['title'] as String? ?? 'Untitled'),
      authors: authors,
      description: _clean(json['description'] as String? ?? ''),
      language: '${json['language'] ?? ''}'.trim(),
      year: int.tryParse('${json['copyright_year'] ?? ''}'),
      totalTime:
          seconds == null || seconds <= 0 ? null : Duration(seconds: seconds),
      chapters: chapters,
      zipUrl: _https(json['url_zip_file'] as String? ?? ''),
      pageUrl: _https(json['url_librivox'] as String? ?? ''),
    );
  }
}

/// "1h 05m", "42m", "35s".
String formatAudiobookDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m';
  return '${d.inSeconds}s';
}

/// Strips HTML tags and entities and collapses whitespace.
String _clean(String html) {
  var s = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  return s.trim();
}

String _https(String url) {
  final u = url.trim();
  return u.startsWith('http://') ? 'https://${u.substring(7)}' : u;
}

/// Makes [name] safe as a file or folder name on Android and Windows.
@visibleForTesting
String safeFileName(String name) {
  var s = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1).trim();
  }
  if (s.length > 120) s = s.substring(0, 120).trim();
  return s.isEmpty ? 'Untitled' : s;
}

/// The folder a book is saved in: "Author - Title" under [root]/Audiobooks.
String audiobookFolder(String root, Audiobook book) {
  final sep = Platform.pathSeparator;
  final base = root.endsWith(sep) ? root.substring(0, root.length - 1) : root;
  final author = book.authors.isEmpty ? '' : '${book.authors.first} - ';
  return '$base${sep}Audiobooks$sep${safeFileName('$author${book.title}')}';
}

/// "03 - The Red-Headed League.mp3": numbered so the files sort in order.
String audiobookChapterFileName(AudiobookChapter chapter, int chapterCount) {
  final width = chapterCount.toString().length < 2
      ? 2
      : chapterCount.toString().length;
  final number = chapter.number.toString().padLeft(width, '0');
  return '$number - ${safeFileName(chapter.title)}.mp3';
}

class AudiobookException implements Exception {
  AudiobookException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tools → Audiobooks: searches LibriVox's catalogue of free, public-domain
/// audiobooks (no API key) and downloads a book chapter by chapter.
class AudiobookService {
  AudiobookService._();

  static final AudiobookService instance = AudiobookService._();

  /// Replaced in tests.
  http.Client? client;

  static const String _api = 'https://librivox.org/api/feed/audiobooks/';

  void _log(String message) => LogService.add('Audiobooks', message);

  Future<List<Audiobook>> _query(
    http.Client httpClient,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse(_api).replace(queryParameters: {
      ...params,
      'format': 'json',
      'extended': '1',
      'limit': '25',
    });
    final http.Response response;
    try {
      response = await httpClient.get(uri).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw AudiobookException('Could not reach LibriVox: $e');
    }
    // No match is a 404 with {"error": "Audiobooks could not be found"}.
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw AudiobookException('LibriVox answered ${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw AudiobookException('LibriVox sent something unreadable');
    }
    if (decoded is! Map || decoded['books'] is! List) return const [];
    return (decoded['books'] as List)
        .whereType<Map>()
        .map((b) => Audiobook.fromJson(Map<String, dynamic>.from(b)))
        .where((b) => b.id.isNotEmpty)
        .toList();
  }

  /// Books whose title contains [query], then books by an author whose last
  /// name is [query] (or its last word), without duplicates. Books with no
  /// chapters (not finished yet on LibriVox) are left out.
  Future<List<Audiobook>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final httpClient = client ?? http.Client();
    try {
      final lastWord = q.split(RegExp(r'\s+')).last;
      final results = await Future.wait([
        _query(httpClient, {'title': q}),
        _query(httpClient, {'author': lastWord}),
      ]);
      final seen = <String>{};
      final books = <Audiobook>[
        for (final list in results)
          for (final b in list)
            if (b.chapters.isNotEmpty && seen.add(b.id)) b,
      ];
      _log('Search "$q": ${books.length} books');
      return books;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Saves [chapter] as [file], reporting bytes as they arrive. Writes to a
  /// `.part` file first so a cancelled or failed chapter leaves nothing that
  /// looks finished.
  Future<void> downloadChapter(
    AudiobookChapter chapter,
    File file, {
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final httpClient = client ?? http.Client();
    final part = File('${file.path}.part');
    IOSink? sink;
    try {
      final response = await httpClient
          .send(http.Request('GET', Uri.parse(chapter.url)))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw AudiobookException(
            'Chapter ${chapter.number}: server answered ${response.statusCode}');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      sink = part.openWrite();
      await for (final bytes
          in response.stream.timeout(const Duration(seconds: 60))) {
        if (cancelled?.call() ?? false) {
          throw AudiobookException('Cancelled');
        }
        sink.add(bytes);
        received += bytes.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      if (e is AudiobookException) rethrow;
      throw AudiobookException('Chapter ${chapter.number}: $e');
    } finally {
      if (client == null) httpClient.close();
    }
  }
}

enum AudiobookDownloadStatus { queued, running, completed, failed, cancelled }

/// One book (or some of its chapters) being saved.
class AudiobookDownloadJob {
  AudiobookDownloadJob({
    required this.id,
    required this.book,
    required this.chapters,
    required this.folder,
  });

  final String id;
  final Audiobook book;
  final List<AudiobookChapter> chapters;
  final String folder;

  AudiobookDownloadStatus status = AudiobookDownloadStatus.queued;
  int chaptersDone = 0;

  /// Bytes of the chapter being downloaded right now.
  int chapterReceived = 0;
  int chapterTotal = 0;
  String? error;
  DateTime? startedAt;

  bool get isActive =>
      status == AudiobookDownloadStatus.queued ||
      status == AudiobookDownloadStatus.running;

  /// 0..1 over the whole job: whole chapters plus the current one's share.
  double get progress {
    if (chapters.isEmpty) return 1;
    final current = chapterTotal > 0
        ? (chapterReceived / chapterTotal).clamp(0.0, 1.0)
        : 0.0;
    return ((chaptersDone + current) / chapters.length).clamp(0.0, 1.0);
  }
}

/// App-level queue for audiobook downloads, so leaving Tools → Audiobooks
/// doesn't stop one. Books download one at a time, chapter by chapter;
/// chapters already in the folder are skipped, so downloading a book again
/// after a failure picks up where it stopped.
class AudiobookDownloadManager {
  AudiobookDownloadManager._();

  static final AudiobookDownloadManager instance =
      AudiobookDownloadManager._();

  /// Newest first.
  final ValueNotifier<List<AudiobookDownloadJob>> jobs =
      ValueNotifier<List<AudiobookDownloadJob>>(<AudiobookDownloadJob>[]);

  final Set<String> _cancelRequests = <String>{};
  bool _draining = false;

  /// Replaced in tests; defaults to the MP3 Downloader's folder.
  @visibleForTesting
  Future<String?> Function()? rootFolderOverride;

  void _log(String message) => LogService.add('Audiobooks', message);

  void _publish() {
    jobs.value = List<AudiobookDownloadJob>.from(jobs.value);
  }

  /// Where books go: `<MP3 Downloader folder>/Audiobooks/<Author - Title>`.
  Future<String?> rootFolder(String configuredFolder) async {
    if (rootFolderOverride != null) return rootFolderOverride!();
    final configured = configuredFolder.trim();
    if (configured.isNotEmpty) return configured;
    return defaultDownloadFolder();
  }

  /// Queues [book] (or just [only] of its chapters) for saving under [root].
  AudiobookDownloadJob enqueue(
    Audiobook book,
    String root, {
    List<AudiobookChapter>? only,
  }) {
    final job = AudiobookDownloadJob(
      id: '${DateTime.now().microsecondsSinceEpoch}-${book.id}',
      book: book,
      chapters: only ?? book.chapters,
      folder: audiobookFolder(root, book),
    );
    jobs.value = [job, ...jobs.value];
    _log('Queued "${book.title}" (${job.chapters.length} chapters) '
        '-> ${job.folder}');
    unawaited(_drain());
    return job;
  }

  void cancel(String jobId) {
    for (final job in jobs.value) {
      if (job.id != jobId || !job.isActive) continue;
      if (job.status == AudiobookDownloadStatus.queued) {
        job.status = AudiobookDownloadStatus.cancelled;
        _publish();
      } else {
        _cancelRequests.add(jobId);
      }
    }
  }

  /// Drops every finished job from the list.
  void clearFinished() {
    jobs.value = jobs.value.where((j) => j.isActive).toList();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final next = jobs.value.cast<AudiobookDownloadJob?>().lastWhere(
              (j) => j!.status == AudiobookDownloadStatus.queued,
              orElse: () => null,
            );
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(AudiobookDownloadJob job) async {
    job.status = AudiobookDownloadStatus.running;
    job.startedAt = DateTime.now();
    _publish();
    final service = AudiobookService.instance;
    try {
      try {
        await Directory(job.folder).create(recursive: true);
      } catch (e) {
        throw AudiobookException(describeFolderProblem(job.folder, e));
      }
      final count = job.book.chapters.length;
      for (final chapter in job.chapters) {
        if (_cancelRequests.contains(job.id)) {
          throw AudiobookException('Cancelled');
        }
        final file = File('${job.folder}${Platform.pathSeparator}'
            '${audiobookChapterFileName(chapter, count)}');
        job.chapterReceived = 0;
        job.chapterTotal = 0;
        if (!await file.exists()) {
          await service.downloadChapter(
            chapter,
            file,
            onProgress: (received, total) {
              job.chapterReceived = received;
              job.chapterTotal = total;
              _publish();
            },
            cancelled: () => _cancelRequests.contains(job.id),
          );
          await MediaScannerService.scanFile(file.path);
        }
        job.chaptersDone++;
        job.chapterReceived = 0;
        job.chapterTotal = 0;
        _publish();
      }
      job.status = AudiobookDownloadStatus.completed;
      _log('Saved "${job.book.title}" to ${job.folder}');
    } catch (e) {
      if (_cancelRequests.contains(job.id)) {
        job.status = AudiobookDownloadStatus.cancelled;
      } else {
        job.status = AudiobookDownloadStatus.failed;
        job.error = e is AudiobookException ? e.message : e.toString();
        _log('"${job.book.title}" failed: ${job.error}');
      }
    } finally {
      _cancelRequests.remove(job.id);
      _publish();
    }
  }

  /// Resolves when no job is queued or running (for tests).
  @visibleForTesting
  Future<void> idle() async {
    while (_draining) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @visibleForTesting
  void resetForTest() {
    jobs.value = <AudiobookDownloadJob>[];
    _cancelRequests.clear();
    _draining = false;
    rootFolderOverride = null;
  }
}
