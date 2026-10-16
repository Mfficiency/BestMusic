import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/track_file_actions.dart';

/// "Delete" from a song's ⋮ menu: asks first (it can't be undone), then
/// deletes the file on the phone or on the music server.
Future<void> confirmAndDeleteTrack(BuildContext context, Track track) async {
  final onServer = track.source == TrackSource.subsonic;
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this song?'),
      content: Text('"${track.title}" is deleted '
          '${onServer ? 'from the music server' : 'from this phone'} and '
          'taken out of every playlist. This can\'t be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete')),
      ],
    ),
  );
  if (confirmed != true) return;
  final error = await TrackFileActions.instance.delete(track);
  messenger.showSnackBar(
      SnackBar(content: Text(error ?? 'Deleted "${track.title}"')));
}

/// "Delete" for several selected songs at once: one question, then each
/// song is deleted in turn. Returns whether the user went ahead.
Future<bool> confirmAndDeleteTracks(
    BuildContext context, List<Track> tracks) async {
  if (tracks.isEmpty) return false;
  if (tracks.length == 1) {
    await confirmAndDeleteTrack(context, tracks.single);
    return true;
  }
  final onServer = tracks.where((t) => t.source == TrackSource.subsonic).length;
  final where = onServer == 0
      ? 'from this phone'
      : onServer == tracks.length
          ? 'from the music server'
          : 'from this phone and the music server';
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete ${tracks.length} songs?'),
      content: Text('They are deleted $where and taken out of every '
          'playlist. This can\'t be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete')),
      ],
    ),
  );
  if (confirmed != true) return false;
  final errors = <String>[];
  for (final track in tracks) {
    final error = await TrackFileActions.instance.delete(track);
    if (error != null) errors.add(error);
  }
  final deleted = tracks.length - errors.length;
  messenger.showSnackBar(SnackBar(
      content: Text(errors.isEmpty
          ? 'Deleted $deleted songs'
          : 'Deleted $deleted of ${tracks.length} songs. ${errors.first}')));
  return true;
}

/// "Move to folder" from a song's ⋮ menu: picks one of the music folder's
/// (or the server's) folders, or a new one, and moves the song there.
Future<void> pickFolderAndMove(BuildContext context, Track track) =>
    pickFolderAndMoveTracks(context, [track]);

/// Whether [tracks] can be moved together: all phone songs, or all server
/// songs (the two have different folders).
bool canMoveTogether(List<Track> tracks) =>
    tracks.isNotEmpty &&
    tracks.every(TrackFileActions.canManage) &&
    tracks.every((t) => t.source == tracks.first.source);

/// "Move to folder" for one or more songs (all phone songs or all server
/// songs, see [canMoveTogether]). Returns whether a folder was picked.
Future<bool> pickFolderAndMoveTracks(
    BuildContext context, List<Track> tracks) async {
  if (!canMoveTogether(tracks)) return false;
  final track = tracks.first;
  final messenger = ScaffoldMessenger.of(context);
  final folders = await TrackFileActions.instance.foldersFor(track);
  if (!context.mounted) return false;
  // The folder they're all in, if they share one (not offered as a target).
  final here = tracks.map(TrackFileActions.folderOf).toSet();
  final current = here.length == 1 ? here.single : null;
  final what =
      tracks.length == 1 ? '"${track.title}"' : '${tracks.length} songs';
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Move $what to',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder…'),
              onTap: () async {
                final name = await showDialog<String>(
                  context: sheetContext,
                  builder: (_) => const _NewFolderDialog(),
                );
                if (name != null && sheetContext.mounted) {
                  Navigator.pop(sheetContext, name);
                }
              },
            ),
            const Divider(height: 1),
            for (final f in folders)
              ListTile(
                leading: Icon(f == current
                    ? Icons.folder_open
                    : Icons.folder_outlined),
                title: Text(f.isEmpty ? '(Top folder)' : f),
                subtitle: f == current ? const Text('Here now') : null,
                enabled: f != current,
                onTap: () => Navigator.pop(sheetContext, f),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return false;
  final to = TrackFileActions.cleanFolder(picked);
  final where = to.isEmpty ? 'the top folder' : to;
  final errors = <String>[];
  for (final t in tracks) {
    if (TrackFileActions.folderOf(t) == to) continue;
    final error = await TrackFileActions.instance.move(t, picked);
    if (error != null) errors.add(error);
  }
  final onServer = track.source == TrackSource.subsonic;
  final String message;
  if (tracks.length == 1) {
    message = errors.isNotEmpty
        ? errors.first
        : onServer
            ? 'Moved "${track.title}" to $where — it plays again after the '
                'server\'s next scan (tonight, or Scan server)'
            : 'Moved "${track.title}" to $where';
  } else {
    final moved = tracks.length - errors.length;
    message = errors.isNotEmpty
        ? 'Moved $moved of ${tracks.length} songs to $where. ${errors.first}'
        : onServer
            ? 'Moved ${tracks.length} songs to $where — they play again '
                'after the server\'s next scan (tonight, or Scan server)'
            : 'Moved ${tracks.length} songs to $where';
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
  return true;
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = TrackFileActions.cleanFolder(_controller.text);
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
            labelText: 'Folder name', hintText: 'e.g. Chill or Party/2026'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Move here')),
      ],
    );
  }
}
