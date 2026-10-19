# Best Music — Specification & History

> **Purpose of this document.** What a human or AI needs to rebuild Best Music and to
> understand *why* it is built the way it is. `CHANGELOG.md` is the per-version record.
>
> Best Music started out as a build flavor of the BestToDo repo (`Mfficiency/best_todo_2`,
> `lib/main_music.dart`) and became its own repo with 0.3.31 (2026-10-12). The sections below
> were moved over from BestToDo's SPEC.md as they were, so their numbers (§10.6d–§10.6q),
> version references (many are BestToDo versions, from before Best Music versioned on its own
> in §10.6i) and mentions of the `music` flavor, `MUSIC_VERSION`, `CHANGELOG_MUSIC.md` and
> `main_music.dart` describe how things were at the time. "The split" below says how they map
> onto this repo today.

---

## The split (0.3.31)

- **Repo:** `Mfficiency/BestMusic` (public; branches `main` + `dev` + `staging`, work on `dev`).
  Flavors are gone: `lib/main.dart` is the app (was `lib/main_music.dart`), `pubspec.yaml`
  carries the version (was `MUSIC_VERSION`), `CHANGELOG.md` the history (was
  `CHANGELOG_MUSIC.md`), and the Dart package is `best_music`.
- **Same app on the phone:** applicationId `com.mfficiency.best_music`, signed with the same
  upload key (`android/key.properties`, not in git). The Android namespace and Kotlin package
  stay `com.mfficiency.best_todo_2`: placed home-screen widgets and the share target are
  stored by component name, so renaming them would break them on update. The method-channel
  names (`besttodo/...`) stay for the same reason of not touching what works.
- **Same data:** every file in the app documents dir keeps its name and format.
  `settings.json` is read and written by a Best-Music-only `Config` (the keys Best Music
  uses; BestToDo-only keys are dropped on the next save). The Wishlist keeps living in
  `tasks.json` in BestToDo's task-record shape, now through `WishlistStore` + `WishItem`
  (unknown fields are kept). One behaviour change: done Wishlist items are no longer moved
  out of the list on the next day (that was BestToDo's daily rollover of done tasks).
- **Updates:** `AppUpdates.githubRepo` is `Mfficiency/BestMusic`; tags keep the `music-v`
  prefix. Installs from before the split read `Mfficiency/best_todo_2`, so the first
  release(s) of this repo are also published there (`dart run tool/publish_apk.dart
  --repo best_todo_2 ...`); once a phone has a build from this repo, it reads this repo.
- **Builds:** the laptop builder (`Mfficiency/laptop-builder`, app `BestMusic`) runs
  `tool\build.ps1 release` on every push to dev/staging/main, like for every other app.
  CI (`flutter_test.yml`) analyzes and runs the tests.
- **Left behind in BestToDo:** the shared generic code (logging, startup times, changelog
  page, subpage app bar, date formats, `SafeFile`) was copied, not shared; BestToDo's own
  pages (about, logs with sync tabs, the changelog story poster, label registry) were
  replaced by small music-only versions.

---

### 10.6d MP3 Downloader (0.2.48, ffmpeg dropped for size 0.2.49, background queue + PoToken fix 0.2.51, filename cleanup + metadata tagging + downloads-list actions + playlist import 0.2.54, playlist empty-getVideos() fallback 0.2.55, browse-API fallback + logging 0.2.56, schema-agnostic playlist-item search 0.2.57, lockupViewModel support 0.2.58)
Tools ▸ MP3 Downloader — Best Music only since 0.2.98, see §10.6n (`lib/ui/mp3_downloader_page.dart`,
`lib/services/mp3_downloader_service.dart`): paste a YouTube URL, or type a
title to search, and save the video's audio. A pasted URL
(`looksLikeYoutubeUrl`/`extractYoutubeVideoId` match `youtube.com/watch`,
`youtu.be/`, `/shorts/`) resolves and downloads directly; a text query calls
`Mp3DownloaderService.search` and shows up to 5 candidates (title, channel,
formatted duration, and play count via `formatViewCount` — `376M plays`,
usually the fastest way to tell the real upload from a reupload) so the
ambiguous case is a tap, not a guess.

Built on `youtube_explode_dart` (a pure-Dart YouTube client — metadata
search, video lookup, and the audio-only stream manifest, no server or API
key, no native code). The audio-only stream is saved exactly as YouTube
serves it — an mp4/AAC stream saved as `.m4a` (preferred: plays almost
everywhere), or `.webm`/Opus when that's the only option — rather than
transcoded to a literal `.mp3`.

**0.2.48 shipped a real-MP3 version using `ffmpeg_kit_flutter_new_full`
(`libmp3lame`) and tripled the APK's size**: every ffmpeg-kit variant bundles
the whole ffmpeg native library per Android ABI, and even the audio-only
variant adds tens of MB — nowhere close to the ≤6%-over-0.2.46 budget this
tool was given. 0.2.49 drops the ffmpeg dependency entirely; the download is
pure Dart again, so the tool adds negligible APK size. Getting a literal
`.mp3` back without that cost would need a from-scratch decode (platform
`MediaCodec`/equivalent) + a small LAME encoder (e.g. `flutter_lame`) —
genuine new native-code work, not a dependency swap, and not done here.

#### How the bytes are actually fetched (0.2.51)

0.2.48-0.2.50 called `streamsClient.get(streamInfo)` and **hung at 0% forever
on real music** — the reported symptom was "mamma mia … keeps turning on 0
percent". Measuring the alternatives against `ABBA - Mamma Mia` (3.4 MB AAC)
found a server-side gate, not a client bug:

| approach | result |
|---|---|
| `streamsClient.get()` | 0 bytes in 300 s |
| plain GET, no `Range` (what `DownloadManager` sends) | `200`, but **31 KiB/s** |
| 1 MiB `Range` requests, stock `youtube_explode` clients | `403` past the first MiB |
| 1 MiB `Range` requests, **visionOS** client | ~4 MiB/s, complete |

Every InnerTube client shipped in `youtube_explode_dart` 3.1.0
(`androidSdkless`, `android`, `ios`, `androidVr`, `tv`, `mweb`, `safari`, …)
returns a stream URL that serves the first 1 MiB and then `403`s every
subsequent byte — YouTube's PoToken gate. Matching User-Agents doesn't help,
and 3.1.0 is the newest release. `yt-dlp` downloads the same video fine, and
its log shows why: it uses a **visionOS** client that 3.1.0 has no constant
for. `_visionOsClient` in `mp3_downloader_service.dart` transcribes that
client's InnerTube payload from `yt_dlp/extractor/youtube/_base.py`, and it
is the only one that serves a whole stream ungated.

So the download is: resolve with `_streamClients` (visionOS first, the stock
clients as fallbacks for videos it refuses — "made for kids" videos aren't
available to it), **probe a range near the end of the file before committing**
so a gated client is rejected up front rather than stalling mid-download, then
pull the stream as a series of `kAudioChunkBytes` (1 MiB) `Range` requests
into `<name>.part`, renamed on success. That is ~125x faster than the single
throttled response and is also why the transfer **cannot** be handed to
Android's `DownloadManager` the way an APK download is (§5 of the update
flow): `DownloadManager` only knows how to fetch one URL straight through,
which is exactly the 31 KiB/s path.

**Network routes (Best Music 0.3.18)** — on some networks (typically home Wi-Fi, dual-stack)
YouTube blocks the address ("Sign in to confirm you're not a bot") or the player request and
the audio leave on different address families, and stream URLs only work from the address
that resolved them, so video/song audio failed on Wi-Fi but worked on mobile data. Resolving
(`_resolveStream`, used by streaming *and* downloads) now walks `YoutubeRoute.tryOrder()`
(`lib/services/youtube_network_route.dart`): `system` (phone default), `ipv4`, `ipv6` —
each the full `_streamClients` walk (`_resolveViaClients`) over `httpClientForRoute(route)`,
an `HttpClient` whose `connectionFactory` looks the host up for that family only and, for a
direct https connection, does TLS itself (`SecureSocket.secure(socket, host:)`), passed to
youtube_explode as `YoutubeHttpClient(IOClient(http))` and used for the range probe — then
`invidious` (`_resolveViaInvidious`: each of `VideoTranscriptService.invidiousInstances`'
`/api/v1/videos/<id>?local=true&fields=adaptiveFormats`, `pickInvidiousAudio` = best
`audio/mp4` by bitrate (else any audio), URL resolved against the instance, size from
`clen`, then the same end-of-file probe) so YouTube only sees the relay's address. The route
that works becomes `YoutubeRoute.lastWorking` (in memory) and is tried first next time;
`ResolvedAudioStream.route` / `_ResolvedStream.route` make `YoutubeAudioSource` and
`downloadMp3` fetch the bytes over that same route. All routes failing → one
`Mp3DownloadException` listing each route's error. The probe now runs for any file over
1 KiB. (How Tubular/NewPipe cope instead: a BotGuard PoToken generated in a hidden WebView
plus client switching — not implemented here.)

Every request is bounded — `kResolveTimeout`/`kChunkTimeout` (90 s each) —
so a wedged socket surfaces as a readable error instead of a progress bar
that never moves, which was the whole failure mode being fixed.

#### Background queue and history (0.2.51)

`Mp3DownloadManager` (`lib/services/mp3_download_manager.dart`) owns the
transfers, not the page: an app-level singleton with a `ValueNotifier<List<
Mp3DownloadJob>>`, running one job at a time so several tracks can't starve
each other of bandwidth. Leaving the page or backgrounding the app therefore
doesn't interrupt a download, and the app-bar download button (badged with
the in-flight count) opens `Mp3DownloadsPage` showing what's running, what's
queued, and the history — each finished job with the path it landed at or the
reason it failed. History persists to `mp3_downloads.json` in the app
documents dir, capped at 100 entries.

It is *not* an OS-level download: a job still `running` when the app is
force-stopped is reloaded as `failed` / "Interrupted when the app closed"
(`Mp3DownloadJob.fromJson`) rather than showing a bar that can never move.

A completed job also calls `MediaScannerService.scanFile` (0.2.53,
`lib/services/media_scanner_service.dart`) with the saved path. The file was
written with plain `dart:io` `File` calls, which never goes through
`MediaStore`, so without this OEM media apps (Samsung's Music/My
Files/Gallery included) don't see the new track until the next full device
scan — on some OEMs that's not until a reboot. The Dart side is a thin,
Android-only (`Platform.isAndroid`) wrapper around the
`besttodo/media_scanner` platform channel; `MainActivity.kt`'s handler calls
`MediaScannerConnection.scanFile` on the given path. Best-effort: any
failure is swallowed since the download itself already succeeded by this
point.

Failures are surfaced on the downloader page itself, not just in the list —
a failed job renders an `errorContainer` card with the full message plus
Dismiss/Retry, because the bug being fixed was precisely a user left guessing
at a stuck 0%. Everything also goes to `LogService` under the `MP3` source
(App logs page): the search, the client chosen, byte counts, throughput, and
every failure.

#### Filename formatting and metadata tagging (0.2.54)

