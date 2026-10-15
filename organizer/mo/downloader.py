"""Downloads songs from YouTube (yt-dlp + ffmpeg), tags them and files them in the library.

A candidate with a "url" downloads that video; otherwise the best match for
"<artist> - <title> audio" is taken. The file is tagged with the candidate's artist and
title (cleaned YouTube title when none), moved to the library by the pattern from Settings
and, when asked, added to a playlist.
"""
import glob
import os
import shutil
import tempfile

from . import names
from .library import LibraryError, write_tags


class DownloadError(Exception):
    pass


def ydl_options(fmt, out_dir, hook=None):
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "outtmpl": os.path.join(out_dir, "%(id)s.%(ext)s"),
        "progress_hooks": [hook] if hook else [],
        "retries": 3,
    }
    if fmt == "m4a":
        # YouTube's own AAC stream, no re-encoding.
        opts["format"] = "bestaudio[ext=m4a]/bestaudio/best"
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}]
    else:
        opts["format"] = "bestaudio/best"
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "0"}]
    return opts


def fetch(candidate, fmt, work_dir, hook=None, ydl_factory=None):
    """Downloads one candidate into work_dir; returns (file, youtube info)."""
    if ydl_factory is None:
        try:
            import yt_dlp
        except ImportError:
            raise DownloadError("yt-dlp is not installed (pip install -r organizer/requirements.txt)")
        ydl_factory = yt_dlp.YoutubeDL
    target = candidate.get("url") or "ytsearch1:%s audio" % " - ".join(
        x for x in (candidate.get("artist"), candidate.get("title")) if x)
    with ydl_factory(ydl_options(fmt, work_dir, hook)) as ydl:
        info = ydl.extract_info(target, download=True)
    if info and info.get("entries"):
        info = info["entries"][0]
    if not info:
        raise DownloadError("Nothing found on YouTube")
    files = [f for f in glob.glob(os.path.join(work_dir, "%s.*" % info.get("id", "*")))
             if not f.endswith((".part", ".ytdl", ".webp", ".jpg"))]
    want = "." + ("m4a" if fmt == "m4a" else "mp3")
    files.sort(key=lambda f: (not f.endswith(want), f))
    if not files:
        raise DownloadError("The download produced no audio file (is ffmpeg installed?)")
    return files[0], info


def download_one(lib, candidate, pattern, fmt, hook=None, ydl_factory=None):
    """Downloads, tags and files one song; returns its library path."""
    work = tempfile.mkdtemp(prefix="bm-dl-", dir=lib.cfg.local)
    try:
        file, info = fetch(candidate, fmt, work, hook, ydl_factory)
        artist, title = candidate.get("artist") or "", candidate.get("title") or ""
        if not title:
            a, t = names.split_artist_title(info.get("title") or "",
                                            names.clean_artist(info.get("artist") or info.get("channel") or ""))
            artist, title = artist or a, names.clean_title(t)
        tags = {"artist": names.clean_artist(artist), "title": title}
        if info.get("release_year"):
            tags["year"] = info["release_year"]
        if candidate.get("album"):
            tags["album"] = candidate["album"]
        try:
            write_tags(file, tags)
        except Exception as e:
            raise DownloadError("Could not tag the file: %s" % e)
        ext = os.path.splitext(file)[1]
        rel = names.format_pattern(pattern, tags) + ext
        dst = lib.full(rel)
        if os.path.exists(dst):
            from .library import unique_rel
            rel = unique_rel(lib, rel)
            dst = lib.full(rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(file, dst)
        lib._index(rel, dst)
        lib.touched()
        return rel
    except LibraryError as e:
        raise DownloadError(str(e))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_queue(lib, candidates, pattern, fmt, playlist=None, job=None, ydl_factory=None):
    """Downloads the candidates one after the other; failures are reported, not fatal."""
    done, failed = [], []
    total = len(candidates)
    for i, c in enumerate(candidates):
        if job and job.cancelled:
            break
        label = " - ".join(x for x in (c.get("artist"), c.get("title")) if x) or c.get("url", "")
        if job:
            job.update(i / max(1, total), "%d of %d · %s" % (i + 1, total, label))

        def hook(d, i=i):
            if job and d.get("status") == "downloading" and d.get("total_bytes"):
                part = d.get("downloaded_bytes", 0) / d["total_bytes"]
                job.update((i + part * 0.9) / max(1, total))

        try:
            rel = download_one(lib, c, pattern, fmt, hook, ydl_factory)
            done.append(rel)
            if job:
                job.log("✓ %s → %s" % (label, rel))
        except Exception as e:
            failed.append({"song": label, "error": str(e)})
            if job:
                job.log("✗ %s: %s" % (label, e))
    if playlist and done:
        existing = next((p for p in lib.playlists() if p["name"].lower() == playlist.lower()), None)
        paths = (existing["tracks"] if existing else []) + [p for p in done if not existing or p not in existing["tracks"]]
        lib.save_playlist(existing["path"] if existing else playlist, paths)
    return {"downloaded": done, "failed": failed}
