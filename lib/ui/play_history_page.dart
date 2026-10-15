import 'package:flutter/material.dart';

import '../services/play_history_service.dart';
import 'now_playing_highlight.dart';
import 'subpage_app_bar.dart';

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

/// "14:05".
String playHistoryTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Tools → Play history: every song and Subscriptions video that started
/// playing in the last 90 days, newest first, under a header per month and
/// per day. Entries can be deleted one by one, a whole day at a time, or
/// all at once.
class PlayHistoryPage extends StatelessWidget {
  const PlayHistoryPage({super.key});

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
    DateTime? month;
    DateTime? day;
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
        rows.add(ListTile(
          dense: true,
          title:
              Text(playHistoryDayLabel(at), style: theme.textTheme.titleSmall),
          subtitle: Text('$count played'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete this day',
            onPressed: () => PlayHistoryService.instance.deleteDay(thisDay),
          ),
        ));
      }
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
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Delete from history',
            onPressed: () => PlayHistoryService.instance.delete(entry.id),
          ),
        ),
      ));
    }
    return rows;
  }
}
