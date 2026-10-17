import 'package:flutter/material.dart';

import '../models/music_playlist.dart';
import '../services/music_playlist_service.dart';
import 'music_player_page.dart' show promptPlaylistName;

/// "Playlists" on a song's info: a dropdown-looking field listing every
/// playlist the song is in; tapping it opens a checklist of all your
/// playlists (Favorites, Liked songs, "Don't really like" and the ones you
/// made) to put the song in or take it out — right away, no Save needed —
/// plus "New playlist" with this song. Smart (rule/most played) playlists
/// fill themselves, so they aren't listed.
class TrackPlaylistsField extends StatelessWidget {
  const TrackPlaylistsField({super.key, required this.trackId});

  final String trackId;

  static List<MusicPlaylist> _editable(List<MusicPlaylist> all) =>
      [for (final p in all) if (p.kind == PlaylistKind.list) p];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MusicPlaylist>>(
      valueListenable: MusicPlaylistService.instance.playlists,
      builder: (context, playlists, _) {
        final inThem = [
          for (final p in _editable(playlists))
            if (p.trackIds.contains(trackId)) p.name
        ];
        return InkWell(
          key: const ValueKey('trackPlaylistsField'),
          borderRadius: BorderRadius.circular(4),
          onTap: () => _pick(context),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Playlists',
              suffixIcon: Icon(Icons.arrow_drop_down),
            ),
            child: Text(
              inThem.isEmpty ? 'Not in any playlist' : inThem.join(', '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  Future<void> _pick(BuildContext context) async {
    final makeNew = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: ValueListenableBuilder<List<MusicPlaylist>>(
            valueListenable: MusicPlaylistService.instance.playlists,
            builder: (_, playlists, __) => ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text('Playlists',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Done'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('New playlist'),
                  onTap: () => Navigator.of(sheetContext).pop(true),
                ),
                const Divider(height: 1),
                for (final p in _editable(playlists))
                  CheckboxListTile(
                    value: p.trackIds.contains(trackId),
                    title: Text(p.name),
                    onChanged: (on) => _set(p, on ?? false),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (makeNew != true || !context.mounted) return;
    final name = await promptPlaylistName(context);
    if (name == null || name.trim().isEmpty) return;
    await MusicPlaylistService.instance.createPlaylist(name.trim(), [trackId]);
  }

  /// In or out of [playlist], keeping the system playlists' rules (a song
  /// can't be both loved and disliked).
  Future<void> _set(MusicPlaylist playlist, bool on) async {
    final service = MusicPlaylistService.instance;
    if (!on) {
      await service.removeFrom(playlist.id, trackId);
      return;
    }
    switch (playlist.id) {
      case MusicPlaylist.favoritesId:
        if (!service.isFavorite(trackId)) await service.toggleFavorite(trackId);
      case MusicPlaylist.likedId:
        await service.markLiked(trackId);
      case MusicPlaylist.dislikedId:
        await service.markDisliked(trackId);
      default:
        await service.addTo(playlist.id, trackId);
    }
  }
}
