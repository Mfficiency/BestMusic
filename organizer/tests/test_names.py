import unittest

import helpers  # noqa: F401
from mo import names


class Names(unittest.TestCase):
    def test_clean_title(self):
        self.assertEqual(names.clean_title("Papaoutai (Official Music Video)"), "Papaoutai")
        self.assertEqual(names.clean_title("Song [Lyrics] [HD]"), "Song")
        self.assertEqual(names.clean_title("Song (Live at Wembley)"), "Song (Live at Wembley)")
        self.assertEqual(names.clean_title("03 - Alors on danse"), "Alors on danse")
        self.assertEqual(names.clean_title("Balance ton quoi ft. Someone"), "Balance ton quoi feat. Someone")
        self.assertEqual(names.clean_title("SANTÉ"), "Santé")
        self.assertEqual(names.clean_title("my_song_title"), "My Song Title")
        self.assertEqual(names.clean_title("1999"), "1999")  # a title that is a number stays

    def test_clean_artist(self):
        self.assertEqual(names.clean_artist("Stromae - Topic"), "Stromae")
        self.assertEqual(names.clean_artist("AdeleVEVO"), "Adele")
        self.assertEqual(names.clean_artist("Bea"), "Bea")

    def test_split(self):
        self.assertEqual(names.split_artist_title("Angèle - Balance ton quoi (Official Video)"), ("Angèle", "Balance ton quoi"))
        self.assertEqual(names.split_artist_title("Just a title", "Chan"), ("Chan", "Just a title"))

    def test_proposal(self):
        ch, why = names.proposal({"artist": "", "title": "Stromae - Papaoutai (Official Video)"})
        self.assertEqual(ch, {"artist": "Stromae", "title": "Papaoutai"})
        self.assertIn("artist from title", why)
        ch, _ = names.proposal({"artist": "Stromae", "title": "Stromae - Santé"})
        self.assertEqual(ch, {"title": "Santé"})
        self.assertEqual(names.proposal({"artist": "Stromae", "title": "Santé"})[0], {})
        # Underscored file names split too.
        ch, _ = names.proposal({"artist": "", "title": "", "stem": "kygo_-_stole_the_show"})
        self.assertEqual(ch, {"artist": "Kygo", "title": "Stole the Show"})

    def test_song_key(self):
        a = names.song_key("Beyoncé", "Halo (Official Video)")
        self.assertEqual(a, names.song_key("beyonce", "HALO"))
        self.assertEqual(names.song_key("A & B", "X (feat. C)"), names.song_key("A and B", "X"))
        self.assertEqual(names.song_key("A", ""), "")

    def test_format_pattern(self):
        t = {"artist": "AC/DC", "title": "Back: In Black?", "album": "", "genre": "Rock", "year": 1980, "track": 1}
        self.assertEqual(names.format_pattern("{artist}/{title}", t), "AC DC/Back In Black")
        self.assertEqual(names.format_pattern("{genre}/{artist}/{album}/{track} {title}", t),
                         "Rock/AC DC/Unknown Album/01 Back In Black")
        self.assertEqual(names.format_pattern("{first}/{artist}", {"artist": "50 Cent"}), "#/50 Cent")
        self.assertEqual(names.safe_part("CON", "x"), "x")  # Windows reserved name
        self.assertEqual(names.safe_part("dots...", "x"), "dots")


if __name__ == "__main__":
    unittest.main()
