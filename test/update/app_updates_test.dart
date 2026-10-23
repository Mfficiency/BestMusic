import 'dart:convert';
import 'dart:io';

import 'package:best_music/config.dart';
import 'package:best_music/services/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_fakes.dart';

/// The app's side of the updates package (`lib/services/app_updates.dart`):
/// its repo and tags, always checking automatically, and the state stored
/// before the package. Everything else is the package's default behaviour,
/// tested in `packages/mfficiency_updates/test`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGithub github;
  late FakeDownloader downloader;

  setUp(() {
    github = FakeGithub();
    downloader = FakeDownloader();
  });
  tearDown(() {
    AppUpdates.controller?.dispose();
    AppUpdates.controller = null;
    AppUpdates.backup = null;
  });

  test('its own public repo, tag prefix music-v, every 15 minutes', () {
    final c = AppUpdates.config(version: '0.3.31', build: 9);
    expect(c.githubRepo, 'Mfficiency/BestMusic');
    expect(c.privateRepo, isFalse, reason: 'no token: the repo is public');
    expect(c.tagPrefix, 'music-v',
        reason: 'installs from before the split only accept this prefix');
    expect(c.appName, 'Best Music');
    expect(c.httpUserAgent, 'BestMusic-update-check');
    expect(c.pollInterval, const Duration(minutes: 15));
    expect(c.checkInterval, const Duration(minutes: 15));
    expect(c.includePrereleases(), isTrue,
        reason: 'dev/staging builds are prereleases of the same app');
    expect(c.autoCheck(), isTrue, reason: 'there is no switch for it');
  });

  test('nothing holds the install prompt back', () {
    final c = fakeController(github: github, downloader: downloader);
    expect(c.promptAllowed, isNull);
  });

  test("takes only music-v tags (never BestToDo's v…), of every channel",
      () async {
    github.releases = [
      release('v9.9.9-9999999'),
      release('music-v0.3.27-3600050-dev', prerelease: true),
      release('music-v0.3.26-3600040'),
    ];
    final c = fakeController(github: github, downloader: downloader);
    expect((await c.check()).key, '0.3.27+3600050');
    expect(github.requests.single.toString(),
        'https://api.github.com/repos/Mfficiency/BestMusic/releases?per_page=30');
  });

  test('create() builds the running app from its version and prefs',
      () async {
    PackageInfo.setMockInitialValues(
      appName: 'Best Music',
      packageName: 'com.mfficiency.best_music',
      version: '0.3.31',
      buildNumber: '3566146',
      buildSignature: '',
    );
    Config.resetVersionForTest();
    SharedPreferences.setMockInitialValues({
      'update_last_checked': DateTime(2026, 10, 11).millisecondsSinceEpoch,
      'update_last_download': jsonEncode({'version': 'junk'}),
    });
    final c = await AppUpdates.create(
        http: github.http, downloader: downloader);
    expect(AppUpdates.controller, same(c));
    expect(c.config.version, '0.3.31');
    expect(c.config.build, 3566146);
    expect(c.lastCheck, DateTime(2026, 10, 11));
    Config.resetVersionForTest();
  });
  test('full backup: Download/Best Music, 3 kept, re-downloadable copies out',
      () {
    const c = AppUpdates.backupConfig;
    expect(c.appName, 'Best Music');
    expect(c.keep, 3);
    expect(c.excluded, {'server_music', 'video_cache', 'widget_art'});
    expect(c.excludedPrefixes, isEmpty);
  });

  test('hasAppData: any of the app files in the documents folder',
      () async {
    final dir = await Directory.systemTemp.createTemp('bm_has_data');
    addTearDown(() => dir.delete(recursive: true));
    expect(await AppUpdates.hasAppData(documents: dir), isFalse);
    File('${dir.path}/unrelated.txt').writeAsStringSync('x');
    expect(await AppUpdates.hasAppData(documents: dir), isFalse);
    File('${dir.path}/music_library.json').writeAsStringSync('{}');
    expect(await AppUpdates.hasAppData(documents: dir), isTrue);
  });

  for (final hadAppData in [true, false]) {
    test('create() builds the full backup; restore offered: ${!hadAppData}',
        () async {
      PackageInfo.setMockInitialValues(
        appName: 'Best Music',
        packageName: 'com.mfficiency.best_music',
        version: '0.3.71',
        buildNumber: '500',
        buildSignature: '',
      );
      Config.resetVersionForTest();
      SharedPreferences.setMockInitialValues({});
      await AppUpdates.create(
          http: github.http,
          downloader: downloader,
          platform: UpdatePlatform(supported: true),
          hadAppData: hadAppData);
      final backup = AppUpdates.backup!;
      expect(backup.config, same(AppUpdates.backupConfig));
      expect(backup.folder, 'Download/Best Music/Backups');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(FullBackup.offeredKey), hadAppData ? isTrue : isNull);
      expect(backup.looksFresh, !hadAppData,
          reason: 'an install with data is never offered a restore '
              '(Best Music keeps nothing in SharedPreferences)');
      Config.resetVersionForTest();
    });
  }
}
