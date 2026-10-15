import os
import unittest

from helpers import HAVE_FFMPEG, LibCase
from mo.library import LibraryError, clean_rel, read_tags


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg to make test MP3s")
class Library(LibCase):
    def test_scan_reads_tags_and_notices_changes(self):
        self.song("Chill/a.mp3", artist="Kygo", title="Stole the Show", genre="House", year="2015")
        self.song("b.mp3")
        r = self.lib.scan()
        self.assertEqual((r["files"], r["read"]), (2, 2))
        t = self.lib.track("Chill/a.mp3")
        self.assertEqual((t["artist"], t["title"], t["genre"], t["year"]), ("Kygo", "Stole the Show", "House", 2015))
        self.assertEqual(self.lib.scan()["read"], 0)  # nothing changed: nothing read again
        os.remove(os.path.join(self.music, "b.mp3"))
        self.assertEqual(self.lib.scan()["gone"], 1)

    def test_retag_writes_the_file(self):
        full = self.song("a.mp3", artist="x")
        self.lib.scan()
        self.lib.retag("a.mp3", {"artist": "Angèle", "genre": "Pop", "year": "2018"})
        self.assertEqual(read_tags(full)["artist"], "Angèle")
        self.assertEqual(self.lib.track("a.mp3")["genre"], "Pop")
        self.lib.retag("a.mp3", {"genre": ""})
        self.assertEqual(read_tags(full)["genre"], "")

    def test_move_journals_and_rewrites_playlists(self):
        self.song("Old/a.mp3", title="A")
        self.song("Old/b.mp3", title="B")
        self.lib.scan()
        self.lib.save_playlist("Mix", ["Old/b.mp3", "Old/a.mp3"])
        new = self.lib.move("Old/a.mp3", "New/Artist/A")
        self.assertEqual(new, "New/Artist/A.mp3")
        self.assertTrue(os.path.isfile(os.path.join(self.music, "New", "Artist", "A.mp3")))
        self.assertIsNone(self.lib.track("Old/a.mp3"))
        pl = self.lib.playlists()[0]
        self.assertEqual(pl["name"], "Mix")
        self.assertEqual(pl["tracks"], ["Old/b.mp3", "New/Artist/A.mp3"])  # order kept
        with open(os.path.join(self.music, "Playlists", "Mix.m3u8"), encoding="utf-8") as f:
            self.assertIn("../New/Artist/A.mp3", f.read())  # relative, for Navidrome
        self.assertEqual([(o["kind"], o["src"], o["dst"]) for o in self.lib.pending_ops()],
                         [("move", "Old/a.mp3", "New/Artist/A.mp3")])

    def test_move_never_overwrites(self):
        self.song("a.mp3")
        self.song("X/a.mp3")
        self.lib.scan()
        self.assertEqual(self.lib.move("a.mp3", "X/a.mp3"), "X/a (2).mp3")
        self.assertFalse(os.path.exists(os.path.join(self.music, "a.mp3")))

    def test_delete_goes_to_trash(self):
        self.song("Sub/a.mp3")
        self.lib.scan()
        self.lib.save_playlist("P", ["Sub/a.mp3"])
        self.lib.delete("Sub/a.mp3")
        self.assertFalse(os.path.exists(os.path.join(self.music, "Sub")))  # emptied folder removed
        trash = os.path.join(self.cfg.local, "trash")
        self.assertTrue(any(f == "a.mp3" for _, _, fs in os.walk(trash) for f in fs))
        self.assertEqual(self.lib.playlists()[0]["tracks"], [])
        self.assertEqual(self.lib.pending_ops()[-1]["kind"], "delete")

    def test_paths_stay_inside(self):
        self.assertIsNone(clean_rel("../x.mp3"))
        self.assertIsNone(clean_rel(".hidden/x.mp3"))
        self.assertIsNone(clean_rel("C:/x.mp3"))
        self.assertEqual(clean_rel("a\\b/./c.mp3"), "a/b/c.mp3")
        with self.assertRaises(LibraryError):
            self.lib.full("../../etc/passwd")


if __name__ == "__main__":
    unittest.main()
