# Best Music

Android music player with an MP3 downloader and a YouTube Subscriptions feed, built with
Flutter. Your own library (local folder or a Subsonic server), playlists (hand-built, smart and
rule-based), background playback with lock-screen controls and home-screen widgets, songs by
BPM, automatic song-info filling, a sleep timer, backups, and in-app updates from this repo's
GitHub releases.

Best Music started out inside [BestToDo](https://github.com/Mfficiency/best_todo_2) and has
been its own repo since 0.3.31. See `SPEC.md` for the full specification and how the split
works, `CHANGELOG.md` for every version.

## Develop

```sh
flutter pub get
flutter analyze --no-pub
flutter test --timeout 60s
flutter run            # lib/main.dart
```

Windows desktop works for tests and screenshots
(`flutter test integration_test/music_home_page_screenshot_test.dart -d windows`).

## Releases

Every push to `dev`, `staging` or `main` asks the laptop builder
([Mfficiency/laptop-builder](https://github.com/Mfficiency/laptop-builder), app `BestMusic`) to
run `tool\build.ps1 release`: it builds that channel's APK and publishes a GitHub release here,
tag `music-v<x.y.z>-<build>` (+ `-dev` / `-staging`, prereleases). Every channel is the same app
(`com.mfficiency.best_music`), which installs the highest build of any channel.

Signing: release builds need `android/key.properties` (the upload key every Best Music install
is signed with). It is not in git; copy it from the BestToDo working copy
(`D:\Code\best_todo_2\android\key.properties`, the same key), and the laptop builder keeps its
own copy under `D:\LaptopBuilder\secrets\BestMusic\`.

Installs from before the split (0.3.30 and older) look for updates in
`Mfficiency/best_todo_2`. To move them over, publish a release of this repo there as well:

```sh
dart run tool/publish_apk.dart --repo best_todo_2 --channel <channel> --build-number <N> --apk <apk>
```

Once a phone runs a build from this repo, it reads this repo's releases.
