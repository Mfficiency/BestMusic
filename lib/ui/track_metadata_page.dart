import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/music_library_service.dart';
import '../services/music_playlist_service.dart';
import '../services/track_file_actions.dart';
import 'subpage_app_bar.dart';
import 'track_playlists_field.dart';

/// Shows (and lets you fill in) one track's metadata — title/artist/album/
/// genre/year, the fields rule/smart playlists read, plus read-only file
/// info (duration, play count, date added, source, path). Reachable from
/// the "info" button on Now Playing and from tapping a row in
/// `MusicMetadataScanPage`.
///
/// Saving only updates this app's cached record of the track (what's
/// actually stored in `music_library.json` and read by playlist rules) —
/// it does not write ID3 tags back into the file itself.
class TrackMetadataPage extends StatefulWidget {
  const TrackMetadataPage({super.key, required this.trackId});

  final String trackId;

  @override
  State<TrackMetadataPage> createState() => _TrackMetadataPageState();
}

class _TrackMetadataPageState extends State<TrackMetadataPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  late final TextEditingController _albumController;
  late final TextEditingController _genreController;
  late final TextEditingController _yearController;
  late final TextEditingController _bpmController;
  late final TextEditingController _tagsController;
  late final TextEditingController _fileNameController;

  @override
  void initState() {
    super.initState();
    final track = MusicLibraryService.instance.byId(widget.trackId);
    _titleController = TextEditingController(text: track?.title ?? '');
    _artistController = TextEditingController(text: track?.artist ?? '');
    _albumController = TextEditingController(text: track?.album ?? '');
    _genreController = TextEditingController(text: track?.genre ?? '');
    _yearController = TextEditingController(text: track?.year?.toString() ?? '');
    _bpmController = TextEditingController(text: track?.bpm?.toString() ?? '');
    _tagsController = TextEditingController(text: (track?.tags ?? const []).join(', '));
    _fileNameController = TextEditingController(
        text: track == null ? '' : TrackFileActions.baseNameOf(track));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _genreController.dispose();
    _yearController.dispose();
    _bpmController.dispose();
    _tagsController.dispose();
    _fileNameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final yearText = _yearController.text.trim();
    final year = yearText.isEmpty ? null : int.tryParse(yearText);
    if (yearText.isNotEmpty && year == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Year must be a number, e.g. 2021')));
      return;
    }
    final bpmText = _bpmController.text.trim();
    final bpm = bpmText.isEmpty ? null : int.tryParse(bpmText);
    if (bpmText.isNotEmpty && (bpm == null || bpm < 1 || bpm > 999)) {
      messenger.showSnackBar(
          const SnackBar(content: Text('BPM must be a number, e.g. 120')));
      return;
    }
    final tags = _tagsController.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    await MusicLibraryService.instance.updateTrackMetadata(
      widget.trackId,
      title: _titleController.text.trim(),
      artist: _artistController.text.trim(),
      album: _albumController.text.trim(),
      genre: _genreController.text.trim(),
      year: year,
      bpm: bpm,
      tags: tags,
    );
    // Last: renaming the file gives the song a new id.
    final track = MusicLibraryService.instance.byId(widget.trackId);
    if (track != null && TrackFileActions.canRename(track)) {
      final error = await TrackFileActions.instance
          .rename(track, _fileNameController.text);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, _, __) {
        final track = MusicLibraryService.instance.byId(widget.trackId);
        return Scaffold(
          appBar: buildSubpageAppBar(
            context,
            title: 'Track info',
            actions: [
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'Save',
                onPressed: _save,
              ),
            ],
          ),
          body: track == null
              ? const Center(child: Text('Track not found.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _artistController,
                      decoration: const InputDecoration(labelText: 'Artist'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _albumController,
                      decoration: const InputDecoration(labelText: 'Album'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _genreController,
                      decoration: const InputDecoration(labelText: 'Genre'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _yearController,
                      decoration: const InputDecoration(labelText: 'Year'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _bpmController,
                      decoration: const InputDecoration(
                          labelText: 'BPM (beats per minute)'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    // Changes right away (no Save needed).
                    TrackPlaylistsField(trackId: track.id),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tagsController,
                      decoration: const InputDecoration(
                        labelText: 'Tags',
                        helperText: 'Comma-separated, e.g. Wedding songs, Belgian Top Charts',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('trackFileNameField'),
                      controller: _fileNameController,
                      enabled: TrackFileActions.canRename(track),
                      decoration: InputDecoration(
                        labelText: 'File name',
                        suffixText: _extensionOf(track),
                        helperText: TrackFileActions.canRename(track)
                            ? 'Renames the file when you save'
                            : 'Songs on the music server can\'t be renamed here',
                      ),
                    ),
                    if (track.metadataEdited) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Manually edited — a rescan keeps these values '
                        'instead of overwriting them from the file\'s tags.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                    const Divider(height: 32),
                    TrackStatsRows(track: track),
                  ],
                ),
        );
      },
    );
  }
}

/// The extension of [track]'s file (".mp3"), shown after the name field.
String _extensionOf(Track track) {
  final name = (track.filePath ?? '').split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot) : '';
}

/// One "Label   value" line of song info.
Widget _infoRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );

