import 'dart:io';

import 'package:best_music/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// The music server's address and login must survive updates: an update
/// kills the app, possibly in the middle of a settings save.
void main() {
  late Directory tempDir;

  void clearLogin() {
    Config.subsonicServerUrl = '';
    Config.subsonicUsername = '';
    Config.subsonicPassword = '';
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    clearLogin();
    await Config.load(); // nothing on disk yet: resets what was saved
  });

  tearDown(() async {
    clearLogin();
    await tempDir.delete(recursive: true);
  });

  Future<void> saveLogin() async {
    Config.subsonicServerUrl = 'http://hally.local:4533';
    Config.subsonicUsername = 'me';
    Config.subsonicPassword = 'secret';
    await Config.save();
    // A later, unrelated save, so settings.json has a .bak too.
    Config.musicPhoneVolume = 0.4;
    await Config.save();
    clearLogin();
  }

  void expectLogin() {
    expect(Config.subsonicServerUrl, 'http://hally.local:4533');
    expect(Config.subsonicUsername, 'me');
    expect(Config.subsonicPassword, 'secret');
  }

  test('the server login is saved and loaded again', () async {
    await saveLogin();
    await Config.load();
    expectLogin();
  });

  test('a settings.json cut off mid-write falls back to its backup',
      () async {
    await saveLogin();
    await File('${tempDir.path}/settings.json').writeAsString('{"darkMo');
    await Config.load();
    expectLogin();
  });

  test('the login survives even when settings.json is gone', () async {
    await saveLogin();
    for (final name in ['settings.json', 'settings.json.bak']) {
      final file = File('${tempDir.path}/$name');
      if (await file.exists()) await file.delete();
    }
    await Config.load();
    expectLogin();
  });

  test('removing the server is remembered too', () async {
    await saveLogin();
    await Config.load();
    clearLogin();
    await Config.save();
    await Config.load();
    expect(Config.subsonicServerUrl, isEmpty);
    expect(Config.subsonicUsername, isEmpty);
  });

  test('the Most Played size is saved, and clamped to 1..1000 on load',
      () async {
    Config.mostPlayedLimit = 200;
    await Config.save();
    Config.mostPlayedLimit = Config.defaultMostPlayedLimit;
    await Config.load();
    expect(Config.mostPlayedLimit, 200);

    Config.applyMap({'mostPlayedLimit': 5000});
    expect(Config.mostPlayedLimit, Config.maxMostPlayedLimit);
    Config.applyMap({'mostPlayedLimit': 0});
    expect(Config.mostPlayedLimit, Config.minMostPlayedLimit);
    Config.mostPlayedLimit = Config.defaultMostPlayedLimit;
  });
}
