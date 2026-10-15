import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/track.dart';
import '../services/music_library_service.dart';
import '../services/music_player_service.dart';
import '../services/server_catalog.dart';
import '../services/server_offline_store.dart';
import '../services/server_upload_service.dart';
import '../services/speaker_play_guard.dart';
import '../services/subsonic_client.dart';
import '../services/subsonic_library_sync.dart';
import '../services/task_progress.dart';
import 'now_playing_page.dart';
import 'remaining_time_text.dart';
import 'subpage_app_bar.dart';
import 'track_file_menu.dart';

/// The Server tab: the music server's folders (e.g. the Navidrome on the
/// MagicMirror Pi), where every folder and song can be kept on this phone or
/// left online only, like OneDrive. Without a server it shows the login.
class ServerTab extends StatefulWidget {
  const ServerTab({super.key});

  @override
  State<ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<ServerTab> {
  @override
  void initState() {
    super.initState();
    unawaited(ServerCatalog.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    if (!SubsonicClient.instance.isConfigured) {
      return _ServerSetup(onConnected: () => setState(() {}));
    }
    return const ServerFolderView(path: '', showHeader: true);
  }
}

String formatMB(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

Widget _stateIcon(OfflineState state) => switch (state) {
      OfflineState.online => const Tooltip(
          message: 'Online only', child: Icon(Icons.cloud_outlined)),
      OfflineState.pending => const Tooltip(
          message: 'Downloading to this phone', child: Icon(Icons.downloading)),
      OfflineState.kept => const Tooltip(
          message: 'On this phone',
          child: Icon(Icons.offline_pin, color: Colors.green)),
      OfflineState.partly => const Tooltip(
          message: 'Partly on this phone',
          child: Icon(Icons.offline_pin_outlined)),
    };

/// One server folder: its subfolders and songs, each with its offline state
/// and a menu to keep it on this phone or free up space.
class ServerFolderView extends StatelessWidget {
  const ServerFolderView(
      {super.key, required this.path, this.showHeader = false});

  /// Server folder ('' = the top).
  final String path;

  /// The top shows the server status, Sync now and Upload phone music.
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final offline = ServerOfflineStore.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([
        ServerCatalog.instance.songs,
        offline.changes,
        offline.progress,
        SubsonicLibrarySync.instance.syncing,
        SubsonicLibrarySync.instance.serverScan,
        SubsonicLibrarySync.instance.serverScanning,
        ServerUploadService.instance.progress,
      ]),
      builder: (context, _) {
        final all = ServerCatalog.instance.songs.value;
        final folder = ServerCatalog.folder(all, path);
        return ListView(
          children: [
            if (showHeader) _ServerHeader(songCount: all.length),
            if (offline.progress.value case final p?)
              ListTile(
                dense: true,
                leading: const Icon(Icons.downloading),
                title: const Text('Keeping music on this phone'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p),
                    TaskRemainingText(offline.transfer),
                  ],
                ),
              ),
            if (all.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No songs from the server yet. Tap Sync now — '
                    'after that the list updates by itself at night.'),
              ),
            for (final sub in folder.folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(sub.name),
                subtitle: Text('${sub.songs.length} song'
                    '${sub.songs.length == 1 ? '' : 's'}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _stateIcon(offline.stateOfSongs(sub.songs)),
                  _OfflineMenu(
                      path: sub.path, songs: sub.songs, name: sub.name),
                ]),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ServerFolderPage(path: sub.path, title: sub.name),
                )),
              ),
            for (var i = 0; i < folder.songs.length; i++)
              _songTile(context, folder.songs, i),
          ],
        );
      },
    );
  }

  Widget _songTile(BuildContext context, List<Track> songs, int index) {
    final song = songs[index];
    final offline = ServerOfflineStore.instance;
    return ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        _stateIcon(offline.stateOfSong(song)),
        _OfflineMenu(
            path: ServerOfflineStore.pathOf(song),
            songs: [song],
            name: song.title,
            song: song),
      ]),
      onTap: () async {
        if (!await SpeakerPlayGuard.confirmPlay(context)) return;
        await MusicPlayerService.playQueue(songs, startIndex: index);
        if (context.mounted) Navigator.of(context).push(NowPlayingPage.route());
      },
    );
  }
}

