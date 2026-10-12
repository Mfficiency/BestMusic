import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:mfficiency_updates/mfficiency_updates.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../utils/date_time_format.dart';
import 'log_service.dart';

export 'package:mfficiency_updates/mfficiency_updates.dart';

/// The app's side of the shared updates package
/// (`packages/mfficiency_updates`, vendored from flutter_app_template — see
/// its README.md; never edit that copy). The behaviour (when to check, the
/// resume check, GitHub's rate limit, silent download, install) is entirely
/// the package's [UpdateController] with its defaults; this file only holds
/// what is Best Music's own:
///
/// * [config]: repo [githubRepo] (public, no token), the tag prefix
///   `music-v` (kept from when Best Music shared the BestToDo repo, whose
///   own tags are `v…`), every 15 minutes while open (GitHub's anonymous
///   limit is 60 requests/hour), always checking automatically;
/// * the app's date format ([strings]) and log ([LogService]);
/// * the update prefs from before the package ([migrateLegacyState]).
class AppUpdates {
  AppUpdates._();

  /// Where Best Music's releases are published. Until the split (Best Music
  /// 0.3.31) they lived in `Mfficiency/best_todo_2`; installs from then read
  /// this repo, and older ones are moved over by one bridge release
  /// published to both (see README.md, "Releases").
  static const String githubRepo = 'Mfficiency/BestMusic';

  static const String appName = 'Best Music';
  static const String tagPrefix = 'music-v';

  /// How often a running app checks (and how old the last check may be at
  /// start or when it comes back): GitHub's anonymous API allows 60
  /// requests/hour/IP.
  static const Duration interval = Duration(minutes: 15);

  /// The running app's updates; null until [create] ran (tests set it,
  /// pages without one show no update UI).
  static UpdateController? controller;

  /// The running app's [UpdateConfig].
  static UpdateConfig config({
    required String version,
    required int build,
    String? channel,
  }) =>
      UpdateConfig(
        appName: appName,
        version: version,
        build: build,
        channel: channel ?? Config.channel,
        githubRepo: githubRepo,
        tagPrefix: tagPrefix,
        checkInterval: interval,
        pollInterval: interval,
      );

  /// The app's texts: the package's English ones in the app's date format.
  static UpdateStrings strings(BuildContext context) => const UpdateStrings(
        dateTime: formatTimerDateTime,
        date: formatTimerDate,
      );

  static void _log(
      UpdateLogLevel level, String event, Map<String, Object?> data) {
    // A check every 15 minutes that finds nothing isn't worth a log line.
    if (level == UpdateLogLevel.debug) return;
    LogService.add('update', data.isEmpty ? event : '$event $data');
  }

  /// The [UpdateController] with everything app-specific; [create] uses it,
  /// tests build theirs on fakes through it.
  static UpdateController controllerFor({
    required String version,
    required int build,
    required UpdateStore store,
    String? channel,
    UpdateHttp? http,
    ApkDownloader? downloader,
    UpdatePlatform? platform,
    DateTime Function()? clock,
  }) =>
      UpdateController(
        config: config(version: version, build: build, channel: channel),
        store: store,
        http: http,
        downloader: downloader,
        platform: platform,
        strings: strings,
        log: _log,
        clock: clock,
      );

  /// Before the first frame: builds [controller] (reads the version,
  /// migrates the stored state, no network). The seams are for tests.
  static Future<UpdateController> create({
    SharedPreferences? prefs,
    UpdateHttp? http,
    ApkDownloader? downloader,
    UpdatePlatform? platform,
    DateTime Function()? clock,
  }) async {
    await Config.ensureVersionLoaded();
    final version = Config.version;
    final build = int.tryParse(Config.buildNumber) ?? 0;
    prefs ??= await SharedPreferences.getInstance();
    await migrateLegacyState(prefs, version: version, build: build);
    final c = controllerFor(
      version: version,
      build: build,
      store: SharedPreferencesUpdateStore(prefs),
      http: http,
      downloader: downloader,
      platform: platform,
      clock: clock,
    );
    await c.init();
    return controller = c;
  }

  /// After the first frame: Android's install time, the check when due,
  /// polling and the resume check. [context] is above every screen (the
  /// navigator's).
  static void start(BuildContext context) => controller?.start(context);

  // ── State from before the package (Best Music 0.3.27 and older) ──────

  static const String _legacyLastChecked = 'update_last_checked';
  static const String _legacyLastDownload = 'update_last_download';
  static const String _legacyFirstSeen = 'install_info_first_seen';

  /// Every key the old update code wrote.
  @visibleForTesting
  static const List<String> legacyKeys = [
    _legacyLastChecked,
    _legacyLastDownload,
    _legacyFirstSeen,
    'update_pending_download',
    'update_downloaded_version',
    'update_downloaded_apk',
  ];

  /// The package's [migrateLegacyUpdateState] with the old update code's
  /// keys: the last check time, the last downloaded build (for
  /// "Downloaded …") and, for the running build, its first start (the
  /// "Installed …" fallback). A DownloadManager download in flight and the
  /// path of a finished APK are dropped (that update downloads once more,
  /// silently); the old APK folder (`<external files>/updates`) is deleted.
  static Future<void> migrateLegacyState(
    SharedPreferences prefs, {
    required String version,
    required int build,
  }) =>
      migrateLegacyUpdateState(
        prefs,
        legacyKeys: legacyKeys,
        deleteExternalUpdatesFolder: true,
        read: (p) {
          final checked = p.getInt(_legacyLastChecked);
          final download = _decode(p.getString(_legacyLastDownload));
          final downloadedAt = download?['at'];
          final downloaded = download?['version'] is String
              ? parseLegacyVersion(download!['version'] as String)
              : null;
          final seen = _decode(p.getString(_legacyFirstSeen));
          final seenAt = seen?['at'];
          final thisBuild =
              seen?['version'] == '$version+$build' && seenAt is int;
          return LegacyUpdateRecords(
            lastCheck: checked == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(checked),
            downloaded: downloaded != null && downloadedAt is int
                ? (
                    version: downloaded.version,
                    build: downloaded.build,
                    at: DateTime.fromMillisecondsSinceEpoch(downloadedAt),
                  )
                : null,
            installedBuild: thisBuild ? build : null,
            installedAt: thisBuild
                ? DateTime.fromMillisecondsSinceEpoch(seenAt)
                : null,
          );
        },
      );

  static Map<String, Object?>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }
}
