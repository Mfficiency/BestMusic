import json
import threading
import time
import unittest
import urllib.error
import urllib.request

from helpers import HAVE_FFMPEG, LibCase
from mo.server import serve


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg to make test MP3s")
class Server(LibCase):
    def setUp(self):
        super().setUp()
        self.httpd = serve(self.cfg, 0)
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.httpd.RequestHandlerClass.app.lib.db.close()
        super().tearDown()

    def call(self, path, body=None, header=True):
        req = urllib.request.Request(self.base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", **({"X-Organizer": "1"} if header else {})})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r) if "json" in r.headers.get("Content-Type", "") else r.read()

    def wait(self, job):
        for _ in range(100):
            if job["status"] != "running":
                return job
            time.sleep(0.05)
            job = self.call("/api/job?id=%d" % job["id"])
        self.fail("job did not finish")

    def test_page_scan_tags_and_csrf_guard(self):
        self.assertIn(b"Music Organizer", self.call("/"))
        self.song("a.mp3", artist="x", title="Song (Official Video)")
        job = self.wait(self.call("/api/scan", {}))
        self.assertEqual(job["result"]["files"], 1)
        tracks = self.call("/api/tracks")
        self.assertEqual(len(tracks["rows"]), 1)
        clean = self.call("/api/cleanup")
        self.assertEqual(clean[0]["changes"]["title"], "Song")
        self.wait(self.call("/api/tags", {"paths": ["a.mp3"], "fields": {"genre": "Pop"}}))
        rows = self.call("/api/tracks")
        genre = rows["rows"][0][rows["fields"].index("genre")]
        self.assertEqual(genre, "Pop")
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.call("/api/config", {"port": 1}, header=False)
        self.assertEqual(e.exception.code, 403)

    def test_audio_supports_ranges(self):
        self.song("a.mp3")
        req = urllib.request.Request(self.base + "/api/audio?path=a.mp3", headers={"Range": "bytes=0-9"})
        with urllib.request.urlopen(req) as r:
            self.assertEqual(r.status, 206)
            self.assertEqual(len(r.read()), 10)

    def test_secret_is_masked(self):
        self.call("/api/config", {"anthropicApiKey": "sk-ant-secret"})
        st = self.call("/api/state")
        self.assertEqual(st["config"]["anthropicApiKey"], "********")
        self.call("/api/config", {"anthropicApiKey": "********"})  # saving the page again keeps it
        self.assertEqual(self.cfg["anthropicApiKey"], "sk-ant-secret")


if __name__ == "__main__":
    unittest.main()
