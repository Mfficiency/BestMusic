# Best Music Watch (Wear OS)

A small Wear OS app that remote-controls Best Music on the phone, made for the Samsung Galaxy
Watch6 Classic (Wear OS 4+, round 480x480, rotating bezel). Kotlin + Jetpack Compose for Wear
OS, a standalone Gradle build in this folder: `flutter build apk` never sees it
(`android/settings.gradle.kts` doesn't include it).

## What it does

One screen, no scrolling, so the bezel is free for the volume (like the watch's own media
controls):

- **Status line** at the top: "Phone connected", "Nothing playing", "Phone not reachable ·
  saved 14:32" (showing the last song it saw, faded), "Update Best Music on your phone" (the
  phone is connected but its Best Music is older than the watch support), "Looking for your
  phone…". A **Retry** chip when the phone is not reachable.
- **Now playing**: song and artist, a thin progress bar with `1:23 / 3:45` (counted on by the
  watch itself while playing).
- **Previous · Play/Pause · Next**: exactly what the phone's home-screen widget buttons do.
  Play with nothing connected to the phone (and "Ask before playing out loud" on in the phone's
  Settings) asks **"Play out loud?"** on the watch, as the widget asks on the phone.
- **Volume**: turn the **bezel** (clockwise = louder) or tap **− / +**. It is the phone's media
  volume (the one its volume buttons change); the watch shows `Volume 7/15` as the phone reports
  it.

Deliberately not there: browsing the library, playlists, likes/favourites, cover art, playing
music on the watch itself, Tiles/complications. The watch needs the phone (`standalone=false`):
the music, the library and the player are all on the phone.

## How it talks to the phone (Wearable Data Layer)

Contract in `app/src/main/kotlin/.../core/Sync.kt` (watch) and the phone's
`android/app/src/main/kotlin/com/mfficiency/best_todo_2/WearSync.kt` +
`WearCommandService.kt`. Both apps have the applicationId `com.mfficiency.best_music` and must be
signed with the **same key**, or Play services won't connect them.

| Direction | What | Path |
|---|---|---|
| phone → watch | DataItem `json` + `at`: `{hasTrack, title, artist, playing, positionMs, durationMs, at}` | `/music/now_playing` |
| phone → watch | DataItem `json` + `at`: `{level, max}` (media volume) | `/music/volume` |
| watch → phone | message, no data | `/music/command/play_pause`, `play_out_loud`, `next`, `previous`, `sync` |
| watch → phone | message, steps as text ("3") | `/music/command/volume_up`, `volume_down` |
| phone → watch | message: "would ask Play out loud?" | `/music/ask_out_loud` |

Capabilities: the phone advertises `best_music_phone` (`android/app/src/main/res/values/wear.xml`),
the watch `best_music_wear` (`app/src/main/res/values/wear.xml`). The watch sends commands to
the reachable node with `best_music_phone` (nearby first).

Phone side:
- `lib/services/wear_now_playing.dart` (Dart) is called by `MusicWidgetService._sync`, the
  same place the home-screen widgets get their state, and hands the JSON to the native side
  through the existing `besttodo/audio_output` channel (method `publishWearNowPlaying`) →
  `WearSync.publish` (a `PutDataMapRequest`, urgent). It only sends when something the watch
  shows changed (song, playing/paused, length, or a seek of more than 3 s), never awaits and
  never throws. Off Android, in tests and without Play services it does nothing / the request
  just fails.
- `WearCommandService` (a `WearableListenerService`, started by Play services only when a
  watch message arrives) turns the commands into the widget's media-button broadcasts to
  audio_service's `MediaButtonReceiver` (`MusicWidgetIntents.mediaButtonBroadcast`), and
  volume into `AudioManager.adjustStreamVolume(STREAM_MUSIC)`, then publishes `/music/volume`.
  Play/pause makes `MusicPlayGuardActivity`'s check (widget data: playing, "ask before playing
  out loud", headphones/Bluetooth connected); where that would ask, the watch is asked instead.
  It reads only the widget's SharedPreferences, never the app's files.

