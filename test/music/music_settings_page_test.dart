import 'package:best_music/config.dart';
import 'package:best_music/ui/music_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Best Music's Settings page (SPEC.md §10.6f): collapsible sections with a
/// row of section buttons, standalone from BestToDo's monolithic
/// settings_page.dart.
void main() {
  setUp(() {
    Config.musicFolder = '';
    Config.musicExcludedSubfolders = [];
  });

  tearDown(() {
    Config.musicFolder = '';
    Config.musicExcludedSubfolders = [];
  });

  testWidgets('prompts to choose a folder when none is set', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(initialSection: MusicSettingsSection.library)));
    await tester.pumpAndSettle();

    expect(find.text('Not set — choose the folder your music lives in'),
        findsOneWidget);
    expect(find.text('Forget this folder'), findsNothing);
    expect(find.text('Excluded subfolders'), findsNothing);
  });

  testWidgets('shows the folder path and exclusion controls once set',
      (tester) async {
    Config.musicFolder = '/does/not/matter/for/this/test';
    Config.musicExcludedSubfolders = ['Podcasts'];

    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(initialSection: MusicSettingsSection.library)));
    await tester.pumpAndSettle();

    expect(find.text('/does/not/matter/for/this/test'), findsOneWidget);
    expect(find.text('Forget this folder'), findsOneWidget);
    expect(find.text('Excluded subfolders'), findsOneWidget);
    expect(find.text('Podcasts'), findsOneWidget);
  });

  testWidgets('"Forget this folder" clears the folder and its exclusions',
      (tester) async {
    Config.musicFolder = '/does/not/matter/for/this/test';
    Config.musicExcludedSubfolders = ['Podcasts'];

    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(initialSection: MusicSettingsSection.library)));
    await tester.pumpAndSettle();

    // Config.save() inside the tap handler is real (best-effort, errors
    // swallowed) file I/O — run the tap under runAsync so its Future can
    // actually complete instead of hanging the fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('Forget this folder'));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    expect(Config.musicFolder, isEmpty);
    expect(Config.musicExcludedSubfolders, isEmpty);
    expect(find.text('Not set — choose the folder your music lives in'),
        findsOneWidget);
  });

  testWidgets('sections start collapsed; buttons and headers open them',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MusicSettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Music folder'), findsNothing);
    expect(find.text('Sleep timer'), findsNothing);

    // The section button opens its section.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Playback'));
    await tester.pumpAndSettle();
    expect(find.text('Sleep timer'), findsOneWidget);

    // Tapping a header toggles its section.
    await tester.ensureVisible(find.byTooltip('Expand Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand Library'));
    await tester.pumpAndSettle();
    expect(find.text('Music folder'), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse Library'));
    await tester.pumpAndSettle();
    expect(find.text('Music folder'), findsNothing);

    await tester.ensureVisible(find.text('Collapse all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collapse all'));
    await tester.pumpAndSettle();
    expect(find.text('Sleep timer'), findsNothing);
    await tester.tap(find.text('Expand all'));
    await tester.pumpAndSettle();
    expect(find.text('Music folder'), findsOneWidget);
  });

  testWidgets('the Backup section offers back up, restore and a schedule',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(initialSection: MusicSettingsSection.backup)));
    await tester.pumpAndSettle();

    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Automatic backup'), findsOneWidget);
    expect(find.text('Backup folder'), findsOneWidget);
  });

  testWidgets('the Music server section: login fields, then test and sync',
      (tester) async {
    addTearDown(() {
      Config.subsonicServerUrl = '';
      Config.subsonicUsername = '';
    });
    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(initialSection: MusicSettingsSection.server)));
    await tester.pumpAndSettle();

    expect(find.text('Server address'), findsOneWidget);
    expect(find.text('User name'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Automatic sync'), findsOneWidget);
    expect(find.textContaining(Config.defaultSubsonicSyncWindow),
        findsOneWidget);
    // Visible from the start, but asks for the login first.
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Fill in the server address and user name first'),
        findsOneWidget);

    Config.subsonicServerUrl = 'http://hally.local:4533';
    Config.subsonicUsername = 'me';
    await tester.pumpWidget(const MaterialApp(
        home: MusicSettingsPage(
            key: ValueKey('configured'),
            initialSection: MusicSettingsSection.server)));
    await tester.pumpAndSettle();

    expect(find.text('http://hally.local:4533'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Remove this server'), findsOneWidget);
  });
}