`downloadMp3` no longer saves the raw YouTube title verbatim.
`parseTrackTitle`/`formatTrackFileBaseName` (`lib/services/track_title.dart`)
split the title on the first `Artist - Title` separator (en/em dash also
match), falling back to the channel name (stripping a trailing `- Topic`,
the suffix YouTube Music's auto-generated artist channels carry) as the
artist when the title has none. Promotional annotations in `(...)`/`[...]`
are stripped from both — but only when *every* word inside reduces to one
from a curated filler list (`official`, `video`, `lyrics`, `hd`, `original`,
`mix`, `remaster`, …), so "(Official Video)"/"(Lyrics)"/"(HD)" go while
"(Live at Wembley)" or "(feat. Other Artist)" are left alone. The result is
saved as `Artist - Title.<ext>`.

An `.m4a` result (not `.webm` — Matroska/Opus tagging is a different format,
not attempted) is then tagged in place by `Mp4MetadataWriter`
(`lib/services/mp4_metadata_writer.dart`) with title, artist (also written
as album artist), the source URL as a comment, the upload year
(`Mp3SearchResult.uploadDate`, from `youtube_explode_dart`'s `Video.
uploadDate`), and the video's thumbnail (`ThumbnailSet.highResUrl`, fetched
best-effort) as cover art. This is real MP4 box surgery, not a transcode:
it locates (or builds) `moov/udta/meta/ilst`, splices in the new atom, and —
only if that changes `moov`'s size *and* `moov` sits before `mdat` in the
file — patches every `stco`/`co64` chunk-offset table found inside `moov`
by the size delta, since those offsets point at absolute byte positions in
`mdat` that just moved. Getting this wrong would corrupt playable audio, so
it is deliberately conservative: a fragmented file (`moof`/`sidx` present),
more than one `mdat`, or an offset table that fails an internal consistency
check aborts tagging entirely, and even a successful rewrite is written to a
sibling `.tag.tmp` file and structurally re-validated before it replaces the
original — a track missing metadata is fine, a corrupted one never ships.
This is the pure-Dart alternative flagged as future work when ffmpeg was
dropped in 0.2.49 (see above): no native encoder, no APK size cost.

#### Downloads-list actions (0.2.54)

Every row in `Mp3DownloadsPage` (queued, running, or finished) now also has
an "Open original video" icon (`launchUrl` on
`https://www.youtube.com/watch?v=<videoId>`, `LaunchMode.externalApplication`)
and a "Share YouTube link" icon (`SharePlus.instance.share`, same pattern as
Wishlist's share action), alongside the existing cancel/remove icon —
`Mp3DownloadJob.videoId` was already stored, so no new persisted state was
needed.

#### Playlist import (0.2.54)

Pasting (or sharing) a playlist link — `youtube.com/playlist?list=...`, or a
video URL that also carries `&list=...` — instead of a single video or a
search query is detected by `looksLikeYoutubePlaylistUrl`
(`mp3_downloader_service.dart`), checked *before* `looksLikeYoutubeUrl` so a
video-within-a-playlist link is treated as the playlist. It's a
domain-anchored regex (`(youtube.com|youtu.be)/…[?&]list=…`) rather than
`youtube_explode_dart`'s own `PlaylistId.parsePlaylistId`, which treats any
short alphanumeric string as a "valid" bare playlist id and would misfire on
an ordinary one-word search query.

`Mp3DownloaderService.resolvePlaylist` fetches the playlist's title
(`client.playlists.get`) and every video in it (`client.playlists.
getVideos`, a `Stream<Video>` drained to a list, in playlist order), mapped
to the same `Mp3SearchResult` shape search/resolve produce
(`Mp3PlaylistInfo(title, tracks)`) so the rest of the pipeline doesn't need
to know a track came from a playlist.

**Fallback for `getVideos()` coming back empty (0.2.55).** Reported against
a real, fully public 3-track playlist: it resolved a title ("MUZ_03") but
zero tracks. `PlaylistClient.getVideos` (`youtube_explode_dart` 3.1.0)
silently *skips* a playlist entry whose uploader channel id it can't parse
off the page — it tries three JSON paths (`ownerText`/`shortBylineText` →
`browseId`, two variants), and a playlist whose byline layout misses all
three loses every single track this way, not just the odd one. When
`getVideos()` returns empty, `resolvePlaylist` falls back to
`fetchPlaylistVideoIdsFromPage` (`lib/services/playlist_video_ids.dart`):
fetches the same playlist page HTML via a plain `yt_explode.
YoutubeHttpClient`, extracts `ytInitialData` from its `<script>` tags the
same way the library's own `YoutubePage` does (`var ytInitialData = ` /
`window["ytInitialData"] =`, JSON-decoded), and walks the identical
`contents.twoColumnBrowseResultsRenderer.tabs[]…playlistVideoListRenderer.
contents` path `PlaylistPage._videoItems` uses — but only ever pulls
`videoId` out of each `playlistVideoRenderer` (direct or
`richItemRenderer`-wrapped), so it isn't tripped by an unparseable byline.
Each id found is then resolved individually via the already-proven
`client.videos.get`, skipping (and logging) any single video that fails
rather than failing the whole playlist. Single page only — no
`continuation` follow-up — so a playlist beyond YouTube's first batch (a
few hundred entries) is only partially covered by the fallback; the normal
`getVideos()` path already paginates and is tried first regardless.

**A second, independent gap — and full logging (0.2.56).** The 0.2.55
fallback alone still didn't fix the reported playlist. A separate reason
`getVideos()` can come back empty: some playlists don't embed their video
list in the initial HTML page's `ytInitialData` at all —
`youtube_explode_dart`'s own `PlaylistPage.get()` already anticipates this
("Needed for Mixes and YT Music playlists whose initial HTML page doesn't
embed the video list") and internally retries via an innertube `browse`
POST call, but that call's *outcome* isn't exposed through
`PlaylistClient.get`/`getVideos`'s public API, so this can't just reuse it.
`fetchPlaylistVideoIdsFromPage` now repeats that retry itself when the page
parse alone finds nothing: `YoutubeHttpClient.sendPost('browse', {
'browseId': 'VL<playlistId>'})` (`VL`-prefixing a playlist id is the
standard way to address its video list as a "browse id" on YouTube's
internal API — the same convention yt-dlp and other scrapers use), then
runs the same `extractPlaylistVideoIdsFromData` walk against that response
too (an initial, non-continuation `browse` response for a playlist has the
same overall shape as the HTML-embedded data).

Every step of resolving a playlist — `playlists.get()`'s metadata,
`getVideos()`'s track count, entering the fallback, the page fetch and its
byte count, ytInitialData found/not-found, items found, ids found, the
browse-API attempt and its id count, and each individual video resolved or
skipped — is now written to `LogService` under the `MP3` source (App Logs
page, reachable from the drawer). Both gaps are easy to reproduce from a
bug report but were hard to diagnose blind with no live YouTube access to
test against.

**The actual root cause, found from those logs (0.2.57).** The 0.2.56
build still came back with zero tracks on the reported playlist — and the
new logs showed exactly why: `playlists.get()` confirmed the playlist
genuinely has videos (`videoCount=3`, a real title), the page fetch
succeeded (840 KB), but both the page-parse *and* the browse-API attempt
hit "tabs found but no playlistVideoListRenderer inside". That path —
`contents.twoColumnBrowseResultsRenderer.tabs[].tabRenderer.content.
sectionListRenderer.contents[].itemSectionRenderer.contents[].
playlistVideoListRenderer.contents` — is the *exact same hardcoded path*
`youtube_explode_dart`'s own `PlaylistPage._videoItems` getter uses, which
is exactly why `getVideos()` returned nothing in the first place: YouTube's
current response no longer nests the video list where that path (0.2.55's
fallback included, since it copied the same path for maximum fidelity)
expects it. Not a filter, not a missing byline — the container structure
itself had moved.

`extractPlaylistVideoIdsFromData` (now in `_findPlaylistVideoIds`)
no longer walks any hardcoded path at all: it recursively searches the
*entire* decoded response for a `playlistVideoRenderer` (direct, or
wrapped in `richItemRenderer.content`) wherever it lives, in document
order (a `jsonDecode`d object preserves source key/array order, so a
depth-first walk visits entries in playlist order without needing to know
the surrounding containers). `playlistVideoRenderer` is otherwise a
stable, specific type name — it only ever represents a video in a
playlist's own listing — so this is robust to exactly the kind of path
drift that broke both the library and the exact-path fallback, without
needing to know or guess the current container structure. If even this
finds nothing, it logs a census of every key anywhere in the response
ending in `Renderer` or `ViewModel` — e.g. if YouTube has since moved
playlist items to some other type name entirely, this names it directly
instead of costing another guess-and-report round trip.

**And that census immediately paid off (0.2.58).** The 0.2.57 build still
found nothing on the reported playlist — but this time the census named
the answer directly: `playlistVideoRenderer`/`playlistVideoListRenderer`
were entirely absent from the response, while `lockupViewModel`,
`lockupMetadataViewModel` and `contentMetadataViewModel` were all present.
This playlist's page has migrated to YouTube's newer unified "lockup"
component system (the same one search results and related videos have
been moving to), which represents a playlist entry as a `lockupViewModel`
with `contentId` (the video id) and a `contentType` field — a `lockupViewModel`
also represents playlists, channels and podcast episodes elsewhere on
YouTube, so `_findPlaylistVideoIds` only trusts `contentId` as a video id
when `contentType` names a video (a substring check for `VIDEO`, since the
exact enum string isn't confirmed and a substring match is robust to any
suffix variant). It now recognises both the older `playlistVideoRenderer`
shape and this one, in the same single recursive pass. No guessing was
needed for this one specifically *because* the 0.2.57 census logged every
candidate type name up front — validating that adding it was worth doing
even though it added no fix of its own that round.

`Mp3DownloaderPage` gets a third stage (`_Stage.playlist`) alongside
`picking`/`error`: every track as a `CheckboxListTile`, an "All"/"None"
bulk-select row, and a "Download N" button that enqueues whatever is
checked, one `Mp3DownloadManager.enqueue` call per track, then resets to
idle. Before showing the list, it asks for (or reuses) the download folder,
works out which folder(s) to check for tracks already downloaded via
`compareFoldersFor(folder, configuredCompareFolder: Config.mp3CompareFolder)`,
and calls `existingTrackBaseNamesAcross(folders)` — a recursive,
case-insensitive scan of every `.m4a`/`.webm`/`.mp3` file already under any
of those folders or their subfolders, matched by filename (without
extension) rather than video id, since a pre-tagging download carries no
reliable back-reference to its source video. Any playlist track whose
would-be filename (`parseTrackTitle(...).fileBaseName`) is already in that
set starts **unchecked** (shown as "Already downloaded", not hidden) so
re-pasting a partially-downloaded list only offers to fetch what's missing,
while still leaving a re-download one tap away.

`compareFoldersFor` always includes the download folder itself, plus
either `Config.mp3CompareFolder` (an explicit override) when set, or —
auto-detected, no permission prompt needed since it's just an `exists()`
check — Android's standard shared Music folder
(`defaultPhoneMusicFolder`, `/storage/emulated/0/Music`) when that folder
is actually there. This matters because `Config.mp3DownloadFolder` is
picked for *writability* (often the app's own sandboxed folder when the
user hasn't granted "All files access" — see below), which is rarely where
a phone's real music library lives; without also checking the phone's
Music folder, a track already sitting there (synced from a PC, or
downloaded before scoped storage pushed the save location into the
sandbox) would be re-offered as new. When auto-detection guesses wrong —
the library lives somewhere non-standard, or scoped storage hides the
standard folder from a plain path check — Settings ▸ MP3 Downloader's
"Check for existing tracks in" tile lets the user point it at the right
folder directly.

The save location is asked for **once** — `Config.mp3DownloadFolder`, set on
the first download via `file_selector`'s `getDirectoryPath` (defaulting to
`getDownloadsDirectory()`) and reused silently afterwards. It is editable at
Settings ▸ MP3 Downloader (BestToDo section index 15 until 0.2.98, §10.6n; gated on the
`mp3_downloader` feature switch — Best Music's own settings since), which can also forget it so the next download asks again.
The same section's "Check for existing tracks in" tile sets
`Config.mp3CompareFolder` (empty = automatic, as above) and can be cleared
back to automatic detection.
`youtube_explode_dart`'s scraping doesn't work from a browser sandbox, so
`Mp3DownloaderService.isSupported` (`!kIsWeb`) gates the page to a "not
supported on this platform" message there; every other platform
(Android/Windows/iOS/macOS/Linux) works. `Mp3DownloaderService` exposes
`searchOverride`/`resolveOverride`/`downloadOverride` (`@visibleForTesting`)
so widget tests substitute fakes instead of hitting the network — the same
seam `TodoistSyncService.apiClientFactory` uses. Because those fakes can't
catch a YouTube-side change like the PoToken gate, the real thing is checked
by `tool/check_mp3_download.dart`: a live search + download that asserts the
saved file is a valid container and is *not* truncated at 1 MiB. It lives in
`tool/` so `flutter test` (which only walks `test/`) can never go red from a
flaky network; run it by hand with
`flutter test tool/check_mp3_download.dart`. Registered like every other
tool: an entry in `_toolEntries`/`_buildToolPage` (home_page.dart) and in
`Config.featureKeys`/`Config.startToolOptions` (feature switch + default
start page).

### 10.6e Music Player (0.2.61)

Tools ▸ Music Player — Best Music only since 0.2.98, see §10.6n (`lib/ui/music_player_page.dart`, `lib/ui/now_playing_page.dart`,
`lib/ui/queue_page.dart`):
a full local MP3/audio player with background playback, home-screen widgets, notification
and lock-screen controls, an M3U/M3U8 playlist import (Samsung Music's share-out format),
and a "Tinder for songs" swipe gesture on Now Playing — swipe up favorites the current
track, swipe down marks it disliked and skips it, so disliked tracks come up far less (not
never) in future shuffles. Separate from and does not replace §10.6d's MP3 Downloader, which
only fetches audio; the two default to sharing a folder — opening Music Player with
`Config.musicFolder` unset auto-adopts `Config.mp3DownloadFolder` when that is already set
(and persists the choice), since downloaded tracks are the common case, but the two settings
are fully independent once either is picked explicitly.

**Library scanning** (`lib/services/music_library_service.dart`, singleton
`MusicLibraryService.instance`, `ValueNotifier<List<Track>> tracks`): recursively scans
`Config.musicFolder` for `mp3`/`m4a`/`flac`/`wav`/`ogg`/`aac`/`wma` files via `dart:io`
`Directory.list(recursive: true)` — not `on_audio_query`/`MediaStore`, so it works on any
folder the user picks, not just the device's indexed media. `Config.musicExcludedSubfolders`
(relative, forward-slash paths) excludes a subfolder and everything nested under it
(`isExcludedRelativeDir`); Settings → Music Player lists every subfolder found so far as a
checkbox (`MusicLibraryService.listSubfolders`). Each mp3's ID3 tags are read best-effort via
the pure-Dart `id3_codec` package — only the file's first 1 MiB is read (`_id3ReadCap`, covers
the common ID3v2-at-the-front case without reading every file whole for a folder that could
hold thousands of tracks); a file with no/unreadable tag, or any non-mp3 format, falls back to
its filename as the title. Results cache to `music_library.json` (same
singleton/`ValueNotifier`/`flush: true`/swallowed-errors pattern as `ProjectService`, §4.2) so
the library shows up instantly on the next launch; a failed or partial rescan (folder deleted,
permission revoked) leaves the previous cache in place rather than clearing it (0.2.68 —
`rescan` no longer swallows the failure silently: every step — permission status, folder
existence, files seen/skipped/kept, any thrown error — is written to `LogService` under source
`Music`, viewable in App Logs, since a scan that quietly finds nothing was previously
undiagnosable from the UI). Rescans are manual (Music Player's refresh button, or automatically
once on first open when the folder is set but the cache is empty) — there is no filesystem
watcher. All three folder pickers (Music Player's own, and Settings → Music Player in both
BestToDo and Best Music) call `MusicLibraryService.ensureFolderPermission()` before opening the
picker (0.2.68): on Android this checks/requests `MANAGE_EXTERNAL_STORAGE`, the same "All files
access" grant §10.6d's MP3 Downloader already prompts for — the music folder pick flow was the
one place in the app that scanned an arbitrary folder without ever asking for it, so a folder
picked before granting it anywhere else scanned as empty with no error shown.

`MusicPlayerService.ensurePermissions` (0.2.69, called from both `main.dart` and
`main_music.dart` shortly after first frame) covers the case where the folder was configured
before the permission existed (e.g. restored from a backup) rather than through the picker:
Best Music requests `MANAGE_EXTERNAL_STORAGE` unconditionally (`eager: true` — local playback is
its whole purpose, so it asks up front like other music apps); BestToDo only asks once
`Config.musicFolder` is already set, so the far larger group of BestToDo users who never open
Music Player aren't interrupted at launch for a permission a tool they don't use needs. Either
way it also requests notification access (for the playback controls notification) and, if
`MANAGE_EXTERNAL_STORAGE` had just been denied and is now granted, immediately re-runs `rescan`
rather than leaving the already-configured folder empty until the user notices and retriggers
one themselves.

**Playback engine** (`lib/services/music_audio_handler.dart`'s `MusicAudioHandler`, a
`BaseAudioHandler` from `audio_service` wrapping a single `just_audio` `AudioPlayer`):
one track is loaded at a time via `setAudioSource` rather than a gapless
`ConcatenatingAudioSource` — simpler to keep in sync with a queue that swipe actions mutate
mid-playback, at the cost of a small gap between tracks. The queue
(`List<Track> _queue`/`_queueIndex`) advances on `ProcessingState.completed` or a manual
skip; running off the end reshuffles the whole scanned library fresh
(`MusicPlaylistService.weightedShuffle`) rather than stopping, so playback continues
indefinitely, radio-style. `MusicPlayerService` (`lib/services/music_player_service.dart`) is
the facade the UI actually calls (`playLibraryShuffled`, `playQueue(tracks, startIndex:)`) and
owns startup: `AudioService.init` registers the handler with the OS notification/lock-screen
integration on Android/iOS/macOS; on a platform `audio_service` doesn't cover for this app
(Windows, used for tests/screenshots per the top of this doc) it falls back to a bare
`MusicAudioHandler()` — playback still works through `just_audio` directly, just without the
system media surfaces. `favoriteCurrent()`/`dislikeCurrentAndSkip()` on the handler are what
Now Playing's swipe gestures and the notification/widget controls ultimately call.
`just_audio`'s `playbackEventStream` only fires on discrete state changes (buffering, track
load, pause/play), not once a second, so `MusicAudioHandler` also runs a one-second
`Timer.periodic` (started/stopped off `playingStream`) that re-broadcasts `playbackState` while
playing — otherwise Now Playing's progress bar/position text sits frozen between events instead
of ticking (0.2.63). It also listens to `durationStream` and patches the current `MediaItem`'s
`duration` once the player itself reports it, since a track's tag-derived `durationMs` (from
library scanning) isn't reliably populated and was leaving the progress bar's total time at
0:00.

**Favorites, "Don't really like" and the weighted shuffle**
(`lib/services/music_playlist_service.dart`, singleton `MusicPlaylistService.instance`,
persisted to `music_playlists.json`): two fixed system playlists
(`MusicPlaylist.favoritesId`/`dislikedId`) plus any number of user/imported ones
(`MusicPlaylist` model: id/name/`trackIds`/`isSystem`). `weightedShuffle` builds a shuffled
play order using Efraimidis–Spirakis weighted random sampling without replacement: each track
gets a key of `random()^(1/weight)` and the result sorts descending by key — favorited tracks
(weight 3.0) tend to land earlier, disliked tracks (weight 0.05, a 60x ratio) tend to land much
later, ordinary tracks (weight 1.0) fall in between, and every track can still appear (nothing
is ever hard-excluded, since a mood can change). `toggleFavorite`/`markDisliked` are mutually
exclusive on a track (favoriting clears a dislike and vice versa).

**Shuffle toggle and queue reordering** (0.2.65 — `MusicAudioHandler.toggleShuffle`/
`reorderQueue`, `lib/ui/queue_page.dart`'s `QueuePage`): a shuffle icon button in Now
Playing's bottom tools row (`ValueNotifier<bool> shuffleEnabled`) shuffles only the not-yet-played
tail of `_queue`, leaving playback history and the current track's position untouched;
toggling it back off restores the tail's pre-shuffle order (captured in `_preShuffleOrder`
when shuffle turns on). A "Queue" icon button next to it opens `QueuePage`, a
`ReorderableListView.builder` (same drag-handle pattern as the task list, `home_page.dart`'s
`_reorderTask`) over `MusicAudioHandler.currentQueueTracks`; dragging calls `reorderQueue`,
which moves the track and keeps `_queueIndex` pointing at whichever track is actually
playing even if its position shifted, then clears `_preShuffleOrder` (a manual drag is a
new baseline order, not something a later shuffle-off should undo). This is separate from
the existing `weightedShuffle`-driven "radio" reshuffle that happens when the queue runs
off the end (**Playback engine**, above) — that automatic reshuffle from the full library is
unaffected by the shuffle toggle.

**Now Playing swipe gesture** (`lib/ui/now_playing_page.dart`): a `GestureDetector` on the
artwork/title column tracks vertical drag distance and velocity; crossing a distance or
velocity threshold upward calls `favoriteCurrent()`, downward calls
`dislikeCurrentAndSkip()` (marks disliked, then immediately skips) — both also available as
plain buttons in the transport row for a non-swipe fallback. A brief toast-style label flashes
to confirm which action fired.

**M3U/M3U8 import** (`lib/services/m3u_playlist_service.dart`): Samsung Music has no public
API or an easily-parsed database without root, but it (like most music apps) can export/share
a playlist as `.m3u`/`.m3u8`. `M3uPlaylistService.parseEntries` strips `#EXT...`
directives/comments/blank lines and decodes `file://` URIs; `importFile` matches each
remaining entry against the scanned library first by exact normalized path, then by file
basename (case/extension-insensitive — the common case, since a playlist made on another
device/app rarely carries this app's exact folder path), and reports what didn't match rather
than silently dropping it. A match creates an ordinary (non-system) `MusicPlaylist`.

**Music server (Best Music 0.3.34)** (`lib/services/subsonic_client.dart`'s `SubsonicClient`,
`lib/services/subsonic_library_sync.dart`'s `SubsonicLibrarySync`, `TrackSource.subsonic`): a
Subsonic/OpenSubsonic server (Navidrome, Airsonic, Gonic, …), typically the Navidrome on the
MagicMirror Pi (`http://hally.local:4533`, see the MagicMirror repo's
`headless-mirror/docs/music-server.md`). Settings → **Music server** has the address, user name
and password (`Config.subsonicServerUrl/Username/Password`), Test connection (`ping`), Sync now,
Automatic sync (`Config.subsonicSyncWindow`, default `01:00-06:00`) and Remove this server.
Auth follows the Subsonic token scheme: `token = md5(password + fresh salt)` on every request,
so the plaintext password never goes on the wire (it is stored in plaintext on the device).
- **Streaming:** `streamUri(songId)` asks for `format=raw`, the original file, so a small
  server never transcodes; `MusicAudioHandler._audioSourceFor` plays it like any other URL.
- **Library:** a sync lists every song with `search3` (empty query, `songOffset` pages of
  `SubsonicClient.pageSize` = 500; `allSongs()` returns null if any page fails, so a half list
  never replaces a full one) and `MusicLibraryService.replaceServerTracks` puts them in the
  same library as the folder's songs (id `subsonic:<id>`; date added, play count, tags and hand
  edits kept across syncs; songs gone from the server leave). A folder `rescan` keeps the
  server songs. Title, artist, album, genre, year and BPM come from the server's own tag scan;
  the phone never downloads server songs to analyse them (`MusicMetadataEnricher` only handles
  folder songs). After the listing the sync reads `getScanStatus` (`ServerScanStatus`: scanning,
  count, lastScan; kept in `SubsonicLibrarySync.serverScan`, also fetched at app start) and,
  when search3 gave nothing or fewer songs than the server says it scanned, walks the library
  album by album instead (`allSongsByAlbum`: `getAlbumList2` alphabeticalByName pages +
  `getAlbum` each, songs de-duplicated by id) and keeps the longer list (0.3.39). The Server
  tab header shows what the server itself knows ("The server itself knows N songs · last
  scanned …", or that it is scanning) and has **Scan server**: `scanServerThenSync` calls
  `startScan` (Navidrome: admin accounts only; refused → a snackbar says so), polls
  `getScanStatus` every 5 s (at most 30 min) until the scan is done, then syncs. Server paths
  lose a leading `/` (Navidrome real paths like `/music/...` made a nameless top folder).
- **When:** the full listing is the one bulk job the app asks of the server, so it runs on its
  own only inside the sync window (the same night window the Pi's Navidrome scans in), at most
  once per window (`SubsonicLibrarySync.minGap` 12 h), while the app is running: at start, on
  resume and every 15 minutes. Sync now runs it right away. Playback needs no sync.

**Server tab (Best Music 0.3.35)** (`lib/ui/server_tab.dart`, `lib/services/server_catalog.dart`,
`server_offline_store.dart`, `server_upload_service.dart`): the music server's songs as folders,
like OneDrive.
- **Catalog:** every sync stores the server's full song list in `ServerCatalog`
  (`server_catalog.json`), with each song's real folder path (`Track.remotePath`; the Pi's
  Navidrome reports real paths, `[Subsonic] DefaultReportRealPath`) and size. The library gets
  the same songs minus those already on the phone (`sameSong`: same file name, or same artist +
  title normalised with lengths within 2 s, the rule the Pi's nightly clean-up uses;
  `SameSongIndex` keeps it quick), so every song shows once. The Folders tab groups server songs
  under `Server/<folder>`.
- **The tab:** without a login it shows the login form (address prefilled
  `http://hally.local:4533`, Connect = ping, save, sync). With one it shows a header (server,
  song count, last sync, Sync now, Upload phone music), then folders and songs. Each has an
  offline-state icon (online only / downloading / on this phone / partly) and a menu. Tapping a
  song plays that folder from it.
- **Always keep on this device / Free up space** (`ServerOfflineStore`, `server_offline.json`):
  rules on folders and songs, and the nearest rule above a song wins. Kept songs download one at
  a time (`/rest/download`, the original file, a background-work notification) into
  `<documents>/server_music/<server path>`, and `MusicAudioHandler` plays that copy instead of
  streaming. New songs in a kept folder download after the next sync; freed songs' copies are
  deleted. Free up space also offers to delete the phone's own copies (music-folder files
  matching songs in that folder, e.g. ones uploaded from here) after a confirm showing the MB.
  The library then rescans and the server copies take their place.
- **Upload phone music** (`ServerUploadService`): asks the Pi's upload service (the server's host,
  port 4534, `mirror-music-upload` in the MagicMirror repo) which phone songs it lacks (`POST
  /api/music/check`, same name and size anywhere, or the same path in `Phone/`). It then sends
  them one at a time (`PUT /api/music/upload?path=<path under the music folder>`, streamed). Same
  login: the Subsonic token on every request, checked by the Pi against Navidrome. They land in
  the server's `Phone/` folder and appear after its nightly scan; its nightly clean-up moves
  duplicates to a 30-day trash.
- **Delete / Move to folder** (0.3.40, `TrackFileActions`, `lib/ui/track_file_menu.dart`): in
  every song row's ⋮ menu (`TrackListView`: Tracks, Folders, playlists, search) and on server
  songs in the Server tab, for phone files and server songs (not YouTube streams). Delete asks
  first. Move offers the top folder, every folder (music folder subfolders / server catalog
  folders) and "New folder…" (`cleanFolder`: no `.`/`..`, forward slashes). A phone song is
  deleted/renamed on disk (copy + delete if a rename fails; never over an existing file); the
  library entry follows (`removeTracks` / `replaceTrack`) and playlists too
  (`removeTrackEverywhere`, `renameTrackId` — a moved file's `local:<path>` id changes). A server
  song goes to the Pi's upload service, same token auth as upload:
  `POST /api/music/delete` `{"id", "path"}` → 200, and `POST /api/music/move`
  `{"id", "path", "to"}` → 200 `{"path": <new path>}`; `path`/`to` as Navidrome reports them
  without a leading slash, `id` the Subsonic song id. On success the catalog and library are
  updated right away (the Pi's next scan confirms). The Pi side is `music-upload-server.py` in
  the MagicMirror repo (2026-10-15): deletes go to its 30-day music trash (`mirrorctl music trash
  restore`), moves never overwrite (409), and a path that isn't found falls back to the song id
  via `getSong`. A Pi without them answers 404 and the app says the server needs an update.
  Navidrome there has no file watcher, so a moved server song streams again only after its next
  scan (night, or Scan server) — the move snackbar says so.
- **Search** (0.3.40, `LibrarySearchResults`): library matches (synced server songs among them)
  plus, with a server set up, the server's own `search3` for the query (400 ms after typing
  stops) — songs the library doesn't have yet and that aren't on the phone. Server songs show a
  cloud icon (`trackSourceIcon`, tooltip "On the music server") in every song list. YouTube is
  the fallback only when both come up empty.
- Android needs `usesCleartextTraffic` for the plain-http home server.

**Home-screen widgets and notification/lock screen:** see §8 for the two widgets
(`MusicMiniWidgetProvider`/`MusicControlsWidgetProvider`) and §9 for the `audio_service`
manifest wiring. The system media notification and lock-screen controls (previous, play/pause,
next — no Stop button, by request) come from `audio_service` itself once `AudioService.init` registers the handler — no
custom notification code needed, unlike the alarm subsystem's hand-built full-screen
notification (§5, §6).

**YouTube fallback in search (Best Music 0.2.93 / BestToDo 0.2.92).** When the library search (`_MusicSearchDelegate`)
finds no track for a non-empty query, it shows `YoutubeSearchFallback` (not on web, where
`Mp3DownloaderService.isSupported` is false), which searches YouTube **automatically**
(Best Music 0.2.98; before that it waited for a "Search on YouTube" tap) once typing pauses
for `YoutubeSearchFallback.debounce` (600 ms — the widget is keyed by the query, so each
keystroke disposes the old one and cancels its timer), via
`Mp3DownloaderService.search(q, limit: 10)`. Results sit under a "Not in your library" banner
card ("Results from YouTube, not songs on your phone...", spinner while searching); each row
has a video icon, a "YouTube · channel · duration" subtitle and a cloud-download icon, so it
can't be mistaken for a local song. Errors show the real message plus "Try again". Tapping a result goes through `SpeakerPlayGuard.confirmPlay`, then
`MusicYoutubeFallback.playAndDownload` (`lib/services/music_youtube_fallback.dart`) does two
things at once: (1) silently queues the video on `Mp3DownloadManager` — no folder prompt; the
folder is `Config.mp3DownloadFolder` if set, else `Config.musicFolder` if writable, else
`defaultDownloadFolder()`; skipped if a job for the same video id is already active or
completed with its file still present — so `MusicDownloadLibrarySync` rescans it into the
library when it lands there; (2) plays a one-track queue of `Track.youtube(videoId, ...)`
(`TrackSource.youtube`, id `youtube:<videoId>`, `remoteId` = video id, `artUrl` = the
`hqdefault.jpg` thumbnail, title/artist from
`parseTrackTitle` so it matches the downloaded file's tags), then opens Now Playing.
The YouTube track plays through the same `YoutubeAudioSource` path the Subscriptions feed
uses (thumbnail as cover art), so a restored "last played" YouTube track still works after a
restart.

**YouTube search goes through the JSON API (Best Music 0.2.95 / BestToDo 0.2.93).** `Mp3DownloaderService.search` (used by
the search fallback above and the MP3 Downloader) first calls `YoutubeSearchApi.search`
(`lib/services/youtube_search_api.dart`): a POST to `youtube.com/youtubei/v1/search` with a WEB
client context and the "videos only" `params` (`EgIQAQ==`), parsing every `videoRenderer` in
page order (title, channel, `lengthText` clock → duration, view count, "N years ago" →
approximate upload date for the year tag). Only if that fails or returns nothing does it fall
back to `youtube_explode_dart`'s `search.search`, which scrapes the HTML results page with the
legacy `CONSENT=YES+cb` cookie — in the EU that page can be Google's consent interstitial, so
every search failed on a working connection (reported as "YouTube search failed. Check your
connection"). A failure now throws `Mp3DownloadException('YouTube search failed: <cause>')`
and the search fallback shows that message instead of a generic connection hint.

**Settings → Music Player** (removed from BestToDo in 0.2.98, §10.6n; was `lib/ui/settings_page.dart`, section 16): folder picker (shares
the `file_selector` `getDirectoryPath` pattern §4.4/§10.6d use), an "Excluded subfolders"
dialog populated from `MusicLibraryService.listSubfolders`, and the Subsonic server
URL/username/password fields with Save/Test connection (in Best Music these are Settings →
Music server since 0.3.34). `Config.featureKeys`/
`startToolOptions` gained a `music_player` entry (`_ToolEntry` in `home_page.dart`, case in
`_buildToolPage`), same wiring pattern as every other tool.

**Known gaps, honestly stated:** this shipped from a single development session without
access to a physical Android device, an emulator, a real Subsonic server, or Samsung Music
itself — `flutter analyze`/`flutter test` are clean and the pure-Dart logic (library scan,
exclusions, weighted shuffle, M3U parsing/matching, Subsonic URL/auth shape) is unit-tested
(`test/music/`), but the native Android side (the two widgets' `RemoteViews`, the
`MediaButtonReceiver` broadcast wiring, the actual system notification/lock-screen chrome, and
playback itself) has not been run on-device and needs manual verification on a real phone
before relying on it. The M3U importer is built against the general-purpose M3U/M3U8 spec,
not a Samsung Music export sample, on the assumption documented in this section (a plain path
list, possibly `file://`, matched by basename when the exact path doesn't line up) — worth
confirming against a real Samsung Music export.

### 10.6f Best Music — a second app from the same codebase (0.2.66, drawer + Settings + About 0.2.67)
`lib/main_music.dart` is a second entry point, built as its own Android app rather than a
BestToDo tool: no task list, alarms, sync, or any other to-do feature — just §10.6e's Music
Player as the home page, with a proper drawer menu (MP3 Downloader, Wishlist, Settings,
Changelog, Startup Times, App Logs, About — see §10.6h for Wishlist) mirroring BestToDo's own
home page. Installs side by side with
BestToDo on the same device (separate `applicationId`, so Android sandboxes its storage
independently — no data collision with BestToDo's own `Config`/library files).

**Build**: `android/app/build.gradle.kts` defines two product flavors under a single `app`
flavor dimension — `todo` (BestToDo, `applicationId` unchanged, still the default: `flutter
build apk` now requires an explicit `--flavor`, so `tool/build.sh` injects `--flavor todo`
when a caller doesn't pass one) and `music` (`applicationId com.mfficiency.best_music`).
`sh tool/build.sh music-apk --release` (or `powershell -ExecutionPolicy Bypass -File
tool\build.ps1 music-apk --release`) is shorthand for `flutter build apk --release --flavor
music -t lib/main_music.dart`; Gradle's `createVersioned<Flavor>ReleaseApk` task — **one task
per flavor**, each finalizing only its own `assemble<Flavor>Release` — renames that flavor's
output to `best_todo_<version>.apk` or `best_music_<version>.apk`, matching what
`tool/stage_local_release.dart --prefix
best_music` stages into `github_releases/` alongside BestToDo's own APKs — both apps' last two
builds live in that one folder, pruned independently by prefix (`namesToPrune` is prefix-blind;
`main()` filters `present` to the caller's own prefix before pruning, since a prefix-blind prune
could otherwise delete the wrong app's build purely by version-number coincidence — see §10.6i
for why that's true even though the two apps no longer share one version).

**Branding, not a fork**: app label (`res/values/strings.xml` `app_name`, overridden per flavor
in `src/music/res/values/strings.xml`) and Best Music's icon set are the flavor-specific
Android resources (the music flavor's own manifest additions — share filter, widgets — aside).
**Icon (Best Music 0.3.13)**: a black eighth note with a motion blur trailing left, on white
(the user's artwork; generated from one 1254 px source by a one-off PIL script — ink alpha =
(250 − luminance) scaled to 0–255, background forced to pure white):
`mipmap-*/ic_launcher.png` (48–192 px full tiles, legacy launchers);
`mipmap-anydpi-v26/ic_launcher.xml` adaptive icon — `@color/ic_launcher_background` (#FFFFFF,
`src/music/res/values/colors.xml`), foreground `mipmap-*/ic_launcher_foreground.png`
(108–432 px, transparent, the source square scaled to 76 of the 108 dp so the note keeps its
framing inside the 66 dp safe zone; also the Android 12+ splash icon) and the same file as the
`<monochrome>` layer for Android 13 themed icons; `drawable-{m..xxx}hdpi/ic_stat_music_note.png`
(24–96 px white-on-transparent silhouette cropped to the note) overriding main's vector
`ic_stat_music_note` for the media and background-work notifications; and the Flutter asset
`assets/branding/best_music_icon.png` (512 px) shown by `BestMusicLogo`
(`lib/ui/best_music_logo.dart`, rounded tile) in the drawer header (40 px, beside "Best Music
vX") and at the top of the About page (96 px). BestToDo keeps its own icons; everything else (permissions, receivers/services, signing)
stays the single shared manifest, unused permissions in the Best Music APK included — a
deliberate simplification since it is sideloaded, not Play-Store-distributed.

**In-app updates** (history; since 0.2.107 each app has its own `UpdateController` of the
shared updates package with its own tag prefix, `AppUpdates` — §11): `UpdateService` gained per-app instance config (`appDisplayName`,
`apkPrefix`, via `UpdateService.forApp(...)`; `UpdateService.instance` stays BestToDo's own
`best_todo`/`BestToDo` default) so each app's folder/release lookup only ever considers its own
prefix — a bare version-number regex over the whole `github_releases/` listing would otherwise
happily match the other app's file name too. A non-default app's `checkReleases` skips the
repo-wide "latest release" fallback entirely (GitHub's `releases/latest` endpoint isn't
per-app), reporting no update rather than risking BestToDo's release. *(Superseded in 0.2.101: both apps publish GitHub releases with their own
tags per channel — see §11 "Laptop channel builds".)*

**The drawer/menu (0.2.67)**: `MusicPlayerPage` gained a `standalone` flag (true only from
`main_music.dart`). Standalone, its `Scaffold` carries `key: homeScaffoldKey` and a real
`Drawer` — the same key `home_page.dart` uses for its own — so it is the Best Music app's home
page in the same sense BestToDo's home page is: `buildSubpageAppBar`'s "Menu" button (used by
every page the drawer pushes: MP3 Downloader, Wishlist, Settings, Changelog, Startup Times, App
Logs, About) opens it via that shared key, and its own app bar (no `buildSubpageAppBar`, since as the
root route it has no "Back to Home" to offer) gets Flutter's automatic drawer-hamburger button
for free from `Scaffold.drawer` being non-null. Drawer order (0.3.33): Home · Settings ·
Subscriptions · **Tools** (a collapsed `ExpansionTile` holding Songs by BPM, MP3 Downloader and
Wishlist) · Changelog · About · App Logs · Startup Times. `lib/ui/music_settings_page.dart` is a
standalone settings page — the music folder picker and excluded-subfolders dialog are
reimplemented from BestToDo's Settings → Music Player section (`settings_page.dart`) since that
page is one monolithic widget tightly coupled to BestToDo's full settings list. Since Best
Music 0.3.3 it is laid out like BestToDo's Settings: a pinned row of `ChoiceChip` section
buttons (tap = open that section and scroll to it; the chip of the section at the top of the
viewport is highlighted and kept on screen), collapsible `Card` sections that all start
closed (header tap toggles; tooltip "Expand <title>"/"Collapse <title>") and a Collapse
all/Expand all button. Sections (`MusicSettingsSection`): Library (music folder, forget,
excluded subfolders), Playback (ask before playing out loud, music volume, sleep timer),
Appearance (dark mode), Subscriptions feed and SponsorBlock (§10.6m), Updates (downloads
folder). `initialSection` opens one section on arrival; the body is a
`SingleChildScrollView` so every section's context exists for `Scrollable.ensureVisible`.
`lib/ui/music_about_page.dart` mirrors `AboutPage` (Best Music branding + an
`UpdateService.forApp` instance, exposed as `MusicAboutPage.updateService` for tests) — the
`UpdateSection` widget (`about_page.dart`, made public and given optional `service`/`appName`
params for this) is shared between the two About pages rather than duplicated. Reusable as-is,
unmodified: `ChangelogPage` (pure CHANGELOG.md rendering, no BestToDo-coupled service),
`StartupTimesPage` (`StartupTimeService.start()`/`.record()` added to `main_music.dart`,
mirroring `main.dart`, so it has real data) and `AppLogsPage` (its Sync/Todoist tabs just stay
empty for Best Music, which never touches those services — a known, harmless simplification
rather than forking the page to hide them).

**CI**: `.github/workflows/build-apk.yml`'s `build_music_apk` job builds the `music` flavor on
every push to main/staging/dev, uploads it as a workflow artifact, and — mirroring what a local
`sh tool/build.sh music-apk --release` does — stages it into `github_releases/` (`--prefix
best_music`) and commits+pushes (rebase-and-retry against the `build` job's own same-branch
push, same pattern `screenshot_changelog.yml` uses). Deliberately does *not* also publish to a
GitHub release the way `tool/publish_apk.dart` does for BestToDo: see `UpdateService.checkReleases`'s
doc comment for why a repo-wide `releases/latest` isn't safe to reuse for a second app sharing
this repo — the folder stays each app's only update-check source. *(Superseded in 0.2.101: both apps publish GitHub releases with their own
tags per channel — see §11 "Laptop channel builds".)*

### 10.6g Smart & rule-based playlists, extended track metadata, Best Music auto-update (0.2.70, hand-built playlist management 0.2.71, in-app metadata scan + editor 0.2.74, CSV bulk metadata export/import 0.2.77)
**Extended `Track` metadata**: `genre` (`String`, default `''`), `year` (`int?`), `dateAdded`
(`DateTime?`) and `playCount` (`int`, default 0) added to `lib/models/track.dart`, all tolerant
of missing keys in `fromJson` and omitted from `toJson` when empty/zero/null (same
minimal-JSON convention as the rest of the model). `Track` stays immutable (`final` fields); a
new `copyWith` is how the library scan/audio handler update just the fields that changed.
`dateAdded`/`playCount` are scan-preserved, not scan-derived: `MusicLibraryService.rescan()`
merges each freshly-scanned `Track` with the previous library entry of the same `id` (falling
back to `DateTime.now()`/`0` for a track seen for the first time) — a rescan refreshes tags, it
must never reset "when was this added" or "how many times has this been played".

**Metadata extraction moved to `lib/services/music_metadata_extractor.dart`** — pure Dart (only
`dart:typed_data` + `package:id3_codec`, no Flutter import), decoding `TIT2`/`TPE1`/`TALB` (as
before) plus `TCON` (genre, stripping an old ID3v1 `"(17)Rock"`-style numeric-code wrapper down
to the trailing name) and `TDRC`/`TYER`/`TDOR` (year, first 4-digit run). `MusicLibraryService`
calls this from `_buildTrack` instead of decoding tags itself; still mp3-only, still capped to
the first `id3ReadCap` (1 MiB) bytes — m4a/flac/etc. still fall back to filename-as-title with
no metadata, unchanged from §10.6e. Never throws — an unreadable/absent tag yields an
all-null `ExtractedTags`, same fallback-to-filename behavior as before.

**`tool/scan_music_metadata.dart`** — a standalone `dart run` script (no Flutter engine, no
`flutter test` harness) sharing that same extractor module, so it reports exactly what the app
itself would see. Walks a folder recursively and prints (or `--out file.json` writes) a JSON
array of `{path, title, artist?, album?, genre?, year?}` per supported audio file, plus a
scanned/tagged-count summary on stderr. For sanity-checking a whole collection's metadata
coverage (which files actually have a readable genre/year) before relying on it for rule
playlists — independent of the app, the music folder setting, or a device.

**Play count**: `MusicLibraryService.incrementPlayCount(trackId)` bumps and persists one
track's count. Called from `MusicAudioHandler`'s `processingStateStream` listener only on
`ja.ProcessingState.completed` (a track that played to the end) — a manual `skipToNext`/
`skipToPrevious` never reaches that stream state, so skipping doesn't count as a play.

**Smart (computed) playlists** — `MusicPlaylist` gained a `kind` (`PlaylistKind`: `list` — the
existing stored-`trackIds` behavior, now the explicit default; `lastAdded`; `mostPlayed`; `rule`)
plus `genreFilter` (scopes `mostPlayed`) and `ruleSet` (drives `rule`), all JSON round-tripped.
`MusicPlaylistService.smartPlaylists` computes "Last Added" and "Most Played" (overall, plus one
per distinct `Track.genre` present in the library) fresh from `MusicLibraryService.instance.tracks`
on every read — never persisted, never deletable, empty entirely when the library itself is
empty. "Last Added" caps at `smartPlaylistLimit` (50) tracks; every "Most Played" list
(overall and per genre) at `Config.mostPlayedLimit` (`settings.json` key `mostPlayedLimit`,
default 50, clamped to 1..1000 on load), set under Settings → Playback → "Most Played size"
(a number dialog; anything outside 1..1000 is rejected with a snackbar). Changing it re-announces
`MusicPlaylistService.playlists` (`notifySmartPlaylistsChanged`) so the Playlists tab's counts
follow. `MusicPlaylistService.resolvedTracks(playlist)`
is the one place that turns any `MusicPlaylist` (whatever its `kind`) into an actual `List<Track>`
— `MusicPlaylistDetailPage`/the Playlists tab's track-count subtitle both go through it instead of
reading `trackIds` directly, so they work uniformly across stored and computed playlists.

**Playlists tab order** — hand-made playlists (Favorites/"Don't really like", hand-built, M3U
imports, rule playlists, in stored order) come first, then the New playlist / New rule playlist /
Songs by BPM rows, then "Last Added" and the overall "Most Played". The per-genre "Most Played"
lists sit in a collapsed "Most played by genre" `ExpansionTile` (subtitle "N genres", each entry
titled by its genre alone; the detail page keeps the full "Most Played: <genre>" name). The group
is omitted when no track has a genre.

**Rule-based ("smart" in the iTunes/Plex sense) playlists** — `lib/models/playlist_rule.dart`:
`RuleCondition` (a `RuleField` — title/artist/album/genre/year — a `RuleOperator`, and a
`values` list) plus `PlaylistRuleSet` (a `RuleCombinator.all`/`any` over a list of conditions).
Deliberately a **flat** model, not a nested AND/OR/NOT expression tree: NOT lives per-condition
(`notEquals`/`notContains`/`notInList`), OR lives inside one `inList` condition's value list
("Artist A or Artist B"), and AND is `RuleCombinator.all` across conditions ("genre X and
released last year, excluding Artist C" is three conditions ANDed together). This covers every
case actually asked for with a UI and evaluator an order of magnitude simpler than a real
boolean-tree editor, at the cost of not supporting an arbitrary nested expression (e.g. "(A or B)
and not (C and D)") — acceptable for a personal playlist-building tool. `year` is the only
numeric field (`greaterOrEqual`/`lessOrEqual` besides the text operators); an empty rule set
matches nothing (not "everything") so a freshly created empty rule playlist reads as empty
rather than the whole library. `lib/ui/rule_playlist_editor_page.dart` is the builder: a name
field, an all/any selector, and a dynamic list of field/operator/value rows (comma-separated
values for `inList`/`notInList`) — reachable from the Playlists tab's "New rule playlist" row,
or an existing rule playlist's edit icon (`MusicPlaylistService.createRulePlaylist`/
`updateRulePlaylist`). Rule playlists are ordinary (non-system) playlists — deletable like any
hand-built one.

**Best Music's own background update poll** (history; the shared updates package's
polling since Best Music 0.3.27, §11): `AutoUpdateChecker.start`/`checkOnce` gained an
optional `service` parameter (defaults to `UpdateService.instance`, so BestToDo's own wiring in
`main.dart` is unchanged) so the same checker class can drive a second app's update instance.
`main_music.dart`'s `BestMusicApp` became a `StatefulWidget` that starts it (Android only,
pointed at `MusicAboutPage.updateService`) in `initState`, showing the same "New version
available" dialog (`showUpdateAvailableDialog`, removed in 0.2.98 — updates now install with no
dialog, see §11) and background download
(`downloadUpdateInBackground`) BestToDo's own poll uses, via a dedicated `musicNavigatorKey`
(mirrors `appNavigatorKey`) since there is no `BuildContext` on hand outside the widget tree.
Best Music has no Settings toggle for this yet (unlike BestToDo's "Automatically check for
updates" switch) — it simply always polls; the manual "Check for updates" button on
`MusicAboutPage` (§10.6f) is unaffected either way.

**Hand-built playlists (0.2.71)** — the plain, add-songs-yourself kind Samsung Music and every
other player offer, previously only reachable via M3U import: the Playlists tab's "New playlist"
row prompts for a name (`promptPlaylistName`/`_PlaylistNameDialog` in `music_player_page.dart` —
its own `StatefulWidget` owning the `TextEditingController`, per the "never dispose right after
`showDialog` returns" convention) and creates an empty `PlaylistKind.list` playlist via the
existing `MusicPlaylistService.createPlaylist`. Every song row (`TrackListView`, shared by the
Library tab and every playlist detail page) gained an "Add to playlist" button
(`showAddToPlaylistSheet`) opening a bottom sheet: a `CheckboxListTile` per hand-built,
non-system playlist (`kind == list && !isSystem` — this excludes Favorites/"Don't really like"
and every smart/rule playlist, which aren't a plain track list to add to) checked when the track
is already in it, toggling `addTo`/`removeFrom` immediately on tap, plus a "New playlist" row at
the top that creates one pre-filled with the current track without leaving the sheet. Removing a
song again happens on the playlist itself: `MusicPlaylistDetailPage` now passes `TrackListView`
an `onRemove` callback (a "Remove from playlist" icon per row) only when the playlist being
viewed is itself a hand-built, non-system one — Favorites/disliked stay swipe-gesture-only, and a
smart/rule playlist's tracks aren't stored to remove from in the first place.

**In-app metadata scan + editor (0.2.74)** — `Track` gained `metadataEdited` (`bool`, default
false, omitted from JSON when false). `MusicLibraryService.rescan` now takes an optional
`onTrackScanned(int scanned, Track track)` callback, fired once per supported file found (with
that file's already-merged final `Track` — dateAdded/playCount preserved as before, and, new
here, its title/artist/album/genre/year preserved too when the previous entry had
`metadataEdited: true`, instead of being overwritten by a fresh — possibly still empty — tag
read); the per-file merge/callback logic that used to run as a separate pass after the whole
folder was walked was folded into the main scan loop so the callback sees final values without a
second pass. `MusicLibraryService.updateTrackMetadata(trackId, {title, artist, album, genre,
year})` sets those fields to exactly the given values (required, not merged via `copyWith`'s
`?? this.field` pattern — an editor needs to be able to clear a field, which that pattern can't
express) and sets `metadataEdited: true`.

`lib/ui/music_metadata_scan_page.dart` (`MusicMetadataScanPage`, opened from
`MusicPlayerPage`'s app bar, "Metadata scan" icon next to "Rescan library") runs `rescan` on
open (and again on its refresh action) and renders every track live as `onTrackScanned` fires —
a `LinearProgressIndicator` plus a running count while scanning, then a
found/with-genre/with-year summary, with each row showing a green check (both genre and year
known), orange (one of the two) or red (neither) icon. Tapping a row opens
`lib/ui/track_metadata_page.dart` (`TrackMetadataPage`), also reachable via a new "Track info"
(ⓘ) button on Now Playing's bottom tools row (disabled — `onPressed: null` — while nothing is playing):
editable title/artist/album/genre/year fields pre-filled from `MusicLibraryService.byId`, plus
read-only duration/play count/date added/source/file path, and a note when the track was already
manually edited. Saving calls `updateTrackMetadata`; an unparsable year shows an inline error
instead of saving. This only ever changes this app's own cached record (`music_library.json`) —
it does not write ID3 tags back into the file itself, which stays a possible future addition, not
something either page does today.

Widget tests that pump a page whose `initState` triggers `rescan` (`MusicMetadataScanPage`) poll
with real delays (`tester.runAsync(delay) + pump()`, condition-driven on the progress indicator
disappearing) rather than `pumpAndSettle()`, which both never resolves the real dart:io Future
inside `testWidgets`' fake-async zone and would hang forever on the indeterminate
`LinearProgressIndicator` even if it did (see CLAUDE.md's "Real file I/O hangs inside
testWidgets" note) — and set the page's initial "scanning" field directly in `initState` rather
than via `setState` (illegal before `initState` returns), letting only the later, async-gap
`setState` calls do the rebuilding.

**CSV bulk metadata export/import (0.2.77)** — a way to fill in metadata for a whole collection
at once outside the app (e.g. hand it to an AI), for when editing one track at a time via
`TrackMetadataPage` doesn't scale. `lib/services/music_metadata_csv.dart` (`MusicMetadataCsv`):
`encode(tracks)` writes one CSV row per track — `id, filename, title, artist, album, genre,
year` — reusing `UsageDataService.csvField`/`toCsv` for RFC-4180-style quoting rather than
duplicating that escaping logic (`UsageDataService`'s CSV primitives are public statics
precisely so other export features can share them). `decode(csvText)` is a hand-rolled decoder
(no `csv` package dependency; none existed in the codebase and none was added) — a small
state-machine parser handling quoted fields, doubled-quote escaping, CRLF/bare-LF line endings,
and a missing trailing newline, then looking columns up **by header name** (case-insensitive,
tolerant of reordering/missing/extra columns) rather than by position, so a spreadsheet round
-trip that reorders columns still imports correctly. A row's `id` is the match key (the export's
`filename` column is read-only context for an AI when a file has no tags to go on at all —
title/artist/album are also empty in that case); a row with a blank `id` is skipped, and a file
with no `id` column at all decodes to zero rows rather than guessing.

`MusicLibraryService.applyMetadataRows(List<ParsedMetadataRow>)` matches each row's `id` against
the library and, for every match, sets `title`/`artist`/`album`/`genre`/`year` — but **only the
non-empty fields**: a blank cell leaves that track's existing value untouched, so a spreadsheet
edit that accidentally clears a cell (or an AI that only filled in the columns it was asked to)
can't silently erase data the app already had. Every matched row gets `metadataEdited: true`,
same as a manual `TrackMetadataPage` edit — so it also survives a later rescan (§ above). Returns
how many rows matched, for the caller's "Updated N of M" summary.

The UI lives on `MusicMetadataScanPage`, alongside the scan itself: "Export metadata CSV" writes
the current library (`MusicLibraryService.instance.tracks.value`, not just what's scanned into
the page's own live list — so it works even without running a fresh scan first) to a file in
`getTemporaryDirectory()` and hands it straight to the OS share sheet
(`SharePlus.instance.share(ShareParams(files: [XFile(path)]))` — the same pattern
`attachments_field.dart` uses to share an attachment) rather than a folder-picker write like
`UsageDataPage`'s CSV export — simpler for "get this file into another app" than picking a save
folder first. "Import filled-in CSV" uses `file_selector`'s `openFile` (same pattern as the M3U
import in `music_player_page.dart`), reads and decodes the file, applies it, and refreshes the
scan page's already-displayed rows in place (looked back up by id) so their status icons update
without a full rescan. Neither the export/import buttons themselves nor the M3U import they
mirror are exercised in `testWidgets` — both go through a real OS file picker/share sheet with no
test seam in this codebase, so only the pure `MusicMetadataCsv`/`applyMetadataRows` logic
underneath is unit tested.

### 10.6h Best Music Wishlist (0.2.75, briefly shared across both apps 0.2.78-0.2.83, reverted to
local-only Best Music 0.2.84 — see §10.6i for the version split)
Drawer → Wishlist (`lib/ui/music_wishlist_page.dart`) gives Best Music the same wishlist
BestToDo has (§10.7's Wishlist tool), reduced to its plainest form. Items are ordinary `Task`
records flagged `isWish` — the same `ItemRepository`/`StorageService` seam BestToDo's own
Wishlist reads and writes (`tasks.json`, unchanged JSON shape). Priority (`0..3`, stored as one
of the `priority-low`/`priority-medium`/`priority-high` label tokens) is shared code too:
`lib/utils/wish_priority.dart` (`wishPriorityLabels`/`wishPriorityRank`/`setWishPriority`/
`bumpWishPriority`) is the single source both `wishlist_page.dart` and `music_wishlist_page.dart`
import, rather than each keeping its own copy.

Unlike BestToDo's Wishlist, this page carries none of that tool's build-tracking chrome
(release-group sections, GitHub "Send to build", swipe-to-reveal Share/Copy/Export/Delete,
multi-select) — those are specific to BestToDo's own development workflow, not something Best
Music's users need. Each row is just a leading `Checkbox` (toggles `isDone`/`completedAt` and
saves immediately, no editor needed — Best Music 0.2.83; the original "no icons at all" design
was amended once actually asked for) and the title (struck through once done) — no priority/tag chips, no
trailing icon. Tapping the title itself pushes a full-page editor for everything else: a "Done"
switch (kept there too, alongside the list's own checkbox), priority as three `ChoiceChip`s, tags
via the shared `LabelPickerField`, and a multi-line description field. The app bar's check icon
saves; a delete icon (edit mode only) confirms then removes the item. Adding is the same editor
with no item, reached via the page's `+` FAB. Sorting mirrors BestToDo's default: open items
before done ones, then by priority, otherwise list order. `ItemViews.wishlist` (the same shared
query BestToDo's Wishlist filters through) is the visibility gate, so demo-seed hiding and the
isWish/isVisibleInMainViews rules apply identically in both apps.

**No inherited BestToDo backlog (Best Music 0.2.83)**: `ItemRepository.loadItems()`/`StorageService.
loadTaskList()` is shared code, and it unconditionally ran a one-time migration
(`_maybeImportLegacyTodoItems`, `lib/services/wishlist_migration.dart`'s `legacyTodoWishlistItems`
— 61 items straight from BestToDo's own historical `Todo.md` backlog) into whichever app's own
`tasks.json` was empty and had never run it before — including a genuinely fresh Best Music
install, which has its own separate app-private storage and so had never spent that one-time flag
either. `Config.isBestMusic` (`lib/config.dart`, default `false`) is set once, first line of
`main_music.dart`'s `main()`, before anything else runs; `_maybeImportLegacyTodoItems` returns
immediately when it's true, so Best Music's Wishlist now starts genuinely empty on a fresh
install, same as its dev-build behavior (see "Empty by default" below) — the migration itself,
and BestToDo's own behavior, are untouched.

**Cross-app sync, added 0.2.78 then reverted to BestToDo-only 0.2.84**: BestToDo and Best Music
are two separately-sandboxed Android apps (different `applicationId`, §10.6f) —
`getApplicationDocumentsDirectory()` (what `StorageService`/`ItemRepository` use for
`tasks.json`) is invisible across that sandbox boundary, so each app's Wishlist really is its own
local database, matching on JSON shape alone but never actually shared. 0.2.78 added
`lib/services/shared_wishlist_store.dart` (`SharedWishlistStore`) to bridge that: it reads/writes
one file — a fixed path under public external storage
(`/storage/emulated/0/BestToDo/wishlist_shared.json`) both apps can reach because both already
hold `MANAGE_EXTERNAL_STORAGE` (the shared `AndroidManifest.xml`; `MusicLibraryService.
ensureFolderPermission` already requests the same permission for the music folder, and Best Music
already asks for it eagerly at startup, §10.6e/f) — via `SafeFile`, the same atomic-write/
corruption-recovery helper `StorageService` itself uses.

Both Wishlist pages treated the shared file as authoritative once it existed: on load,
`reconcileWishlist(local, shared)` replaced the local wish-item subset with the shared file's
content whenever that file already existed (so a deletion or edit made in the other app took
effect here too — the whole set was replaced, not merged item-by-item, since there is no
per-field "last modified" timestamp on `Task` to arbitrate a real conflict), and only fell back
to seeding the shared file from local data the first time, before it existed at all. Every save
(add/edit/delete/toggle) re-pushed the page's current wish-item set out to the shared file.
**0.2.84 reverted this for Best Music**: `music_wishlist_page.dart` no longer imports
`SharedWishlistStore`/`WishlistSyncBanner` at all — it reads and writes only its own
app-private `tasks.json` via `ItemRepository`, exactly like every other Best Music list, so
checking an item off there can never mark it done in BestToDo (users had not asked for the two
lists to be the same list, and being checked in an app they weren't using was surprising). Best
Music's Wishlist drawer entry no longer shows a connect banner or offers to sync at all.
BestToDo's own Wishlist (`wishlist_page.dart`) is untouched: `SharedWishlistStore`, the dismissible
`WishlistSyncBanner` (`lib/ui/wishlist_sync_banner.dart`) and its "Connect" flow
(`Config.wishlistSyncBannerDismissed`, `SharedWishlistStore.requestConnection()` showing
Android's "All files access" settings screen) still exist there exactly as before — connecting
now just means nothing else reads the file it writes to.
`SharedWishlistStore.sharedDirectoryOverride`/`connectionOverride` (test-only) redirect this to a
temp directory and force a connected/not-connected state without the real `permission_handler`
plugin, which `flutter test`'s host platform can't provide —
`test/core/shared_wishlist_store_test.dart` covers the store directly (save/load round-trip,
deletion visibility, `reconcileWishlist`); the former `test/tools/wishlist_cross_app_sync_test.dart`,
which proved an item added/deleted in one app's Wishlist showed up in the other's, was removed
along with that behavior.

**Empty by default, even in dev builds (0.2.77)**: both Wishlist tools used to seed demo content
on an empty list — `WishlistPage._load`'s "Learn to sail" fallback, `home_page.dart`'s
`_seedDevWishItem` (same item, seeded on first launch) and `_buildDevWishlistSeed` (the
`legacyTodoWishlistItems` backlog, re-backfilled on *every* dev launch once no wishes remain,
independent of first-launch) — all gated on `Config.isDev`. That backfill in particular meant a
developer who cleared the Wishlist to test an empty state saw it silently repopulate on the next
launch. All three are removed; the Wishlist starts (and stays) genuinely empty in dev builds
exactly like production, so testing the cross-app sync feature above from a clean slate doesn't
require fighting demo data first. The production one-time Todo.md-backlog import
(`StorageService`/`wishlist_migration.dart`, §10.6, unconditional on `Config.isDev`) is untouched
— that is a real, flag-guarded, one-time migration for actual installs, not a dev convenience.

### 10.6i Independent versioning and changelogs (0.2.81)
Through 0.2.80, Best Music's every build shared BestToDo's own `pubspec.yaml` `version:` line
(via Flutter's `flutter.versionCode`/`flutter.versionName`, injected into both Gradle product
flavors alike) and its Android APK's release notes came from BestToDo's own CHANGELOG.md — so a
Todo-only release always bumped Music's version number too, and Music's own Changelog tool
showed BestToDo's whole history mixed in with the entries actually about Music. The two apps now
version and changelog fully independently, seeded from 0.2.80+371 (the last build number they
shared) going forward — nothing before the split was rewritten or copied over; BestToDo's own
history stays in CHANGELOG.md.

**Best Music's own version file**: `MUSIC_VERSION` at the repo root holds a single `version:
x.y.z+build` line, the same shape as `pubspec.yaml`'s. `android/app/build.gradle.kts` reads it
(`rootProject.file("../MUSIC_VERSION")`, mirroring how `key.properties` is already read) and
overrides `versionCode`/`versionName` on the `music` product flavor only — `todo` keeps coming
from `flutter.versionCode`/`flutter.versionName` (i.e. `pubspec.yaml`) exactly as before. The
`createVersionedReleaseApk` task's `fullVersion` (used to name `best_todo_<version>.apk` /
`best_music_<version>.apk`) now branches on which flavor's APK it actually found rather than
always reading `flutter.*`. `PackageInfo.fromPlatform()` (what `Config.versionWithBuild` and
`MusicAboutPage` read) then reports each installed app's own real version for free, since it
reads the running APK's own `versionCode`/`versionName` — no Dart-side change needed there.
`versionCode` only ever moves forward from 371 (Android refuses an "update" with a lower
versionCode than what's installed), so bumping `MUSIC_VERSION` always increments the existing
build number rather than resetting it, even though its `x.y.z` name can change freely.

**Best Music's own changelog**: `CHANGELOG_MUSIC.md` at the repo root, bundled as an app asset
alongside `CHANGELOG.md` (`pubspec.yaml`'s `assets:`). `ChangelogPage` (§10.7) gained `assetPath`
(default `CHANGELOG.md`) and `showStoryPoster` (default `true`) constructor params;
`MusicPlayerPage`'s drawer entry passes `assetPath: 'CHANGELOG_MUSIC.md', showStoryPoster:
false` (its status card, pull-down and version taps are about the running app's
`AppUpdates.controller`, i.e. Best Music's own builds; the release cards start at the first
`## ` release, so the file's title + developer intro never show; the `hidePreamble` flag and
`stripChangelogPreamble` that did this for the old markdown view went away in 0.2.105) — the story-poster view's `changelogMilestones` are BestToDo's own curated history and
would be wrong to show under Best Music.

**Tooling, both apps share the same scripts with a flag rather than forking them**:
- `dart run tool/bump_version.dart <version> "<entry>" --music` bumps `MUSIC_VERSION` +
  `CHANGELOG_MUSIC.md` instead of `pubspec.yaml` + `CHANGELOG.md`; the changelog-insertion logic
  now finds the first `## [...]` heading and inserts the new section right above it rather than
  assuming a single-line header, so `CHANGELOG_MUSIC.md`'s explanatory preamble paragraph (above
  its first release) survives every bump untouched.
- `dart run tool/append_build_time.dart --app music` (default: BestToDo) notes a local build in
  `CHANGELOG_MUSIC.md` and reads `MUSIC_VERSION` for its `build_history.json` record, which now
  also carries an `app` field (`'todo'`/`'music'`).
- `dart run tool/stage_local_release.dart --version <x.y.z+build>` names the staged file
  explicitly instead of the tool re-reading `pubspec.yaml` — without it, staging a
  `--prefix best_music` build would silently tag it with BestToDo's version once the two
  diverged. `tool/build.sh`/CI always pass it now.
- `tool/build.sh`: `VERSION` is read from `MUSIC_VERSION` instead of `pubspec.yaml` whenever
  `FLAVOR=music` (i.e. every `music-apk` build), and `--app music`/`--version "$VERSION"` are
  passed through to `append_build_time.dart`/`stage_local_release.dart` accordingly.
  `tool/publish_apk.dart` stays BestToDo-only (Best Music's update check never looks at GitHub
  releases — see §10.6f's "In-app updates" paragraph), so `PUBLISH_APK=1` is now a no-op for a
  music build rather than publishing a GitHub release mislabeled "BestToDo" from Music's bytes.
- `.github/workflows/build-apk.yml`'s `build_music_apk` job reads its "app version" step from
  `MUSIC_VERSION` and passes `--version` to `stage_local_release.dart` the same way.
- `tool/build_all.sh`/`tool/build.ps1` (the gap this change originally left open, closed since):
  `all` now builds the Best Music APK as its own step between the BestToDo APK and the Windows
  exe — "everything this project ships" includes Best Music — skippable with `MUSIC=0`, and the
  sync step also stages `CHANGELOG_MUSIC.md`. `tool/build.ps1` has full flavor parity with
  `tool/build.sh`: a `music-apk` shorthand, `--flavor todo` injected when an `apk` build doesn't
  name one, `MUSIC_VERSION` as the version source and `best_music_` as the artifact prefix for a
  music build, `--app music`/`--version`/`--prefix` passed through to
  `append_build_time.dart`/`stage_local_release.dart`, and the same BestToDo-only `PUBLISH_APK`
  guard.

**Why the rename task is per-flavor** (regression fixed after the split): a single shared
`createVersionedReleaseApk` used to decide which app it had just built by scanning
`build/app/outputs/flutter-apk/` for the first existing `app-<flavor>-release.apk`, `todo`
first. That directory is never cleaned between builds, so on any machine that had built
BestToDo at least once, every subsequent `--flavor music` build matched the leftover
`app-todo-release.apk`, re-copied that stale BestToDo APK as `best_todo_<pubspec version>.apk`
and produced **no** `best_music_<MUSIC_VERSION>.apk` at all. The music build exited 0, so the
failure was silent — `stage_local_release.dart` then staged nothing (or the wrong app). CI never
saw it because each job starts from a clean checkout. Deciding the flavor from the task that
triggered the rename, rather than from whatever files happen to be on disk, is what makes a
local music build correct.

Not split by this change: `SCREENSHOT_CHANGELOG.md` (`tool/update_screenshot_changelog.dart`)
stays one shared file for both apps' screenshot-capture audit trail, and still labels every
entry with BestToDo's `pubspec.yaml` version regardless of which app's screenshots it's
recording — a known, low-stakes inconsistency (it's an audit log, not a user-facing changelog)
left for a future pass if it's ever worth the tooling churn.

### 10.6j Samsung-Music-style redesign: Favourites/Artists/Folders tabs, search, sort, "+" add-songs (Best Music 0.2.81)
`MusicPlayerPage`'s `TabController` grew from 2 tabs (Library/Playlists) to 5, matching Samsung
Music's own layout: Favourites, Playlists, **Tracks** (renamed from Library), Artists, Folders —
`TabBar(isScrollable: true)` since five labels don't all fit on a phone width, same as Samsung's.
Favourites (`_FavouritesTab`) is a shortcut straight to the Favorites system playlist's resolved
tracks — the same list already reachable via Playlists → Favorites, just one tap away. Artists
(`_ArtistsTab`) and Folders (`_FoldersTab`) are new grouping views computed live from
`MusicLibraryService.instance.tracks` (never persisted): Artists groups by `Track.artist`
(`Unknown artist` for a blank tag, sorted last); Folders groups by each local track's folder
relative to `Config.musicFolder` (`folderLabelOf`, a top-level function in
`music_player_page.dart` — tracks right under the music folder itself land in `(Music folder)`,
whose leading `(` sorts it ahead of any real subfolder name; a Subsonic track with no
`Track.filePath` groups under `Other`). Tapping a row in either tab pushes `_FilteredTracksPage`,
a plain `TrackListView` over that artist's/folder's tracks.

**Search** (app bar search icon, `_MusicSearchDelegate extends SearchDelegate<void>`): filters
the whole library by title/artist (falling back to the filename), reusing `TrackListView` for
results so a search hit is playable and carries the same "more options" menu as everywhere else.
Plain `showSearch(context:, delegate:)` — no separate search page/route to maintain.

**Quick sort + shuffle/play-all header** (`TrackListView`, a `StatefulWidget` owning its own
`TrackSortField` + direction): every track list — Tracks/Favourites tabs, an artist/folder
drill-down, search results, and any playlist detail page — gets a header row with a
`PopupMenuButton<TrackSortField>` (Added to device [default] / Added to app / Title / Artist /
Duration, checkmark plus
an up/down arrow on the active choice), a direction `TextButton` (key `sortDirectionButton`,
labelled per field: Newest/Oldest first, A–Z/Z–A, Longest/Shortest first) that flips ascending ↔
descending, plus shuffle and play-all icon buttons that queue the *currently sorted* list.
Re-picking the active field also flips its direction; picking a new field starts in its natural
direction (`trackSortDefaultAscending`: A–Z for text, newest/longest first otherwise). Ties fall
back to title; tracks with no date added always sink to the bottom. The choice is persisted in
`Config.musicTrackSortField`/`musicTrackSortAscending` (0.2.85) so every list and the next launch
follow it.

**Two "date added"s** (0.2.87): `Track.deviceDate` is when the *file* arrived on the
phone/computer — `FileStat.changed` (creation time on Windows, inode change time on Android/Linux,
i.e. when it was copied/downloaded there), re-read on every rescan, persisted as `deviceDate`
(ms), null for Subsonic tracks. `Track.dateAdded` stays "first seen by a Best Music scan" (backs the
Last Added smart playlist, unchanged). Sorting offers both ("Added to device" — the default — and
"Added to app"); Track info shows both rows ("Added to device", "Added to app").

**Fast scroll** (`lib/ui/fast_scroll_list.dart`, `FastScrollList`, 0.2.85): track rows are a
fixed two-line height (`prototypeItem`; title/artist ellipsize to one line, a missing artist reads
"Unknown artist") so a drag position maps exactly onto a row. Lists of 30+ tracks get a draggable
handle on the right edge (key `fastScrollHandle`; tap or drag to jump) with a bubble showing the
top row's `trackSectionLabel` — initial letter (digits → `#`) for Title/Artist, "Sep 2026" for
Date added, "3 min" for Duration.

**Blue theme + dark mode** (0.2.89): Best Music's theme comes from `lib/ui/music_theme.dart` —
`buildMusicTheme(brightness)` seeds `ColorScheme.fromSeed` with `musicSeedColor` (0xFF005FDD, the
same blue as BestToDo's `_seedColor`) and pins `primary` to it, light and dark. Settings →
"Dark mode" (`SwitchListTile`) calls `MusicTheme.setDarkMode`, which persists `Config.darkMode` (Best
Music's own settings file) and flips the `MusicTheme.darkMode` notifier that `BestMusicApp` wraps its
`MaterialApp` in, so the switch applies instantly.

**Sleep timer** (0.2.89): `MusicSleepTimer.instance` (`lib/services/music_sleep_timer.dart`) holds a
`ValueNotifier<SleepTimerState>` — off, timed (`endsAt`, a Dart `Timer` that pauses playback when
it fires) or end-of-song (`MusicAudioHandler`'s completion listener calls `consumeEndOfTrack()` and,
when set, pauses and rewinds instead of advancing). `extend()` adds time, `cancel()` turns it off.
One picker, `showSleepTimerSheet` (`lib/ui/sleep_timer_sheet.dart`: 5/10/15/30/45/60/90 min, End of
current song, Custom… minutes, plus Add 10 minutes / Turn off while active), opened from: Now
Playing's app bar (`SleepTimerButton`, tooltip "Sleep timer" / "Sleep timer: 23 min"), Settings
("Sleep timer" row), and the mini player (a bedtime + time-left badge while running, and
long-press on the bar). The Best Music drawer no longer has a "Sleep timer" entry (0.3.33). The timer is in-memory —
not restored after the app process is killed.

**Always-visible mini player + resume after restart** (0.2.88): `MusicMiniPlayerBar`
(`lib/ui/music_mini_player_bar.dart`) is mounted once in `BestMusicApp`'s `MaterialApp.builder`
(a `Column` of the navigator + the bar, inside the bottom `SafeArea`), so the current song — title,
artist, play/pause, tap → `NowPlayingPage` via `musicNavigatorKey` — is at the bottom of every Best
Music screen. That spot has no Overlay, so the bar uses no tooltips (play/pause has key
`musicMiniPlayerPlayPause` + a Semantics label). It hides while Now Playing is open
(`NowPlayingPage.openCount`, bumped in a microtask from initState/dispose) and when there is no
current or remembered song. `MusicPlayerPage(standalone: true)` no longer renders its own bar
(the non-standalone mode was BestToDo's Music Player tool, removed in 0.2.98 — §10.6n).
`MusicResumeService` (`music_resume_service.dart`) persists `{queue: [track ids], index, positionMs,
current: Track json}` to `music_resume.json` in the app documents dir (survives restarts, reboots
and app updates). `MusicAudioHandler` saves it on every track change, pause, shuffle/reorder and
every 15 s while playing (writes chained so they never interleave). At startup `main_music.dart`
calls `MusicPlayerService.restoreLastSession()` after the library loads: queue ids are mapped
through the library (missing ones dropped, the current track falling back to its saved copy) and
`handler.restore()` shows it paused (mediaItem + paused playbackState at the saved position)
without loading audio; the first `play()` loads it with `initialPosition`. Skipping before
playing drops the saved position.

**Navigation-bar inset** (0.2.86): `BestMusicApp` (`lib/main_music.dart`) wraps every route in
`MaterialApp.builder: SafeArea(bottom: true)` exactly like BestToDo's `main.dart`, so no page (track
lists, Track info, the mini player) draws under Android's edge-to-edge navigation bar. 0.2.85's
attempt (mini player as the Scaffold's `bottomNavigationBar`) only covered the home page and let
the mini player's `Column` stretch to the full screen height — reverted; the mini player is back
as the last child of the home body `Column` (its text `Column` now `MainAxisSize.min`).

**Per-track "more options" menu**: the row's separate Favorite/"Add to playlist"/"Remove from
playlist" icon buttons were folded into one `PopupMenuButton<String>` (`Icons.more_vert`, tooltip
"More options") per Samsung Music's own ⋮ button — Favorite/Unfavorite (dynamic label + heart
icon), Add to playlist (still `showAddToPlaylistSheet`), Remove from playlist (only when
`TrackListView.onRemove` is set — i.e. inside a hand-built, non-system playlist, unchanged
condition), and a new Track info entry (`TrackMetadataPage`, previously only reachable from Now
Playing's info button). Tapping the row itself still plays the (sorted) list from that track,
unchanged.

**"+" add-songs-to-playlist (`AddSongsToPlaylistPage`)**: `MusicPlaylistDetailPage` gained an
"Add songs" app bar button, shown under the same `editable` condition as its existing "Remove
from playlist" wiring (`kind == list && !isSystem` — a hand-built playlist only; Favorites/
disliked/smart/rule playlists don't get one). It opens a full-screen multi-select checkbox list
of every library track not already in the playlist; "Add selected" (enabled once at least one is
checked) calls the new `MusicPlaylistService.addAllTo(playlistId, trackIds)` — one save/notify
for the whole batch rather than one per track (`addTo` in a loop). Complements the existing
one-track-at-a-time flow from a track row's own "Add to playlist" menu entry, for adding several
songs into a playlist at once instead.

### 10.6k Artists tab groups "feat." credits, free-form Tags (Best Music 0.2.82)
**Artists tab merges featuring credits.** A library ripped from Samsung Music (or similarly
tagged) often has one artist appear as several distinct `Track.artist` strings — "49th & Main",
"49th & Main feat. SKYLAR", "50 Cent feat. Justin Timberlake" — because the ID3 `TPE1` tag
folds the featured artist into the same field. `lib/utils/artist_utils.dart`'s
`splitArtistCredit(artist)` splits that on the first `feat.`/`feat`/`ft.`/`ft`/`featuring`
marker (case-insensitive, tolerant of surrounding whitespace) into `mainArtist` + `featuring`,
returning an empty `featuring` when there's no such marker. `_ArtistsTab` groups by
`mainArtist` instead of the raw `Track.artist` (an empty main artist still falls back to
"Unknown artist", sorted last) — so "49th & Main" and "49th & Main feat. SKYLAR" land under one
row, its track count covering both. When any of a main artist's tracks carry a featuring
credit, the row's `trailing` shows "feat. <names>" (deduped via a `Set`, comma-joined, ellipsized
past two lines) so that information isn't lost, just moved out of the grouping key. This only
affects grouping in the Artists tab — `Track.artist` itself, and every other view/search/sort
that reads it, is untouched.

**Free-form tags.** `Track` gained `tags` (`List<String>`, default `const []`, omitted from
`toJson` when empty, tolerant of a missing/non-list key in `fromJson`) — unlike every other
metadata field, never read from a file's ID3 tags; purely a user-assigned label for grouping
tracks the way genre/artist/folder can't (occasion, a personal chart, "songs for a specific
playlist elsewhere"), e.g. "Belgian Top Charts", "Wedding songs". Editable on
`TrackMetadataPage` (a comma-separated "Tags" text field alongside title/artist/album/genre/
year, `helperText` showing the format) — saving goes through the same
`MusicLibraryService.updateTrackMetadata(..., tags: [...])` call as every other field (now
taking an optional `tags` parameter, default `const []`) and sets `metadataEdited: true`, so
tags survive a rescan exactly like a manually-fixed genre does (§10.6g). `applyMetadataRows`
gained the same blank-means-leave-alone semantics for tags as every other field: a row's empty
`tags` list keeps the track's existing tags. `MusicMetadataCsv` round-trips tags as an eighth
`tags` column, multiple tags in one cell `; `-joined (not `,`-joined, since the CSV's own field
separator is a comma) and split back the same way on import.

A new **Tags tab** (`_TagsTab`, `TabController` grown from 5 to 6, `TabBar` labels Favourites/
Playlists/Tracks/Artists/Tags/Folders) groups the library by tag the same way Artists/Folders
do, computed live from `MusicLibraryService.instance.tracks` — but unlike those two (each track
belongs to exactly one artist/folder), a tag grouping is many-to-many: a track with several tags
appears once under each one, and a track with none groups under "Untagged" (sorted last, same
pattern as "Unknown artist"). Tapping a tag row pushes the same `_FilteredTracksPage` Artists/
Folders already use.

### 10.6m Subscriptions feed — YouTube channels in Best Music (Best Music 0.2.92)
A Tubular/NewPipe-style feed built in Dart on the existing `youtube_explode_dart` + player
stack rather than by forking Tubular (a native Java app, GPL-3.0 — embedding it would mean
two UIs and two media sessions, and would make the APK GPL). Drawer entry **Subscriptions**
in Best Music (`MusicPlayerPage._buildDrawer`) → `YoutubeFeedPage`
(`lib/ui/youtube_feed_page.dart`).

**State** — `YoutubeFeedService` (`lib/services/youtube_feed_service.dart`, singleton) owns
`ValueNotifier`s for `subscriptions` (`YoutubeChannel`: `UC...` id, name, avatar URL),
`videos` (`FeedVideo`, newest first, unfiltered), `settings` (`YoutubeFeedSettings`),
`progress` (`videoId → WatchProgress`: position, duration, completed, updated; capped at the
2000 most recently updated) and `refreshing`/`failedChannels`, all persisted to one
`youtube_feed.json` in the app documents dir (models in `lib/models/youtube_feed.dart`,
tolerant `fromJson`). `main_music.dart` loads it before `MusicPlayerService.init` so feed
playback has its settings and resume positions.

**Refresh** — on opening the feed (when there are subscriptions), pull-to-refresh, after a
Tubular import, and for just the new channel on subscribe. Up to 6 channels in parallel; per
channel `fetchChannel` reads:
1. the RSS feed `youtube.com/feeds/videos.xml?channel_id=UC...` (`parseYoutubeRss`, package
   `xml`): the 15 newest uploads of every kind, exact `published`, full `media:description`,
   view count; a `/shorts/<id>` link sets `isShort`;
2. the Videos tab (`channels.getUploadsFromPage`): durations and view counts. Livestreams sit
   on the separate Live tab, so `mergeVideosTab` flags a non-Short RSS entry missing from a
   *successfully read, non-empty* Videos tab as `isLivestream`.
If RSS fails the Videos tab is used alone (approximate "3 days ago" dates, no descriptions —
the video page fetches one on demand via `videos.get`); if the tab fails nothing is flagged
live; only both failing fails the channel. A failed channel keeps its cached videos and is
named in the feed's error row; descriptions fetched on demand survive later refreshes.
`filterFeed` applies the settings at display time (`visibleVideos`), so toggles need no
refetch.

**Feed UI** — rows: 16:9 thumbnail (`i.ytimg.com/vi/<id>/mqdefault.jpg`) with duration badge
and red progress bar, title, "channel · 2d ago · 1.2K views", a Play button (tooltip "Play").
Played videos are dimmed with a check icon. The app bar has **Channels** and **Feed
settings**. Empty state → "Add channels". Tapping a row opens `YoutubeVideoPage`: large
thumbnail, title, meta line, **Play**/"Resume at m:ss", **Open in YouTube**
(`launchUrl(watchUrl, externalApplication)` → the YouTube app), **Download** (pushes
`Mp3DownloaderPage(initialQuery: watchUrl)`, which submits it like a typed URL → queued
through the usual folder checks, §10.6d), **Mark played/unplayed**, and the description as
`LinkifiedText`.

**Channels** (`YoutubeChannelsPage`) — search by name → Subscribe/Subscribed per result.
`searchChannels` posts to InnerTube's `search` endpoint (`YoutubeHttpClient.sendPost`,
`params: EgIQAg==` = channels only) and walks the whole response for `channelRenderer`s
(`parseChannelSearchResults`); it does **not** use `youtube_explode_dart`'s `searchContent`,
whose 3.1.0 channel parser calls the `getT` extension on a `dynamic` (`videoCountText/runs
.first`) and throws `NoSuchMethodError` for every channel with a video count (Best Music
0.2.94 fix). A typed/pasted `/channel/UC...` URL, `@handle` or `/user/` URL resolves to that
channel directly; the subscribed list with
Unsubscribe (+ Undo snackbar); app-bar "Import from Tubular/NewPipe" opens a `.json` export
(`{"subscriptions":[{"service_id":0,"url":...,"name":...}]}`, `parseNewPipeSubscriptions`):
non-YouTube services are dropped, `/channel/UC...` URLs map directly, `@handle`/`/user/` URLs
are resolved through `youtube_explode_dart`, anything else counts as skipped; already
subscribed channels are counted, not duplicated. App-bar "Add channels by name" (0.3.32) opens a
dialog for a pasted list, one channel name per line (`parseChannelNameList`: bullets/numbering
stripped, blanks and case-insensitive repeats dropped); `importChannelNames` runs each through
`searchChannels` (4 at a time, so `@handles`/URLs work too), takes the result whose name matches
exactly ignoring case, else the top result, subscribes the new ones in one save, fetches their
videos, and the snackbar lists the names nothing was found for.

**Playback** — `TrackSource.youtube` (`Track.youtube`: id `youtube:<videoId>`, `remoteId` =
video id, `artist` = channel, new `Track.artUrl` = `hqdefault.jpg`, also sent as the
`MediaItem.artUri` for the notification/lock screen and drawn on Now Playing instead of the
note icon). Play builds the queue with `queueFrom`: the tapped video, then up to 50 *unplayed*
videos below it. The end of a YouTube queue pauses instead of reshuffling the local library.
Audio comes from `YoutubeAudioSource` (`lib/services/youtube_audio_source.dart`, a just_audio
`StreamAudioSource`): it resolves the stream with `Mp3DownloaderService.resolveAudioStream`
(the downloader's visionOS-first client walk + PoToken-wall probe) and serves just_audio's
local proxy from 1 MiB range requests, because YouTube throttles one open response to
~31 KiB/s and 403s most clients past 1 MiB. Each request bumps a generation counter so the
stream abandoned by a seek stops at its next chunk, and reads stay at most 6 MiB ahead of
estimated real-time consumption (the proxy has no back-pressure).
**Progress**: `MusicAudioHandler._persist` (every ~15 s and on pause) records the position
of a YouTube track once its own audio is loaded (`_loadedTrackId`); within the last 30 s or
95 % counts as played, as does reaching the end. `_playCurrent` resumes a feed video at its
saved position minus 3 s unless it was played or under 10 s in.
**SponsorBlock**: on loading a YouTube track the handler fetches
`sponsor.ajay.app/api/skipSegments?videoID=..&categories=[..]` (`SponsorBlockService`; 404/
errors = nothing to skip; only `actionType: skip`) and, on `positionStream`, seeks to a
segment's end when the playhead is within its first 2 s — so seeking into the middle of a
segment on purpose still plays it.

**Playback speed** (Best Music 0.2.96): `YoutubeFeedSettings.playbackSpeed` (default 1.0,
clamped 0.5–3.0) is the default for feed videos; local/Subsonic tracks always play at 1x.
`MusicAudioHandler._applySpeed` sets it after each track loads, using
`_videoSpeedOverride` when set; `setVideoSpeed` (Now Playing) sets that override and applies
it at once, and `setQueueAndPlay` clears it, so a quick change lasts for the rest of that
queue only. `handler.videoSpeed` (ValueNotifier) drives Now Playing's bottom-row
`PlaybackSpeedButton` (`lib/ui/playback_speed_sheet.dart`), shown only while the current
track is a feed video (`isFeedVideo`), labelled e.g. "1.5×" (tooltip "Playback speed"). Its sheet
has preset chips (0.75–3x), a 0.05-step slider with Slower/Faster buttons, and "Make … the
default". Feed settings has a "Default playback speed" row opening the same sheet in
default-only mode.

**Music vs. video playback rules (Best Music 0.2.98).** `Track.isFeedVideo` (=
`TrackSource.youtube && !youtubeSong`) is what every feed-only behaviour keys on — speed,
volume/boost, SponsorBlock, resume position/`recordProgress`, "played" marks, and stopping at
the end of the queue. Songs streamed from the library search's YouTube fallback are
`Track.youtube(..., song: true)` (`youtubeSong`, persisted as `"youtubeSong": true`), so they
follow music rules: always 1x, music's phone volume, no feed bookkeeping; the speed button is
hidden for them. **Volume** (Best Music 0.3.4: no app volume any more) is the phone's own
media volume (Android `STREAM_MUSIC`), remembered per kind and switched automatically.
`MediaVolume` (`lib/services/media_volume.dart`) talks to the `besttodo/media_volume`
channel in `MainActivity.kt` (`get` → current index / max as 0..1, null when unreadable;
`set {volume, showUi}` → `setStreamVolume`, skipped on fixed-volume devices, a Do Not
Disturb `SecurityException` swallowed; non-Android: no-ops). State lives in `Config`:
`musicPhoneVolume`/`videoPhoneVolume` (0..1, null until known) and `phoneVolumeKind`
(`'music'`/`'video'`/`''`, survives restarts). `MusicAudioHandler._applyVolume` runs for every
track that loads: the player volume is always 1.0, then `MediaVolume.onPlaying(kind)` — when
the kind differs from `phoneVolumeKind`, the phone's current level is saved for the kind that
was playing (so volume-button changes are kept) and the new kind's remembered level, if any,
is set with `showUi: true` (the phone's own volume bar appears); the very first track, or a
kind with nothing remembered yet, leaves the phone alone. The old app volumes
(`Config.musicVolume`, `YoutubeFeedSettings.videoVolume`) are gone; their JSON keys are
ignored. `YoutubeFeedSettings.videoBoostDb` (0–12 dB, default 0) is the only in-app level: it
drives an `AndroidLoudnessEnhancer` in the player's `AudioPipeline` (Android only; enabled
only while a feed video plays with boost > 0, gain 0/disabled for music). UI:
`lib/ui/volume_sheet.dart` — a 5%-step slider for the kind's phone volume
(`MediaVolume.choose`: for the kind playing — or when nothing has played yet — it moves the
phone volume live while dragging; for the other kind it only sets the level it gets on the
next switch; saved on release) and, for videos on Android, a "Boost for quiet videos" slider
("Off"/"+N dB"). The sheet opens on `MediaVolume.current` (the phone's level for the kind
playing, else the remembered one). Opened from Now Playing's volume button (tooltip "Music
volume" or "Video volume" by the current track), Settings → Subscriptions feed → "Video
volume" and Settings → Playback → "Music volume" (both show the remembered level, or "Not
remembered yet").

**Now Playing layout (Best Music 0.3.7).** The app bar holds only the menu button
(`buildSubpageAppBar(..., showBack: false)`; the system back gesture still pops) and the
title. Every control is at the bottom, top to bottom: the swipe hint, the "Back to music/
videos" chip, the progress slider, the transport row (`_Transport`) and a tools row
(`_ToolsRow`): playback speed (feed videos only), volume ("Music volume"/"Video volume"),
sleep timer, shuffle, queue and track info. The tools row also shows under "Nothing playing".

**Back/forward 10 seconds (Best Music 0.3.5).** While a feed video is the current track,
`MusicAudioHandler.notificationControls` is `[previous, replay10, play/pause, forward10,
next]` (songs keep `[previous, play/pause, next]`) with `androidCompactActionIndices`
`[1, 2, 3]` so the collapsed notification shows back 10 / play / forward 10. The two controls
are `MediaAction.rewind`/`fastForward` with the app's own icons
(`res/drawable/ic_replay_10.xml`/`ic_forward_10.xml`: Material's replay arrow, mirrored for
forward, around a "10"); audio_service also exposes them as custom actions, so Android 13+'s
media controls and the lock screen show them, and `systemActions` adds rewind/fastForward for
headsets and Bluetooth. `rewind()`/`fastForward()` call `seekBy(∓/±seekStep)` (10 s), clamped
to 0..duration; a restored track that isn't loaded yet moves its resume point instead (and
`_broadcastState` reports that resume point as the position until it loads). In the app: Now
Playing's transport row swaps Favorite/"Don't really like" for "Back 10 seconds"/"Forward 10
seconds" (`Icons.replay_10`/`forward_10`) on a video, and the mini player shows the same two
around its play button for a video only.

**Last song ↔ last video (Best Music 0.2.99).** `MusicAudioHandler.otherSession`
(`ValueNotifier<PlaybackSession?>`; `PlaybackSession` = queue, index, position) holds the
paused queue of the *other* kind. `setQueueAndPlay` snapshots the current queue into it
(after a `_persist()` so a feed video records its resume point) whenever the new queue's
first track differs in `isFeedVideo` from the current one; `switchToOtherSession()` swaps the
two — the current queue becomes `otherSession`, the saved one is resumed at its position
(`_resumePosition`; speed override cleared, shuffle off). `MusicResumeService.save(state,
other:)` writes it under `"other"` in `music_resume.json` (`loadOther()` reads it back);
video sessions — active or other — also store full `tracks` copies since feed videos aren't
in the library. `MusicPlayerService.restoreLastSession` resolves both
(`_resolve`: `tracks` if present, else library ids + saved `current`) and calls
`restoreOtherSession`. UI: `SwitchSessionButton` in the mini player (icon only, labelled via
`Semantics` "Back to video: <title>"/"Back to music: <title>" — the bar has no Overlay for
tooltips) and an `ActionChip` with the same label at the top of Now Playing.

**Feed loading, tap-to-play, switch pill (Best Music 0.3.0).**
- *Staged window*: `YoutubeFeedService.window` (`ValueNotifier<Duration>`). Opening the feed
  calls `startSession()` (window = `initialWindow`, 2 days) so cached videos of the last two days
  show at once; the refresh now publishes `videos` after **each** channel finishes (`_merged`),
  so fresh ones join as they arrive; when the refresh ends (or fails) the page calls
  `widenToBackgroundWindow()` (7 days). `visibleVideos` = `windowFeed(filterFeed(...), window)`
  — newest first; undated videos only once nothing dated is hidden. Older weeks only on
  demand: scrolling within 400 px of the end (once the week is shown) or the footer's "Show
  older videos" calls `showOlder()` — `windowStep` (7 days) further, or straight to the next
  older video across a quiet stretch. Footer: "Loading the rest of the week..." /
  "Show older videos" / "No older videos".
- *Rows*: tapping a `FeedVideoTile` plays it; its trailing info button (tooltip "Video info",
  was a play button) opens `YoutubeVideoPage`.
- *No auto-play*: `YoutubeFeedSettings.autoplayNext` (default **false**): `queueFrom` returns
  just the tapped video unless it's on (Feed settings → "Play the next video automatically").
- *Speed remembered*: the Now Playing speed sheet now writes
  `YoutubeFeedSettings.playbackSpeed` directly (no per-queue override, no "Make default");
  the handler's feed-settings listener re-applies speed and volume to the playing track.
- *Switch pill*: `SessionSwitchPill` (`music_mini_player_bar.dart`) floats bottom-left just
  above the song bar on every Best Music screen (a `Stack` in `main_music.dart`'s builder),
  hidden while Now Playing is open or there's nothing to switch to. Since Best Music 0.3.15 it
  is a 40 px icon-only circle (`CircleBorder`, `secondaryContainer` at 60 % alpha, no
  elevation; `smart_display_outlined` to go to videos, `library_music_outlined` to go to
  music, icon at 85 % alpha) so snackbars behind it stay readable — the label "Back to
  videos: <title>" / "Back to music: <title>" is only its `Semantics`; tap → `switchToOtherSession()`, which now resumes `switchTarget()`: the
  remembered `otherSession`, else (music or nothing playing) the feed's
  `lastPlayedVideo()` (most recently updated progress entry still in the feed), else (a video
  playing) a fresh weighted shuffle of the library. Volume and speed follow the track's kind
  (`_applyVolume`/`_applySpeed` in `_playCurrent`).

**Switching brings its screen, reliable duration/views/upload time in rows (Best Music 0.3.2).**
- Every "Back to music"/"Back to video(s)" control (the pill, the mini player's
  `SwitchSessionButton`, Now Playing's chip) calls `switchSessionAndShow(handler, navigator)`:
  it reads `switchTarget()`, starts `switchToOtherSession()` and calls
  `showSessionScreen(navigator, video: target.isVideo)` — a video opens the Subscriptions feed,
  a song opens Now Playing. `showSessionScreen` `popUntil`s a route named
  `YoutubeFeedPage.routeName` (`/subscriptions`) / `NowPlayingPage.routeName`
  (`/now-playing`) or the root; if it didn't find one it pushes `YoutubeFeedPage.route()` /
  `NowPlayingPage.route()`. Every push of those pages uses `route()` so the names are always
  set. The pill and mini player sit outside the navigator, so `main_music.dart` hands them
  `musicNavigatorKey`.
- `FeedVideoTile`: title, channel (1 line), then `_MetaRow`s — play icon + "12:34 · 1.2K
  views" (key `feedVideoStats`) and clock icon + "Today 14:05 (3h ago)" (key
  `feedVideoUploadTime`). `formatFeedUploadTime` (local time): "Today 14:05", "Yesterday 09:12",
  "Mon 18:30" within the week, "3 Oct, 14:05" this year, "3 Oct 2025" before; with
  `approx: true` (`FeedVideo.publishedApprox`, a date read off "3 days ago") no clock time.
  The video page's meta line has all of it.
- *Reliable duration/views/date*: `youtube_explode`'s `getUploadsFromPage` reads YouTube's newer
  `lockupViewModel` cards from dead paths (duration 0, views 0), and `mergeVideosTab` used to
  overwrite the RSS view count with that 0. Now:
  `YoutubeChannelVideosApi` (`lib/services/youtube_channel_videos_api.dart`) POSTs
  `youtubei/v1/browse` (browseId = channel id, params `EgZ2aWRlb3PyBgQKAjoA` = Videos tab)
  and `parseVideosTab` walks the tree for `videoRenderer`/`gridVideoRenderer`/
  `lockupViewModel` cards, collecting each card's texts (`simpleText`/`runs`/`text`/
  `content`) and recognising the clock (`12:34`), views (`parseViewCount`: "1,234 views",
  "1.2K views", "No views"; "watching" = live, ignored) and "N units ago". `fetchChannel`
  tries it first and falls back to `getUploadsFromPage` with 0 → null — and (0.3.14) also
  runs `getUploadsFromPage` whenever RSS failed, even if the JSON tab answered, because the
  JSON tab has no titles: before, a channel whose RSS feed hiccuped was dropped from that
  refresh. The scraped page then only fills titles (`tab ??=` keeps the JSON tab's
  durations/views); without RSS only videos with a title are listed. `mergeVideosTab`
  takes the higher of the RSS/tab view counts, a null never erases the other.
  `_merged` runs every fresh video through `keepKnownDetails(fresh, known)` so a refresh that
  missed duration/views/description/exact date keeps the cached ones. After each refresh,
  `fillMissingDetails()` (unawaited; also callable) looks up, newest first, up to
  `maxDetailLookups` (15) non-Short filtered videos still missing duration, views or an exact
  date on their own page (`youtube_explode` `videos.get`, 3 at a time, each video once per app
  run via `_detailsTried`; tests: `detailsOverride` → `VideoDetails`, and it never runs when
  `fetchOverride` is set without one). A video whose page gives a duration is no longer
  flagged `isLivestream`.
- *Gestures, options sheet, online search, offline queue (Best Music 0.3.17)*:
  `YoutubeFeedSettings` gains `swipeRight` (default `addToQueue`), `swipeLeft`
  (`togglePlayed`), `longPress` (`options`) — `FeedGestureAction` {nothing, addToQueue,
  togglePlayed, options, play, transcript, summary, info}, JSON by `key`, unknown → default —
  and `offlineDays` (default 2, 0–`maxOfflineDays` 14). Each feed row is a `_SwipeableVideo`
  (`Dismissible` whose `confirmDismiss` runs the action and returns false, so the row springs
  back; a direction set to Nothing doesn't swipe; colored background with the action's icon
  and label — "Mark watched"/"Mark unwatched" by state); `FeedVideoTile.onLongPress` runs the
  long-press action. Actions: Add to queue → `MusicAudioHandler.addToVideoQueue(trackFor(v))`
  (snackbar "Added to the queue — downloading it for offline play" / "Already in the queue");
  Mark watched/unwatched → `setPlayed` with an Undo snackbar; Show options → bottom sheet
  (title, Play, Add to queue, Mark watched/unwatched, Transcript, Quick summary, Download as
  MP3, Open in YouTube, Video info). The app bar's "Feed settings" (tune) button is gone —
  feed settings live in Settings → Subscriptions, which gets "Swipe a video right/left",
  "Long-press a video" (radio dialogs over every action) and "Keep queued videos offline"
  (0 = off, 1, 2, 3, 5, 7, 14 days). `addToVideoQueue`: with a video playing/paused → appended
  to `_queue` (and `_preShuffleOrder`) unless already there; with music current → appended to
  the video `otherSession` (or a new one), so "Back to videos" resumes into it; with nothing
  loaded → `restore([track])`. Every add starts `VideoAudioCache.cacheInBackground`; playing a
  feed video also caches the next `_videosAhead` (2) queued feed videos. `VideoAudioCache.keepFor`
  is now an instance getter = `offlineDays` days (was a fixed 7); 0 → nothing is cached.
  **Online fallback of the feed search**: when the local search (`_localMatches`) has no match
  and the query is ≥ 2 characters, YouTube is searched after `onlineSearchDelay` (600 ms; a
  newer query wins via `_onlineSeq`) with `YoutubeSearchApi.search(q, limit: 15)`; results
  (`feedVideoFromSearch`: channelId '', `publishedApprox`) show as normal rows — same tap,
  swipes and long-press — under "Nothing in your feed — searching YouTube…" / "— results from
  YouTube" / "…couldn't be searched (offline?)" / "Nothing in your feed or on YouTube".
- *Loading without RSS + a saved, growing feed (Best Music 0.3.16)*: `fetchChannel` asks the
  RSS feed (`_fetchRss`, 12 s timeout) and the Videos tab (`YoutubeChannelVideosApi.fetch`)
  **in parallel**; `ChannelTabVideo.title` is now parsed (`videoRenderer`/`gridVideoRenderer`
  `title` runs/simpleText; `lockupViewModel` `metadata.lockupMetadataViewModel.title.content`;
  the title text is excluded from the age/views/clock scan so "… 10 years ago" in a title
  isn't a date), so the tab alone can list a channel. `getUploadsFromPage` (20 s) only runs
  when the tab didn't answer, or RSS failed and no tab card had a title (titles then come from
  it via `extraTitles`). `combineChannelSources(channel, rss:, tab:, extraTitles:)`: with RSS →
  `mergeVideosTab` plus every titled tab video RSS doesn't list (RSS carries only the newest
  15); without → every titled tab video (`publishedApprox` when dated); untitled ones are
  skipped; no RSS and nothing titled → throws. Why: YouTube's RSS fails often, and needing it
  for titles made channels — at times the whole feed — not load (0.3.14 then waited 30 s per
  channel on the scraper). `_merged` now **adds** instead of replacing a fetched channel's
  videos: fresh ones are added/updated (`keepKnownDetails`), saved ones stay unless the
  channel was fetched and they were published more than `keepVideosFor` (30 days, `clock()`)
  ago or are undated and no longer listed; unsubscribed channels' videos go. Opening the feed
  calls `refreshIfStale()`: skipped when `lastRefresh` is under `freshFor` (10 min) old, the
  feed isn't empty and no channel failed; pull-to-refresh calls `refresh()` directly. The saved
  feed (`youtube_feed.json`) shows at once either way.
- *Force-checking one channel (Best Music 0.3.14)*: `forceRefreshChannel(channel)` fetches
  just that channel, up to 3 tries `forceRetryDelays` apart (2 s, 5 s); success → its videos
  replace its cached ones via `_merged({id: fresh})`, it leaves `failedChannels`, saves,
  `fillMissingDetails()`, and returns how many video ids are new to the feed; all tries failed
  → null and its name is (kept) in `failedChannels`. `forceRefreshing` (`Set` of channel ids)
  drives spinners; a second call for a channel already being checked returns null at once.
  `retryFailedChannels()` force-checks every subscription whose name is in `failedChannels`
  (in parallel) and returns how many loaded. UI: each row under "Subscribed (N)" on the
  Channels page has a refresh button ("Check for new videos"; spinner while checking) next to
  Unsubscribe → snackbar "<name>: N new videos" / "<name>: no new videos" / "Couldn't reach
  <name> — try again in a bit"; the feed's "Couldn't refresh N channels: …" line gets a
  trailing **Retry** (spinner while any check runs) → "All N channels loaded" / "Loaded X of
  N — the rest still don't answer".

**Video audio cache (Best Music 0.2.99).** `VideoAudioCache`
(`lib/services/video_audio_cache.dart`) keeps a full copy of every feed video started:
`_playCurrent` calls `cacheInBackground(track)` for `isFeedVideo` tracks once loaded; it
downloads one at a time with `Mp3DownloaderService.downloadMp3` into
`<app support>/video_cache/<videoId>/` (not the library, not the MP3 downloads list; a failed
download deletes its folder). `_audioSourceFor` plays a feed video from `cachedFile(id)` when
present and `touch`es it. A file's mtime = last played; `keepFor` = 7 days — `cachedFile`
ignores older files and `purgeExpired` (after each download batch and at Best Music startup)
deletes folders not played within 7 days.

**Loading progress (Best Music 0.2.99).** `EstimatedProgressBar`
(`lib/ui/estimated_progress_bar.dart`): a thin `LinearProgressIndicator` that shows a real
`value` when known, otherwise an estimate `0.95·(1−e^(−t/τ))`, τ = `expected`/2.5, so it
always visibly fills; it jumps to 100% for 300 ms when `active` turns false, then hides.
Used for track loading/buffering (mini player top edge, Now Playing), the feed refresh (real
fraction: `YoutubeFeedService.refreshProgress` = channels fetched / total), a feed video's
description, channel search/import, the library search's YouTube lookup and the MP3
Downloader's search.

**Time left (Best Music 0.3.38).** Anything that can take more than 30 seconds shows a
rough "hh:mm:ss remaining" line below its progress: `RemainingTimeText`
(`lib/ui/remaining_time_text.dart`) on top of the shared package's `RemainingTime`
(`mfficiency_updates`): nothing unless the whole job looks longer than 30 s (time so far +
time left), nothing in the first 3 s, extrapolated from a 0..1 `done` (or counting down a
`typical` duration), refreshed every second, hidden instead of 00:00:00; `startedAt` for
work that began before the widget (a download, a feed refresh). `EstimatedProgressBar`
shows it below the bar with `showRemaining`; `TaskRemainingText` shows it for a service's
`ValueNotifier<TaskProgress?>` (`lib/services/task_progress.dart`: {startedAt, done};
`TaskProgressTracker` publishes at most once per 0.1% and clears it). Covered: **Upload
phone music** (`ServerUploadService.transfer` = bytes read into the PUT requests ÷ bytes of
the whole batch; the upload page's bar shows that fraction too, and the Server tab header
under "Uploading …"), the server **library sync** (`SubsonicLibrarySync.progress` = songs
fetched page by page (`allSongs(onPage:)`) ÷ the songs the server had last time; nothing
on a first sync; Server tab header and Settings › Music server › Sync now), **keeping server
songs on the phone** (`ServerOfflineStore.transfer` = bytes ÷ the batch's reported sizes,
average for songs without one; under "Keeping music on this phone"), MP3 downloads (MP3 Downloader card
and Downloads page; `Mp3DownloadJob.startedAt`, from received/total bytes), the library
scan on Metadata Scan (tracks found / tracks the library had before; nothing on a first
scan), the song-info lookup and BPM detection passes (Metadata Scan, Songs by BPM,
notification), the feed refresh (`YoutubeFeedService.refreshStartedAt`, channels fetched /
total) and channel imports (NewPipe file, channel names; `onProgress`). Short loads
(searches, a video's description, transcripts, track buffering, local pages) have none.
App updates show it through the package.

**Settings** (Best Music 0.3.3: no separate page any more — two sections of Best Music's own
Settings, `MusicSettingsPage`; the feed's tune icon "Feed settings" opens it with
`initialSection: MusicSettingsSection.feed`, i.e. that section open and scrolled to):
*Subscriptions feed* — Hide Shorts (default on), Hide livestreams (default on), Video speed
(above), Video volume, Play the next video automatically; *SponsorBlock* — "Skip sponsored
segments" on/off (default on) and per-category checkboxes (default sponsor, selfpromo,
interaction, music_offtopic). Log lines go to App Logs under "Feed".

**Search** (Best Music 0.3.3): the feed's search icon ("Search feed") puts a text field and
All/Title/Channel/Date chips under the app bar. It searches every fetched video
(`filterFeed(videos, settings)` — Shorts/livestream hiding still applies, but not the
2-day/week window, so older videos are found too) with `searchFeed`
(`lib/services/feed_search.dart`): every query word must match the title, channel name or
upload date (only the chosen field when a chip other than All is picked). A word matches a
text best when a word there starts with it (1), then when it's contained (0.85), then within
1 edit — 2 for words of 7+ letters — of a word or a word's prefix (Levenshtein with adjacent
swaps: 0.7/0.55), then as letters in order within a word at most twice its length (0.4);
words under 3 letters only match exactly. Words with digits match whole numbers only
(`3` finds `3/10/2026`, not `30`). The date text (`feedDateSearchText`) spells the upload day
as `2026-10-03`, `3/10/2026`, `10/3/2026`, `03.10.2026`, the month name and its 3-letter
abbreviation, the weekday and its abbreviation, and `today`/`yesterday`. Results sort by the
average word score (bucketed to tenths) and then newest first; tapping one plays it with the
search results as the queue. Paging older weeks and the footer are off while searching;
"No videos in your feed match." when nothing does. The close button clears the search.

Not done yet (deliberately out of the MVP): in-app video playback, background
new-upload notifications, feed groups.

### 10.6n Songs by BPM (Best Music 0.3.9)
**BPM per track** — `Track.bpm` (int?, JSON `bpm`, omitted when null; kept by `copyWith`).
Sources: an mp3's ID3 `TBPM` frame (`decodeMp3Tags` → `ExtractedTags.bpm` via `parseBpm`:
first number in the text, `,`/`.` decimals rounded, 1–999 else null); an OpenSubsonic
server's `bpm` (0 = unknown → null, `Track.subsonic(bpm:)`); the Track info page's "BPM (beats
per minute)" field (validated 1–999, passed to `updateTrackMetadata(bpm:)` — which sets
exactly the given values, so the page must always pass it); and the metadata CSV's `bpm`
column (between `year` and `tags`; blank cell = keep, like the other columns). A rescan of a
`metadataEdited` track keeps the hand-set BPM but fills a missing one from the tag
(`previous.bpm ?? track.bpm`).

**Page** — `lib/ui/bpm_range_page.dart` (`BpmRangePage`), from Best Music's drawer (Tools →
"Songs by BPM") and the Playlists tab's third row (also in BestToDo's Music Player). With no song
having a BPM it explains the three ways to add one. Otherwise: a row of preset `InputChip`s
("<name> · min–max"; tap applies the range — with a snackbar if it reaches past the
library's range — delete icon removes it with Undo), a big "min – max BPM" label, a
`RangeSlider` over `bpmBounds(library)` (lowest..highest BPM in the library, 1-BPM steps,
both handles draggable; the range starts as the full span and is clamped when the library
changes), "N songs · M without a BPM aren't shown", and the list `tracksInBpmRange` (BPM
ascending, then title; trailing "128 BPM"; tap = play the list from that song). Bottom
buttons: "Play as queue" (`MusicPlayerService.playQueue` of the list), "Save as playlist"
(name dialog suggesting "min–max BPM" → `MusicPlaylistService.createPlaylist` with the listed
ids — a fixed snapshot), "Save preset" (name dialog → `Config.musicBpmPresets`, a list of
`BpmPreset {name, min, max}` (`lib/models/bpm_preset.dart`, tolerant `fromJson`: swapped
ends reordered, missing ends dropped); saving under an existing name replaces it).

### 10.6p Automatic metadata filling (Best Music 0.3.11)
Hands-off, no setting: `MusicMetadataEnricher.instance.start()` runs after Best Music's
first frame (`main_music.dart`, not on web) and listens to `MusicLibraryService.tracks`.
Every library change (launch, rescan, finished download) first re-applies its cache, then —
debounced 3 s — runs two passes over local tracks, one song at a time:
1. **Online lookup** for any track missing artist/album/genre/year/BPM
   (`MusicOnlineMetadataLookup`, `lib/services/music_online_metadata.dart`). Query
   variants (`queryVariants`): the `cleanTitle`d title (track-number prefixes, "(Official
   Video)"/"[Lyrics]"-style brackets, "feat." tails and underscores stripped) with the
   artist; with `mainArtist` (first of "A feat. B"/"A & B"/"A, B"/"A x B"); without any
   bracketed part; and, for a track with no artist tag, an "Artist - Title" filename split
   both ways round. Services in order, each skipped once every wanted field is known:
   **Deezer** (`/search` with `artist:"…" track:"…"`, falling back to a free query; then
   `/track/{id}` for `bpm` (30–300, 0 = unknown) and release date, `/album/{id}` for the
   first genre), **iTunes Search** (`entity=song`: `primaryGenreName`, album, year),
   **MusicBrainz** (`/ws/2/recording` Lucene query, ≥1.1 s apart, `User-Agent:
   BestMusic/1.0 (…)`; first-release year, a no-secondary-type Album release preferred,
   most-counted tag title-cased as genre) — always asked when a year is wanted, since its
   first-release year wins over the others' (else the earliest of Deezer/iTunes).
   Candidates are scored by `matchScore`: 0.6 × title + 0.4 × artist word similarity
   (`textSimilarity` — accent/punctuation-folded Dice, or 0.9 × containment), artist < 0.5
   rejects; with no artist only a ≥0.95 title counts; length off by >30 s halves the score,
   >10 s × 0.85, ≤3 s +0.05; accepted at ≥ 0.72.
   **Rate limits (0.3.12)** — every request goes through `_getJson`, paced per host
   (`defaultSpacing`: Deezer 120 ms — its limit is 50 per 5 s; iTunes 3.1 s — ~20/min;
   MusicBrainz 1.1 s). A rate-limit answer (429, 5xx, iTunes' 403, Deezer's in-body
   `error.code == 4`) or a connection failure/timeout is retried twice (waits: `Retry-After`
   ≤ 60 s if given, Deezer quota 5 s, else 2 s then 6 s); after that the host *rests* for
   `cooldown` (10 min; connection-only failures don't rest it) and the lookup carries on
   with the other services, returning `incomplete: true`. Hosts already resting are skipped
   (also `incomplete`). If no service answered at all and something failed →
   `MetadataLookupUnavailable` (offline, `retryAfter` null); if every needed host was
   resting → `MetadataLookupUnavailable(retryAfter: earliest rest end)`. `resetCooldowns()`
   clears the rests. (0.3.11 threw on the first rate-limit answer and paused the whole
   pass for 15 min — with ~10 unpaced Deezer requests per song it stalled after ~4 songs.)
   The enricher marks an incomplete song `EnrichmentEntry.incomplete` (persisted), merges
   it with any earlier result (old values win) and re-asks it after `incompleteRetry`
   (1 h); the pass moves straight on. On `MetadataLookupUnavailable` the pass stops without
   marking the song: status "Song info services asked for a break — continuing at HH:MM"
   (retry then + 5 s) or "No internet connection — trying again in 15 min (or tap
   Restart)" (`offlineRetry`).
2. **On-device BPM** — only when, after the online pass, under 90 %
   (`bpmCoverageTarget`) of local tracks have a BPM; then every local track still without
   one is analyzed: `AudioPcmDecoder` decodes 45 s from 30 s in (from 0 for songs under
   75 s; the native side slides the window back for short files) to mono 16-bit PCM at
   11025 Hz — Android via channel `besttodo/audio_pcm` (`AudioPcmDecoder.kt`:
   MediaExtractor + MediaCodec on a single worker thread, downmix, box-filter resample,
   16-bit or float PCM), desktop via an `ffmpeg` on PATH, else null — and `estimateBpm`
   (`lib/services/bpm_detector.dart`, run with `compute`): log-compressed spectral flux
   (512-sample Hann frames, 128 hop, radix-2 FFT), minus a ±0.25 s moving mean, rectified;
   unbiased autocorrelation over 50–220 BPM lags × a log-normal prior at 120 BPM (σ = 1
   octave); parabolic refinement. Null when the envelope peak < 5 (no attacks), the best
   lag's correlation < 5 % of zero-lag, or < 1.3 × the mean over the lag range (no beat).

Results are cached per track id in `music_enrichment.json` (`EnrichmentEntry {onlineAt,
found, detectedAt, detectedBpm}`); a song is looked up/analyzed once — retried only after
30 days when nothing was found. They are applied through
`MusicLibraryService.fillMissingMetadata`, which fills only empty fields (title only when
it was the filename and there's no artist), never sets `metadataEdited`, so tags, manual
edits and CSV imports always win and a rescan simply gets the cache re-applied. The
enricher's `status` line ("Looking up song info online… 3/40", "Detecting BPM on device…",
"Song info filled in automatically — N of M complete, K with a BPM", "…paused (offline?)")
shows under the Metadata Scan page's counts and on Songs by BPM while songs lack a BPM.
Both passes publish `progress` (`TaskProgress` {startedAt, done 0..1 of the songs
that needed work}; null between passes), shown as an "hh:mm:ss remaining" line below the
status (`EnrichmentRemainingText`, see *Time left* below); the notification text gets the
same " · 00:12:34 remaining". On Metadata Scan the row is always shown (idle text
"Missing song info is looked up online in the background.") with a **Restart** button →
`restartOnlineSearch()`: `resetCooldowns()`, cancels a pending retry, clears `onlineAt` on
every entry whose track still misses a field (so no-match songs are asked again too),
interrupts a running pass (`_restartRequested`) and runs now.
**Background running (0.3.12)** — while a pass has work, `BackgroundWork.start`
(`lib/services/background_work.dart`, channel `besttodo/background_work`) starts
`BackgroundWorkService.kt`: a `specialUse` foreground service (no 6 h/day cap like
`dataSync`; `FOREGROUND_SERVICE_SPECIAL_USE`, subtype property in the manifest) with an
ongoing silent low-importance notification "Best Music · filling in song info" whose text
mirrors `status` (`update` re-notifies; tap opens the app) and a partial wake lock (3 h
timeout, released on stop). It keeps the process from being frozen while other apps are in
front; Dart keeps running on audio_service's cached engine. Stopped when a run ends with
nothing paused (kept up during a pause so the retry still fires) and on `stop()`. Android
12+ refusing a start from the background is swallowed — the work then just runs while the
app is open. No-op off Android.
App Logs ("Music") record each pass's counts.

3. **Into the files** — after the two passes, every mp3 whose entry has data and no
   `taggedAt` gets it written into its own ID3v2 tag (`Id3TagWriter.addMissing`,
   `lib/services/id3_tag_writer.dart`), using the library's *current* value for each field
   the enricher supplied (so a manual in-app edit is what lands in the file; the title only
   when the online one was applied). Fill-only: a TIT2/TPE1/TALB/TCON/TYER (v2.3) or TDRC
   (v2.4)/TBPM frame that already has text is never changed (TYER and TDRC count for each
   other); empty ones are replaced; every other frame is copied byte for byte. No tag →
   a new v2.3 one (Latin-1, or UTF-16 with BOM when needed; v2.4 writes UTF-8). Bails with
   `unsupported` on non-mp3, v2.2, or any of the unsync/extended-header/experimental/footer
   flags, or if `decodeMp3Tags` can't read the new artist/BPM back. When the frames fit in
   the old tag (its padding) only the tag bytes are overwritten in place; otherwise
   tag + 2048 bytes padding + the audio stream into `<file>.besttodo-tag.tmp`, its length is
   checked, and it is renamed over the original. The modified time is restored. Result →
   `taggedAt` set (written/nothingToAdd/unsupported) or `tagFailures++` (I/O error; given up
   after 3). New online/detected data resets `taggedAt`. Because writing bumps a file's
   change time, `rescan` now keeps the *earlier* of the previous and fresh `deviceDate`.

**ID3 read fix (0.3.11)** — `decodeMp3Tags` had never actually read a frame: id3_codec 1.0.x
reports ID3v2 frames as a `Frames` list of `{Frame ID, Content: {Information}}` maps, not the
`Frame[<id>]` keys it looked up, so every mp3 scanned as untagged (filename title, no
artist/album/genre/year/BPM). Frames are now indexed as `Frame[<id>]` (first wins). On its first `start()` the enricher rescans the library
once (marker file `music_enrichment_rescan_v1`; skipped for an empty library) so existing
installs pick their tags up before anything is looked up online.

### 10.6n Music & MP3 download live only in Best Music (0.2.98)

BestToDo no longer ships the Music Player or the MP3 Downloader; both exist only in the Best
Music app (§10.6f, entry point `lib/main_music.dart`). The shared code under `lib/` is
unchanged — only BestToDo's wiring to it is gone:

- `Config.startToolOptions`/`featureKeys` (and their label/description arrays) no longer list
  `mp3_downloader` or `music_player`; `home_page.dart` has no `_ToolEntry` or `_buildToolPage`
  case for them. A saved `startTool` of either key fails `startToolOptions.contains` on load
  and falls back to `tasks`; stale `features` entries for them are ignored.
- Settings drops its MP3 Downloader and Music Player sections (old indexes 15/16, with their
  search entries and Subsonic controllers); Claude Routine is now section 15 (16 sections).
- `main.dart` boots no music services (`MusicLibraryService`/`MusicPlaylistService`/
  `MusicPlayerService.init`, the deferred `ensurePermissions`), and a shared Spotify/YouTube/
  Shazam link opens the normal quick-add screen like any other share — `detectMusicShareLink`
  routing to `Mp3DownloaderPage` is Best Music only. The `besttodomusic://` widget-tap branch
  of `_handleWidgetClick` is gone.
- The two music home-screen widgets (`MusicMiniWidgetProvider`/`MusicControlsWidgetProvider`)
  are declared in `android/app/src/music/AndroidManifest.xml` instead of `src/main`, so only
  Best Music offers them; the Kotlin classes stay in `src/main` (one shared source set).
  Widget Previews no longer mocks them.
- The `audio_service` service/receiver and `MANAGE_EXTERNAL_STORAGE` stay in the shared
  manifest (the latter is also used by the shared Wishlist store).

Earlier sections (§8 music widgets, §10.6d, §10.6e, "Settings → Music Player") describe the
code as it still runs inside Best Music; their "Tools ▸ …" / BestToDo-Settings wiring is
historical.

### 10.6o Video transcripts & Quick summary (Best Music 0.3.9)

A Subscriptions video's page (`YoutubeVideoPage`) has **Transcript** and **Quick summary**
buttons (`lib/ui/video_transcript_page.dart`, both take a `VideoRef` of id/title/channel/
published).

- **Transcript source** — `VideoTranscriptService` (`lib/services/video_transcript_service.dart`,
  singleton, per-session in-memory cache by video id): first YouTube's own caption tracks via
  youtube_explode (`videos.closedCaptions.getManifest` → `get`), then, if that throws or has no
  tracks, the public Invidious instances in `invidiousInstances` (`/api/v1/captions/<id>` →
  the chosen track's WebVTT, parsed by `parseVtt`). Track choice (`pickTrack`): manual English
  → auto English → any manual → first. `cleanSegments` strips tags/entities, drops the
  repeated lines of YouTube's rolling auto-captions and `[Music]`-style cues. All sources
  failing throws `TranscriptUnavailableException` listing each attempt (shown on the page).
  `paragraphs()` groups segments into ~45 s timestamped paragraphs (forced break at 90 s for
  unpunctuated auto-captions). The transcript page shows source/language/auto/word count,
  Copy and Share (Markdown) and a Quick summary button.
- **Summary** — `VideoSummaryService.summarize` (`lib/services/video_summary_service.dart`):
  with `Config.claudeApiKey` set it POSTs to `https://api.anthropic.com/v1/messages`
  (`x-api-key`, `anthropic-version: 2023-06-01`, `anthropic-beta:
  server-side-fallback-2026-07-01`; model `claude-opus-5-5`, `fallbacks: "default"`,
  `output_config.effort: low` + a JSON-schema format `{overview, key_points[], conclusion}`;
  the whole transcript is sent, never truncated). Non-200, network errors and
  `stop_reason: refusal` throw `VideoSummaryException`; the page then shows the on-device
  summary with the error. Without a key: `extractiveSummary` — sentences (or 25-word chunks for
  unpunctuated captions) scored by content-word frequency, best five in order as key points,
  the last 1–2 as the conclusion, an overview naming length/word count/top words. A banner
  on an on-device summary links to Settings → Transcripts & summaries.
- **Obsidian** — `ObsidianResearchNote.markdown` builds the note (frontmatter: title, source,
  channel, published, created, tags research+video; then `## Summary`/`## Key points`/
  `## Conclusion`). **Save to Obsidian** opens `obsidian://new?vault=…&file=<folder>/<title>&content=…`
  (`saveUri`, percent-encoded by hand since Obsidian keeps `+`; vault omitted when empty =
  the open vault; file name sanitized, ≤100 chars); Share/Copy send the same Markdown.
- **Settings** — Best Music Settings gains a "Transcripts & summaries" section
  (`MusicSettingsSection.summaries`, before Updates): Claude API key (obscured),
  Obsidian research folder (`Config.obsidianResearchFolder`, default `Research`) and vault
  (`Config.obsidianVault`), edited in `_TextSettingDialog`. All three persist in
  `settings.json`.
- Tests: `test/music/video_transcript_test.dart`.

### 10.6q Best Music backup & restore (Best Music 0.3.25)

Best Music's counterpart of BestToDo's Export Everything/Import + automatic
backup (Settings → Backup). `MusicBackupService`
(`lib/services/music_backup_service.dart`) writes one JSON file
`best_music_backup_<yyyyMMdd_HHmmss>.json`:
`{app: "best_music", export_version: 1, exported_at, settings: Config.toMap(),
wishlist: [Task.toJson of the isWish items], stores: {<file name>: <decoded
contents>}}`. `stores` carries the documents-dir files listed in
`MusicBackupService.storeFiles` — `music_library.json`, `music_playlists.json`,
`youtube_feed.json` (subscriptions, feed videos, feed settings incl.
SponsorBlock, watch progress), `mp3_downloads.json`, `music_enrichment.json`
and `music_resume.json` (the playback resume point; read once at startup, so a
restored one applies on the next launch, Best Music 0.3.30), `play_history.json`
(Play history, Best Music 0.3.45) — read straight
from disk so a backup is complete without any page loaded. The library entries
carry the analyzed metadata (BPM, genre, year, …), play counts and manual
edits; `music_enrichment.json` the online/on-device lookup results; the feed
file the subscriptions, watch progress and feed settings. Everything else
Best Music keeps (BPM presets, remembered phone volumes, …) is a `Config` key
and rides in `settings`.

**Path remap (Best Music 0.3.30).** Local songs are keyed by absolute path
(`local:<path>` ids in the library, playlists' `trackIds`, the enrichment
map's keys, the resume point; plain paths in `filePath`/download history).
`MusicBackupService.remapRoot(json, oldRoot, newRoot)` rewrites every string
and map key equal to or under `oldRoot` (bare or `local:`-prefixed, `/` or
`\` separator; trailing separators ignored; `/old/Musicals` is not under
`/old/Music`) to the same path under `newRoot`. A restore whose backup
`settings.musicFolder` differs from this phone's non-empty `Config.musicFolder`
keeps this phone's folder and remaps every store before writing it; with no
folder set yet (fresh install) the backup's folder is adopted as is.
`relocateLibrary(oldRoot, newRoot)` applies the same remap to the store files
on disk and reloads the services; Settings → Library → Music folder calls it
when the previously chosen folder no longer exists on the device (and then
keeps the excluded subfolders, which are relative), before the rescan.

**Restore** (`restoreFile`/`restore`) refuses anything not tagged
`app: "best_music"` (a BestToDo export — recognised by its `tasks_bundle` — gets
"That is a BestToDo backup — restore it in BestToDo"). It first writes the
current state to `music_pre_restore_backup.json` in the documents dir, then
overwrites each store file present in the backup (stores the backup lacks are
left alone), replaces the Wishlist items in `tasks.json` (non-wish items, if
any, are kept), applies + saves the settings, and calls `reload()` on the
affected singletons (`MusicLibraryService`, `MusicPlaylistService`,
`YoutubeFeedService`, `Mp3DownloadManager`, `MusicMetadataEnricher` — each
resets its `_loaded` guard and re-reads its file). `Mp3DownloadManager.reload`
keeps downloads running right now on top and drops restored jobs that were
still queued/running when the backup was taken (they can't resume). The
Settings page re-syncs `MusicTheme.darkMode` after a restore.

**Automatic backup** reuses `Config.autoBackupFrequency`/`autoBackupDirectory`
(Best Music's settings.json is its own sandbox, so these keys are free there)
and `AutoBackupService.isDue`, with its own marker file
`last_music_backup.txt`. `MusicBackupService.maybeRun()` runs after the first
frame in `main_music.dart` and on every app resume; no-op while off or without
a folder.

**UI** — `MusicSettingsSection.backup` ("Backup", between Transcripts &
summaries and Updates): "Back up now" (into the backup folder, or a folder
picked for that one backup when none is set; subtitle shows the last backup
time), "Restore from backup" (JSON file picker → "Restore backup?" confirm
dialog → snackbar with the result), "Automatic backup" Off/Daily/Weekly
`SegmentedButton` (turning it on asks for a folder if none and backs up right
away), and "Backup folder". Tests: `test/music/music_backup_service_test.dart`,
`test/music/music_settings_page_test.dart`.

### Platform: widgets, share, "Play out loud?" (moved from BestToDo's §8/§9)

These were part of BestToDo's widget and Android-platform chapters while Best Music was a
flavor there; `lib/main_music.dart` is now `lib/main.dart`, and the music flavor's manifest
overlay (`android/app/src/music/AndroidManifest.xml`) is now the app's only manifest
(`android/app/src/main/AndroidManifest.xml`), with the same text/plain-only `ShareActivity`.

- **Music mini widget** (`MusicMiniWidgetProvider.kt`, 0.2.61): a single play/pause button plus
  a one-line title, nothing else. **Music controls widget** (`MusicControlsWidgetProvider.kt`,
  0.2.61): the same, plus skip-previous and (0.2.63) skip-next buttons. Both differ from every
  other widget here: their buttons don't call into Dart at all (there is no in-memory
  `MusicAudioHandler` a separate background isolate could reach — unlike the on-disk task/alarm
  lists, playback state lives in the running foreground service). Instead `MusicWidgetIntents.kt`
  builds an explicit `ACTION_MEDIA_BUTTON` broadcast (`KEYCODE_MEDIA_PLAY_PAUSE`/
  `KEYCODE_MEDIA_PREVIOUS`/`KEYCODE_MEDIA_NEXT`) targeted straight at `audio_service`'s own
  `MediaButtonReceiver` — the same path a Bluetooth headset or wired remote uses — so the buttons
  work whenever the Music Player's playback service is alive, in the foreground or not.
  `MusicWidgetService` (`lib/services/music_widget_service.dart`) only pushes the display data
  (title/artist/playing) by subscribing to the audio handler's `mediaItem`/`playbackState`
  streams; tapping the title opens the app (`besttodomusic://open`). Best Music only since
  0.2.98 (receivers declared in the `music` flavor manifest) — see §10.6e/§10.6n.

**Song-link share routing** (0.2.60): before presenting `QuickAddSharePage`, `main.dart`
runs the share's text (or subject) through `detectMusicShareLink`
(`lib/services/music_share_link.dart`) looking for a Spotify track link
(`open.spotify.com/track/...`), a Shazam track link (`shazam.com/track|song/...`), or a
YouTube video/playlist link (the same patterns `Mp3DownloaderService` already
recognizes). A match routes straight into `Mp3DownloaderPage(sharedLink: ...)` instead of
the task editor, skipping the quick-add flow entirely — the share's caption text (with
the link itself removed, and boilerplate like "I used Shazam to discover" stripped) is
kept as a `textHint`. On open, the page resolves the link into a search query via
`MusicLinkResolverService.resolveSearchQuery`: a YouTube link passes through unchanged
(the downloader's existing direct-URL path resolves and downloads it immediately, no
picker); a Spotify/Shazam link uses the caption `textHint` when there is one, otherwise
fetches Spotify's public `open.spotify.com/oembed` endpoint (`title` + `author_name`, no
API key) or parses the Shazam page's `og:title`/`<title>` (via the `html` package,
stripping the trailing " | Shazam") — either way the resolved text feeds the same
`_submit()` a typed query uses, landing on the usual up-to-5-candidate picker. A failed
lookup with no caption to fall back on shows an error (`MusicLinkResolveException`)
rather than hanging. `Mp3DownloaderPage` swaps its normal Tools app bar for one with a
"Find & Download Song" title and a Close button (`_finishShare`) that calls
`ShareIntentService.returnToPreviousApp` and pops, same as `QuickAddSharePage`'s
Save/Discard; a bare back-gesture dismissal does the same from `dispose()`. Tests:
`test/tools/music_share_link_test.dart`,
`test/tools/mp3_downloader_test.dart` ("opened from a share (sharedLink)").

**"Play out loud?" confirmation** (Best Music 0.2.91):
`SpeakerPlayGuard.confirmPlay` (`lib/services/speaker_play_guard.dart`) runs before every
UI play entry point — `MusicPlayerPage` Shuffle play and `_play` (tap a song / Play / play a
playlist), the mini player's and Now Playing's play button. It shows a "Play out loud?"
Cancel/Play dialog only when `Config.musicConfirmSpeakerPlay` (default on; Music Settings →
"Ask before playing out loud") is set, nothing is playing right now, and the
`besttodo/audio_output` channel's `isExternalOutputConnected` (MainActivity:
`AudioManager.getDevices(GET_DEVICES_OUTPUTS)` has any type besides built-in speaker/
earpiece/speaker-safe/telephony/remote-submix/unknown — i.e. no Bluetooth, wired/USB
headset, car, HDMI) returns false. Off Android or on a channel error it never asks.
Hardware media buttons and the notification are untouched (a headset button implies a
headset anyway). Tests: `test/music/speaker_play_guard_test.dart`.
*0.3.19 gaps closed*: "nothing is playing" now means not **audible** —
`MusicAudioHandler.isAudible` = `_player.playing && _audibleSinceLoad`, the latter set when
the player state is playing+ready and cleared at the start of every `_playCurrent` — because
`playbackState.playing` is already true while a video is still being resolved/buffered, so
switching to music then skipped the question. The guard now also runs in
`switchSessionAndShow` ("Back to music/videos" pill, mini player and Now Playing switch;
dialog on the navigator's context, Cancel = no switch), the Subscriptions feed's `_play`
(tap, swipe/long-press "Play", options-sheet Play, online search results) and Songs by
BPM's `_play`. **Home-screen widgets**: their play/pause button is now a `PendingIntent`
for `MusicPlayGuardActivity` (translucent, `taskAffinity=""`, `noHistory`, excluded from
Recents) instead of the bare media-button broadcast: when the widget data says playing,
`music_confirm_speaker` (written by `MusicWidgetService` on attach, with every sync and when
the setting is toggled) is false, or `AudioOutputs.isExternalConnected` (the shared helper
MainActivity's channel now uses too) — it sends the play/pause broadcast
(`MusicWidgetIntents.playPauseBroadcast`) and finishes invisibly; otherwise it shows a
native "Play out loud?" AlertDialog over the home screen (Play → broadcast; Cancel/outside →
nothing). Skip buttons still broadcast directly.

**Best Music share-to-download** (Best Music 0.2.91): Best Music uses the same native path
(`ShareActivity` → `MainActivity` → `besttodo/share` → `ShareIntentService`), hooked up in
`lib/main_music.dart`'s `_BestMusicAppState` with the same one-at-a-time share queue as
`main.dart`. Since everything shared into a music app is a song to find, it routes through
`detectBestMusicShare` instead: Spotify/Shazam/YouTube exactly as above, plus any *other*
link (`MusicLinkSource.otherLink` — Apple Music, Deezer, SoundCloud, ...; caption first,
else the page's `og:title`/`<title>` minus a short trailing "| Site") and plain text such
as "Song - Artist" (`MusicLinkSource.text`, searched as-is). Only a blank (file-only)
share is dropped, straight back to the sharing app. Best Music opens
`Mp3DownloaderPage(sharedLink: ..., autoDownloadTopMatch: true)`: a share that resolves to
a *search* queues the top result immediately (no tap needed) and keeps the other
candidates listed under "Downloading the top match. Wrong song? Tap the right one below
instead." — tapping another candidate cancels the auto-picked job (`Mp3DownloadManager.
cancel`) and queues that one. BestToDo keeps the plain picker (flag off). After a download
lands inside the library folder (`Config.musicFolder`, defaulting to the MP3 download folder
when unset — same rule as `MusicPlayerPage.initState`), `MusicDownloadLibrarySync`
(`lib/services/music_download_library_sync.dart`) rescans the library once the download
queue goes idle, so the song is playable without a manual Rescan; only completions seen
after `attach()` count, never the persisted history. The music flavor's
`android/app/src/music/AndroidManifest.xml` replaces `ShareActivity` (`tools:node=
"replace"`) with a text/plain-only filter, so Best Music isn't offered for images/PDFs.
Tests: `test/tools/music_share_link_test.dart` (`detectBestMusicShare`, other-link/text
resolving), `test/tools/mp3_downloader_test.dart` ("autoDownloadTopMatch (Best Music)"),
`test/music/music_download_library_sync_test.dart`, `test/update/music_build_wiring_test.dart`
(manifest overlay).

### 10.6r Settings survive updates (Best Music 0.3.36)

`Config.save` writes `settings.json` through `SafeFile.writeString` (atomic `.tmp` + rename,
previous content kept as `settings.json.bak`) and `Config.load` reads it through
`SafeFile.readWithRecovery`, so a save cut off by the app being killed — an update installing,
while `MediaVolume` saves on every volume change — falls back to the last good settings
instead of silently resetting everything (the music server login included). The music server
address, user name and password are also kept in `music_server.json` (same SafeFile handling),
rewritten only when they change; `load` takes the login from there whenever `settings.json`
has no server address. A failed "Connect" in the Server tab now puts the previous login back
instead of clearing just the user name. Tests: `test/music/config_persistence_test.dart`.

### 10.6r2 Song name and artist from "Artist - Song" names (0.3.44)

`Track.displayTitle` / `Track.displayArtist` are what every song row, Now Playing / the
notification (`MusicAudioHandler._toMediaItem`), the queue, the Server tab, the BPM page, the
metadata scan and the online look-up use. The title is taken, or the file name when there is no
title; then an "Artist - Song" form (`-`, `–` or `—`, `Track.splitArtistAndSong`) shows "Song",
with "Artist" below when the artist tag is empty or is that same artist. A different artist
leaves a dashed title alone ("Hey Jude - Remastered 2015"), and Subscriptions videos keep their
own titles. At scan time (`MusicLibraryService._buildTrack`), a file with no title and no artist
tag (every non-MP3, since only MP3 tags are read on the phone) is stored with the split title
and artist, so the Artists tab, search and rule playlists see them too.

### 10.6s Best Music Organizer on the computer (organizer/, 2026-10-15)

A separate tool, not part of the app: `organizer/` is a Python web app run on the computer
(`organizer/Music-Organizer.cmd` on Windows, `python organizer/organizer.py`), serving a page on
127.0.0.1:8770. The idea is to organize the music where it's fast (the computer) and sync the
result to the music server Pi, which the app streams from. Full guide: `organizer/README.md`.

- **Library** (`mo/library.py`): an SQLite index (`organizer/local/library.sqlite`) of every audio
  file under Settings → Music folder, re-read only when size or mtime changes. Tags are read and
  written with mutagen's easy interface (title, artist, album, albumartist, genre, date,
  tracknumber). Moves never overwrite (`name (2).mp3`), and folders left empty are removed.
  Deletes go to `organizer/local/trash/<day>/`. Every move and delete goes into a journal
  (table `ops`), which the sync replays on the Pi.
- **Playlists** are `.m3u8` files in `<music>/Playlists/`, with relative paths. They sync like
  songs, and Navidrome imports them at its scan (`AutoImportPlaylists = true` in the
  MagicMirror repo's navidrome.toml). A moved song's entry follows it, and a deleted song's
  entry is dropped.
- **Names** (`mo/names.py`): `clean_title`/`clean_artist` port `track_title.dart`'s
  junk-annotation rule and add track-number, underscore, ALL-CAPS and "feat." clean-up.
  `split_artist_title` treats underscores as spaces, so `kygo_-_stole_the_show` splits too.
  `song_key` (accent/case/punctuation/feat-insensitive artist|title) drives duplicates and the
  "already have" mark. `format_pattern` builds paths from `{artist}/{title}`-style patterns with
  Windows-safe parts.
- **Get music** (`mo/sources.py`, `mo/downloader.py`):
  - **Lists:** pasted lists, YouTube search (yt-dlp flat search), Deezer's public API for an
    artist's top songs and a country's "Top <country>" chart playlist by "Deezer Charts" (local
    names like "Top Belgique" accepted), and a free prompt answered by Claude. Charts also has a
    period picker ("right now" or one of the last 16 years): a year sends a ready-made
    year-end-chart prompt to the Claude source instead of Deezer (Belgium → Ultratop year
    chart). Without an API key (Settings or `ANTHROPIC_API_KEY`) the Claude source says so
    instead of failing inside the client.
  - **Claude:** `claude-opus-5-5` with the `web_search_20260209` server tool and a strict
    `submit_songs` tool for the result. It handles `pause_turn`, has `fallbacks: "default"`
    under `server-side-fallback-2026-07-01`, and checks for refusals.
  - **Downloads:** the downloader takes `ytsearch1:<artist> - <title> audio` (or the given
    link), converts with ffmpeg (mp3 VBR 0, or m4a without re-encoding), tags with the list's
    artist/title, files by pattern and can append to a playlist.
- **Sync** (`mo/pisync.py`), over `ssh <piHost>` (BatchMode, key only):
  - **Remote script:** a small standard-library Python script, base64-wrapped, lists the Pi's
    music folder (`mirror.json` `music.folder`) and applies the journal. Moves happen only when
    the source is there and the target isn't; if the target already has the same size, the
    source goes to the trash. Deletes go to `music.trashFolder/<day>/`, the same layout as the
    nightly clean-up.
  - **What gets copied:** files new here, or with a different size, or newer here by more
    than 2 s, are copied as a tar stream (`tar -xf - --no-same-owner`, umask 002, mtimes
    kept).
  - **Pi-only files:** they can be pulled (`tar -cf - --null -T -`, extracted safely) or sent
    to the trash, chosen per top folder.
  - **Scan:** optional `sudo -n mirrorctl music scan`.
- **Not yet:** the app doesn't list the server's playlists (Navidrome has them after its scan;
  the Server tab shows folders only).
- Tests: `python -m unittest discover -s organizer/tests` (real MP3s made with ffmpeg, a
  folder standing in for the Pi, and a stand-in `ssh` that runs the real SSH code path
  locally).

### 10.6t Build facts per version in the Changelog (Best Music 0.3.43)

Each release card on the Changelog page (`lib/ui/changelog_page.dart`) ends with small chips
saying when that version was built, how long the build took and how big its APK is ("Built
15.10.2026, 14:02", "Build time 3m 12s", "APK 19.4 MB", in the app's date format). They come
from the updates package (1.5.0)'s `ReleaseBuildInfo` on `AppUpdates.controller`: the
version's GitHub release (the highest build of that x.y.z, any channel) — its notes' build
footer ("- Built: … in 3m 12s", "- Build duration: …"; else the release's publish time) and the
APK asset's size — from the same cached releases list the version sheet uses (one request,
refreshed by pull-down). The CHANGELOG.md build lines (`isChangelogBuildNote`: "Local build:",
"Build duration (apk):", "APK size:", …) are the `fallback`: shown while the list loads, when
the version has no release or its release says nothing, and when there is no controller —
never together with the release's chips. The strings are the package's English defaults
(`releaseBuilt`, `releaseBuildTime`, `releaseApkSize`). Tests:
`test/music/changelog_page_test.dart` (fake releases through `test/update/update_fakes.dart`,
whose `release()` takes `body:` and `size:`).

### 10.6u Now-playing highlight, Play history, listening counters (Best Music 0.3.45)

**Now-playing highlight** — `NowPlaying.trackId` (`lib/services/now_playing.dart`, a static
`ValueNotifier<String?>`) holds the id of the track the player holds, playing or paused;
`MusicAudioHandler` sets it in `restore` and `_playCurrent`. `NowPlayingHighlight`
(`lib/ui/now_playing_highlight.dart`) rebuilds a row when it changes and gives `ListTile`s the
`primaryContainer` selected colours, so rows pass `selected: isCurrent` and swap their leading
icon for `nowPlayingIcon` (`Icons.graphic_eq`). Used by every song row (`TrackListView`: Tracks,
Favourites, playlists, artist/tag/folder drill-ins, search), the Queue (which now follows the
player as songs change), Songs by BPM, Server folder songs, YouTube search results, Play history,
and `FeedVideoTile` (tinted background + a "Now playing" line; never dimmed as played while
playing). Feed videos and YouTube songs match on `youtube:<videoId>`.

**Play history** — `PlayHistoryService` (`lib/services/play_history_service.dart`,
`play_history.json`, loaded at startup, in backups) keeps a `PlayHistoryEntry` (id, trackId,
title, artist, isVideo, playedAt) for every song or Subscriptions video whose audio loaded
(`_playCurrent`, after `setAudioSource` succeeds — unplayable tracks aren't logged). Title and
artist are copied at play time. Starting the same track again within `repeatWindow` (30 min:
resuming after a pause, restart or "Back to music") adds nothing. Entries older than `retention`
(90 days) are dropped on load and on every new entry. `delete(id)`, `deleteDay(date)`, `clear()`.
Page: drawer → Tools → Play history (`lib/ui/play_history_page.dart`) — newest first, a month
header ("October 2026"), a day header ("Today"/"Yesterday"/"Thursday 15 October", "N played",
"Delete this day"), then rows "HH:mm · [Video ·] artist" with "Delete from history"; app bar
"Clear history" (asks first).

**Listening counters** — `Track` gained `skipCount`, `upSwipeCount`, `downSwipeCount` next to
`playCount` (JSON keys of the same names, omitted at 0; kept by rescans and server syncs via
`Track.withCountersOf`, by manual edits and CSV imports). Counted by `MusicAudioHandler`:
play = played to the end (unchanged); skip = `skipToNext` (Next on Now Playing, notification,
headset) while the track plays; swipe up = `swipeUpCurrent` (Now Playing swipe up — now always
adds to Favorites instead of toggling it off when already there; the heart button still
toggles and isn't counted); swipe down = `dislikeCurrentAndSkip` (swipe down or thumbs-down),
which moves on without also counting a skip. The Track info page shows Plays, Skipped, Swiped
up, Swiped down and the Shuffle weight. `isFavorite`/`isDisliked` return false (instead of
crashing) before the playlists are loaded.

**Shuffle** — `weightedShuffle` weighs each track by `weightFor(track)` = `weightOf(id)`
(Favorites 3, "Don't really like" 0.05, else 1) × `listeningFactor(track)` =
`sqrt((plays + 2·ups + 2) / (skips + 3·downs + 2))` clamped to 0.25–4: 1.0 with no history,
~2.9 for 100 plays/10 skips, ~0.53 for 5 skips and nothing else. A ratio, so a much-played song
skipped now and then stays high. Applies to every shuffle (Shuffle all, a list's shuffle
button, the end-of-queue reshuffle, the switch from videos back to music).
Tests: `test/music/play_history_service_test.dart`, `test/music/play_history_page_test.dart`,
`music_playlist_service_test.dart` (factor/weight/ordering), `music_audio_handler_test.dart`,
`music_player_page_test.dart`, `youtube_feed_page_test.dart`, `track_metadata_page_test.dart`.

### 10.6v Add to playlist from Now Playing, one switch button, volume order on switching (Best Music 0.3.46)

- **Add to playlist** — Now Playing's tools row gains a `playlist_add` button (tooltip "Add to
  playlist", songs only — hidden for Subscriptions videos) that opens the same
  `showAddToPlaylistSheet` as a track row's ⋮ menu: New playlist, then a checkbox per hand-built
  playlist.
- **One switch button** — `SessionSwitchPill` (the floating bottom-left circle) is now also
  hidden whenever the song bar shows its own `SwitchSessionButton` (a track is loaded and
  `otherSession` is set). It still shows when the bar has none to offer, e.g. nothing loaded yet
  or no remembered other session but a last-played video to go back to.
- **Volume order** — `MusicAudioHandler.volumeOrder(MediaVolume.playingKind, nextKind)` decides
  when `_playCurrent` moves the phone volume: video → music (`beforeSwitch`): the music volume is
  set first, while the video still plays, then the song loads and starts; music → video
  (`afterSwitch`): the music is paused at once, the video loads and starts, and the volume
  changes once it is actually playing (`_untilAudible`: playing + ready, at most 10 s); same
  kind or nothing before (`whenLoaded`): right after loading, as before.
  Tests: `test/music/music_resume_test.dart` (pill hidden next to the bar's button, volume
  order), `test/music/now_playing_page_test.dart` (Add to playlist).

### 10.6w Next on the song bar (Best Music 0.3.47)

`MusicMiniPlayerBar` gains a Next button after play/pause (and after forward 10 s for a video):
`skip_next`, key `musicMiniPlayerNext`, labelled "Next" through `Semantics` like play/pause
(the bar sits outside the navigator's Overlay). It calls `skipToNext`, so it counts as a skip
of the track being left (§10.6u). Test: `test/music/music_resume_test.dart`.

### 10.6x Play history entry options (Best Music 0.3.48)

Each Play history row gets an info button (tooltip "Song info and options", next to "Delete from
history") opening `showPlayHistoryEntrySheet`: the title/artist, then **Song info**
(`TrackMetadataPage`), **Play next**, **Add to queue**, **Add to playlist**
(`showAddToPlaylistSheet`) and **Delete from history**. `playHistoryTrackOf(entry)` finds the
track: the library song by id (null once it's gone, which leaves only Delete and says "no longer
in your library"), or for a video the feed's copy, else `Track.youtube` rebuilt from the entry.
A video only gets Add to queue, through `addToVideoQueue`. Songs use the new
`MusicAudioHandler.addToMusicQueue(track, playNext:)`: right after the playing song or at the
end of the music queue; while a video plays, into the remembered music session (or a new one)
that "Back to music" resumes; with nothing loaded, the paused queue. Queue options need the
player to be ready. Tests: `test/music/play_history_page_test.dart`,
`test/music/music_audio_handler_test.dart`.

### 10.6y Play history days fold (Best Music 0.3.49)

`PlayHistoryPage` is stateful: tapping a day header (chevron `expand_less`/`expand_more`) folds
or unfolds that day's entries. Only the newest day in the list starts open; days toggled by hand
are remembered while the page is open (`_open`), so after deleting the newest day the next one
becomes the open default. The day header's subtitle is the short date plus the count,
"Fri 16.10.26 · 5 played" (`playHistoryShortDate`: `ddd dd.mm.yy`), under the
"Today"/"Yesterday"/"Thursday 15 October" title. Test: `test/music/play_history_page_test.dart`.

### 10.6z Playlists: rename, edit, delete (Best Music 0.3.50)

`lib/ui/playlist_edit.dart`. Every hand-built, imported or rule playlist
(`playlistIsEditable`: not system, kind list or rule) gets a `PlaylistOptionsButton` (⋮, tooltip
"Playlist options") on its Playlists-tab row (replacing the old delete / edit-rules icons) and in
its `MusicPlaylistDetailPage` app bar: **Rename** (`promptPlaylistName` with title "Rename
playlist", the old name pre-selected, "Save" → `MusicPlaylistService.renamePlaylist`, which
ignores system playlists and blank names), **Edit songs** / **Edit rules**
(`openPlaylistEditor`: `EditPlaylistSongsPage` for a list, `RulePlaylistEditorPage` for a rule
playlist) and **Delete** (`confirmDeletePlaylist`: "Delete "<name>"?" — the songs stay; from the
playlist's own page the page closes after). `EditPlaylistSongsPage`: a `ReorderableListView` of
the resolved songs with a drag handle each, "Remove from playlist" per row, and Rename / Add
songs in the app bar; a drag saves through `MusicPlaylistService.setTrackOrder(id, ordered)`,
which keeps ids not shown (songs no longer in the library) at the end. Every change saves at
once. Test: `test/music/playlist_edit_test.dart`.

### 10.6aa Sort by times played, playlist order (Best Music 0.3.51)

`TrackSortField` gains `playCount` ("Times played": most played first by default, "Least played
first" flipped; ties by title; fast-scroll bubble "12 plays"; while it's the sort, each row's
subtitle adds "· N plays" via `playCountLabel`) and `listOrder` ("Playlist order": the list as
given, or reversed — "First to last"/"Last to first"). `listOrder` is only offered where
`TrackListView(listOrder: true)`, which `MusicPlaylistDetailPage` passes for every playlist (its
`resolvedTracks` order: the order dragged on Edit songs, or Last Added/Most Played's computed
order). The choice is shared through `Config.musicTrackSortField` like the others; a list that
isn't a playlist shows "Added to device" while "Playlist order" is the remembered choice
(`_shownField`). Tests: `test/music/music_player_page_test.dart` (track sorting).

### 10.6ab Liked songs, separate from Favorites (Best Music 0.3.52)

A third system playlist, `MusicPlaylist.liked()` (id `liked`, "Liked songs", icon `thumb_up`),
kept between Favorites and "Don't really like". Swipe up on Now Playing
(`MusicAudioHandler.swipeUpCurrent`) counts the swipe and calls
`MusicPlaylistService.markLiked` (into Liked songs, out of "Don't really like"); it no longer
touches Favorites, which only the heart button / ⋮ "Add to Favorites" / Add to playlist fill.
`markDisliked` also takes a song out of Liked songs. `load` adds Liked songs to an older
playlists file, filled with the library songs that have `upSwipeCount > 0` (swipe-ups are
counted since 0.3.45; before 0.3.52 they went into Favorites, which keeps them). Shuffle weight:
`likedWeight` 2 (Favorites 3 wins when both). Now Playing flashes "Added to Liked songs", the
hint reads "Swipe up to like • swipe down to skip & dislike", and a liked song shows a
thumbs-up next to the Favorites heart under its title. Liked songs' page offers "Remove from
playlist" per song (there is no un-swipe); it stays a system list (no add, rename or delete).
Tests: `music_playlist_service_test.dart`, `music_audio_handler_test.dart`,
`music_player_page_test.dart`.

### 10.6ac Lyrics and Repeat on Now Playing (Best Music 0.3.53)

Two ideas taken from the Obsidian Music Player app (`varun7009/obsidian-music`, a closed-source
Android player whose repo holds only its README, screenshots and release notes): synced lyrics
and a repeat button. Now Playing's tools row gains two buttons (Repeat, and Lyrics for songs),
which makes eight for a song; on a phone narrower than 48 dp per button the row is scaled down
to fit (`FittedBox`) rather than overflowing.

- **Repeat** — `MusicRepeatMode { off, all, one }` on `MusicAudioHandler.repeatMode`
  (`ValueNotifier`), cycled by `cycleRepeat()` (off → all → one → off) and saved as
  `Config.musicRepeatMode` (`settings.json` key `musicRepeatMode`, `'off'`/`'all'`/`'one'`).
  The button shows `repeat` / `repeat_one`, coloured when on; tooltips "Repeat off" / "Repeat
  all" / "Repeat one". The mode is also reported in `PlaybackState.repeatMode`, and
  `setRepeatMode` (what Bluetooth/car/Android media controls call) sets it.
  - *off* is what Best Music always did: after the queue's last song, a fresh weighted shuffle
    of the whole library (a Subscriptions-feed queue just stops).
  - *all*: `_advance` runs the next position through `MusicAudioHandler.wrapIndex`, so past
    the last song is the first again and Previous on the first is the last (feed queues
    too).
  - *one*: when a song ends (`ProcessingState.completed`, after the play count and the "end of
    song" sleep timer are handled), it is rewound and played again, and recorded in the play
    history again. Next/Previous still move on.
- **Lyrics** — `lib/ui/lyrics_view.dart` (`LyricsView`; until 0.3.55 a separate `LyricsPage`
  opened by a "Lyrics" button, now the Lyrics tab of Now Playing's ⓘ panel, §10.6ae). It
  follows the playing song (a new `mediaItem` → a new lookup) and shows:
  - *synced* lyrics as a column of lines: the one being sung (`Lyrics.indexAt`) is bright and
    fills in character by character as it's sung (`Lyrics.progressAt`: LRC only gives line
    starts, so a line is assumed to last 70 ms per character, at least 1.5 s, never past the
    next line's start); the rest are dim. The page polls `playbackState.position` every 100 ms
    and scrolls the current line to 40 % of the panel's height (`Scrollable.ensureVisible`) unless the
    user scrolled by hand in the last 4 s. Tapping a line seeks there. An empty LRC line
    (instrumental break) shows as "♪".
  - *plain* lyrics as selectable text, with a note that they aren't timed.
  - messages for no lyrics ("Search again"), LRCLIB unreachable ("Try again"), instrumental,
    and a Subscriptions video (they have a transcript instead).
  Under the lyrics, "Lyrics from …" names the source, next to a refresh button ("Search
  lyrics again") that looks again, skipping the saved copy.
- **Where lyrics come from** — `lib/services/lyrics_service.dart` (`LyricsService.lyricsFor`),
  in order: (1) an `.lrc` file next to a local song (`Song.mp3` → `Song.lrc`, UTF-8 or
  Latin-1); (2) the `USLT` frame of a local mp3's ID3v2 tag (the whole tag is read, size from
  its header, at most 8 MiB, so big cover art in front doesn't hide it); (3) the saved result of
  an earlier lookup, `lyrics/<sha1 of track id>.json` in the app documents dir (found lyrics and
  "instrumental" for good, "nothing found" for 7 days); (4) LRCLIB (`lrclib.net`, free, no
  account): `/api/get` with title, artist, album and length (seconds) first, then `/api/search`
  per spelling from `queryVariants` (cleaned title, main artist, no brackets), each result scored
  with the metadata lookup's `matchScore` (≥ `minMatchScore`), a synced record winning a tie.
  Title/artist are `displayTitle`/`displayArtist`, so "Artist - Song" file names work. A
  network failure, 429 or 5xx is reported as unavailable and not saved. Lookups only happen
  while the lyrics page is open, so playing music uses no extra data.
- **LRC parsing** — `lib/models/lyrics.dart` (`Lyrics.parseLrc`): `[mm:ss]`, `[mm:ss.x]`,
  `[mm:ss.xx]`, `[mm:ss.xxx]` and `[mm:ss:xx]` stamps, several per line (a repeated chorus),
  `[offset:±ms]` (positive = earlier), word stamps (`<mm:ss.xx>`) dropped, other `[tag:value]`
  lines skipped, lines sorted by time (stable). Text without stamps becomes plain lyrics.
  Tests: `test/music/lyrics_test.dart` (parser, `indexAt`, `progressAt`, JSON),
  `test/music/lyrics_service_test.dart` (exact match, search fallback and scoring, the 7-day
  "nothing found", instrumental, offline, `.lrc` file, ID3 `USLT`, videos),
  `test/music/lyrics_view_test.dart` (panel, sung line, plain, messages, following the song,
  narrow phone), `test/music/music_audio_handler_test.dart` and
  `test/music/now_playing_page_test.dart` (repeat).

### 10.6ad Selecting several songs (Best Music 0.3.54)

Every song list can select songs and act on all of them at once. `TrackSelection`
(`lib/ui/track_selection_bar.dart`, a mixin on the list's `State`) holds the selected ids:

- **Starting** — a row's music icon (the note, the server cloud, or the now-playing icon) is
  wrapped in an `InkResponse` with tooltip "Select" (`selectionLeading`); tapping it selects
  that song. Long-pressing a row selects it too.
- **While selecting** — the icons turn into a tick (`check_circle`, primary colour) or an empty
  circle, selected rows are highlighted (`ListTile.selected`), a row tap selects/unselects
  instead of playing (`selectionTap`), and the system back gesture ends the selection instead
  of leaving the page (`selectionScope`, a `PopScope`). Songs that leave the list (deleted,
  removed) drop out of the selection (`keepSelectedIn`).
- **`TrackSelectionBar`** replaces the list's sort/play row (or the BPM page's divider, or sits
  above a server folder's list): ✕ "Cancel selection", "N selected", "Select all" / "Select
  none" (once all are selected), "Play selected" (plays them as the queue, in list order, and
  opens Now Playing), "Add selected to playlist" (`showAddTracksToPlaylistSheet`: New playlist
  with all of them, or tap a hand-made playlist to add them — `addAllTo`, no duplicates,
  "Already in it" shown) and "More for selected": Play next / Add to queue
  (`MusicAudioHandler.addAllToMusicQueue`: in list order; with nothing loaded they become the
  queue), Add to Favorites (`MusicPlaylistService.addAllToFavorites`, also out of "Don't really
  like"), Remove from playlist (only where `TrackListView.onRemove` is set: a hand-made
  playlist's page), Move to folder (`pickFolderAndMoveTracks`: only when all are phone songs or
  all server songs, `canMoveTogether`; the shared current folder isn't offered) and Delete
  (`confirmAndDeleteTracks`: one "Delete N songs?" question, then each is deleted; a failure is
  reported with how many went). Every action except Select all ends the selection.
- **Where** — `TrackListView` (Tracks, Favourites, search results, artist/folder/tag pages,
  playlist pages), Songs by BPM (`BpmRangePage`) and the server's folders (`ServerFolderView`,
  now stateful). The queue (drag to reorder, its own remove) and Play history (its own per-entry
  menu) keep their own handling.
  Tests: `test/music/track_selection_test.dart`, `test/music/bpm_range_page_test.dart`,
  `test/music/music_audio_handler_test.dart` (`addAllToMusicQueue`).

### 10.6ae Now Playing's ⓘ panel: Lyrics and Info tabs, controls always in view (Best Music 0.3.55)

The ⓘ button in Now Playing's tools row (tooltip "Track info", "Hide track info" while open,
filled and coloured when open) no longer opens `TrackMetadataPage`; it toggles
`NowPlayingPage.showDetails` (a static `ValueNotifier<bool>`, so the next Now Playing in the same
app run opens the same way). The separate Lyrics button is gone.

- **Closed** — as before: the big artwork, title and artist fill the top, the "Swipe up to like
  • swipe down to skip & dislike" hint, then the controls; the whole page takes the swipes.
- **Open** — everything moves up: `_CompactHeader` (56 px artwork, title, artist, the
  favourite/liked marks; it alone takes the swipes, and the swipe's confirmation shows in place
  of the title) at the top, then the controls (back-to-video chip, progress bar, transport, tools
  row) — never scrolled away — then, filling the rest (about the bottom half),
  `_DetailsPanel`: a `TabBar` with **Lyrics** (`LyricsView`) and **Info** (`TrackInfoView`),
  each scrolling on its own. The last tab is remembered (`NowPlayingPage.detailsTab`).
- **Info tab** — `TrackInfoView` (`lib/ui/track_metadata_page.dart`): title, artist, album,
  genre, year, BPM, tags, an "Edit info" button (opens `TrackMetadataPage`, the editor), then
  `TrackStatsRows` — length, plays, skips, swipes, shuffle weight, dates, source, file — the
  same rows `TrackMetadataPage` shows under its fields (moved there from the page). A
  Subscriptions video (not a library song) shows its title, channel and length.
  Tests: `test/music/lyrics_view_test.dart` (ⓘ opens the panel above which the controls stay,
  Info tab, closing, the panel on a 320×640 screen), `test/music/now_playing_page_test.dart`.

### 10.6af Progress bar on one line, lyrics lookup says why it failed (Best Music 0.3.56)

- Now Playing's `_ProgressBar` is one row: elapsed time, the `Slider`, the length (small text),
  so it takes one line instead of two (the ⓘ panel gets the room). While the length isn't
  known yet the bar is empty and the length reads "--:--" (it used to show a full bar and
  "00:00").
- `LyricsService`: each LRCLIB request is tried once more after a timeout or connection error;
  when it still fails the lookup carries a `reason` ("no answer within 15 s", "server error
  503", the connection error's first line), shown in brackets under "Couldn't reach the
  lyrics service (LRCLIB)" and written to the app log (source "Lyrics").
- `LyricsService.splitForLyrics`: a song with no artist whose name is "Artist ●● Song",
  "Artist • Song", "Artist | Song" or "Artist: Song" (YouTube uploads) is searched as that
  artist and song.
  Tests: `test/music/now_playing_page_test.dart`, `test/music/lyrics_service_test.dart`.

### 10.6ag No volume button on Now Playing (Best Music 0.3.57)

Now Playing's tools row no longer has the volume button (tooltip "Music volume" / "Video
volume"): the phone's volume keys change the volume, and the separate music and video volumes
(`showVolumeSheet`, `MediaVolume`) are still set in Settings. The row is now speed (videos),
sleep timer, shuffle, repeat, queue, add to playlist (songs) and ⓘ.
- **Lyrics lookup, more robust (same release)** — `LyricsService._getJson` tries each LRCLIB
  request up to 3 times (waiting 1 s, then 3 s: `retryDelays`) on a timeout (now 20 s), lost
  connection, 429 or server error, instead of once. A request that still fails no longer ends
  the lookup: the other requests (exact match, then the searches) carry on, and only when none
  of them got an answer is the result "unavailable", with the actual reason — "No internet:
  lrclib.net could not be found", "LRCLIB didn't answer within 20 s", "LRCLIB server error
  503", "The connection to lrclib.net was cut off", … "(tried 3 times)" — shown as "Couldn't
  get lyrics: <reason>." and logged. Found lyrics stay on the phone for good
  (`lyrics/<sha1>.json`): they're shown without a connection ("Lyrics from LRCLIB · saved on
  this phone", `LyricsLookup.saved`), and "Search again" / "Try again" falling offline or finding
  nothing keeps showing the saved copy rather than throwing it away.

### 10.6ac Charts in the MP3 Downloader (Best Music 0.3.58)

`lib/services/chart_lookup_service.dart` + the MP3 Downloader page. A folded "Top songs from the
charts" panel (`ExpansionTile`, shown while no results are on screen: idle, error, or during a
chart lookup) with four dropdowns: Year (this year back to 1960), Top (5/10/20/25/40/50/100,
default 10), Country (`ChartQuery.countries`, Belgium first, Worldwide last) and Style
(`ChartQuery.styles`, default Pop, "All styles" for the main chart), then "Find chart songs".
`ChartLookupService.lookup(ChartQuery)` calls Claude (`claude-opus-5-5`, raw HTTP like
`VideoSummaryService`, key `Config.claudeApiKey`; without it the page says to set it under
Settings → Transcripts & summaries) with the `web_search_20260209` server tool and a strict
`submit_songs` client tool (no forced `tool_choice` — it is a 400 on Opus 5.5 — the system prompt
asks for it), `output_config.effort: medium`, `fallbacks: "default"` under
`server-side-fallback-2026-07-01`. `pause_turn` resends the paused assistant turn; a text-only
answer gets one "please use submit_songs" follow-up; a refusal or API error becomes a readable
`ChartLookupException`. `ChartQuery.prompt` asks for the year-end chart (the year-to-date ranking
for the current year), Ultratop (Flanders) for Belgium, global charts for Worldwide, and a genre
chart or the style's songs from the main chart. The page then searches YouTube per song, lyric video first
(0.3.63): `search("Artist - Title lyrics", limit: 5)` and takes the first hit whose title says
"lyric" and contains the song title (`ChartSong.pickLyricsVideo`; lyric videos are more often the
clean edit), else `search("Artist - Title", limit: 1)` (progress: an `EstimatedProgressBar` with remaining time
while Claude searches, then "Finding the videos: i of N"), skips songs with no video or a
duplicate video (listed in a snackbar), and opens the result in the playlist picker
(`_showTrackPicker`, shared with playlist links: already-saved songs unticked, All/None,
Download N). Picker rows carry a second line "1 · Artist - Title" for a chart, and every row (charts
and playlists) has a "Download this one" button that queues just that song and marks it
Downloading. Tests: `test/tools/chart_lookup_test.dart`.

### 10.6ah Track info: Playlists dropdown and editable file name (Best Music 0.3.59)

- **Playlists** — `TrackPlaylistsField` (`lib/ui/track_playlists_field.dart`), above Tags on
  `TrackMetadataPage` and in Now Playing's Info tab (`TrackInfoView`): an `InputDecorator` styled
  like a dropdown ("Playlists", ▾) listing every hand-made/system list playlist the song is in
  ("Not in any playlist" when none). Tapping it opens a bottom sheet with a checkbox per list
  playlist (Favorites, Liked songs, "Don't really like", your own; smart playlists fill
  themselves and aren't listed), "New playlist" (with this song) and Done. Ticks apply right
  away, keeping the system rules: ticking Favorites also leaves "Don't really like"
  (`toggleFavorite`), Liked songs uses `markLiked`, "Don't really like" uses `markDisliked`.
- **File name** — under Tags on `TrackMetadataPage`: a text field with the file name without
  its extension (shown after it as `suffixText`), key `trackFileNameField`. Save (after the tag
  fields are saved) calls `TrackFileActions.rename(track, name)`: same folder, same extension;
  refuses an empty name, `\ / : * ? " < > |` and a name already taken (a change of case only is
  allowed); renames an `.lrc` file next to it too; the song keeps its playlists
  (`renameTrackId`), counts and saved lyrics (`LyricsService.moveSaved`), and the player's queue
  swaps it in (`MusicAudioHandler.replaceTrack`, also used by Move to folder now) so the playing
  song plays on. An error shows as a snack bar and the page stays open. Music server songs
  can't be renamed (the field is disabled, saying so). The Info tab shows "File name" under Tags.
  Tests: `test/music/track_metadata_page_test.dart`, `test/music/track_file_actions_test.dart`,
  `test/music/music_audio_handler_test.dart` (`replaceTrack`).

### 10.6ad Charts without an API key (Best Music 0.3.60)

`lib/services/builtin_charts.dart`. `ChartLookupService.lookup` now: with `Config.claudeApiKey`
→ Claude as in §10.6ac; without it → `BuiltInCharts.lookup` (asset
`assets/charts/year_end_charts.json`: `{"<country>": {"<year>": [["Artist", "Title", "Style"],
...]}}` for Belgium, United Kingdom, United States, France, Germany, Spain and Switzerland,
2000–2025, 15–25 songs a year in chart order where known, each tagged with one of
`ChartQuery.styles`; the query's style filters, its count cuts; result `source: builtIn`, summary
"Built-in list: the biggest Pop hits of 2005 in Belgium (N in the built-in top M)"); else, for the
current year, `DeezerCharts.currentChart` (Deezer's free API: the "Top <country>" playlist by the
"Deezer Charts" account, found through `search/playlist` with per-country aliases, then
`playlist/<id>/tracks?limit=N`; no style filter, the summary says so); else a
`ChartLookupException` naming what's covered and pointing to the key. `ChartSong.style` carries the
tag; `ChartQuery.countries` lists the built-in countries first (Switzerland added). The page no
longer requires the key and shows the result's summary (source) in the snackbar with any songs
that had no video.

The built-in lists were compiled on 2026-10-17 from year-end charts (Ultratop Flanders, Official
Charts Company, Billboard Year-End Hot 100, SNEP, Offizielle Deutsche Charts, PROMUSICAE, Schweizer
Hitparade) as far as web search summaries showed them, completed from knowledge: the top of each
year is mostly in official order, lower places are ordered by how big the hit was. Test
(`test/tools/chart_lookup_test.dart`) checks the asset's shape: every country and year, ≥ 15
songs, known styles.

### 10.6ae Shorten song (Best Music 0.3.61)

`lib/services/audio_trimmer.dart` (`AudioTrimmer`, pure Dart, run in an `Isolate`): cuts a file
without re-encoding. **MP3**: frames are parsed (MPEG 1/2/2.5, layers I-III, a frame counts as
real only when another follows), whole frames inside the range are kept (a frame is in when at
least half of it is), the ID3v2 tag at the front and ID3v1 at the end are copied, and a
Xing/Info first frame is rewritten (frame count, byte count, a fresh 100-entry seek table; the
LAME/Lavc tag after it, whose encoder delay/padding/CRC no longer fit, is blanked; VBRI is left).
**M4A/MP4 (AAC)**: one non-fragmented audio track only (`moof` or several `trak`s are refused);
per-sample durations/sizes/offsets come from `stts`/`stsz`/`stsc`/`stco`|`co64`; the kept samples
(half-inside rule) go into a new `mdat` after a rebuilt `moov` (`stbl` = original `stsd` + new
`stts`, a one-chunk `stsc`, `stsz`, `stco`; `edts` and sample groups dropped; `mdhd`/`mvhd`/`tkhd`
durations updated; `udta` tags copied; `ftyp` kept). **WAV**: `fmt ` + the data cut on block
boundaries. Other formats throw `AudioTrimException` ("Shortening .webm files isn't supported
yet").

`lib/services/track_trimmer.dart` (`TrackTrimmer`): phone songs only (`canTrim`: local file with a
supported extension). In place: the short version is written next to the file
(`<name>.trimming.<ext>`), the original moves to `<documents>/trim_backups/<ms>_<name>` (backups
older than 7 days are purged on the next trim), the short one takes the original name; the
library entry keeps its id and counters and gets the new `durationMs`; the media scanner is told.
Keep original: `<name> (short).<ext>` (or `(short 2)`…) becomes a new library song titled
"<title> (short)" with fresh counters. `undo` moves the original back (or deletes the copy) and
restores the library entry.

`lib/ui/trim_song_page.dart` (`TrimSongPage`), from a song's ⋮ menu ("Shorten song") and the
Track info app bar (scissors, tooltip "Shorten song"): the exact length read from the file, a
`RangeSlider` (min 1 s kept), ±1 s buttons per edge, previews of the first/last 5 s through a
page-local `just_audio` player (`ClippingAudioSource`), "Save as a new song" switch, Shorten →
snackbar "Shortened to m:ss.t" with Undo. Tests: `test/music/audio_trimmer_test.dart` with
ffmpeg-made fixtures in `test/fixtures/audio/` (CBR and VBR MP3, AAC M4A, WAV); the trimmed
outputs were checked with ffprobe/ffmpeg (length, tags, error-free decode) when written.

