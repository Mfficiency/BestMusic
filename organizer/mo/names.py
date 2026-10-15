"""Song names: cleaning up titles/artists, matching songs, and file names from a pattern.

The title rules match the phone app's (lib/services/track_title.dart): an annotation in
(...) or [...] is dropped only when every word in it is promotional ("(Official Video)",
"[Lyrics]", "(HD)"); "(Live at Wembley)" or "(feat. Someone)" stay.
"""
import re
import unicodedata

JUNK_WORDS = {
    "official", "video", "audio", "lyric", "lyrics", "music", "mv", "visualizer",
    "visualiser", "original", "mix", "edit", "version", "remaster", "remastered",
    "explicit", "clean", "full", "only", "hd", "hq", "4k", "oficial", "clip", "stereo",
    "mono", "high", "quality", "topic",
}

_ANNOTATION = re.compile(r"\(([^()]*)\)|\[([^\[\]]*)\]")
_SPLIT = re.compile(r"^(.+?)\s+[-–—]\s+(.+)$")
_TOPIC = re.compile(r"\s*-\s*Topic$", re.I)
_VEVO = re.compile(r"\s*VEVO$", re.I)
_TRACK_NO = re.compile(r"^\s*(?:\d{1,3}\s*[-._)]\s*|\d{1,3}\s+(?=\D))")
_FEAT = re.compile(r"\b(?:ft\.?|feat\.?|featuring)\s+", re.I)


def _junk(inner):
    words = [w for w in re.sub(r"[^a-z0-9]+", " ", inner.lower()).split() if w]
    return not words or all(w in JUNK_WORDS for w in words)


def strip_junk(text):
    out = _ANNOTATION.sub(lambda m: "" if _junk(m.group(1) or m.group(2) or "") else m.group(0), text)
    out = re.sub(r"\s+", " ", out).strip()
    return re.sub(r"[\s\-–—|:]+$", "", out).strip()


def _smart_case(text):
    """ALL CAPS or all lower case (longer than a word) becomes Title Case."""
    letters = [c for c in text if c.isalpha()]
    if len(letters) < 4 or not (text.isupper() or text.islower()):
        return text
    small = {"a", "an", "the", "and", "or", "of", "in", "on", "to", "at", "by", "for", "de", "van", "la", "le"}
    words = text.lower().split(" ")
    return " ".join(w if (i and w in small) else w[:1].upper() + w[1:] for i, w in enumerate(words))


def clean_artist(artist):
    a = _TOPIC.sub("", artist or "")
    if len(a) > 6:
        a = _VEVO.sub("", a)
    a = strip_junk(a.replace("_", " "))
    return _smart_case(re.sub(r"\s+", " ", a).strip())


def clean_title(title):
    t = (title or "").replace("_", " ")
    t = _TRACK_NO.sub("", t) if re.search(r"[A-Za-z]", _TRACK_NO.sub("", t)) else t
    t = strip_junk(t)
    t = _FEAT.sub("feat. ", t)
    t = re.sub(r"\(\s*feat\. ", "(feat. ", t)
    t = t.split(" | ")[0].strip()
    return _smart_case(re.sub(r"\s+", " ", t).strip()) or (title or "").strip()


def split_artist_title(text, fallback_artist=""):
    """'Artist - Title' -> (artist, title); otherwise (fallback_artist, text)."""
    t = strip_junk(text or "") or (text or "").strip()
    m = _SPLIT.match(t)
    if m and m.group(1).strip() and m.group(2).strip():
        return m.group(1).strip(), m.group(2).strip()
    return fallback_artist, t


def proposal(track):
    """What clean-up would change in a track: {field: new value}, plus a reason list."""
    artist, title = track.get("artist") or "", track.get("title") or ""
    reasons = []
    if not title:
        title = track.get("stem") or ""
        reasons.append("title from file name")
    if not artist or artist.lower() in ("unknown", "unknown artist"):
        a, t = split_artist_title(title)
        if a:
            artist, title = a, t
            reasons.append("artist from title")
    elif " - " in title:
        a, t = split_artist_title(title)
        if a and norm(a) == norm(artist):
            title = t
            reasons.append("artist repeated in title")
    new_artist, new_title = clean_artist(artist), clean_title(title)
    if new_artist != artist or new_title != title:
        reasons.append("tidied")
    changes = {}
    if new_title and new_title != (track.get("title") or ""):
        changes["title"] = new_title
    if new_artist and new_artist != (track.get("artist") or ""):
        changes["artist"] = new_artist
    return changes, reasons


def norm(text):
    """Comparable form: no accents, case, punctuation or 'feat.' part."""
    t = unicodedata.normalize("NFKD", text or "")
    t = "".join(c for c in t if not unicodedata.combining(c)).lower()
    t = re.sub(r"[(\[]\s*(?:feat|ft|featuring)\b[^)\]]*[)\]]", " ", t)
    t = re.sub(r"\s(?:feat|ft|featuring)\.?\s.*$", " ", t)
    t = t.replace("&", " and ")
    return re.sub(r"[^a-z0-9]+", "", t)


def song_key(artist, title):
    """Same song, whatever the spelling: normalised artist + title ('' without a title)."""
    t = norm(clean_title(title))
    if not t:
        return ""
    return norm(clean_artist(artist)) + "|" + t


# --------------------------------------------------------------------- file names
_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_RESERVED = {"con", "prn", "aux", "nul"} | {"com%d" % i for i in range(1, 10)} | {"lpt%d" % i for i in range(1, 10)}

PATTERN_FIELDS = ("artist", "albumartist", "title", "album", "genre", "year", "track", "first")

PRESETS = {
    "{artist}/{title}": "Artist / Title",
    "{artist}/{album}/{track} {title}": "Artist / Album / 01 Title",
    "{genre}/{artist}/{title}": "Genre / Artist / Title",
    "{first}/{artist}/{title}": "A-Z / Artist / Title",
    "{artist} - {title}": "Artist - Title (one folder)",
}


def safe_part(text, fallback):
    t = _BAD.sub(" ", (text or "").strip())
    t = re.sub(r"\s+", " ", t).strip().rstrip(". ")
    if not t or t.lower().split(".")[0] in _RESERVED:
        t = fallback
    return t[:120].rstrip(". ") or fallback


def format_pattern(pattern, track):
    """Relative path (no extension) for a track from a pattern like '{artist}/{title}'."""
    artist = track.get("albumartist") or track.get("artist") or ""
    values = {
        "artist": safe_part(track.get("artist") or artist, "Unknown Artist"),
        "albumartist": safe_part(artist, "Unknown Artist"),
        "title": safe_part(track.get("title") or track.get("stem"), "Unknown Title"),
        "album": safe_part(track.get("album"), "Unknown Album"),
        "genre": safe_part(track.get("genre"), "Unknown Genre"),
        "year": safe_part(str(track.get("year") or ""), "Unknown Year"),
        "track": "%02d" % track["track"] if track.get("track") else "",
    }
    first = values["albumartist"][:1].upper()
    values["first"] = first if first.isalpha() else "#"
    parts = []
    for raw in (pattern or "{artist}/{title}").replace("\\", "/").split("/"):
        part = re.sub(r"\{(\w+)\}", lambda m: values.get(m.group(1), m.group(0)), raw)
        part = safe_part(part, "")
        if part:
            parts.append(part)
    return "/".join(parts) or values["title"]
