# Best Music

## The 3 parts of Best Music

| | What | Where | How to start |
|---|---|---|---|
| **1. The app** | Android music player: plays your songs, playlists, YouTube Subscriptions; downloads MP3s on the phone | your phone (this repo, `lib/`) | updates itself from this repo's GitHub releases |
| **2. The server** | Navidrome music server on the MagicMirror Raspberry Pi (`hally`): holds the whole library, the app streams from it; plus the upload service (port 4534) and `mirrorctl music ...` | the Pi (`http://hally.local:4533`), set up in the MagicMirror repo (`headless-mirror/docs/music-server.md`) | always on |
| **3. The computer music organiser** | **Bulk library organiser / sorter / filter tool**: sort and group thousands of songs by artist, album, genre and folder, fix tags and file names in bulk, find duplicates, make playlists, download from YouTube (artist top 10, charts, year charts, any list), then **Sync to Pi** | your computer (`organizer/`) | Windows: double-click **`organizer\Music-Organizer.cmd`**, then open http://127.0.0.1:8770. Guide: [`organizer/README.md`](organizer/README.md) |

How they fit: organise on the computer (3) → **Sync to Pi** puts songs and playlists on the
server (2) → the app (1) plays them from the server after its scan. Songs downloaded or uploaded
from the phone land in the server's `Phone/` folder, and the organiser offers to fetch them.

## 1. The app

Android music player with an MP3 downloader and a YouTube Subscriptions feed, built with
Flutter. Your own library (local folder or a Subsonic server), playlists (hand-built, smart and
rule-based), background playback with lock-screen controls and home-screen widgets, songs by
BPM, automatic song-info filling, a sleep timer, backups, and in-app updates from this repo's
GitHub releases.

Best Music started out inside [BestToDo](https://github.com/Mfficiency/best_todo_2) and has
been its own repo since 0.3.31. See `SPEC.md` for the full specification and how the split
works, `CHANGELOG.md` for every version.

### Develop

```sh
flutter pub get
flutter analyze --no-pub
flutter test --timeout 60s
flutter run            # lib/main.dart
```

Windows desktop works for tests and screenshots
(`flutter test integration_test/music_home_page_screenshot_test.dart -d windows`).

### Releases

Every push to `dev`, `staging` or `main` asks the laptop builder
([Mfficiency/laptop-builder](https://github.com/Mfficiency/laptop-builder), app `BestMusic`) to
run `tool\build.ps1 release`: it builds that channel's APK and publishes a GitHub release here,
tag `music-v<x.y.z>-<build>` (+ `-dev` / `-staging`, prereleases). Every channel is the same app
(`com.mfficiency.best_music`), which installs the highest build of any channel.

The same run builds the **Wear OS watch app** (`wear/`, a remote for the phone's player) after
the phone release and publishes it as its own release, tag `wear-music-v…` (never offered to
phones; `WEAR=0` skips it, a failing watch build never fails the phone release). Build,
install with wireless ADB and test: [`wear/README.md`](wear/README.md).

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

## 2. The server

Lives in the MagicMirror repo (`headless-mirror/docs/music-server.md`), not here: Navidrome at
`http://hally.local:4533` (the app's Settings → Music server), the upload service on port 4534
(phone songs → `Phone/`, moves and deletes from the app), `mirrorctl music scan|trash`, a
nightly scan and a 30-day music trash. The app's side of it is in `SPEC.md` ("Music server").

## 3. The computer music organiser

The bulk library organiser / sorter / filter tool in `organizer/`. Start it with
`organizer\Music-Organizer.cmd` (Windows) or `python organizer/organizer.py`; everything else,
including a short "how to use it" list, is in [`organizer/README.md`](organizer/README.md).
Tests: `python -m unittest discover -s organizer/tests`.

