import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'models/bpm_preset.dart';
import 'services/safe_file.dart';

/// Best Music's settings, persisted as `settings.json` in the app documents
/// dir. The keys are the ones Best Music has always written (it used to be a
/// flavor of the BestToDo repo, sharing BestToDo's settings class), so an
/// update keeps every choice; keys this class doesn't know are dropped on
/// the next save.
class Config {
  /// Whether the app is running in development mode.
  /// Uses the `dart.vm.product` flag to detect production builds.
  static const bool isDev = !bool.fromEnvironment('dart.vm.product');

  /// Release channel (branch) this build came from — `dev`, `staging` or
  /// `main` — compiled in by the laptop builder
  /// (`--dart-define=BUILD_CHANNEL=...`, see `tool/build.ps1 release`). Only
  /// informational: all channels build the same Android app, which updates
  /// to the highest build number of any channel. Unset (`flutter run`,
  /// tests) = `main`.
  static const String buildChannel = String.fromEnvironment(
    'BUILD_CHANNEL',
    defaultValue: 'main',
  );

  /// The channel normalized to one of `main` / `staging` / `dev` (anything
  /// unexpected counts as `main`).
  static String get channel {
    final c = buildChannel.trim().toLowerCase();
    return (c == 'dev' || c == 'staging') ? c : 'main';
  }

  /// Version line shown on the About page: `0.3.30+12199 · dev` on a
  /// dev/staging build, plain `0.3.30+12199` on main.
  static String get versionWithChannel =>
      channel == 'main' ? versionWithBuild : '$versionWithBuild · $channel';

  static String _appVersion = 'unknown';
  static String _buildNumber = '';
  static Future<void>? _versionLoadFuture;

  /// Current application version, read from pubspec at runtime.
  static String get version => _appVersion;

  /// The running build number (Android's versionCode) as read from the
  /// platform; empty until [ensureVersionLoaded] finished (or off a device).
  static String get buildNumber => _buildNumber;

  /// Current application version including build number when available.
  static String get versionWithBuild =>
      _buildNumber.isEmpty ? _appVersion : '$_appVersion+$_buildNumber';

  /// Ensures app version metadata has been loaded from the platform.
  static Future<void> ensureVersionLoaded() {
    _versionLoadFuture ??= _loadVersion();
    return _versionLoadFuture!;
  }

