"""The music library on this computer: an index of every song (SQLite, so the page is fast),
tags read and written with mutagen, moves/renames/deletes, and playlists (.m3u8 files).

Every move and delete is written to a journal (table ops), which the Pi sync replays there,
so a renamed song is renamed on the Pi instead of copied again.
"""
import datetime
import os
import shutil
import sqlite3
import threading
import time

from . import names

AUDIO = {".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".wma", ".aif", ".aiff", ".alac"}
PLAYLIST = {".m3u", ".m3u8"}
SYNCED = AUDIO | PLAYLIST | {".jpg", ".jpeg", ".png", ".lrc"}
PLAYLIST_FOLDER = "Playlists"
FIELDS = ("title", "artist", "album", "albumartist", "genre", "year", "track")
SKIP_DIRS = {"$RECYCLE.BIN", "System Volume Information"}


class LibraryError(Exception):
    pass


def _easy(path):
    import mutagen  # imported late so the tests of other parts run without it
    f = mutagen.File(path, easy=True)
    if f is None:
        raise LibraryError("Not an audio file mutagen can read: %s" % os.path.basename(path))
    return f


def _first(tags, key):
    v = tags.get(key) if tags else None
    if isinstance(v, list):
        v = v[0] if v else ""
    return str(v).strip() if v is not None else ""


def _int(text):
    digits = ""
    for c in str(text or "").strip():
        if not c.isdigit():
            break
        digits += c
    return int(digits) if digits else None


def read_tags(path):
    """{title, artist, album, albumartist, genre, year, track, duration, bitrate} of a file."""
    out = {k: "" for k in ("title", "artist", "album", "albumartist", "genre")}
    out.update(year=None, track=None, duration=None, bitrate=None)
    try:
        f = _easy(path)
    except Exception:
        return out
    tags = f.tags
    for k in ("title", "artist", "album", "albumartist", "genre"):
        out[k] = _first(tags, k)
    out["year"] = _int(_first(tags, "date") or _first(tags, "year"))
    out["track"] = _int(_first(tags, "tracknumber"))
    info = getattr(f, "info", None)
    if info is not None:
        out["duration"] = round(getattr(info, "length", 0) or 0, 1) or None
        out["bitrate"] = int((getattr(info, "bitrate", 0) or 0) / 1000) or None
    return out


def write_tags(path, fields):
    """Writes the given fields (title, artist, album, albumartist, genre, year, track)."""
    f = _easy(path)
    if f.tags is None:
        try:
            f.add_tags()
        except Exception as e:
            raise LibraryError("This file type can't hold tags: %s (%s)" % (os.path.basename(path), e))
    for k, v in fields.items():
        key = {"year": "date", "track": "tracknumber"}.get(k, k)
        if k not in FIELDS:
            continue
        v = "" if v is None else str(v).strip()
        try:
            if v:
                f.tags[key] = [v]
            elif key in f.tags:
                del f.tags[key]
        except (KeyError, ValueError) as e:
            raise LibraryError("Can't set %s on %s: %s" % (k, os.path.basename(path), e))
    f.save()


class Library:
    def __init__(self, config):
        self.cfg = config
        self.lock = threading.RLock()
        self.db = sqlite3.connect(os.path.join(config.local, "library.sqlite"), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS tracks (
                path TEXT PRIMARY KEY, size INTEGER, mtime REAL, title TEXT, artist TEXT,
                album TEXT, albumartist TEXT, genre TEXT, year INTEGER, track INTEGER,
                duration REAL, bitrate INTEGER, added REAL);
            CREATE TABLE IF NOT EXISTS ops (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, src TEXT, dst TEXT,
                at REAL, synced INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        self.db.commit()
        self.version = 0  # bumped on every change, so the page knows to reload

    # ------------------------------------------------------------------ paths
    @property
    def root(self):
        root = self.cfg.music
        if not root or not os.path.isdir(root):
            raise LibraryError("Pick your music folder in Settings first")
        return root

    def full(self, rel):
        rel = clean_rel(rel)
        if rel is None:
            raise LibraryError("Not a path inside the music folder")
        full = os.path.normpath(os.path.join(self.root, *rel.split("/")))
        if not os.path.realpath(full).startswith(os.path.realpath(self.root) + os.sep):
            raise LibraryError("Not a path inside the music folder")
        return full

    def touched(self):
        self.version += 1

    # ------------------------------------------------------------------ scan
    def walk(self, exts=AUDIO):
        """(rel, full) of every file with one of exts under the music folder."""
        root = self.root
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS)
            for name in sorted(filenames):
                if name.startswith(".") or os.path.splitext(name)[1].lower() not in exts:
                    continue
                full = os.path.join(dirpath, name)
                yield os.path.relpath(full, root).replace(os.sep, "/"), full

    def scan(self, progress=None):
        """Brings the index up to date: new and changed files are read, gone files dropped."""
        with self.lock:
            known = {r["path"]: (r["size"], r["mtime"]) for r in self.db.execute("SELECT path, size, mtime FROM tracks")}
        seen, changed, n = set(), 0, 0
        files = list(self.walk())
        for rel, full in files:
            n += 1
            seen.add(rel)
            try:
                st = os.stat(full)
            except OSError:
                continue
            if known.get(rel) == (st.st_size, round(st.st_mtime, 3)):
                continue
            self._index(rel, full, st)
            changed += 1
            if progress and changed % 25 == 0:
                progress(n / max(1, len(files)), "%d of %d files" % (n, len(files)))
        gone = [p for p in known if p not in seen]
        with self.lock:
            self.db.executemany("DELETE FROM tracks WHERE path = ?", [(p,) for p in gone])
            self.db.commit()
        self.touched()
        return {"files": len(files), "read": changed, "gone": len(gone)}

    def _index(self, rel, full, st=None):
        st = st or os.stat(full)
        t = read_tags(full)
        with self.lock:
            row = self.db.execute("SELECT added FROM tracks WHERE path = ?", (rel,)).fetchone()
            self.db.execute(
                "INSERT OR REPLACE INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (rel, st.st_size, round(st.st_mtime, 3), t["title"], t["artist"], t["album"],
                 t["albumartist"], t["genre"], t["year"], t["track"], t["duration"], t["bitrate"],
                 row["added"] if row else time.time()))
            self.db.commit()

    # ------------------------------------------------------------------ reading
    def tracks(self):
        with self.lock:
            rows = self.db.execute("SELECT * FROM tracks ORDER BY path").fetchall()
        return [track_dict(r) for r in rows]

    def track(self, rel):
        with self.lock:
            r = self.db.execute("SELECT * FROM tracks WHERE path = ?", (rel,)).fetchone()
        return track_dict(r) if r else None

    def keys(self):
        """{song key: path} of the library, to mark songs that are already here."""
        return {names.song_key(t["artist"], t["title"]): t["path"] for t in self.tracks() if t["title"]}

    def folders(self):
        out = set()
        for dirpath, dirnames, _ in os.walk(self.root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS]
            rel = os.path.relpath(dirpath, self.root).replace(os.sep, "/")
            if rel != ".":
                out.add(rel)
        return sorted(out, key=str.lower)

    # ------------------------------------------------------------------ changing
    def retag(self, rel, fields):
        full = self.full(rel)
        write_tags(full, {k: v for k, v in fields.items() if k in FIELDS})
        self._index(rel, full)
        self.touched()

    def move(self, rel, new_rel):
        """Moves/renames a song (keeping its extension) and returns the path it got."""
        src = self.full(rel)
        if not os.path.isfile(src):
            raise LibraryError("Not found: %s" % rel)
        ext = os.path.splitext(src)[1]
        new_rel = clean_rel(new_rel)
        if not new_rel:
            raise LibraryError("Bad target path")
        if not new_rel.lower().endswith(ext.lower()):
            new_rel += ext
        if new_rel == rel:
            return rel
        dst = self.full(new_rel)
        if os.path.exists(dst) and os.path.normcase(dst) != os.path.normcase(src):
            new_rel = unique_rel(self, new_rel)
            dst = self.full(new_rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.normcase(dst) == os.path.normcase(src):  # only the case changes (Windows)
            tmp = src + ".renaming"
            os.replace(src, tmp)
            os.replace(tmp, dst)
        else:
            shutil.move(src, dst)
        prune_empty(self.root, os.path.dirname(src))
        with self.lock:
            self.db.execute("UPDATE tracks SET path = ? WHERE path = ?", (new_rel, rel))
            self.journal("move", rel, new_rel)
        self.rewrite_playlists({rel: new_rel})
        self.touched()
        return new_rel

    def delete(self, rel):
        """Moves a song to organizer/local/trash/<day>/ (and the Pi's trash at the next sync)."""
        src = self.full(rel)
        if os.path.exists(src):
            day = datetime.date.today().isoformat()
            dst = os.path.join(self.cfg.local, "trash", day, *rel.split("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.exists(dst):
                base, ext = os.path.splitext(dst)
                dst = "%s.%d%s" % (base, int(time.time()), ext)
            shutil.move(src, dst)
            prune_empty(self.root, os.path.dirname(src))
        with self.lock:
            self.db.execute("DELETE FROM tracks WHERE path = ?", (rel,))
            self.journal("delete", rel, "")
        self.rewrite_playlists({rel: None})
        self.touched()

    def journal(self, kind, src, dst):
        with self.lock:
            self.db.execute("INSERT INTO ops (kind, src, dst, at) VALUES (?,?,?,?)", (kind, src, dst, time.time()))
            self.db.commit()

    def pending_ops(self):
        with self.lock:
            return [dict(r) for r in self.db.execute("SELECT * FROM ops WHERE synced = 0 ORDER BY id")]

    def mark_synced(self, ids):
        with self.lock:
            self.db.executemany("UPDATE ops SET synced = 1 WHERE id = ?", [(i,) for i in ids])
            self.db.commit()

    # ------------------------------------------------------------------ playlists
    def playlist_files(self):
        return list(self.walk(PLAYLIST))

    def playlists(self):
        """[{name, path, tracks: [rel...], missing: n}] of every .m3u/.m3u8 in the library."""
        out = []
        for rel, full in self.playlist_files():
            paths, missing = read_m3u(full, self.root)
            out.append({"name": os.path.splitext(os.path.basename(rel))[0], "path": rel,
                        "tracks": paths, "missing": missing})
        return sorted(out, key=lambda p: p["name"].lower())

    def playlist_path(self, name):
        return "%s/%s.m3u8" % (PLAYLIST_FOLDER, names.safe_part(name, "Playlist"))

    def save_playlist(self, rel, paths):
        """Writes a playlist (rel = its .m3u8 path, or a new name) with these songs in order."""
        if not rel.lower().endswith((".m3u", ".m3u8")):
            rel = self.playlist_path(rel)
        full = self.full(rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        tracks = {t["path"]: t for t in self.tracks()}
        lines = ["#EXTM3U"]
        here = os.path.dirname(full)
        for p in paths:
            t = tracks.get(p)
            if t:
                label = "%s - %s" % (t["artist"], t["title"]) if t["artist"] else (t["title"] or t["stem"])
                lines.append("#EXTINF:%d,%s" % (int(t["duration"] or -1), label))
            lines.append(os.path.relpath(self.full(p), here).replace(os.sep, "/"))
        tmp = full + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, full)
        self.touched()
        return rel

    def rename_playlist(self, rel, new_name):
        new_rel = os.path.dirname(rel) + "/" + names.safe_part(new_name, "Playlist") + os.path.splitext(rel)[1]
        new_rel = new_rel.lstrip("/")
        if new_rel == rel:
            return rel
        if os.path.exists(self.full(new_rel)):
            raise LibraryError("There is already a playlist called %s" % new_name)
        os.replace(self.full(rel), self.full(new_rel))
        self.journal("move", rel, new_rel)
        self.touched()
        return new_rel

    def delete_playlist(self, rel):
        full = self.full(rel)
        if os.path.exists(full):
            os.remove(full)
        self.journal("delete", rel, "")
        self.touched()

    def rewrite_playlists(self, changes):
        """Points playlists at moved songs ({old: new}) and drops deleted ones ({old: None})."""
        for p in self.playlists():
            if any(t in changes for t in p["tracks"]):
                new = [changes.get(t, t) for t in p["tracks"]]
                self.save_playlist(p["path"], [t for t in new if t])


# ---------------------------------------------------------------------- helpers
def track_dict(r):
    d = dict(r)
    d["stem"] = os.path.splitext(os.path.basename(d["path"]))[0]
    d["folder"] = os.path.dirname(d["path"])
    d["ext"] = os.path.splitext(d["path"])[1].lower().lstrip(".")
    return d


def clean_rel(rel):
    """A safe relative path with forward slashes, or None."""
    parts = [p.strip() for p in str(rel or "").replace("\\", "/").split("/")]
    parts = [p for p in parts if p and p != "."]
    if not parts or any(p == ".." or p.startswith(".") for p in parts):
        return None
    if ":" in parts[0]:
        return None
    return "/".join(parts)


def unique_rel(lib, rel):
    base, ext = os.path.splitext(rel)
    n = 2
    while os.path.exists(lib.full("%s (%d)%s" % (base, n, ext))):
        n += 1
    return "%s (%d)%s" % (base, n, ext)


def prune_empty(root, folder):
    root = os.path.realpath(root)
    folder = os.path.realpath(folder)
    while folder.startswith(root + os.sep):
        try:
            if any(not n.startswith(".") for n in os.listdir(folder)):
                return
            for n in os.listdir(folder):  # only hidden clutter (desktop.ini-like dotfiles)
                os.remove(os.path.join(folder, n))
            os.rmdir(folder)
        except OSError:
            return
        folder = os.path.dirname(folder)


def read_m3u(full, root):
    """(song paths relative to root, number of lines pointing at nothing) of a playlist."""
    paths, missing = [], 0
    here = os.path.dirname(full)
    try:
        with open(full, encoding="utf-8-sig", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return [], 0
    root_real = os.path.realpath(root)
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.replace("\\", "/")
        cand = p if os.path.isabs(p) else os.path.join(here, p)
        cand = os.path.realpath(cand)
        if not cand.startswith(root_real + os.sep):
            missing += 1
            continue
        # Kept even when the file is gone, so a move can point the entry at its new place.
        paths.append(os.path.relpath(cand, root_real).replace(os.sep, "/"))
        if not os.path.isfile(cand):
            missing += 1
    return paths, missing