class ServerFolderPage extends StatelessWidget {
  const ServerFolderPage({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: title),
      body: ServerFolderView(path: path),
    );
  }
}

class _ServerHeader extends StatelessWidget {
  const _ServerHeader({required this.songCount});

  final int songCount;

  @override
  Widget build(BuildContext context) {
    final syncing = SubsonicLibrarySync.instance.syncing.value;
    final scanningServer = SubsonicLibrarySync.instance.serverScanning.value;
    final scan = SubsonicLibrarySync.instance.serverScan.value;
    final uploading = ServerUploadService.instance.progress.value;
    final last = Config.subsonicLastSync;
    String two(int v) => v.toString().padLeft(2, '0');
    final scanCount = scan?.count;
    final lastScan = scan?.lastScan;
    final String? scanLine;
    if (scanningServer || scan?.scanning == true) {
      scanLine = 'The server is scanning its music folder'
          '${scanCount != null ? ' ($scanCount songs so far)' : ''}'
          ' — new songs come in once it is done';
    } else if (scan != null) {
      scanLine = 'The server itself knows '
          '${scanCount != null ? '$scanCount songs' : 'its songs'}'
          '${lastScan != null ? ' · last scanned ${lastScan.day}.'
              '${lastScan.month}. ${two(lastScan.hour)}:'
              '${two(lastScan.minute)}' : ''}'
          '. Songs copied or uploaded to it since then come in after its '
          'next scan.';
    } else {
      scanLine = null;
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Config.subsonicServerUrl,
                style: Theme.of(context).textTheme.titleSmall),
            Text(last == null
                ? 'Not synced yet'
                : '$songCount songs · synced ${last.day}.${last.month}. '
                    '${two(last.hour)}:${two(last.minute)} · syncs by itself '
                    'at ${Config.subsonicSyncWindow}'),
            if (scanLine != null) Text(scanLine),
            if (uploading != null) ...[
              Text('Uploading $uploading'),
              TaskRemainingText(ServerUploadService.instance.transfer),
            ],
            if (syncing)
              TaskRemainingText(SubsonicLibrarySync.instance.progress),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: syncing ? null : () => _syncNow(context),
                icon: syncing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
              FilledButton.tonalIcon(
                onPressed: syncing || scanningServer
                    ? null
                    : () => _scanServer(context),
                icon: scanningServer
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.manage_search),
                label: const Text('Scan server'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ServerUploadPage())),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Upload phone music'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final count = await SubsonicLibrarySync.instance.syncNow();
    messenger.showSnackBar(SnackBar(
      content: Text(count == null
          ? 'Sync failed — the server could not be reached'
          : '$count songs on the server'),
    ));
  }

  Future<void> _scanServer(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('Asked the server to scan for new songs — this can '
            'take a while on the Pi')));
    final count = await SubsonicLibrarySync.instance.scanServerThenSync();
    messenger.showSnackBar(SnackBar(
      content: Text(count == null
          ? 'The server did not scan — only its admin account may start a '
              'scan, or it could not be reached'
          : 'Scan done: $count songs on the server'),
    ));
  }
}

/// "Always keep on this device" / "Free up space" for a folder or song; for
/// a single [song] also "Move to folder" and "Delete" (on the server).
class _OfflineMenu extends StatelessWidget {
  const _OfflineMenu(
      {required this.path,
      required this.songs,
      required this.name,
      this.song});

  final String path;
  final List<Track> songs;
  final String name;
  final Track? song;

