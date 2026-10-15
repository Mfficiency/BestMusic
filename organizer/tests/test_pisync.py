import os
import shutil
import time
import unittest

from helpers import HAVE_FFMPEG, LibCase, make_mp3
from mo import pisync


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg to make test MP3s")
class PiSync(LibCase):
    def setUp(self):
        super().setUp()
        self.pi = os.path.join(self.tmp, "pi-music")
        os.makedirs(self.pi)
        self.remote = pisync.LocalRemote(self.pi)

    def pi_files(self):
        return sorted(os.path.relpath(os.path.join(d, f), self.pi).replace(os.sep, "/")
                      for d, _, fs in os.walk(self.pi) for f in fs)

    def test_first_sync_copies_everything(self):
        self.song("Kygo/Stay.mp3", artist="Kygo", title="Stay")
        self.lib.scan()
        self.lib.save_playlist("Chill", ["Kygo/Stay.mp3"])
        p = pisync.plan(self.lib, self.remote)
        self.assertEqual(p["upload"], ["Kygo/Stay.mp3", "Playlists/Chill.m3u8"])
        r = pisync.run(self.lib, self.remote)
        self.assertEqual(r["uploaded"], 2)
        self.assertEqual(self.pi_files(), ["Kygo/Stay.mp3", "Playlists/Chill.m3u8"])
        self.assertEqual(pisync.plan(self.lib, self.remote)["upload"], [])  # in sync now

    def test_moves_and_deletes_are_replayed_not_copied(self):
        self.song("Old/a.mp3", title="A")
        self.song("Old/b.mp3", title="B")
        self.lib.scan()
        pisync.run(self.lib, self.remote)
        self.lib.move("Old/a.mp3", "New/a.mp3")
        self.lib.delete("Old/b.mp3")
        p = pisync.plan(self.lib, self.remote)
        self.assertEqual(p["upload"], [])  # the move is replayed, nothing to copy
        self.assertEqual(len(p["ops"]), 2)
        r = pisync.run(self.lib, self.remote)
        self.assertEqual(r["ops"], {"moved": 1, "trashed": 1})
        self.assertEqual(self.pi_files(), ["New/a.mp3"])
        day_trash = os.path.join(self.remote.trash)
        self.assertTrue(any(f == "b.mp3" for _, _, fs in os.walk(day_trash) for f in fs))
        self.assertEqual(self.lib.pending_ops(), [])

    def test_edited_tags_are_copied_again(self):
        self.song("a.mp3", title="A")
        self.lib.scan()
        pisync.run(self.lib, self.remote)
        future = time.time() + 60
        self.lib.retag("a.mp3", {"genre": "Something much longer to change the size"})
        os.utime(os.path.join(self.music, "a.mp3"), (future, future))
        self.assertEqual(pisync.plan(self.lib, self.remote)["upload"], ["a.mp3"])

    def test_pi_only_files_can_be_pulled_or_trashed(self):
        make_mp3(os.path.join(self.pi, "Phone", "x.mp3"))
        make_mp3(os.path.join(self.pi, "Junk", "y.mp3"))
        self.lib.scan()
        p = pisync.plan(self.lib, self.remote)
        self.assertEqual(p["remoteOnly"], ["Junk/y.mp3", "Phone/x.mp3"])
        r = pisync.run(self.lib, self.remote, pull=["Phone/x.mp3"], trash_remote=["Junk/y.mp3"])
        self.assertEqual((r["pulled"], r["trashed"]), (1, 1))
        self.assertIsNotNone(self.lib.track("Phone/x.mp3"))  # in the library now
        self.assertEqual(self.pi_files(), ["Phone/x.mp3"])

    def test_remote_script_refuses_paths_outside(self):
        res = self.remote.apply_ops([{"id": 1, "kind": "delete", "src": "../../etc/passwd", "dst": ""}])
        self.assertTrue(res[0][1].startswith("error"))

    def tearDown(self):
        super().tearDown()
        shutil.rmtree(self.pi, ignore_errors=True)


class SSHCommand(unittest.TestCase):
    def test_quoting(self):
        self.assertEqual(pisync._sh("it's"), "'it'\\''s'")
        self.assertEqual(pisync._sh(""), "''")


if __name__ == "__main__":
    unittest.main()
