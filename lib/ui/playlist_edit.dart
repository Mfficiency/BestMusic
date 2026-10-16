import 'package:flutter/material.dart';

import '../models/music_playlist.dart';
import '../models/track.dart';
import '../services/music_library_service.dart';
import '../services/music_playlist_service.dart';
import 'music_player_page.dart' show AddSongsToPlaylistPage, promptPlaylistName;
import 'now_playing_highlight.dart';
import 'rule_playlist_editor_page.dart';
import 'subpage_app_bar.dart';

/// Asks for a new name and renames [playlist]. Returns whether it changed.
Future<bool> renamePlaylistFlow(
    BuildContext context, MusicPlaylist playlist) async {
  final name = await promptPlaylistName(context,
      title: 'Rename playlist', initial: playlist.name, action: 'Save');
  if (name == null || name.trim().isEmpty || name.trim() == playlist.name) {
    return false;
  }
  await MusicPlaylistService.instance.renamePlaylist(playlist.id, name);
  return true;
}

/// Asks first, then deletes [playlist] (the songs stay in the library).
/// Returns whether it was deleted.
Future<bool> confirmDeletePlaylist(
    BuildContext context, MusicPlaylist playlist) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete "${playlist.name}"?'),
      content: const Text('The playlist is deleted. Its songs stay in your '
          'library.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await MusicPlaylistService.instance.deletePlaylist(playlist.id);
  return true;
}

/// Opens the right editor: the rules editor for a rule playlist, the
/// songs editor (order, remove, add) for a hand-built one.
void openPlaylistEditor(BuildContext context, MusicPlaylist playlist) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => playlist.kind == PlaylistKind.rule
        ? RulePlaylistEditorPage(existing: playlist)
        : EditPlaylistSongsPage(playlistId: playlist.id),
  ));
}

/// Whether [playlist] can be renamed, edited and deleted: every hand-built,
/// imported or rule playlist — not Favorites/"Don't really like" or the
/// computed smart playlists.
bool playlistIsEditable(MusicPlaylist playlist) =>
    !playlist.isSystem &&
    (playlist.kind == PlaylistKind.list || playlist.kind == PlaylistKind.rule);

/// ⋮ menu of a playlist: Rename, Edit songs / Edit rules, Delete. Used on
/// the Playlists tab rows and in a playlist's app bar; [onDeleted] runs
/// after a delete (the playlist page closes itself with it).
class PlaylistOptionsButton extends StatelessWidget {
  const PlaylistOptionsButton(
      {super.key, required this.playlist, this.onDeleted});

  final MusicPlaylist playlist;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final rule = playlist.kind == PlaylistKind.rule;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'Playlist options',
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            await renamePlaylistFlow(context, playlist);
          case 'edit':
            openPlaylistEditor(context, playlist);
          case 'delete':
            if (await confirmDeletePlaylist(context, playlist)) {
              onDeleted?.call();
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.drive_file_rename_outline),
            title: Text('Rename'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(rule ? Icons.rule : Icons.edit_outlined),
            title: Text(rule ? 'Edit rules' : 'Edit songs'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// Edit a hand-built playlist's songs: drag to change the order, remove
/// songs, add more (+). Every change is saved right away.
class EditPlaylistSongsPage extends StatelessWidget {
  const EditPlaylistSongsPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final service = MusicPlaylistService.instance;
    return ValueListenableBuilder<List<MusicPlaylist>>(
      valueListenable: service.playlists,
      builder: (context, _, __) {
        final playlist = service.byId(playlistId);
        if (playlist == null) {
          return Scaffold(
            appBar: buildSubpageAppBar(context, title: 'Edit playlist'),
            body: const Center(child: Text('This playlist is gone.')),
          );
        }
        return ValueListenableBuilder<List<Track>>(
          valueListenable: MusicLibraryService.instance.tracks,
          builder: (context, _, __) {
            final tracks = service.resolvedTracks(playlist);
            return Scaffold(
              appBar: buildSubpageAppBar(
                context,
                title: 'Edit ${playlist.name}',
                actions: [
                  IconButton(
                    icon: const Icon(Icons.drive_file_rename_outline),
                    tooltip: 'Rename',
                    onPressed: () => renamePlaylistFlow(context, playlist),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add songs',
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          AddSongsToPlaylistPage(playlistId: playlist.id),
                    )),
                  ),
                ],
              ),
              body: tracks.isEmpty
                  ? const Center(
                      child: Text('No songs yet. Tap + to add some.'))
                  : ReorderableListView.builder(
                      itemCount: tracks.length,
                      onReorder: (oldIndex, newIndex) {
                        final ids = [for (final t in tracks) t.id];
                        if (newIndex > oldIndex) newIndex -= 1;
                        ids.insert(newIndex, ids.removeAt(oldIndex));
                        service.setTrackOrder(playlist.id, ids);
                      },
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        return NowPlayingHighlight(
                          key: ValueKey('${track.id}#$index'),
                          trackId: track.id,
                          builder: (context, isCurrent) => ListTile(
                            selected: isCurrent,
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle,
                                  semanticLabel: 'Drag to move'),
                            ),
                            title: Text(
                                track.title.isNotEmpty
                                    ? track.title
                                    : track.fileBaseName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: track.artist.isNotEmpty
                                ? Text(track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)
                                : null,
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              tooltip: 'Remove from playlist',
                              onPressed: () =>
                                  service.removeFrom(playlist.id, track.id),
                            ),
                          ),
                        );
                      },
                      buildDefaultDragHandles: false,
                    ),
            );
          },
        );
      },
    );
  }
}