  @override
  Widget build(BuildContext context) {
    final song = this.song;
    return PopupMenuButton<String>(
      tooltip: song != null ? 'More options' : 'Keep on this phone',
      onSelected: (value) async {
        switch (value) {
          case 'keep':
            await ServerOfflineStore.instance.keep(path);
          case 'free':
            await freeUpSpace(context, path: path, songs: songs, name: name);
          case 'move':
            if (song != null) await pickFolderAndMove(context, song);
          case 'delete':
            if (song != null) await confirmAndDeleteTrack(context, song);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'keep',
          child: ListTile(
              leading: Icon(Icons.offline_pin_outlined),
              title: Text('Always keep on this device')),
        ),
        const PopupMenuItem(
          value: 'free',
          child: ListTile(
              leading: Icon(Icons.cloud_outlined),
              title: Text('Free up space')),
        ),
        if (song != null) ...[
          const PopupMenuItem(
            value: 'move',
            child: ListTile(
                leading: Icon(Icons.drive_file_move_outline),
                title: Text('Move to folder')),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('Delete')),
          ),
        ],
      ],
    );
  }
}

/// Stops keeping [path] on the phone, then offers to delete the phone's own
/// copies of these songs (from the music folder — e.g. songs uploaded from
/// here) now that they are safely on the server.
Future<void> freeUpSpace(BuildContext context,
    {required String path,
    required List<Track> songs,
    required String name}) async {
  await ServerOfflineStore.instance.freeUp(path);
  final onServer = SameSongIndex(songs);
  final copies = [
    for (final t in MusicLibraryService.instance.tracks.value)
      if (t.source == TrackSource.local &&
          t.filePath != null &&
          onServer.match(t) != null)
        t,
  ];
  if (copies.isEmpty || !context.mounted) return;
  var bytes = 0;
  for (final t in copies) {
    try {
      bytes += await File(t.filePath!).length();
    } catch (_) {}
  }
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Also delete the phone copies?'),
      content: Text('${copies.length} song${copies.length == 1 ? '' : 's'} in '
          '"$name" are also in your phone\'s music folder (${formatMB(bytes)}). '
          'Delete them from the phone? They stay on the server and keep playing '
          'from there.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep them')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete from phone')),
      ],
    ),
  );
  if (confirmed != true) return;
  var deleted = 0;
  for (final t in copies) {
    try {
      await File(t.filePath!).delete();
      deleted++;
    } catch (_) {}
  }
  await MusicLibraryService.instance.rescan();
  // The server's copies take their place in the library.
  await MusicLibraryService.instance
      .replaceServerTracks(ServerCatalog.instance.songs.value);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deleted $deleted song${deleted == 1 ? '' : 's'} '
            'from the phone (${formatMB(bytes)})')));
  }
}

/// Login for the music server, shown in the Server tab until it is set.
class _ServerSetup extends StatefulWidget {
  const _ServerSetup({required this.onConnected});

  final VoidCallback onConnected;

  @override
  State<_ServerSetup> createState() => _ServerSetupState();
}

class _ServerSetupState extends State<_ServerSetup> {
  late final TextEditingController _url = TextEditingController(
      text: Config.subsonicServerUrl.isEmpty
          ? 'http://hally.local:4533'
          : Config.subsonicServerUrl);
  late final TextEditingController _user =
      TextEditingController(text: Config.subsonicUsername);
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final previousUrl = Config.subsonicServerUrl;
    final previousUser = Config.subsonicUsername;
    final previousPassword = Config.subsonicPassword;
    Config.subsonicServerUrl = _url.text.trim();
    Config.subsonicUsername = _user.text.trim();
    Config.subsonicPassword = _password.text;
    final ok = await SubsonicClient.instance.ping();
    if (!mounted) return;
    if (!ok) {
      // Put back what was there, rather than leaving a half-cleared login
      // that the next save (of any setting) would persist.
      Config.subsonicServerUrl = previousUrl;
      Config.subsonicUsername = previousUser;
      Config.subsonicPassword = previousPassword;
      setState(() {
        _busy = false;
        _error = 'No connection. Check the address (try the Pi\'s IP address, '
            'e.g. http://192.168.1.23:4533, if .local doesn\'t work on this '
            'phone), user name and password.';
      });
      return;
    }
    await Config.save();
    widget.onConnected();
    unawaited(SubsonicLibrarySync.instance.syncNow());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Connect your music server',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('The Navidrome on the MagicMirror Pi, with the account you '
            'made at its web page.'),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Server address'),
        ),
        TextField(
          controller: _user,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'User name'),
        ),
        TextField(
          controller: _password,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _busy ? null : _connect(),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.login),
          label: const Text('Connect'),
        ),
      ],
    );
  }
}