Watch side (`MusicRemote.kt`): reads the DataItems on start, listens for changes and for the
"Play out loud?" message only while the activity is started (no background service), checks
which phone is reachable on start and every 30 s while open, and keeps the last now-playing
and volume in SharedPreferences so it shows them (with "saved hh:mm") without the phone.
Every Play services call is wrapped: a failure is the status line or a short Toast, never a
crash. Bezel steps are shown at once and sent together 250 ms after the last one.

Battery: nothing runs while the screen is off (the activity stops); no polling of the phone
(the phone pushes); dark UI; R8 on release.

## Build

Needs the Android SDK (Android Studio's) and JDK 17+ (Android Studio's `jbr` is fine).

```sh
# from the repo root
wear/gradlew -p wear assembleDebug      # wear\gradlew.bat on Windows
wear/gradlew -p wear assembleRelease -PbuildNumber=12345 -PversionName=0.3.69
wear/gradlew -p wear test               # unit tests of the pure core (JUnit, no device)
```

- `wear/local.properties` (`sdk.dir=...`, not in git) or `ANDROID_HOME` tells Gradle where the
  SDK is; `tool\build.ps1 release` copies the line from `android/local.properties`.
- versionCode = `-PbuildNumber` or `BUILD_NUMBER` (default 1); versionName = `-PversionName` or
  the `x.y.z` of `pubspec.yaml`.
- Signing: `android/key.properties` (the phone's upload key; `storeFile` relative to
  `android/app`, same as the phone build). Without it the build uses the phone's committed
  debug keystore (so a debug watch build pairs with a debug phone build);
  `REQUIRE_RELEASE_KEY=1` makes a missing key fail instead.
- Output: `wear/app/build/outputs/apk/release/app-release.apk`.

## Releases

`tool\build.ps1 release` (the laptop builder, every push to dev/staging/main) builds the watch
**after** the phone APK is built and published: `build\wear\BestMusic-Watch-<x.y.z>-<build>[-dev|-staging].apk`
(not committed), and with `PUBLISH=1` a separate GitHub release, tag `wear-<phone tag>` (e.g.
`wear-music-v0.3.69-3456789-dev`), title "Best Music Watch <version> (<channel>)", prerelease
for dev/staging, never "Latest", on the same commit. The phone's updater only takes tags
`music-v<digit>…`, so it never offers a watch APK, and the same-code release lookup only looks
at `music-v…` tags. The step can't fail the phone release (a warning and
`WEAR_BUILD_RESULT status=failed`); `WEAR=0` skips it. If the phone release already exists,
nothing is built, the watch included.

## Install on the Galaxy Watch6 Classic (wireless ADB)

1. Watch: Settings › About watch › Software information › tap **Software version** 5 times
   (Developer options on).
2. Settings › Developer options › **ADB debugging** on, **Wireless debugging** on (watch and
   computer on the same Wi-Fi).
3. Wireless debugging › **Pair new device**: it shows an IP:port and a code. On the computer:
   `adb pair <ip>:<pair-port> <code>`
4. Then connect to the port shown on the Wireless debugging screen (not the pairing port):
   `adb connect <ip>:<port>`
5. `adb -s <ip>:<port> install -r BestMusic-Watch-<version>-<build>.apk`

Get the APK from the `wear-music-v…` release on GitHub (the one next to the phone release
the phone runs) or from `build\wear\` on the laptop. The phone must run a Best Music from the
same laptop builds (same signing key, and a version with watch support); a debug phone build
pairs only with a debug watch build.

## Test

- Unit tests: `wear/gradlew -p wear test` (`app/src/test`: JSON parsing, position counting,
  status line, bezel steps, the volume draft).
- Emulator: Android Studio's Wear OS emulator ("Wear OS Large Round", API 33+), paired with a
  phone emulator or phone through the Wear OS app (Device Manager › Pair Wearable).
- By hand, on the watch:
  - phone playing: title, artist, progress move; play/pause, next, previous work; the phone's
    widget follows.
  - press play with nothing connected to the phone: "Play out loud?" on the watch; Play
    starts, ✕ doesn't.
  - turn the bezel both ways: `Volume n/15` follows, the phone's volume changes; − / + too.
  - phone off / Bluetooth off / airplane mode: "Phone not reachable · saved hh:mm", the last
    song faded, a toast on a button; Retry after turning it back on shows "Phone connected".
  - phone with an older Best Music: "Update Best Music on your phone".
  - the screen off and on again: picks up the current song.
