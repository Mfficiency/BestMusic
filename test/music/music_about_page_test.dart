import 'package:best_music/config.dart';
import 'package:best_music/services/app_updates.dart';
import 'package:best_music/ui/best_music_logo.dart';
import 'package:best_music/ui/music_about_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../update/update_fakes.dart';

/// The About page: the [UpdateSection] on the app's controller (tag prefix
/// `music-v`).
void main() {
  late FakeGithub github;
  late FakeDownloader downloader;
  late FakeInstaller installer;

  setUp(() {
    Config.resetVersionForTest();
    github = FakeGithub();
    downloader = FakeDownloader();
    installer = FakeInstaller();
  });
  tearDown(() {
    installer.dispose();
    AppUpdates.controller?.dispose();
    AppUpdates.controller = null;
  });

  Future<void> useMusicUpdates() => fakeController(
          github: github,
          downloader: downloader,
          version: '0.3.27',
          build: 1000)
      .init();

  testWidgets('shows Best Music branding and a Check for updates button',
      (tester) async {
    await useMusicUpdates();
    await tester.pumpWidget(const MaterialApp(home: MusicAboutPage()));
    await tester.pump();

    expect(find.textContaining('Best Music v'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('shows the app icon, and the icon asset is bundled',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MusicAboutPage()));
    await tester.pump();
    expect(find.byType(BestMusicLogo), findsOneWidget);
    expect(find.bySemanticsLabel('Best Music'), findsOneWidget);
    final bytes = await tester.runAsync(
        () => rootBundle.load(BestMusicLogo.assetPath));
    expect(bytes!.lengthInBytes, greaterThan(1000));
  });

  testWidgets(
      "Check for updates only looks at music-v tags (not BestToDo's v…)",
      (tester) async {
    github.releases = [
      release('v9.9.9-999999'),
      release('music-v0.3.27-1000'),
    ];
    await useMusicUpdates();
    await tester.pumpWidget(const MaterialApp(home: MusicAboutPage()));
    await tester.pump();
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.pump();
    await tester.tap(find.text('Check for updates'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Up to date'), findsOneWidget);
    expect(downloader.urls, isEmpty);
    expect(installer.installs, isEmpty);
  });
}
