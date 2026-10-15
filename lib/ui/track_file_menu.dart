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

/// "Move to folder" from a song's ⋮ menu: picks one of the music folder's
/// (or the server's) folders, or a new one, and moves the song there.
Future<void> pickFolderAndMove(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  final folders = await TrackFileActions.instance.foldersFor(track);
  if (!context.mounted) return;
  final current = TrackFileActions.folderOf(track);
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
              title: Text('Move "${track.title}" to',
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
  if (picked == null) return;
  final error = await TrackFileActions.instance.move(track, picked);
  final to = TrackFileActions.cleanFolder(picked);
  final where = to.isEmpty ? 'the top folder' : to;
  messenger.showSnackBar(SnackBar(
      content: Text(error ??
          (track.source == TrackSource.subsonic
              ? 'Moved "${track.title}" to $where — it plays again after the '
                  'server\'s next scan (tonight, or Scan server)'
              : 'Moved "${track.title}" to $where'))));
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
