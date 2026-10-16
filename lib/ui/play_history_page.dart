import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/music_library_service.dart';
import '../services/music_player_service.dart';
import '../services/play_history_service.dart';
import '../services/youtube_feed_service.dart';
import 'music_player_page.dart' show showAddToPlaylistSheet;
import 'now_playing_highlight.dart';
import 'subpage_app_bar.dart';
import 'track_metadata_page.dart';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];
const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];

/// "October 2026".
String playHistoryMonthLabel(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// "Today", "Yesterday" or "Thursday 15 October".
String playHistoryDayLabel(DateTime d, {DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(d);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

const _shortWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Thu 15.10.26".
String playHistoryShortDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_shortWeekdays[d.weekday - 1]} ${two(d.day)}.${two(d.month)}.'
      '${two(d.year % 100)}';
}

/// "14:05".
String playHistoryTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Tools → Play history: every song and Subscriptions video that started
/// playing in the last 90 days, newest first, under a header per month and
/// per day. A day's header folds its songs away (only the newest day starts
/// open). Entries can be deleted one by one, a whole day at a time, or all
/// at once.
class PlayHistoryPage extends StatefulWidget {
  const PlayHistoryPage({super.key});

  @override
  State<PlayHistoryPage> createState() => _PlayHistoryPageState();
}

class _PlayHistoryPageState extends State<PlayHistoryPage> {
  /// Days opened or closed by hand; every other day follows the default
  /// (open only for the newest day).
  final Map<DateTime, bool> _open = {};

  bool _isOpen(DateTime day, DateTime newest) => _open[day] ?? day == newest;

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear play history?'),
        content: const Text('Every entry is deleted. Play counts on your '
            'songs are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await PlayHistoryService.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PlayHistoryEntry>>(
      valueListenable: PlayHistoryService.instance.entries,
      builder: (context, entries, _) {
        return Scaffold(
          appBar: buildSubpageAppBar(
            context,
            title: 'Play history',
            actions: [
              if (entries.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  tooltip: 'Clear history',
                  onPressed: () => _confirmClear(context),
                ),
            ],
          ),
          body: entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing played yet. Songs and videos you play show up '
                      'here and are kept for 90 days.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(children: _rows(context, entries)),
        );
      },
    );
  }

  List<Widget> _rows(BuildContext context, List<PlayHistoryEntry> entries) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    final newest = DateUtils.dateOnly(entries.first.playedAt);
    DateTime? month;
    DateTime? day;
    var dayOpen = true;
    for (final entry in entries) {
      final at = entry.playedAt;
      if (month == null || month.year != at.year || month.month != at.month) {
        month = DateTime(at.year, at.month);
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            playHistoryMonthLabel(at),
            style: theme.textTheme.titleLarge
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ));
      }
      if (day == null || !DateUtils.isSameDay(day, at)) {
        day = DateUtils.dateOnly(at);
        final thisDay = day;
        final count = entries
            .where((e) => DateUtils.isSameDay(e.playedAt, thisDay))
            .length;
        dayOpen = _isOpen(thisDay, newest);
        final open = dayOpen;
        rows.add(ListTile(
          key: ValueKey('day-$thisDay'),
          dense: true,
          leading: Icon(open ? Icons.expand_less : Icons.expand_more,
              semanticLabel: open ? 'Fold this day' : 'Unfold this day'),
          title:
              Text(playHistoryDayLabel(at), style: theme.textTheme.titleSmall),
          subtitle: Text('${playHistoryShortDate(at)} · $count played'),
          onTap: () => setState(() => _open[thisDay] = !open),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete this day',
            onPressed: () => PlayHistoryService.instance.deleteDay(thisDay),
          ),
        ));
      }
      if (!dayOpen) continue;
      rows.add(NowPlayingHighlight(
        key: ValueKey(entry.id),
        trackId: entry.trackId,
        builder: (context, isCurrent) => ListTile(
          selected: isCurrent,
          leading: isCurrent
              ? nowPlayingIcon
              : Icon(entry.isVideo
                  ? Icons.smart_display_outlined
                  : Icons.music_note_outlined),
          title: Text(entry.title.isEmpty ? 'Unknown' : entry.title,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              playHistoryTime(at),
              if (entry.isVideo) 'Video',
              if (entry.artist.isNotEmpty) entry.artist,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Song info and options',
              onPressed: () => showPlayHistoryEntrySheet(context, entry),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Delete from history',
              onPressed: () => PlayHistoryService.instance.delete(entry.id),
            ),
          ]),
        ),
      ));
    }
    return rows;
  }
}

/// The track a history entry stands for: the library song (null once it's
/// gone from the library), or for a Subscriptions video the feed's copy,
/// else one rebuilt from the entry.
Track? playHistoryTrackOf(PlayHistoryEntry entry) {
  if (!entry.isVideo) return MusicLibraryService.instance.byId(entry.trackId);
  const prefix = 'youtube:';
  if (!entry.trackId.startsWith(prefix)) return null;
  final videoId = entry.trackId.substring(prefix.length);
  for (final v in YoutubeFeedService.instance.videos.value) {
    if (v.videoId == videoId) return YoutubeFeedService.trackFor(v);
  }
  return Track.youtube(
      videoId: videoId, title: entry.title, artist: entry.artist);
}

/// The history row's info button: the song's info page, Play next, Add to
/// queue, Add to playlist and Delete from history. A video gets Add to
/// queue (the video queue) only; a song no longer in the library only
/// Delete.
Future<void> showPlayHistoryEntrySheet(
    BuildContext context, PlayHistoryEntry entry) {
  final track = playHistoryTrackOf(entry);
  final canQueue = track != null && MusicPlayerService.isReady;
  void done(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      void close() => Navigator.of(sheetContext).pop();
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(entry.title.isEmpty ? 'Unknown' : entry.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (entry.isVideo) 'Video',
                  if (entry.artist.isNotEmpty) entry.artist,
                  if (track == null) 'no longer in your library',
                ].join(' · '),
              ),
            ),
            const Divider(height: 1),
            if (track != null && !entry.isVideo)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Song info'),
                subtitle: const Text('Details, plays, skips and swipes'),
                onTap: () {
                  close();
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TrackMetadataPage(trackId: track.id)));
                },
              ),
            if (canQueue && !entry.isVideo)
              ListTile(
                leading: const Icon(Icons.queue_play_next),
                title: const Text('Play next'),
                onTap: () async {
                  close();
                  await MusicPlayerService.handler
                      .addToMusicQueue(track, playNext: true);
                  done('Plays next');
                },
              ),
            if (canQueue)
              ListTile(
                leading: const Icon(Icons.add_to_queue),
                title: const Text('Add to queue'),
                onTap: () async {
                  close();
                  final handler = MusicPlayerService.handler;
                  if (entry.isVideo) {
                    final added = await handler.addToVideoQueue(track);
                    done(added
                        ? 'Added to the video queue'
                        : 'Already in the video queue');
                  } else {
                    await handler.addToMusicQueue(track);
                    done('Added to the queue');
                  }
                },
              ),
            if (track != null && !entry.isVideo)
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Add to playlist'),
                onTap: () {
                  close();
                  if (context.mounted) showAddToPlaylistSheet(context, track);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete from history'),
              onTap: () {
                close();
                PlayHistoryService.instance.delete(entry.id);
              },
            ),
          ],
        ),
      );
    },
  );
}
