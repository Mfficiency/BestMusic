import 'package:flutter/material.dart';

import '../models/music_playlist.dart';
import '../models/track.dart';
import '../services/music_player_service.dart';
import '../services/music_playlist_service.dart';
import '../services/speaker_play_guard.dart';
import '../services/track_file_actions.dart';
import 'music_player_page.dart' show promptPlaylistName;
import 'now_playing_page.dart';
import 'track_file_menu.dart';

/// The bar a song list shows instead of its sort/play row while songs are
/// selected (tap a row's music icon, or long-press the row): how many are
/// selected, Cancel, Select all / Select none, Play, Add to playlist, and
/// a ⋮ menu with Play next, Add to queue, Add to Favorites, Remove from
/// playlist (inside a hand-made playlist), Move to folder and Delete.
/// [selected] is in the list's order; [onClear] ends the selection, which
/// every action except Select all does when it's done.
class TrackSelectionBar extends StatelessWidget {
  const TrackSelectionBar({
    super.key,
    required this.selected,
    required this.total,
    required this.onSelectAll,
    required this.onClear,
    this.onRemove,
  });

  final List<Track> selected;

  /// How many songs the list has — Select all becomes Select none once all
  /// of them are selected.
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  /// "Remove from playlist", only inside a playlist that can be edited.
  final void Function(List<Track> tracks)? onRemove;

  bool get _all => selected.length >= total;

  Future<void> _play(BuildContext context) async {
    if (!await SpeakerPlayGuard.confirmPlay(context)) return;
    await MusicPlayerService.playQueue(selected);
    onClear();
    if (context.mounted) Navigator.of(context).push(NowPlayingPage.route());
  }

  Future<void> _queue(BuildContext context, {required bool playNext}) async {
    final messenger = ScaffoldMessenger.of(context);
    await MusicPlayerService.handler
        .addAllToMusicQueue(selected, playNext: playNext);
    messenger.showSnackBar(SnackBar(
        content: Text(playNext
            ? '${_songs(selected.length)} will play next'
            : 'Added ${_songs(selected.length)} to the queue')));
    onClear();
  }

  Future<void> _favorite(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await MusicPlaylistService.instance
        .addAllToFavorites(selected.map((t) => t.id));
    messenger.showSnackBar(SnackBar(
        content: Text('Added ${_songs(selected.length)} to Favorites')));
    onClear();
  }

  Future<void> _onMenu(BuildContext context, String value) async {
    switch (value) {
      case 'next':
        await _queue(context, playNext: true);
      case 'queue':
        await _queue(context, playNext: false);
      case 'favorite':
        await _favorite(context);
      case 'remove':
        onRemove?.call(selected);
        onClear();
      case 'move':
        if (await pickFolderAndMoveTracks(context, selected)) onClear();
      case 'delete':
        if (await confirmAndDeleteTracks(context, selected)) onClear();
    }
  }

  static PopupMenuItem<String> _item(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canDelete =
        selected.isNotEmpty && selected.every(TrackFileActions.canManage);
    return Material(
      color: scheme.secondaryContainer,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel selection',
            onPressed: onClear,
          ),
          Expanded(
            child: Text('${selected.length} selected',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: Icon(_all ? Icons.deselect : Icons.select_all),
            tooltip: _all ? 'Select none' : 'Select all',
            onPressed: _all ? onClear : onSelectAll,
          ),
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Play selected',
            onPressed: () => _play(context),
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add selected to playlist',
            onPressed: () async {
              if (await showAddTracksToPlaylistSheet(context, selected)) {
                onClear();
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More for selected',
            onSelected: (value) => _onMenu(context, value),
            itemBuilder: (context) => [
              _item('next', Icons.queue_play_next, 'Play next'),
              _item('queue', Icons.add_to_queue, 'Add to queue'),
              _item('favorite', Icons.favorite_border, 'Add to Favorites'),
              if (onRemove != null)
                _item('remove', Icons.remove_circle_outline,
                    'Remove from playlist'),
              if (canMoveTogether(selected))
                _item('move', Icons.drive_file_move_outline, 'Move to folder'),
              if (canDelete) _item('delete', Icons.delete_outline, 'Delete'),
            ],
          ),
        ],
      ),
    );
  }
}

