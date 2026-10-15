"""Keeps the music server Pi's music folder the same as the library on this computer.

1. Moves, renames and deletes done here (the library's journal) are replayed on the Pi, so a
   renamed song is renamed there instead of copied again. Deletes go to the Pi's music trash
   (kept 30 days, 'mirrorctl music trash restore').
2. Files that are new here, or changed here since they were copied (bigger/smaller, or newer
   after a tag edit), are copied over SSH as a tar stream, mtimes kept.
3. Files that are only on the Pi (e.g. songs uploaded from the phone into Phone/) are listed;
   they can be pulled to this computer or moved to the Pi's trash.
4. Optionally Navidrome scans right away ('sudo mirrorctl music scan'); otherwise at night.

Playlists are .m3u8 files in the library, so they travel with the songs and Navidrome
imports them at its scan (AutoImportPlaylists).

The Pi is reached with plain `ssh <host>` (same key as the MagicMirror tools); everything on
it runs as the mirror user with Python's standard library.
"""
import base64
import json
import os
import subprocess
import tarfile
import time

from .library import SYNCED, clean_rel

REMOTE_PY = r'''
import datetime, json, os, shutil, sys
mode, override = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
try:
    music = json.load(open("/etc/magicmirror/mirror.json")).get("music", {})
except Exception:
    music = {}
root = os.path.abspath(override or music.get("folder") or "/srv/music")
trash = os.path.abspath(music.get("trashFolder") or (root.rstrip("/") + "-trash"))
EXTS = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else set()

def inside(rel):
    full = os.path.normpath(os.path.join(root, rel))
    if not full.startswith(root + os.sep) or "/." in "/" + rel:
        raise ValueError("bad path " + rel)
    return full

def prune(folder):
    while folder.startswith(root + os.sep):
        try:
            os.rmdir(folder)
        except OSError:
            return
        folder = os.path.dirname(folder)

def to_trash(full, rel):
    day = datetime.date.today().isoformat()
    dst = os.path.join(trash, day, rel)
    base, ext = os.path.splitext(dst)
    n = 1
    while os.path.exists(dst):
        n += 1
        dst = "%s (%d)%s" % (base, n, ext)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(full, dst)
    prune(os.path.dirname(full))

if mode == "info":
    print(json.dumps({"root": root, "trash": trash, "exists": os.path.isdir(root),
                      "writable": os.access(root, os.W_OK)}))
elif mode == "list":
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        for f in files:
            if f.startswith(".") or os.path.splitext(f)[1].lower() not in EXTS:
                continue
            p = os.path.join(d, f)
            try:
                st = os.stat(p)
            except OSError:
                continue
            out[os.path.relpath(p, root)] = [st.st_size, int(st.st_mtime)]
    print(json.dumps(out))
elif mode == "ops":
    results = []
    for op in json.load(sys.stdin):
        try:
            src = inside(op["src"])
            if op["kind"] == "delete":
                if os.path.isfile(src):
                    to_trash(src, op["src"])
                    results.append([op["id"], "trashed"])
                else:
                    results.append([op["id"], "absent"])
            elif op["kind"] == "move":
                dst = inside(op["dst"])
                if not os.path.isfile(src):
                    results.append([op["id"], "absent"])
                elif os.path.exists(dst):
                    if os.path.getsize(dst) == os.path.getsize(src):
                        to_trash(src, op["src"])  # the new place already has it
                        results.append([op["id"], "merged"])
                    else:
                        results.append([op["id"], "target exists"])
                else:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    os.replace(src, dst)
                    prune(os.path.dirname(src))
                    results.append([op["id"], "moved"])
        except Exception as e:
            results.append([op.get("id"), "error: %s" % e])
    print(json.dumps(results))
'''


class SyncError(Exception):
    pass


