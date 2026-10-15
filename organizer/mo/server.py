"""The organizer's local web server: the page (web/) and a JSON API on 127.0.0.1 only."""
import json
import mimetypes
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import downloader, names, pisync, sources
from .config import HERE
from .jobs import Jobs
from .library import FIELDS, Library, LibraryError

WEB = os.path.join(HERE, "web")
for _ext, _type in ((".m4a", "audio/mp4"), (".flac", "audio/flac"), (".opus", "audio/ogg"),
                    (".ogg", "audio/ogg"), (".mp3", "audio/mpeg"), (".js", "text/javascript")):
    mimetypes.add_type(_type, _ext)
TRACK_FIELDS = ["path", "title", "artist", "album", "albumartist", "genre", "year", "track",
                "duration", "bitrate", "size", "added", "ext"]


class App:
    def __init__(self, config, remote_factory=None):
        self.cfg = config
        self.lib = Library(config)
        self.jobs = Jobs()
        self.remote_factory = remote_factory or (
            lambda: pisync.SSHRemote(self.cfg["piHost"], self.cfg["piMusicFolder"]))
        self.last_plan = None

    # ------------------------------------------------------------------ reads
    def state(self):
        root = self.cfg.music
        return {"config": self.cfg.public(), "musicOk": bool(root and os.path.isdir(root)),
                "version": self.lib.version, "pending": len(self.lib.pending_ops()),
                "presets": names.PRESETS, "countries": sources.COUNTRIES,
                "jobs": self.jobs.public()}

    def tracks(self):
        rows = [[t.get(f) for f in TRACK_FIELDS] for t in self.lib.tracks()]
        return {"version": self.lib.version, "fields": TRACK_FIELDS, "rows": rows}

    def mark_known(self, candidates):
        keys = self.lib.keys() if self.cfg.music and os.path.isdir(self.cfg.music) else {}
        for c in candidates:
            c["have"] = keys.get(names.song_key(c.get("artist"), c.get("title"))) or ""
        return candidates

    # ------------------------------------------------------------------ jobs
    def start_scan(self):
        return self.jobs.start("scan", "Reading the music folder", lambda job: self.lib.scan(job.update))

    def bulk(self, kind, title, items, fn):
        """Runs fn(item) for every item as a job; failures are listed, the rest goes on."""
        def work(job):
            ok, failed = 0, []
            for i, item in enumerate(items):
                if job.cancelled:
                    break
                job.update(i / max(1, len(items)), "%d of %d" % (i + 1, len(items)))
                try:
                    fn(item)
                    ok += 1
                except Exception as e:
                    failed.append({"item": item if isinstance(item, str) else item.get("path"), "error": str(e)})
                    job.log("✗ %s" % e)
            return {"done": ok, "failed": failed}
        return self.jobs.start(kind, title, work)

    def source_job(self, kind, body):
        n = max(1, min(100, int(body.get("count") or 10)))
        if kind == "paste":
            return {"songs": self.mark_known(sources.parse_list(body.get("text", ""))), "summary": ""}
        titles = {"youtube": "Searching YouTube", "artist": "Top songs of %s" % body.get("artist", ""),
                  "chart": "Chart: %s" % body.get("country", ""), "ask": "Asking Claude"}

        def work(job):
            if kind == "youtube":
                songs, summary = sources.youtube_search(body.get("query", ""), n), ""
            elif kind == "artist":
                songs, summary = sources.artist_top(body.get("artist", ""), n), "Deezer's top songs"
            elif kind == "chart":
                songs, summary = sources.chart(body.get("country", ""), n), "Deezer's current chart"
            elif kind == "ask":
                songs, summary = sources.ask_claude(body.get("prompt", ""), self.cfg["anthropicApiKey"])
            else:
                raise sources.SourceError("Unknown source")
            return {"songs": self.mark_known(songs), "summary": summary}
        return self.jobs.start("source", titles.get(kind, kind), work)

    def download_job(self, body):
        items = [c for c in body.get("songs", []) if c.get("title") or c.get("url")]
        if not items:
            raise LibraryError("Nothing selected")
        self.lib.root  # music folder must be set
        pattern = body.get("pattern") or self.cfg["pattern"]
        fmt = self.cfg["downloadFormat"]
        playlist = (body.get("playlist") or "").strip() or None
        return self.jobs.start("download", "Downloading %d song%s" % (len(items), "" if len(items) == 1 else "s"),
                               lambda job: downloader.run_queue(self.lib, items, pattern, fmt, playlist, job))

    def sync_plan_job(self):
        def work(job):
            job.update(0.1, "Asking the Pi what it has")
            self.last_plan = pisync.plan(self.lib, self.remote_factory())
            return self.last_plan
        return self.jobs.start("sync-plan", "Comparing with the Pi", work)

    def sync_job(self, body):
        if self.jobs.running("sync"):
            raise LibraryError("A sync is already running")
        return self.jobs.start("sync", "Syncing with the Pi", lambda job: pisync.run(
            self.lib, self.remote_factory(), pull=body.get("pull", []), trash_remote=body.get("trash", []),
            scan=bool(body.get("scan", self.cfg["piScanAfterSync"])), job=job))

    # ------------------------------------------------------------------ tidy
    def cleanup(self):
        out = []
        for t in self.lib.tracks():
            changes, reasons = names.proposal(t)
            if changes:
                out.append({"path": t["path"], "artist": t["artist"], "title": t["title"],
                            "changes": changes, "reasons": reasons})
        return out

    def organize_preview(self, pattern, paths=None):
        moves = []
        wanted = set(paths) if paths else None
        taken = {}
        for t in self.lib.tracks():
            if wanted is not None and t["path"] not in wanted:
                continue
            new = names.format_pattern(pattern, t) + os.path.splitext(t["path"])[1]
            if new == t["path"]:
                continue
            key = new.lower()
            if key in taken:
                base, ext = os.path.splitext(new)
                taken[key] += 1
                new = "%s (%d)%s" % (base, taken[key], ext)
            else:
                taken[key] = 1
            moves.append({"from": t["path"], "to": new})
        return moves

    def duplicates(self):
        groups = {}
        for t in self.lib.tracks():
            k = names.song_key(t["artist"], t["title"] or t["stem"])
            if k:
                groups.setdefault(k, []).append(t)
        out = []
        for k, ts in groups.items():
            if len(ts) < 2:
                continue
            ts.sort(key=lambda t: (-(t["bitrate"] or 0), -(t["size"] or 0)))
            out.append({"key": k, "tracks": [{f: t.get(f) for f in TRACK_FIELDS} for t in ts]})
        return sorted(out, key=lambda g: g["tracks"][0]["artist"].lower())