/// Sends the phone's songs the server doesn't have yet to the server.
class ServerUploadPage extends StatefulWidget {
  const ServerUploadPage({super.key});

  @override
  State<ServerUploadPage> createState() => _ServerUploadPageState();
}

class _ServerUploadPageState extends State<ServerUploadPage> {
  List<PendingUpload>? _pending;
  bool _checking = true;
  int? _stored;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final pending = await ServerUploadService.instance.pending();
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _checking = false;
    });
  }

  Future<void> _upload() async {
    final songs = _pending ?? const [];
    final stored = await ServerUploadService.instance.upload(songs);
    if (!mounted) return;
    setState(() => _stored = stored);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final upload = ServerUploadService.instance;
    return Scaffold(
      appBar: buildSubpageAppBar(context, title: 'Upload phone music'),
      body: ValueListenableBuilder<String?>(
        valueListenable: upload.progress,
        builder: (context, progress, _) {
          final pending = _pending;
          final bytes = pending?.fold<int>(0, (s, p) => s + p.size) ?? 0;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_stored != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.check_circle_outline),
                    title: Text(
                        '$_stored song${_stored == 1 ? '' : 's'} uploaded'),
                    subtitle: Text('They show up in the Server tab after the '
                        "server's nightly scan (${Config.subsonicSyncWindow}); "
                        'duplicates are cleaned up then too.'),
                  ),
                ),
              if (progress != null) ...[
                Text('Uploading $progress'),
                const SizedBox(height: 8),
                ValueListenableBuilder<TaskProgress?>(
                  valueListenable: upload.transfer,
                  builder: (context, t, _) =>
                      LinearProgressIndicator(value: t?.done),
                ),
                TaskRemainingText(upload.transfer),
                const SizedBox(height: 8),
                OutlinedButton(
                    onPressed: upload.cancel, child: const Text('Stop')),
              ] else if (_checking)
                const ListTile(
                  leading: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text("Checking what the server doesn't have yet…"),
                )
              else if (pending == null)
                const ListTile(
                  leading: Icon(Icons.cloud_off),
                  title: Text('The upload service could not be reached'),
                  subtitle:
                      Text('It runs on the MagicMirror Pi next to Navidrome '
                          '(port 4534). Check the server address in Settings.'),
                )
              else if (pending.isEmpty)
                const ListTile(
                  leading: Icon(Icons.cloud_done_outlined),
                  title: Text('Everything on this phone is on the server'),
                )
              else ...[
                Text('${pending.length} song${pending.length == 1 ? '' : 's'} '
                    '(${formatMB(bytes)}) on this phone are not on the server yet.'),
                const SizedBox(height: 4),
                const Text(
                    "They go to the server's Phone folder; the phone keeps "
                    'its copies until you choose Free up space.'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Upload'),
                ),
                const SizedBox(height: 12),
                for (final p in pending.take(200))
                  ListTile(
                    dense: true,
                    title: Text(p.track.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${p.path} · ${formatMB(p.size)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                if (pending.length > 200)
                  Text('… and ${pending.length - 200} more'),
              ],
            ],
          );
        },
      ),
    );
  }
}
