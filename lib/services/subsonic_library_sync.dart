import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'log_service.dart';
import 'music_library_service.dart';
import 'server_catalog.dart';
import 'server_offline_store.dart';
import 'subsonic_client.dart';
import 'task_progress.dart';

/// Brings the music server's songs (Settings → Music server) into the library.
///
/// Listing a whole library is the one bulk job this app asks of the server,
/// and the server may be a small Raspberry Pi that also drives a MagicMirror.
/// So it runs on its own only inside [Config.subsonicSyncWindow] (default
/// 01:00-06:00, the same night window the Pi's Navidrome scans in), at most
/// once per window, while the app is running (checked at start, on resume
/// and every 15 minutes). "Sync now" in Settings runs it right away.
/// Playing a song needs no sync: streams go straight to the server, as the
/// original file (`SubsonicClient.streamUri`).
///
/// Metadata comes from the server's own scan of the file tags (title,
/// artist, album, genre, year, BPM); the phone never downloads server songs
/// to analyse them (`MusicMetadataEnricher` only handles folder songs).
class SubsonicLibrarySync {
  SubsonicLibrarySync._();

  static final SubsonicLibrarySync instance = SubsonicLibrarySync._();

  static const Duration checkEvery = Duration(minutes: 15);

  /// A sync within this long counts as "this window's sync done".
  static const Duration minGap = Duration(hours: 12);

  /// True while a sync runs (Settings shows a spinner).
  final ValueNotifier<bool> syncing = ValueNotifier<bool>(false);

  /// While syncing: songs fetched ÷ the songs the server had last time, for
  /// the "hh:mm:ss remaining" line (nothing to go on before the first sync).
  final ValueNotifier<TaskProgress?> progress =
      ValueNotifier<TaskProgress?>(null);

  /// The server's own scan status as of the last sync or scan check
  /// (shown in the Server tab, so a song count lower than expected can be
  /// told apart from songs the server simply hasn't scanned yet).
  final ValueNotifier<ServerScanStatus?> serverScan =
      ValueNotifier<ServerScanStatus?>(null);

  /// True while [scanServerThenSync] waits for the server's scan.
  final ValueNotifier<bool> serverScanning = ValueNotifier<bool>(false);

  /// How often [scanServerThenSync] checks whether the scan is done, and how
  /// long it waits at most.
  @visibleForTesting
  Duration scanPollEvery = const Duration(seconds: 5);
  static const Duration scanWaitAtMost = Duration(minutes: 30);

  Timer? _timer;
  Future<int?>? _running;

  @visibleForTesting
  SubsonicClient client = SubsonicClient.instance;

  @visibleForTesting
  MusicLibraryService library = MusicLibraryService.instance;

  @visibleForTesting
  ServerCatalog catalog = ServerCatalog.instance;

  /// Downloads for "keep on this device" after a sync; off in tests.
  @visibleForTesting
  bool syncOffline = true;

  static final RegExp _windowPattern =
      RegExp(r'^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$');

  /// Whether [window] looks like `01:00-06:00`.
  static bool isValidWindow(String window) =>
      _windowPattern.hasMatch(window.trim());

  /// Whether [now] (local time) falls inside [window]; a window may cross
  /// midnight (`23:00-07:00`). An invalid window falls back to the default.
  static bool inWindow(String window, DateTime now) {
    final m = _windowPattern.firstMatch(window.trim()) ??
        _windowPattern.firstMatch(Config.defaultSubsonicSyncWindow)!;
    final start = int.parse(m[1]!) * 60 + int.parse(m[2]!);
    final end = int.parse(m[3]!) * 60 + int.parse(m[4]!);
    final t = now.hour * 60 + now.minute;
    return start <= end ? (t >= start && t < end) : (t >= start || t < end);
  }

  /// Whether an automatic sync should run at [now].
  bool isDue(DateTime now) {
    if (!client.isConfigured) return false;
    if (!inWindow(Config.subsonicSyncWindow, now)) return false;
    final last = Config.subsonicLastSync;
    return last == null || now.difference(last) >= minGap;
  }