  static Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
      _buildNumber = info.buildNumber;
    } catch (_) {}
  }

  /// Clears the memoized version future so each widget test loads it fresh in
  /// its own async zone (a future completed in a prior test's zone never fires
  /// its continuation when awaited in the next test).
  static void resetVersionForTest() {
    _versionLoadFuture = null;
    _appVersion = 'unknown';
    _buildNumber = '';
  }

  /// If true, the app uses a dark color scheme.
  static bool darkMode = false;

  /// Times are shown in 24-hour format (the update and changelog dates).
  static bool use24HourFormat = true;

  /// Available date display formats; the first entry is the default.
  static const List<String> dateFormats = [
    'dd.MM.yy',
    'dd.MM.yyyy',
    'dd/MM/yyyy',
    'MM/dd/yyyy',
    'yyyy-MM-dd',
    'd MMM yyyy',
  ];

  /// Date display format, one of [dateFormats]. Defaults to dd.mm.yy.
  static String dateFormat = dateFormats.first;

  /// How often the automatic backup writes a backup to
  /// [autoBackupDirectory]. The keys are persisted, so keep them stable:
  /// `off` (never, the default), `daily`, `weekly`.
  static const List<String> autoBackupFrequencies = ['off', 'daily', 'weekly'];

  /// Human-readable labels for [autoBackupFrequencies], index-aligned.
  static const List<String> autoBackupFrequencyLabels = [
    'Off',
    'Daily',
    'Weekly',
  ];

  /// Which of [autoBackupFrequencies] the automatic backup uses.
  static String autoBackupFrequency = 'off';

  /// Folder the automatic backup writes into; empty until the user picks one.
  static String autoBackupDirectory = '';

  /// Anthropic API key (console.anthropic.com) used for a video's "Quick
  /// summary" (`VideoSummaryService`). Empty means summaries are made
  /// on-device. Stored in plain text (local device storage only).
  static String claudeApiKey = '';

  /// The Obsidian vault "Save to Obsidian" writes research notes into
  /// (empty = whichever vault Obsidian has open) and the folder inside it.
  static String obsidianVault = '';
  static String obsidianResearchFolder = 'Research';

  /// Folder the MP3 Downloader saves audio into. Empty means "not chosen
  /// yet" — the tool asks once, stores the answer here, and never prompts
  /// again unless the user changes it in Settings → MP3 Downloader.
  static String mp3DownloadFolder = '';

  /// Folder the MP3 Downloader checks for tracks already downloaded (in
  /// addition to [mp3DownloadFolder] itself), searched recursively through
  /// every subfolder. Empty means "figure it out automatically" — the
  /// downloader falls back to the phone's standard Music folder when one
  /// exists, then to [mp3DownloadFolder] alone. Set explicitly in
  /// Settings → MP3 Downloader when auto-detection picks the wrong place
  /// (e.g. music actually lives somewhere the OS doesn't advertise).
  static String mp3CompareFolder = '';

  /// Root folder the Music Player scans for playable tracks (mp3/m4a/flac/
  /// wav/ogg), including every subfolder recursively. Empty means "not
  /// chosen yet". Defaults to [mp3DownloadFolder] on first use if that is
  /// already set, since downloaded tracks are the common case, but is a
  /// fully independent setting once picked.
  static String musicFolder = '';

  /// Subfolder paths (relative to [musicFolder], forward-slash separated)
  /// excluded from the Music Player's scan — e.g. a ringtones or podcast
  /// subfolder the user doesn't want mixed into shuffle. Set from Settings
  /// → Music Player, where each subfolder found under [musicFolder] gets a
  /// checkbox.
  static List<String> musicExcludedSubfolders = [];

  /// Music Player track-list sort field (`TrackSortField.name`:
  /// deviceDate, dateAdded, title, artist or duration) and direction,
  /// remembered across restarts so the Tracks tab reopens the way it was
  /// left. Defaults to when files arrived on the device, newest first.
  static String musicTrackSortField = 'deviceDate';
  static bool musicTrackSortAscending = false;

  /// Saved ranges on the BPM page, in the order they were saved.
  static List<BpmPreset> musicBpmPresets = [];

  /// Music Player: ask "Play out loud?" before starting playback from a
  /// standstill while the phone's own speaker is the only audio output (no
  /// Bluetooth/wired headphones or speaker) — see `SpeakerPlayGuard`.
  static bool musicConfirmSpeakerPlay = true;

  /// How many songs the "Most Played" smart playlists (overall and per
  /// genre) show at most, [minMostPlayedLimit]..[maxMostPlayedLimit].
  static int mostPlayedLimit = defaultMostPlayedLimit;
  static const int defaultMostPlayedLimit = 50;
  static const int minMostPlayedLimit = 1;
  static const int maxMostPlayedLimit = 1000;

  /// The phone's media volume (0..1) last used for music — local/Subsonic
  /// songs and songs streamed from the library search's YouTube fallback —
  /// and for Subscriptions videos. There is no app-specific volume:
  /// switching between music and videos saves the phone's level for the
  /// kind that was playing and puts back the other's (`MediaVolume`).
  /// Null until known.
  static double? musicPhoneVolume;
  static double? videoPhoneVolume;

  /// Which of those was playing last: 'music', 'video' or '' (nothing yet).
  static String phoneVolumeKind = '';

  /// Now Playing's repeat button: 'off', 'all' or 'one'
  /// (`MusicRepeatMode`).
  static String musicRepeatMode = 'off';

  /// Base URL of a self-hosted Subsonic/OpenSubsonic-compatible server
  /// (Navidrome, Airsonic, Gonic, …), e.g. `https://music.example.com`.
  /// Empty means the Music Player only plays from [musicFolder].
  static String subsonicServerUrl = '';

  /// Subsonic server username.
  static String subsonicUsername = '';

  /// Subsonic server password, stored in plain text (local device storage
  /// only).
  static String subsonicPassword = '';

  /// When the server's song list may be fetched automatically ('HH:MM-HH:MM',
  /// phone local time, may cross midnight) — see `SubsonicLibrarySync`. The
  /// default matches the night window of the MagicMirror Pi's music server,
  /// so the Pi does bulk work only while nobody looks at the mirror.
  static String subsonicSyncWindow = defaultSubsonicSyncWindow;
  static const String defaultSubsonicSyncWindow = '01:00-06:00';

  /// When the server's song list was last fetched completely; null = never.
  static DateTime? subsonicLastSync;

  static const _settingsFileName = 'settings.json';

  /// The music server's address and login, kept in a file of their own on
  /// top of [_settingsFileName]: that one is rewritten all the time (the
  /// phone volume alone saves it on every change), this one only when the
  /// login changes, so even if `settings.json` were ever lost the server
  /// stays connected after an update.
  static const _serverLoginFileName = 'music_server.json';

  /// What [save] last wrote to [_serverLoginFileName] (or [load] read), so
  /// it is only rewritten when the login actually changed.
  static String? _savedServerLogin;

  static Future<File> _getSettingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_settingsFileName');
  }

  static Future<File> _getServerLoginFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_serverLoginFileName');
  }

  static Map<String, dynamic> _parseMap(String contents) =>
      jsonDecode(contents) as Map<String, dynamic>;

  static String _serverLoginJson() => jsonEncode({
        'subsonicServerUrl': subsonicServerUrl,
        'subsonicUsername': subsonicUsername,
        'subsonicPassword': subsonicPassword,
      });

  /// Loads persisted settings from disk. Saves are atomic with a `.bak` of
  /// the previous content ([SafeFile]), so a write cut off by the app being
  /// killed (e.g. while an update installs) falls back to the last good
  /// settings instead of resetting everything.
  static Future<void> load() async {
    try {
      final data =
          await SafeFile.readWithRecovery(await _getSettingsFile(), _parseMap);
      if (data != null) applyMap(data);
    } catch (_) {}
    try {
      final login = await SafeFile.readWithRecovery(
          await _getServerLoginFile(), _parseMap);
      if (login != null && subsonicServerUrl.trim().isEmpty) {
        subsonicServerUrl = login['subsonicServerUrl'] as String? ?? '';
        subsonicUsername = login['subsonicUsername'] as String? ?? '';
        subsonicPassword = login['subsonicPassword'] as String? ?? '';
      }
      _savedServerLogin = login == null ? null : _serverLoginJson();
    } catch (_) {}
  }

  static Map<String, dynamic> toMap() {
    return {
      'darkMode': darkMode,
      'use24HourFormat': use24HourFormat,
      'dateFormat': dateFormat,
      'autoBackupFrequency': autoBackupFrequency,
      'autoBackupDirectory': autoBackupDirectory,
      'claudeApiKey': claudeApiKey,
      'obsidianVault': obsidianVault,
      'obsidianResearchFolder': obsidianResearchFolder,
      'mp3DownloadFolder': mp3DownloadFolder,
      'mp3CompareFolder': mp3CompareFolder,
      'musicFolder': musicFolder,
      'musicExcludedSubfolders': musicExcludedSubfolders,
      'musicTrackSortField': musicTrackSortField,
      'musicTrackSortAscending': musicTrackSortAscending,
      'musicBpmPresets': [for (final p in musicBpmPresets) p.toJson()],
      'musicConfirmSpeakerPlay': musicConfirmSpeakerPlay,
      'mostPlayedLimit': mostPlayedLimit,
      'musicPhoneVolume': musicPhoneVolume,
      'videoPhoneVolume': videoPhoneVolume,
      'phoneVolumeKind': phoneVolumeKind,
      'musicRepeatMode': musicRepeatMode,
      'subsonicServerUrl': subsonicServerUrl,
      'subsonicUsername': subsonicUsername,
      'subsonicPassword': subsonicPassword,
      'subsonicSyncWindow': subsonicSyncWindow,
      if (subsonicLastSync != null)
        'subsonicLastSync': subsonicLastSync!.millisecondsSinceEpoch,
    };
  }

  static void applyMap(Map<String, dynamic> data) {
    darkMode = data['darkMode'] as bool? ?? darkMode;
    use24HourFormat = data['use24HourFormat'] as bool? ?? use24HourFormat;
    final savedDateFormat = data['dateFormat'] as String?;
    if (savedDateFormat != null && dateFormats.contains(savedDateFormat)) {
      dateFormat = savedDateFormat;
    }
    final savedBackupFrequency = data['autoBackupFrequency'] as String?;
    if (savedBackupFrequency != null &&
        autoBackupFrequencies.contains(savedBackupFrequency)) {
      autoBackupFrequency = savedBackupFrequency;
    }
    autoBackupDirectory =
        data['autoBackupDirectory'] as String? ?? autoBackupDirectory;
    claudeApiKey = data['claudeApiKey'] as String? ?? claudeApiKey;
    obsidianVault = data['obsidianVault'] as String? ?? obsidianVault;
    obsidianResearchFolder =
        data['obsidianResearchFolder'] as String? ?? obsidianResearchFolder;
    mp3DownloadFolder =
        data['mp3DownloadFolder'] as String? ?? mp3DownloadFolder;
    mp3CompareFolder = data['mp3CompareFolder'] as String? ?? mp3CompareFolder;
    musicFolder = data['musicFolder'] as String? ?? musicFolder;
    final savedExcludedSubfolders = data['musicExcludedSubfolders'];
    if (savedExcludedSubfolders is List) {
      musicExcludedSubfolders =
          savedExcludedSubfolders.whereType<String>().toList();
    }
    musicTrackSortField =
        data['musicTrackSortField'] as String? ?? musicTrackSortField;
    musicTrackSortAscending =
        data['musicTrackSortAscending'] as bool? ?? musicTrackSortAscending;
    final bpmPresets = data['musicBpmPresets'];
    if (bpmPresets is List) {
      musicBpmPresets = [
        for (final p in bpmPresets)
          if (BpmPreset.fromJson(p) case final preset?) preset,
      ];
    }
    musicConfirmSpeakerPlay =
        data['musicConfirmSpeakerPlay'] as bool? ?? musicConfirmSpeakerPlay;
    final savedMostPlayedLimit = data['mostPlayedLimit'];
    if (savedMostPlayedLimit is num) {
      mostPlayedLimit = savedMostPlayedLimit
          .round()
          .clamp(minMostPlayedLimit, maxMostPlayedLimit);
    }
    musicPhoneVolume = (data['musicPhoneVolume'] as num?)
            ?.toDouble()
            .clamp(0.0, 1.0)
            .toDouble() ??
        musicPhoneVolume;
    videoPhoneVolume = (data['videoPhoneVolume'] as num?)
            ?.toDouble()
            .clamp(0.0, 1.0)
            .toDouble() ??
        videoPhoneVolume;
    phoneVolumeKind = data['phoneVolumeKind'] as String? ?? phoneVolumeKind;
    musicRepeatMode = data['musicRepeatMode'] as String? ?? musicRepeatMode;
    subsonicServerUrl =
        data['subsonicServerUrl'] as String? ?? subsonicServerUrl;
    subsonicUsername = data['subsonicUsername'] as String? ?? subsonicUsername;
    subsonicPassword = data['subsonicPassword'] as String? ?? subsonicPassword;
    subsonicSyncWindow =
        data['subsonicSyncWindow'] as String? ?? subsonicSyncWindow;
    final lastSync = data['subsonicLastSync'];
    if (lastSync is num) {
      subsonicLastSync = DateTime.fromMillisecondsSinceEpoch(lastSync.round());
    }
  }

  /// Persists the current settings to disk.
  static Future<void> save() async {
    try {
      await SafeFile.writeString(
          await _getSettingsFile(), jsonEncode(toMap()));
    } catch (_) {}
    try {
      final login = _serverLoginJson();
      if (login != _savedServerLogin) {
        _savedServerLogin = login;
        await SafeFile.writeString(await _getServerLoginFile(), login);
      }
    } catch (_) {
      _savedServerLogin = null;
    }
  }
}
