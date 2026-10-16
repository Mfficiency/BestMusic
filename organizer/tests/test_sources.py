import os
import unittest
from types import SimpleNamespace as NS

import helpers  # noqa: F401
from mo import sources


class Paste(unittest.TestCase):
    def test_parse_list(self):
        text = """1. Stromae - Papaoutai
        2) Angèle – Balance ton quoi (Official Video)
        Alors on danse by Stromae
        https://www.youtube.com/watch?v=abc123
        # a comment
        """
        got = sources.parse_list(text)
        self.assertEqual(got[0], {"artist": "Stromae", "title": "Papaoutai"})
        self.assertEqual(got[1], {"artist": "Angèle", "title": "Balance ton quoi"})
        self.assertEqual(got[2], {"artist": "Stromae", "title": "Alors on danse"})
        self.assertEqual(got[3]["url"], "https://www.youtube.com/watch?v=abc123")
        self.assertEqual(len(got), 4)


class Deezer(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.orig = sources._get_json

        def fake(url, timeout=20):
            self.calls.append(url)
            if "search/artist" in url:
                return {"data": [{"id": 1, "name": "Stromae"}]}
            if "/artist/1/top" in url:
                return {"data": [{"title": "Papaoutai", "title_short": "Papaoutai", "artist": {"name": "Stromae"}, "album": {"title": "Racine carrée"}}]}
            if "search/playlist" in url:
                if "belgique" in url.lower():
                    return {"data": [{"id": 9, "title": "Top Belgique", "user": {"name": "Deezer Charts"}}]}
                return {"data": [{"id": 5, "title": "Top Belgium hits", "user": {"name": "someone"}}]}
            if "/playlist/9/tracks" in url:
                return {"data": [{"title": "Song", "artist": {"name": "Artist"}, "album": {}}]}
            raise AssertionError(url)
        sources._get_json = fake

    def tearDown(self):
        sources._get_json = self.orig

    def test_artist_top(self):
        got = sources.artist_top("stromae", 5)
        self.assertEqual(got, [{"artist": "Stromae", "title": "Papaoutai", "note": "Racine carrée"}])
        self.assertIn("limit=5", self.calls[1])

    def test_chart_finds_the_deezer_charts_playlist_by_local_name(self):
        got = sources.chart("Belgium", 10)
        self.assertEqual(got[0]["title"], "Song")
        self.assertTrue(any("/playlist/9/" in c for c in self.calls))


class Claude(unittest.TestCase):
    def test_pause_turn_then_tool_call(self):
        class Messages:
            def __init__(self):
                self.calls = []

            def create(self, **kw):
                self.calls.append(kw)
                if len(self.calls) == 1:
                    return NS(stop_reason="pause_turn", content=[NS(type="server_tool_use", name="web_search")])
                return NS(stop_reason="tool_use", content=[NS(type="tool_use", name="submit_songs", input={
                    "songs": [{"artist": "A", "title": "One", "note": "#1"}, {"artist": "B", "title": "", "note": ""}],
                    "summary": "Ultratop 2026"})])
        m = Messages()
        songs, summary = sources.ask_claude("top 2 Belgium 2026", client=NS(messages=m))
        self.assertEqual(songs, [{"artist": "A", "title": "One", "note": "#1"}])
        self.assertEqual(summary, "Ultratop 2026")
        first = m.calls[0]
        self.assertEqual(first["model"], "claude-opus-5-5")
        self.assertEqual(first["tools"][0]["type"], "web_search_20260209")
        self.assertEqual(first["extra_body"], {"fallbacks": "default"})
        self.assertEqual(m.calls[1]["messages"][1]["role"], "assistant")  # paused turn sent back

    def test_refusal(self):
        client = NS(messages=NS(create=lambda **kw: NS(stop_reason="refusal", content=[])))
        with self.assertRaises(sources.SourceError):
            sources.ask_claude("x", client=client)

    def test_no_api_key_says_where_to_put_it(self):
        old = os.environ.pop("ANTHROPIC_API_KEY", None)
        try:
            with self.assertRaisesRegex(sources.SourceError, "Settings"):
                sources.ask_claude("x", api_key="")
        finally:
            if old is not None:
                os.environ["ANTHROPIC_API_KEY"] = old


if __name__ == "__main__":
    unittest.main()
