import 'package:flutter/material.dart';

import '../config.dart';
import '../services/audiobook_service.dart';
import 'remaining_time_text.dart';
import 'subpage_app_bar.dart';

/// Tools → Audiobooks: search LibriVox's free, public-domain audiobooks by
/// title or author and download a whole book (or single chapters) as MP3s
/// into `<MP3 Downloader folder>/Audiobooks/<Author - Title>`.
class AudiobooksPage extends StatefulWidget {
  const AudiobooksPage({super.key});

  @override
  State<AudiobooksPage> createState() => _AudiobooksPageState();
}

class _AudiobooksPageState extends State<AudiobooksPage> {
  final TextEditingController _query = TextEditingController();
  List<Audiobook>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final books = await AudiobookService.instance.search(q);
      if (!mounted) return;
      setState(() => _results = books);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: 'Audiobooks'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: 'Title or author',
                      prefixIcon: Icon(Icons.menu_book_outlined),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: _searching ? null : _search,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Free public-domain audiobooks from LibriVox, read by volunteers.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const _DownloadsList(),
          if (_searching) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: results == null
                ? const SizedBox.shrink()
                : results.isEmpty
                    ? const Center(child: Text('No audiobooks found'))
                    : ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final book = results[i];
                          return ListTile(
                            title: Text(book.title),
                            subtitle: Text(_bookLine(book)),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AudiobookDetailPage(book: book),
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: 'Download book',
                              icon: const Icon(Icons.download_outlined),
                              onPressed: () =>
                                  startAudiobookDownload(context, book),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

String _bookLine(Audiobook book) {
  final parts = <String>[
    book.authorLine,
    if (book.totalTime != null) formatAudiobookDuration(book.totalTime!),
    '${book.chapters.length} chapters',
    if (book.language.isNotEmpty) book.language,
  ];
  return parts.join(' · ');
}

/// Queues [book] (or [only] some chapters) and says where it goes.
Future<void> startAudiobookDownload(
  BuildContext context,
  Audiobook book, {
  List<AudiobookChapter>? only,
}) async {
  final manager = AudiobookDownloadManager.instance;
  final messenger = ScaffoldMessenger.of(context);
  final root = await manager.rootFolder(Config.mp3DownloadFolder);
  if (root == null) {
    messenger.showSnackBar(const SnackBar(
        content: Text('No folder to save to. Pick one in Settings → '
            'MP3 Downloader.')));
    return;
  }
  final job = manager.enqueue(book, root, only: only);
  messenger.showSnackBar(SnackBar(
    content: Text('Downloading "${book.title}" to ${job.folder}'),
  ));
}

/// The running and finished downloads, above the search results.
class _DownloadsList extends StatelessWidget {
  const _DownloadsList();

  @override
  Widget build(BuildContext context) {
    final manager = AudiobookDownloadManager.instance;
    return ValueListenableBuilder<List<AudiobookDownloadJob>>(
      valueListenable: manager.jobs,
      builder: (context, jobs, _) {
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 0, 0),
                  child: Text('Downloads',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                if (jobs.any((j) => !j.isActive))
                  TextButton(
                    onPressed: manager.clearFinished,
                    child: const Text('Clear finished'),
                  ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView(
                shrinkWrap: true,
                children: [for (final job in jobs) _JobTile(job: job)],
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final AudiobookDownloadJob job;

  @override
  Widget build(BuildContext context) {
    final count = '${job.chaptersDone}/${job.chapters.length} chapters';
    final String status = switch (job.status) {
      AudiobookDownloadStatus.queued => 'Waiting',
      AudiobookDownloadStatus.running => count,
      AudiobookDownloadStatus.completed => 'Saved in ${job.folder}',
      AudiobookDownloadStatus.failed =>
        'Failed ($count): ${job.error ?? 'unknown error'}',
      AudiobookDownloadStatus.cancelled => 'Cancelled ($count)',
    };
    final running = job.status == AudiobookDownloadStatus.running;
    return ListTile(
      dense: true,
      title: Text(job.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          if (running) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: job.progress),
            RemainingTimeText(done: job.progress, startedAt: job.startedAt),
          ],
        ],
      ),
      trailing: job.isActive
          ? IconButton(
              tooltip: 'Cancel download',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  AudiobookDownloadManager.instance.cancel(job.id),
            )
          : null,
    );
  }
}

/// A book's description and chapters, with Download book and a download
/// button per chapter.
class AudiobookDetailPage extends StatelessWidget {
  const AudiobookDetailPage({super.key, required this.book});

  final Audiobook book;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: book.title),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => startAudiobookDownload(context, book),
        icon: const Icon(Icons.download),
        label: const Text('Download book'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          ListTile(
            title: Text(book.title,
                style: Theme.of(context).textTheme.titleLarge),
            subtitle: Text(_bookLine(book)),
          ),
          if (book.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(book.description),
            ),
          const _DownloadsList(),
          for (final chapter in book.chapters)
            ListTile(
              leading: Text('${chapter.number}'),
              title: Text(chapter.title),
              subtitle: Text([
                if (chapter.duration != null)
                  formatAudiobookDuration(chapter.duration!),
                if (chapter.reader.isNotEmpty) 'read by ${chapter.reader}',
              ].join(' · ')),
              trailing: IconButton(
                tooltip: 'Download chapter',
                icon: const Icon(Icons.download_outlined),
                onPressed: () =>
                    startAudiobookDownload(context, book, only: [chapter]),
              ),
            ),
        ],
      ),
    );
  }
}
