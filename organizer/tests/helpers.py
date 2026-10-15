import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mo.config import Config  # noqa: E402
from mo.library import Library  # noqa: E402

HAVE_FFMPEG = shutil.which("ffmpeg") is not None
_TEMPLATE = {}


def make_mp3(path, seconds=1):
    """A real, short MP3 (ffmpeg), so mutagen can read and write its tags."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    key = seconds
    if key not in _TEMPLATE:
        tmp = os.path.join(tempfile.mkdtemp(prefix="bmo-tpl-"), "t.mp3")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=%s" % seconds,
                        "-q:a", "9", tmp], check=True)
        _TEMPLATE[key] = tmp
    shutil.copyfile(_TEMPLATE[key], path)
    return path


class LibCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bmo-test-")
        self.music = os.path.join(self.tmp, "music")
        os.makedirs(self.music)
        self.cfg = Config(os.path.join(self.tmp, "local"))
        self.cfg.update({"musicFolder": self.music})
        self.lib = Library(self.cfg)

    def tearDown(self):
        self.lib.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def song(self, rel, **tags):
        from mo.library import write_tags
        full = make_mp3(os.path.join(self.music, *rel.split("/")))
        if tags:
            write_tags(full, tags)
        return full