String _formatDuration(int? ms) {
  if (ms == null) return 'Unknown';
  final duration = Duration(milliseconds: ms);
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// The read-only part of a song's info — length, play/skip/swipe counts,
/// shuffle weight, dates, source and file — shown under the edit fields on
/// [TrackMetadataPage] and in Now Playing's Info tab ([TrackInfoView]).
class TrackStatsRows extends StatelessWidget {
  const TrackStatsRows({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _infoRow('Duration', _formatDuration(track.durationMs)),
        _infoRow('Plays', '${track.playCount}'),
        _infoRow('Skipped', '${track.skipCount}'),
        _infoRow('Swiped up', '${track.upSwipeCount}'),
        _infoRow('Swiped down', '${track.downSwipeCount}'),
        _infoRow(
          'Shuffle weight',
          '×${MusicPlaylistService.instance.weightFor(track).toStringAsFixed(2)}',
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Shuffle puts songs with a higher weight earlier: '
            'Favorites ×3, Liked songs ×2, "Don\'t really '
            'like" ×0.05, times '
            'what you did with the song — plays and swipes up '
            'raise it, skips and swipes down lower it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _infoRow(
          'Added to device',
          track.deviceDate == null ? 'Unknown' : _formatDate(track.deviceDate!),
        ),
        _infoRow(
          'Added to app',
          track.dateAdded == null ? 'Unknown' : _formatDate(track.dateAdded!),
        ),
        _infoRow('Source', switch (track.source) {
          TrackSource.local => 'Local file',
          TrackSource.subsonic => 'Subsonic',
          TrackSource.youtube => 'YouTube',
        }),
        if (track.filePath != null) _infoRow('File', track.filePath!),
      ],
    );
  }
}

/// Now Playing's Info tab (tap ⓘ): the playing song's info, read-only and
/// scrollable — title, artist, album, genre, year, BPM, tags, then
/// [TrackStatsRows] — with "Edit info" opening [TrackMetadataPage]. A
/// Subscriptions video (not a library song) shows its title and channel.
class TrackInfoView extends StatelessWidget {
  const TrackInfoView({super.key, required this.trackId, this.fallback});

  final String trackId;

  /// Shown when [trackId] isn't a library song (a feed video).
  final Track? fallback;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: MusicLibraryService.instance.tracks,
      builder: (context, _, __) {
        final track = MusicLibraryService.instance.byId(trackId);
        if (track == null) {
          final other = fallback;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (other != null) ...[
                _infoRow('Title', other.displayTitle),
                if (other.displayArtist.isNotEmpty)
                  _infoRow(other.isFeedVideo ? 'Channel' : 'Artist',
                      other.displayArtist),
                if (other.durationMs != null)
                  _infoRow('Duration', _formatDuration(other.durationMs)),
              ] else
                const Text('Track not found.'),
            ],
          );
        }
        String or(String v) => v.trim().isEmpty ? '—' : v;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _infoRow('Title', or(track.displayTitle)),
            _infoRow('Artist', or(track.displayArtist)),
            _infoRow('Album', or(track.album)),
            _infoRow('Genre', or(track.genre)),
            _infoRow('Year', track.year?.toString() ?? '—'),
            _infoRow('BPM', track.bpm?.toString() ?? '—'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TrackPlaylistsField(trackId: track.id),
            ),
            if (track.tags.isNotEmpty) _infoRow('Tags', track.tags.join(', ')),
            if (track.filePath != null)
              _infoRow('File name', TrackFileActions.baseNameOf(track)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit info'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TrackMetadataPage(trackId: track.id),
                )),
              ),
            ),
            const Divider(height: 16),
            TrackStatsRows(track: track),
          ],
        );
      },
    );
  }
}
