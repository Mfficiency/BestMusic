import os
import unittest

from helpers import HAVE_FFMPEG, LibCase, make_mp3
from mo import downloader
from mo.library import read_tags


class FakeYDL:
    """Stands in for yt_dlp.YoutubeDL: 'downloads' a short MP3 into the output folder."""
    seen = []

    def __init__(self, opts):
        self.opts = opts

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def extract_info(self, target, download=True):
        FakeYDL.seen.append(target)
        if "fail" in target:
            raise RuntimeError("no video")
        out = self.opts["outtmpl"].replace("%(id)s", "vid1").replace("%(ext)s", "mp3")
        make_mp3(out)
        return {"entries": [{"id": "vid1", "title": "Stromae - Papaoutai (Official Video)", "channel": "StromaeVEVO"}]}


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg to make test MP3s")
class Downloads(LibCase):
    def test_queue_tags_files_and_fills_the_playlist(self):
        FakeYDL.seen = []
        res = downloader.run_queue(self.lib, [
            {"artist": "Angèle", "title": "Balance ton quoi"},
            {"url": "https://youtu.be/xyz"},
            {"artist": "fail", "title": "fail"},
        ], "{artist}/{title}", "mp3", playlist="New", ydl_factory=FakeYDL)
        self.assertEqual(res["downloaded"], ["Angèle/Balance ton quoi.mp3", "Stromae/Papaoutai.mp3"])
        self.assertEqual(len(res["failed"]), 1)
        self.assertEqual(FakeYDL.seen[0], "ytsearch1:Angèle - Balance ton quoi audio")
        self.assertEqual(FakeYDL.seen[1], "https://youtu.be/xyz")
        tags = read_tags(os.path.join(self.music, "Stromae", "Papaoutai.mp3"))
        self.assertEqual((tags["artist"], tags["title"]), ("Stromae", "Papaoutai"))
        pl = self.lib.playlists()[0]
        self.assertEqual((pl["name"], len(pl["tracks"])), ("New", 2))
        self.assertIsNotNone(self.lib.track("Angèle/Balance ton quoi.mp3"))

    def test_options(self):
        self.assertEqual(downloader.ydl_options("m4a", "/x")["postprocessors"][0]["preferredcodec"], "m4a")
        self.assertEqual(downloader.ydl_options("mp3", "/x")["postprocessors"][0]["preferredcodec"], "mp3")


if __name__ == "__main__":
    unittest.main()
