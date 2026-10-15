import 'dart:convert';

import 'package:best_music/services/app_updates.dart';
import 'package:best_music/ui/changelog_page.dart';
import 'package:best_music/utils/date_time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../update/update_fakes.dart';

/// Serves [changelog] as `CHANGELOG.md` (no disk, no rootBundle).
class _ChangelogBundle extends CachingAssetBundle {
  _ChangelogBundle(this.changelog);
  final String changelog;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(utf8.encode(changelog));

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      changelog;
}

const _changelog = '''
# Best Music Changelog

## [0.3.41] - 2026-10-15
- The changelog shows when each version was built.

## [0.3.40] - 2026-10-14
- Songs can be moved.
- Local build: 2026-10-14 09:00
- APK size: 18.0 MB
''';

void main() {
  late FakeGithub github;
  late FakeDownloader downloader;
  late FakeInstaller installer;

  setUp(() {
    github = FakeGithub();
    downloader = FakeDownloader();
    installer = FakeInstaller();
  });
  tearDown(() {
    installer.dispose();
    AppUpdates.controller?.dispose();
    AppUpdates.controller = null;
  });

  testWidgets(
      'each version shows when it was built, how long the build took and '
      'its APK size from its GitHub release; CHANGELOG.md build lines only '
      'without one', (tester) async {
    github.releases = [
      release(
        'music-v0.3.41-3600100-dev',
        prerelease: true,
        body: 'Changes\n\n- Built: 2026-10-15 14:02 in 3m 12s, APK 19.4 MB',
        size: 20342112,
      ),
    ];
    final updates = fakeController(
      github: github,
      downloader: downloader,
      version: '0.3.41',
      build: 3600100,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultAssetBundle(
          bundle: _ChangelogBundle(_changelog),
          child: ChangelogPage(updates: updates),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final built = find.byKey(const ValueKey('changelog-build-info-0.3.41'));
    expect(built, findsOneWidget);
    expect(
      find.descendant(
        of: built,
        matching: find.text(
            'Built ${formatTimerDateTime(DateTime(2026, 10, 15, 14, 2))}'),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: built, matching: find.text('Build time 3m 12s')),
        findsOneWidget);
    expect(find.descendant(of: built, matching: find.text('APK 19.4 MB')),
        findsOneWidget);

    // 0.3.40 has no release: its own CHANGELOG.md lines, as before.
    expect(find.text('Local build: 2026-10-14 09:00'), findsOneWidget);
    expect(find.text('APK size: 18.0 MB'), findsOneWidget);
    expect(find.text('Songs can be moved.'), findsOneWidget);
    expect(github.requests, hasLength(1),
        reason: 'one releases list for every version, no real network');
  });

  testWidgets('a release with build info replaces the CHANGELOG.md lines',
      (tester) async {
    github.releases = [
      release('music-v0.3.40-3600000',
          body: '- Built: 2026-10-14 09:00 in 2m 5s', size: 19 * 1024 * 1024),
    ];
    final updates = fakeController(
      github: github,
      downloader: downloader,
      version: '0.3.41',
      build: 3600100,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultAssetBundle(
          bundle: _ChangelogBundle(_changelog),
          child: ChangelogPage(updates: updates),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build time 2m 05s'), findsOneWidget);
    expect(find.text('APK 19.0 MB'), findsOneWidget);
    expect(find.text('APK size: 18.0 MB'), findsNothing,
        reason: 'never both');
    expect(find.text('Local build: 2026-10-14 09:00'), findsNothing);
  });
}
