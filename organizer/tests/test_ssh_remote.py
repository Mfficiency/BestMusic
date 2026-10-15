"""SSHRemote end to end, with a stand-in `ssh` that runs the command on this machine: covers
the base64-wrapped remote script, the tar copy up and down, and the shell quoting."""
import os
import shutil
import stat
import sys
import unittest

from helpers import HAVE_FFMPEG, LibCase, make_mp3
from mo import pisync

FAKE_SSH = """#!/bin/sh
# fake ssh: drop options and the host, run the command here
while [ $# -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift  # host
exec sh -c "$*"
"""


@unittest.skipUnless(HAVE_FFMPEG and shutil.which("tar") and sys.platform != "win32", "needs sh, tar, ffmpeg")
class SSHRemoteTest(LibCase):
    def setUp(self):
        super().setUp()
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        ssh = os.path.join(bin_dir, "ssh")
        with open(ssh, "w") as f:
            f.write(FAKE_SSH)
        os.chmod(ssh, os.stat(ssh).st_mode | stat.S_IEXEC)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + os.pathsep + self.old_path
        self.pi = os.path.join(self.tmp, "pi music")  # a space, to test quoting
        os.makedirs(self.pi)
        self.remote = pisync.SSHRemote("hally", self.pi)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        super().tearDown()

    def test_full_round_trip(self):
        self.song("Stromae/Santé.mp3", artist="Stromae", title="Santé")
        self.song("It's/a.mp3")
        self.lib.scan()
        self.assertEqual(self.remote.info()["root"], os.path.abspath(self.pi))
        r = pisync.run(self.lib, self.remote)
        self.assertEqual(r["uploaded"], 2)
        self.assertTrue(os.path.isfile(os.path.join(self.pi, "Stromae", "Santé.mp3")))
        self.lib.move("It's/a.mp3", "Other/a.mp3")
        r = pisync.run(self.lib, self.remote)
        self.assertEqual((r["ops"], r["uploaded"]), ({"moved": 1}, 0))
        self.assertTrue(os.path.isfile(os.path.join(self.pi, "Other", "a.mp3")))
        make_mp3(os.path.join(self.pi, "Phone", "x.mp3"))
        r = pisync.run(self.lib, self.remote, pull=["Phone/x.mp3"])
        self.assertEqual(r["pulled"], 1)
        self.assertTrue(os.path.isfile(os.path.join(self.music, "Phone", "x.mp3")))
        self.assertEqual(pisync.plan(self.lib, self.remote)["upload"], [])


if __name__ == "__main__":
    unittest.main()