class SSHRemote:
    """The Pi over `ssh <host>`."""

    def __init__(self, host, music_folder=""):
        if not host:
            raise SyncError("Set the Pi's SSH host in Settings")
        self.host = host
        self.override = music_folder or ""
        self._info = None

    def _ssh(self, command, stdin=None, timeout=600):
        try:
            p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", self.host, command],
                               input=stdin, capture_output=True, timeout=timeout)
        except FileNotFoundError:
            raise SyncError("ssh is not installed on this computer (Windows: Settings → Optional features → OpenSSH Client)")
        except subprocess.TimeoutExpired:
            raise SyncError("The Pi did not answer in time")
        if p.returncode != 0:
            raise SyncError("ssh %s failed: %s" % (self.host, (p.stderr or b"").decode(errors="replace").strip()[-400:]))
        return p.stdout

    def _py(self, mode, stdin=None, exts=""):
        code = base64.b64encode(("import base64,sys\n" + REMOTE_PY).encode()).decode()
        args = [mode, self.override, exts]
        cmd = "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' %s %s" % (
            code, " ".join(_sh(a) for a in args))
        out = self._ssh(cmd, stdin=stdin).decode("utf-8", errors="replace").strip()
        try:
            return json.loads(out)
        except ValueError:
            raise SyncError("Unexpected answer from the Pi: %s" % (out[-300:] or "(nothing)"))

    def info(self):
        if self._info is None:
            self._info = self._py("info")
            if not self._info.get("exists"):
                raise SyncError("No music folder %s on %s ('mirrorctl music setup' on the Pi)" % (self._info["root"], self.host))
        return self._info

    def listing(self):
        return self._py("list", exts=",".join(sorted(SYNCED)))

    def apply_ops(self, ops):
        return self._py("ops", stdin=json.dumps(ops).encode())

    def upload(self, local_root, rels, progress=None):
        root = self.info()["root"]
        done = 0
        for batch in _batches(rels, 100):
            cmd = "umask 002 && cd %s && tar -xf - --no-same-owner" % _sh(root)
            with subprocess.Popen(["ssh", "-o", "BatchMode=yes", self.host, cmd],
                                  stdin=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
                try:
                    with tarfile.open(fileobj=proc.stdin, mode="w|", format=tarfile.GNU_FORMAT) as tar:
                        for rel in batch:
                            tar.add(os.path.join(local_root, *rel.split("/")), arcname=rel, recursive=False,
                                    filter=_plain)
                            done += 1
                            if progress:
                                progress(done, rel)
                    proc.stdin.close()
                except BrokenPipeError:
                    pass
                err = proc.stderr.read().decode(errors="replace")
                code = proc.wait()
            if code != 0:
                raise SyncError("Copy to the Pi failed: %s" % err.strip()[-400:])

    def download(self, local_root, rels, progress=None):
        root = self.info()["root"]
        for batch in _batches(rels, 100):
            cmd = "cd %s && tar -cf - --null -T -" % _sh(root)
            with subprocess.Popen(["ssh", "-o", "BatchMode=yes", self.host, cmd],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
                proc.stdin.write(b"\0".join(r.encode() for r in batch) + b"\0")
                proc.stdin.close()
                _extract(proc.stdout, local_root, progress)
                err = proc.stderr.read().decode(errors="replace")
                code = proc.wait()
            if code != 0:
                raise SyncError("Copy from the Pi failed: %s" % err.strip()[-400:])

    def scan(self):
        return self._ssh("sudo -n mirrorctl music scan 2>&1 | tail -n 2").decode(errors="replace").strip()


class LocalRemote:
    """A folder standing in for the Pi (tests, or the Pi's music share mounted as a drive)."""

    def __init__(self, root, trash=None):
        self.root = os.path.abspath(root)
        self.trash = os.path.abspath(trash or self.root.rstrip("/\\") + "-trash")

    def _run(self, mode, stdin=None):
        import io
        import sys
        from contextlib import redirect_stdout
        argv, stdin_old = sys.argv, sys.stdin
        sys.argv = ["remote", mode, self.root, ",".join(sorted(SYNCED))]
        sys.stdin = io.StringIO(stdin or "")
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                code = REMOTE_PY.replace('music.get("trashFolder")', repr(self.trash))
                exec(compile(code, "remote", "exec"), {"__name__": "__main__"})
        finally:
            sys.argv, sys.stdin = argv, stdin_old
        return json.loads(buf.getvalue())

    def info(self):
        return self._run("info")

    def listing(self):
        return {k.replace(os.sep, "/"): v for k, v in self._run("list").items()}

    def apply_ops(self, ops):
        return self._run("ops", json.dumps(ops))

    def upload(self, local_root, rels, progress=None):
        import shutil
        for i, rel in enumerate(rels, 1):
            dst = os.path.join(self.root, *rel.split("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(local_root, *rel.split("/")), dst)
            if progress:
                progress(i, rel)

    def download(self, local_root, rels, progress=None):
        import shutil
        for i, rel in enumerate(rels, 1):
            dst = os.path.join(local_root, *rel.split("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(self.root, *rel.split("/")), dst)
            if progress:
                progress(i, rel)

    def scan(self):
        return "(no scan for a local folder)"


def _sh(text):
    return "'" + str(text).replace("'", "'\\''") + "'"


def _plain(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mode = 0o664 if info.isfile() else 0o2775
    return info


def _batches(items, n):
    for i in range(0, len(items), n):
        yield items[i:i + n]


def _extract(stream, local_root, progress=None):
    """Untars a stream into local_root, refusing anything outside it."""
    root = os.path.realpath(local_root)
    n = 0
    with tarfile.open(fileobj=stream, mode="r|") as tar:
        for m in tar:
            rel = clean_rel(m.name)
            if not m.isfile() or rel is None:
                continue
            dst = os.path.realpath(os.path.join(root, *rel.split("/")))
            if not dst.startswith(root + os.sep):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            src = tar.extractfile(m)
            tmp = dst + ".part"
            with open(tmp, "wb") as f:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.replace(tmp, dst)
            os.utime(dst, (m.mtime, m.mtime))
            n += 1
            if progress:
                progress(n, rel)


# ---------------------------------------------------------------------- plan + run
def local_files(lib):
    out = {}
    for rel, full in lib.walk(SYNCED):
        try:
            st = os.stat(full)
        except OSError:
            continue
        out[rel] = [st.st_size, int(st.st_mtime)]
    return out


def simulate(remote_files, ops):
    """The Pi's file list after the journal's moves and deletes."""
    files = dict(remote_files)
    for op in ops:
        if op["kind"] == "delete":
            files.pop(op["src"], None)
        elif op["kind"] == "move" and op["src"] in files and op["dst"] not in files:
            files[op["dst"]] = files.pop(op["src"])
    return files


def plan(lib, remote):
    info = remote.info()
    ops = lib.pending_ops()
    there = simulate(remote.listing(), ops)
    here = local_files(lib)
    upload = sorted(rel for rel, (size, mtime) in here.items()
                    if rel not in there or there[rel][0] != size or mtime > there[rel][1] + 2)
    only_there = sorted(rel for rel in there if rel not in here)
    return {
        "root": info.get("root"),
        "ops": [{"id": o["id"], "kind": o["kind"], "src": o["src"], "dst": o["dst"]} for o in ops],
        "upload": upload,
        "uploadBytes": sum(here[r][0] for r in upload),
        "remoteOnly": only_there,
        "remoteOnlyBytes": sum(there[r][0] for r in only_there),
        "local": len(here),
        "remote": len(there),
    }


def run(lib, remote, pull=(), trash_remote=(), scan=False, job=None):
    """Applies a sync: journal → Pi, copy up, pull/trash the chosen Pi-only files, scan."""
    def say(frac, msg):
        if job:
            job.update(frac, msg)

    report = {"ops": {}, "uploaded": 0, "pulled": 0, "trashed": 0, "scan": None}
    ops = lib.pending_ops()
    if ops:
        say(0.02, "Moving and deleting on the Pi (%d changes)" % len(ops))
        results = remote.apply_ops([{"id": o["id"], "kind": o["kind"], "src": o["src"], "dst": o["dst"]} for o in ops])
        done = [i for i, r in results if not str(r).startswith(("error", "target exists"))]
        lib.mark_synced(done)
        for _, r in results:
            report["ops"][r] = report["ops"].get(r, 0) + 1
            if job and (str(r).startswith("error") or r == "target exists"):
                job.log("Pi: %s" % r)
    p = plan(lib, remote)
    todo = p["upload"]
    if todo:
        total = len(todo)
        remote.upload(lib.root, todo, lambda n, rel: say(0.05 + 0.75 * n / total, "Copying %d of %d · %s" % (n, total, rel)))
        report["uploaded"] = total
    pull = [r for r in pull if r in p["remoteOnly"]]
    if pull:
        total = len(pull)
        remote.download(lib.root, pull, lambda n, rel: say(0.8 + 0.1 * n / total, "Getting %d of %d · %s" % (n, total, rel)))
        report["pulled"] = total
        lib.scan()
    trash = [r for r in trash_remote if r in p["remoteOnly"] and r not in pull]
    if trash:
        say(0.92, "Moving %d files to the Pi's trash" % len(trash))
        res = remote.apply_ops([{"id": i, "kind": "delete", "src": r, "dst": ""} for i, r in enumerate(trash)])
        report["trashed"] = sum(1 for _, r in res if r == "trashed")
    if scan:
        say(0.96, "Navidrome is scanning")
        report["scan"] = remote.scan()
    say(1.0, "Done")
    report["at"] = time.time()
    return report