class Handler(BaseHTTPRequestHandler):
    app = None  # App
    server_version = "BestMusicOrganizer"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, data, ctype="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        a = self.app
        try:
            if path.startswith("/api/"):
                q = dict(urllib.parse.parse_qsl(url.query))
                routes = {
                    "/api/state": a.state,
                    "/api/tracks": a.tracks,
                    "/api/playlists": a.lib.playlists,
                    "/api/folders": a.lib.folders,
                    "/api/jobs": a.jobs.public,
                    "/api/cleanup": a.cleanup,
                    "/api/duplicates": a.duplicates,
                }
                if path == "/api/job":
                    job = a.jobs.get(q.get("id", 0))
                    return self.send(200, job.public()) if job else self.send(404, {"error": "No such job"})
                if path == "/api/audio":
                    return self.audio(q.get("path", ""))
                if path in routes:
                    return self.send(200, routes[path]())
                return self.send(404, {"error": "Not found"})
            return self.static(path)
        except (LibraryError, sources.SourceError, pisync.SyncError) as e:
            self.send(400, {"error": str(e)})

    def do_POST(self):
        # Only the page itself (same origin) may change things.
        if self.headers.get("X-Organizer") != "1":
            return self.send(403, {"error": "Forbidden"})
        path = urllib.parse.urlsplit(self.path).path
        a = self.app
        try:
            b = self.body()
            if path == "/api/config":
                a.cfg.update(b)
                return self.send(200, a.state())
            if path == "/api/scan":
                return self.send(200, a.start_scan().public())
            if path == "/api/tags":
                fields = {k: v for k, v in (b.get("fields") or {}).items() if k in FIELDS}
                return self.send(200, a.bulk("tags", "Writing tags", list(b.get("paths", [])),
                                             lambda p: a.lib.retag(p, fields)).public())
            if path == "/api/retag":  # different values per song: [{path, fields}]
                items = list(b.get("items", []))
                return self.send(200, a.bulk("tags", "Writing tags", items,
                                             lambda it: a.lib.retag(it["path"], it.get("fields", {}))).public())
            if path == "/api/move":
                if b.get("moves"):
                    moves = list(b["moves"])
                elif b.get("pattern"):
                    moves = a.organize_preview(b["pattern"], b.get("paths"))
                else:
                    folder = (b.get("folder") or "").strip("/")
                    moves = [{"from": p, "to": (folder + "/" if folder else "") + os.path.basename(p)}
                             for p in b.get("paths", [])]
                return self.send(200, a.bulk("move", "Moving %d songs" % len(moves), moves,
                                             lambda m: a.lib.move(m["from"], m["to"])).public())
            if path == "/api/organize/preview":
                return self.send(200, a.organize_preview(b.get("pattern") or a.cfg["pattern"], b.get("paths")))
            if path == "/api/delete":
                paths = list(b.get("paths", []))
                return self.send(200, a.bulk("delete", "Deleting %d songs" % len(paths), paths, a.lib.delete).public())
            if path == "/api/playlist/save":
                rel = a.lib.save_playlist(b.get("path") or b.get("name") or "Playlist", list(b.get("tracks", [])))
                return self.send(200, {"path": rel})
            if path == "/api/playlist/add":
                pl = next((p for p in a.lib.playlists() if p["path"] == b.get("path")), None)
                tracks = (pl["tracks"] if pl else []) + [t for t in b.get("tracks", []) if not pl or t not in pl["tracks"]]
                rel = a.lib.save_playlist(b.get("path") or b.get("name") or "Playlist", tracks)
                return self.send(200, {"path": rel, "count": len(tracks)})
            if path == "/api/playlist/rename":
                return self.send(200, {"path": a.lib.rename_playlist(b["path"], b["name"])})
            if path == "/api/playlist/delete":
                a.lib.delete_playlist(b["path"])
                return self.send(200, {"ok": True})
            if path.startswith("/api/source/"):
                kind = path.rsplit("/", 1)[1]
                r = a.source_job(kind, b)
                return self.send(200, r if isinstance(r, dict) else r.public())
            if path == "/api/download":
                return self.send(200, a.download_job(b).public())
            if path == "/api/sync/plan":
                return self.send(200, a.sync_plan_job().public())
            if path == "/api/sync/run":
                return self.send(200, a.sync_job(b).public())
            if path == "/api/job/cancel":
                job = a.jobs.get(b.get("id", 0))
                if job:
                    job.cancelled = True
                return self.send(200, {"ok": True})
            return self.send(404, {"error": "Not found"})
        except (LibraryError, sources.SourceError, pisync.SyncError, downloader.DownloadError, KeyError, ValueError) as e:
            self.send(400, {"error": str(e)})

    def static(self, path):
        rel = path.lstrip("/") or "index.html"
        full = os.path.realpath(os.path.join(WEB, rel))
        if not full.startswith(os.path.realpath(WEB) + os.sep) or not os.path.isfile(full):
            full = os.path.join(WEB, "index.html")
        with open(full, "rb") as f:
            data = f.read()
        self.send(200, data, mimetypes.guess_type(full)[0] or "application/octet-stream")

    def audio(self, rel):
        """Lets the page play a song (with seeking: Range requests)."""
        full = self.app.lib.full(rel)
        if not os.path.isfile(full):
            return self.send(404, {"error": "Not found"})
        size = os.path.getsize(full)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else max(0, size - int(b or 0))
            end = int(b) if a and b else size - 1
        end = min(end, size - 1)
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", mimetypes.guess_type(full)[0] or "audio/mpeg")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(1 << 16, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)


def serve(config, port=None, remote_factory=None):
    Handler.app = App(config, remote_factory)
    httpd = ThreadingHTTPServer(("127.0.0.1", config["port"] if port is None else port), Handler)
    httpd.daemon_threads = True
    return httpd