  /// Starts the automatic syncs (once, at app start), after putting the
  /// last known server songs in the library and finishing any downloads
  /// for "keep on this device".
  void start() {
    _timer ??= Timer.periodic(checkEvery, (_) => unawaited(maybeSync()));
    unawaited(() async {
      await catalog.load();
      if (catalog.songs.value.isNotEmpty) {
        await library.replaceServerTracks(catalog.songs.value);
        await ServerOfflineStore.instance.sync();
      }
      if (await maybeSync() == null && client.isConfigured) {
        await refreshScanStatus();
      }
    }());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Syncs when [isDue]; returns the server's song count, or null when it
  /// didn't run or failed.
  Future<int?> maybeSync({DateTime? now}) async {
    if (!isDue(now ?? DateTime.now())) return null;
    return syncNow();
  }

  /// Fetches the server's whole song list into [ServerCatalog] (the Server
  /// tab) and the library (minus songs already on the phone), then updates
  /// the songs kept on this device. Returns the server's song count; null
  /// when the server can't be reached (everything keeps what it had).
  Future<int?> syncNow() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<int?> _sync() async {
    if (!client.isConfigured) return null;
    syncing.value = true;
    final expected = catalog.songs.value.length;
    final tracker = expected > 0 ? TaskProgressTracker(progress) : null;
    try {
      void onPage(int fetched) =>
          tracker?.set((fetched / expected).clamp(0.0, 0.99));
      var songs = await client.allSongs(onPage: onPage);
      if (songs == null) {
        LogService.add('Music', 'server sync: server not reachable');
        return null;
      }
      final scan = await client.scanStatus();
      serverScan.value = scan;
      final scanned = scan?.count;
      if (songs.isEmpty || (scanned != null && scanned > songs.length)) {
        // Some servers' empty-query search3 returns only part of the
        // library; walk it album by album instead.
        final byAlbum = await client.allSongsByAlbum(onPage: onPage);
        LogService.add(
            'Music',
            'server sync: search3 gave ${songs.length} song(s), the server '
                'scanned ${scanned ?? '?'}, albums gave '
                '${byAlbum?.length ?? 'nothing'}');
        if (byAlbum != null && byAlbum.length > songs.length) songs = byAlbum;
      }
      await catalog.replace(songs);
      await library.replaceServerTracks(songs);
      final count = songs.length;
      Config.subsonicLastSync = DateTime.now();
      await Config.save();
      LogService.add('Music', 'server sync: $count song(s)');
      if (syncOffline) unawaited(ServerOfflineStore.instance.sync());
      return count;
    } finally {
      tracker?.end();
      syncing.value = false;
    }
  }

  /// Fetches the server's scan status into [serverScan] (cheap; the Server
  /// tab shows it; fetched at app start and on every sync).
  Future<void> refreshScanStatus() async {
    final status = await client.scanStatus();
    if (status != null) serverScan.value = status;
  }

  /// Asks the server to scan its music folder (picking up songs copied or
  /// uploaded to it since its last scan — the MagicMirror Pi otherwise
  /// scans only at night), waits until the scan is done and then syncs.
  /// Returns the synced song count; null when the server refused the scan
  /// (Navidrome allows it for admin accounts only) or couldn't be reached.
  Future<int?> scanServerThenSync() async {
    if (serverScanning.value) return null;
    serverScanning.value = true;
    try {
      if (!await client.startScan()) {
        LogService.add('Music', 'server scan: refused or not reachable');
        return null;
      }
      final until = DateTime.now().add(scanWaitAtMost);
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(scanPollEvery);
        final status = await client.scanStatus();
        if (status != null) serverScan.value = status;
        if (status != null && !status.scanning) break;
      }
      return await syncNow();
    } finally {
      serverScanning.value = false;
    }
  }

  /// How many songs the server has (as of the last sync).
  int get serverSongCount => catalog.songs.value.length;
}
