# CLAUDE.md — AI working guide for Best Music

Flutter music app (Android-first; Windows desktop used for tests/screenshots). Read
`SPEC.md` for the specification and history ("The split" at the top says how this repo
relates to BestToDo, where it came from).

## Commands

- Analyze: `flutter analyze --no-pub` (keep it free of errors and warnings)
- Tests: `flutter test --timeout 60s` (CI runs the same). Suites: `test/music/` (the app),
  `test/tools/` (MP3 downloader, share links, track titles), `test/update/` (updater fakes).
- Screenshots: `flutter test integration_test/music_home_page_screenshot_test.dart -d windows`
  → `build/e2e_screenshots_music/`.
- Local APK: `powershell -ExecutionPolicy Bypass -File tool\build.ps1 apk` (arm64, release).
- Releases come from the laptop builder only: every push to `dev`/`staging`/`main` runs
  `tool\build.ps1 release` there (see README.md "Releases" and the header of
  `tool/build.ps1`). Needs `android/key.properties` (upload key, not in git).
- Publish by hand: `dart run tool/publish_apk.dart [--channel ...] [--build-number N]
  [--apk <path>] [--repo best_todo_2]` (`--repo best_todo_2` = the bridge release for
  installs from before the split).
- Version bump: `dart run tool/bump_version.dart <x.y.z> "<changelog entry>"` (pubspec.yaml +
  CHANGELOG.md).
- Live checks (network, not part of `flutter test`): `flutter test tool/check_mp3_download.dart`,
  `dart run tool/scan_music_metadata.dart`.

## Workflow

1. Bump version + CHANGELOG entry for every feature batch (user-facing bullets).
2. Commit to `dev`, push. Branch flow: feature → dev → staging → main; each push ships that
   channel.
3. Keep `SPEC.md` updated when adding/changing features.

## Architecture in one minute

- `lib/main.dart` boots config, library, playlists, feed, player, updates; the root page is
  `MusicPlayerPage(standalone: true)` with the drawer.
- `lib/models/` — plain models with tolerant `toJson`/`fromJson`.
- `lib/services/` — singletons persisting JSON files in the app documents dir (errors
  swallowed so tests keep working): `MusicLibraryService` (`music_library.json`),
  `MusicPlaylistService`, `YoutubeFeedService`, `Mp3DownloadManager`, `MusicMetadataEnricher`,
  `MusicBackupService`, `WishlistStore` (`tasks.json`), `Config` (`settings.json`).
- File names, JSON keys, the Android Kotlin package (`com.mfficiency.best_todo_2`) and the
  `besttodo/...` method channels are inherited from the BestToDo days and must not be renamed:
  existing installs and placed widgets depend on them.

## Conventions

- Tests mirror existing style: plain `test()` for logic, `testWidgets` with
  `MaterialApp(home: ...)` for widgets, `_FakePathProvider extends PathProviderPlatform` +
  temp dir for anything touching persistence.
- **Real file I/O hangs inside `testWidgets`** (the fake-async zone never services dart:io
  completions): create temp dirs / pre-save files in `setUp` or wrap in
  `await tester.runAsync(...)`; for I/O started by the widget, loop rounds of
  `runAsync(delay 5ms)` + `pump()` (see `pumpUntilFound`/`settleWrites` in
  `test/music/music_wishlist_page_test.dart`). Always run with `--timeout 60s`.
- Never dispose `TextEditingController`s right after `showDialog` returns; give the dialog its
  own StatefulWidget owning them.
- Icon buttons carry tooltips; tests find them by tooltip.
- Anything that can take more than 30 s shows `RemainingTimeText` ("hh:mm:ss remaining",
  `lib/ui/remaining_time_text.dart`, on the updates package's `RemainingTime`) below its
  progress; `EstimatedProgressBar(showRemaining: true)` does it for that bar. SPEC.md › Time left.
- Don't introduce new deprecation warnings.