String _songs(int n) => n == 1 ? '1 song' : '$n songs';

/// "Add to playlist" for several songs: New playlist (with all of them),
/// or tap one of your playlists to add them to it (songs already in it
/// aren't added twice). Returns whether they went somewhere.
Future<bool> showAddTracksToPlaylistSheet(
    BuildContext context, List<Track> tracks) async {
  final ids = [for (final t in tracks) t.id];
  final messenger = ScaffoldMessenger.of(context);
  final picked = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
        child: ValueListenableBuilder<List<MusicPlaylist>>(
          valueListenable: MusicPlaylistService.instance.playlists,
          builder: (_, playlists, __) {
            final regular = playlists
                .where((p) => p.kind == PlaylistKind.list && !p.isSystem)
                .toList();
            return ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text('Add ${_songs(tracks.length)} to',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('New playlist'),
                  onTap: () => Navigator.of(sheetContext).pop(true),
                ),
                if (regular.isNotEmpty) const Divider(height: 1),
                for (final playlist in regular)
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(playlist.name),
                    subtitle: ids.every(playlist.trackIds.contains)
                        ? const Text('Already in it')
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(playlist),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
  if (picked is MusicPlaylist) {
    await MusicPlaylistService.instance.addAllTo(picked.id, ids);
    messenger.showSnackBar(SnackBar(
        content: Text('Added ${_songs(tracks.length)} to ${picked.name}')));
    return true;
  }
  if (picked == true) {
    // Prompted on the caller's context: the sheet's is gone by now.
    if (!context.mounted) return false;
    final name = await promptPlaylistName(context);
    if (name == null || name.trim().isEmpty) return false;
    await MusicPlaylistService.instance.createPlaylist(name.trim(), ids);
    messenger.showSnackBar(
        SnackBar(content: Text('Made "${name.trim()}" with ${_songs(tracks.length)}')));
    return true;
  }
  return false;
}

/// Selecting songs in a list (the state behind [TrackSelectionBar]): a
/// song row's music icon becomes a [selectionLeading] that selects it, a
/// long-press selects too, and while a selection is going a row tap
/// selects or unselects ([selectionTap]) and the system back gesture ends
/// it ([selectionScope]).
mixin TrackSelection<W extends StatefulWidget> on State<W> {
  final Set<String> selectedIds = {};

  bool get selecting => selectedIds.isNotEmpty;

  void toggleSelected(Track track) => setState(() {
        if (!selectedIds.remove(track.id)) selectedIds.add(track.id);
      });

  void clearSelection() => setState(selectedIds.clear);

  /// Forgets selected songs no longer in [tracks] (deleted, removed).
  void keepSelectedIn(Iterable<Track> tracks) {
    if (!selecting) return;
    final ids = {for (final t in tracks) t.id};
    selectedIds.removeWhere((id) => !ids.contains(id));
  }

  /// The bar for a list showing [shown], in that order.
  Widget selectionBar(List<Track> shown,
          {void Function(List<Track> tracks)? onRemove}) =>
      TrackSelectionBar(
        selected: [
          for (final t in shown)
            if (selectedIds.contains(t.id)) t
        ],
        total: shown.length,
        onSelectAll: () =>
            setState(() => selectedIds.addAll(shown.map((t) => t.id))),
        onClear: clearSelection,
        onRemove: onRemove,
      );

  /// A row's leading icon: [icon] (tap it to select the song) normally, a
  /// tick / empty circle while selecting.
  Widget selectionLeading(BuildContext context, Track track, Widget icon) {
    if (selecting) {
      final isSelected = selectedIds.contains(track.id);
      return Icon(
        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: isSelected ? Theme.of(context).colorScheme.primary : null,
      );
    }
    return InkResponse(
      onTap: () => toggleSelected(track),
      radius: 24,
      child: Tooltip(message: 'Select', child: icon),
    );
  }

  /// A row tap: [play] normally, select/unselect while selecting.
  VoidCallback selectionTap(Track track, VoidCallback play) =>
      selecting ? () => toggleSelected(track) : play;

  bool isSelected(Track track) => selectedIds.contains(track.id);

  /// Back ends a selection before it leaves the page.
  Widget selectionScope({required Widget child}) => PopScope(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) clearSelection();
        },
        child: child,
      );
}
