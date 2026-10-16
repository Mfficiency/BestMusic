# Best Music Organizer (on your computer)

A fast web page on your own computer for **organizing your music**: grouping by artist, album
and genre, fixing tags, cleaning up file names, sorting songs into folders, making playlists and
downloading new songs from YouTube. Everything happens on the computer (instant, even with
thousands of songs); **Sync to Pi** then sends the result to the music server on the Raspberry
Pi in one go. The Best Music app on the phone sees it after the server's scan.

## Start

Windows: double-click **`organizer\Music-Organizer.cmd`**. It installs what it needs
(`pip install -r requirements.txt`, which also keeps yt-dlp up to date) and opens
http://127.0.0.1:8770 in the browser. Elsewhere:

```sh
pip install -r organizer/requirements.txt
python organizer/organizer.py            # --port 8770 --no-browser --local <settings folder>
```

Needs:

- **Python 3.10+** (`winget install Python.Python.3.12`)
- **ffmpeg** for downloads (`winget install Gyan.FFmpeg`)
- **SSH to the Pi with a key** for the sync: `ssh hally` must log in without a password. It's the
  same setup as the MagicMirror tools (`headless-mirror/tools/mirror-music-copy.sh`). Windows
  10/11 has `ssh` built in.
- An **Anthropic API key** only for *Ask for a list* (Settings, or `ANTHROPIC_API_KEY`).

The page only listens on 127.0.0.1, so nothing outside the computer can reach it. Settings,
the song index and the organizer's own trash are kept in `organizer/local/`, which is not in git.

## First time

1. **Settings → Music folder**: the folder with your music on this computer, for example
   `D:\Music`. If the music is only on the Pi so far, pick an empty folder.
2. **Sync to Pi → Check what changed**. Songs that are only on the Pi (all of them, the first
   time, and songs uploaded from the phone into `Phone/`) can be fetched with **Get them here**.
   After that, the computer is where you organize, and the Pi follows.

## What's in it

**Library**
- **Songs**: every song in a fast list. Sort by any column, filter as you type (`/`), select with
  click, Shift and Ctrl (Ctrl+A for all). Double-click a cell to edit that tag, on every selected
  song at once. Double-click a title (or press Enter) to play it. Select songs to get
  **Edit info**, **Add to playlist**, **Move to folder**, **Rename by pattern**,
  **Clean up names** and **Delete**. Delete moves songs to `organizer/local/trash/` here, and
  to the Pi's 30-day trash at the next sync.
- **Artists / Albums / Genres / Folders**: the groups on the left, their songs on the right.
  Select several groups and use **Rename / merge** to make "KYGO", "Kygo" and
  "Kygo - Topic" one artist, or to sort genres into the ones you want.
- **Playlists**: + makes one. Drag songs onto a playlist in the sidebar, drag inside a playlist
  to change the order. They are `.m3u8` files in `<music>/Playlists/`. The Pi's Navidrome
  imports them as playlists at its scan, and they follow songs that move.

**Get music** (you see the list and tick what you want first; songs you already have are
marked and unticked):
- **Search YouTube**: pick the exact videos.
- **Artist's top songs**: the artist's most played songs (Deezer).
- **Charts**: a country's current chart (Deezer's "Top Belgium"-style charts), or pick a year
  for that year's official year-end chart (for Belgium the Ultratop year chart; the current year
  gives the year so far). A year's chart is looked up by Claude, so it needs the API key.
- **Ask for a list**: anything in your own words, for example *"the top 10 of the Belgian
  Ultratop year chart 2026"* or *"Dua Lipa's 15 most streamed songs"*. Claude looks it up on
  the web, so it uses real, current charts, and returns the list. Each list costs a few cents of
  API use.
- **Paste a list**: `Artist - Title` lines, `Title by Artist` or YouTube links.

Downloads are tagged with artist and title, saved by your pattern (default
`{artist}/{title}`), and can go straight into a playlist. MP3 by default; M4A in Settings
keeps YouTube's own audio without re-encoding.

**Tidy up**
- **Clean up names**: removes "(Official Video)", "[Lyrics]", "- Topic", "VEVO", track numbers
  and underscores, fixes ALL CAPS, and takes the artist out of "Artist - Title" titles.
  You check each change, and the files can be renamed to match in the same step.
- **Group into folders**: moves every song into folders made from its tags, for example
  `Artist/Title`, `Genre/Artist/Title` or `A-Z/Artist/Title`, with a preview first.
- **Duplicates**: the same song in several files (spelling, case and "feat." ignored). The
  copy with the best bitrate is kept.
- **Missing info**: songs without an artist, title, genre, album or year.

**Sync to Pi**
1. Moves, renames and deletes you did here are **repeated on the Pi**, so a renamed song is
   renamed there instead of copied again. Deleted songs go to the Pi's music trash
   (`mirrorctl music trash`, kept 30 days).
2. New songs, and songs you changed here (tags), are copied over SSH.
3. Files that are only on the Pi are listed by folder. For each folder you choose **Get them
   here**, **Move to the Pi's trash** or **Leave**. `Phone/` (uploads from the app) defaults to
   Get them here.
4. *Let the server scan right away* runs `sudo mirrorctl music scan` (low priority). Otherwise
   the changes show up after the nightly scan.

The Pi's music folder comes from its `mirror.json` (`music.folder`, normally `/srv/music`),
or from Settings → Pi music folder.

## For developers

- `organizer.py` starts `mo/server.py` (JSON API + `web/`). The modules are `mo/library.py`
  (SQLite index, mutagen tags, moves/deletes with a journal, playlists), `mo/names.py`
  (clean-up rules, the same as the app's `track_title.dart`, plus file name patterns),
  `mo/sources.py` (lists), `mo/downloader.py` (yt-dlp), `mo/pisync.py` (sync over SSH; on
  the Pi only Python's standard library and tar are used) and `mo/jobs.py` (background jobs
  the page polls).
- Tests: `python -m unittest discover -s organizer/tests` (needs ffmpeg for the test MP3s;
  `test_ssh_remote.py` runs the real SSH code path through a stand-in `ssh` on Linux/macOS).
