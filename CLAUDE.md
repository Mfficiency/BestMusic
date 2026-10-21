# CLAUDE.md — AI working guide for Best Music

## Every request ends on `dev` (standing rule from the owner)

Any request that changes files is finished only when the work is **merged into
`dev` and pushed**, without being asked: commit on the working branch, merge
`origin/dev` into it (resolve conflicts, keep both sides' intent), run the repo's
checks, then merge the branch into `dev` and `git push origin dev`. Report the
`dev` commit. `staging`/`main` only when the request says so. If the merge or
push can't be done, say exactly why. `.claude/hooks/require-merged-to-dev.sh` (a Stop
hook in `.claude/settings.json`) blocks stopping while commits or tracked changes
are not on `dev`.

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
- Organizer (part 3 of Best Music, the computer music bulk library organiser/sorter/filter tool;
  Python, in `organizer/`, see its README and SPEC.md §10.6s; README.md lists the 3 parts):
  `python -m unittest discover -s organizer/tests` (needs ffmpeg); run with
  `python organizer/organizer.py`.
- Live checks (network, not part of `flutter test`): `flutter test tool/check_mp3_download.dart`,
  `dart run tool/scan_music_metadata.dart`.
- Wear OS watch app (a remote for the phone's player; Kotlin/Compose, its own Gradle build in
  `wear/`, not part of the phone build): `wear/gradlew -p wear test|assembleRelease`; everything
  (sync paths, phone side `WearSync.kt`/`WearCommandService.kt`/`wear_now_playing.dart`,
  release tag `wear-music-v…`, install) in `wear/README.md`.

## Workflow

1. Bump version + CHANGELOG entry for every feature batch (user-facing bullets).
2. Commit to `dev`, push. Branch flow: feature → dev → staging → main; each push ships that
   channel. **Always merge finished work into `dev` and push it, without asking** — the owner
   has said so explicitly ("Always always merge!"). Working on a feature branch is fine, but
   every finished change ends merged into `dev` (resolve version/CHANGELOG conflicts by taking
   the next free version number) with full tests green first.
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
  progress; `EstimatedProgressBar(showRemaining: true)` does it for that bar, `TaskRemainingText`
  for a service's `ValueNotifier<TaskProgress?>` (server upload/sync/keep). SPEC.md › Time left.
- Don't introduce new deprecation warnings.
