"""Where download lists come from. Each source returns candidates:
{"artist", "title", "url" (optional, a YouTube link), "note" (optional)}.

- pasted lists ("Artist - Title" lines, YouTube links, numbered lists),
- YouTube search (yt-dlp, no download),
- an artist's top songs and a country's current chart (Deezer's public API, no account),
- a free prompt ("top 10 Belgian charts this year") answered by Claude with web search.
"""
import json
import os
import re
import urllib.parse
import urllib.request

from . import names

UA = {"User-Agent": "BestMusicOrganizer/1.0"}
YT_URL = re.compile(r"https?://(?:www\.|m\.|music\.)?(?:youtube\.com/\S+|youtu\.be/\S+)", re.I)

# Deezer's "Top <country>" chart playlists (made by the "Deezer Charts" account).
COUNTRIES = ["Belgium", "Netherlands", "France", "Germany", "United Kingdom", "USA", "Spain",
             "Italy", "Canada", "Australia", "Brazil", "Mexico", "Sweden", "Norway", "Denmark",
             "Poland", "Portugal", "Switzerland", "Austria", "Ireland", "Japan", "Worldwide"]


class SourceError(Exception):
    pass


def _get_json(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
    except Exception as e:
        raise SourceError("Could not reach %s: %s" % (urllib.parse.urlsplit(url).netloc, e))
    if isinstance(data, dict) and data.get("error"):
        raise SourceError("Deezer: %s" % data["error"].get("message", data["error"]))
    return data


# ---------------------------------------------------------------------- pasted text
def parse_list(text):
    """Lines of 'Artist - Title', 'Title by Artist', YouTube links; numbering is ignored."""
    out = []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        url = YT_URL.search(line)
        if url:
            out.append({"artist": "", "title": "", "url": url.group(0).rstrip(").,"), "note": "link"})
            continue
        line = re.sub(r"^\s*(?:\d{1,3}\s*[.)\-:]|[-*•])\s*", "", line)
        line = line.strip(" \"'“”")
        artist, title = names.split_artist_title(line)
        if not artist:
            m = re.match(r"^(.+?)\s+(?:by|van|de)\s+(.+)$", line, re.I)
            if m:
                title, artist = m.group(1).strip(" \"'“”"), m.group(2).strip()
        if title:
            out.append({"artist": artist, "title": title})
    return out


# ---------------------------------------------------------------------- YouTube search
def youtube_search(query, n=15):
    try:
        import yt_dlp
    except ImportError:
        raise SourceError("yt-dlp is not installed (pip install -r organizer/requirements.txt)")
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info("ytsearch%d:%s" % (n, query), download=False)
    out = []
    for e in (info or {}).get("entries") or []:
        url = e.get("url") or ("https://www.youtube.com/watch?v=%s" % e.get("id"))
        artist, title = names.split_artist_title(e.get("title") or "", names.clean_artist(e.get("channel") or e.get("uploader") or ""))
        dur = e.get("duration")
        out.append({"artist": artist, "title": names.clean_title(title), "url": url,
                    "note": "%s · %s" % (e.get("channel") or "", "%d:%02d" % (dur // 60, dur % 60) if dur else ""),
                    "source": e.get("title") or ""})
    return out


# ---------------------------------------------------------------------- Deezer
def artist_top(artist, n=10):
    found = _get_json("https://api.deezer.com/search/artist?" + urllib.parse.urlencode({"q": artist, "limit": 5}))
    hits = found.get("data") or []
    if not hits:
        raise SourceError("No artist called %s on Deezer" % artist)
    best = next((h for h in hits if names.norm(h.get("name")) == names.norm(artist)), hits[0])
    top = _get_json("https://api.deezer.com/artist/%s/top?limit=%d" % (best["id"], max(1, min(100, n))))
    return [_deezer_track(t) for t in top.get("data") or []][:n]


def chart(country, n=50):
    """A country's current Top chart (Deezer Charts playlist); 'Worldwide' = the global one."""
    if country.lower() in ("worldwide", "world", "global"):
        data = _get_json("https://api.deezer.com/chart/0/tracks?limit=%d" % max(1, min(100, n)))
        return [_deezer_track(t) for t in data.get("data") or []][:n]
    playlist = find_chart_playlist(country)
    tracks = _get_json("https://api.deezer.com/playlist/%s/tracks?limit=%d" % (playlist["id"], max(1, min(100, n))))
    return [_deezer_track(t) for t in tracks.get("data") or []][:n]


# Local names Deezer may use in its chart playlist titles ("Top Belgique").
ALIASES = {
    "belgium": ["belgium", "belgique", "belgie", "belgië"], "netherlands": ["netherlands", "nederland"],
    "germany": ["germany", "deutschland"], "spain": ["spain", "espana", "españa"],
    "italy": ["italy", "italia"], "brazil": ["brazil", "brasil"], "mexico": ["mexico", "méxico"],
    "sweden": ["sweden", "sverige"], "norway": ["norway", "norge"], "denmark": ["denmark", "danmark"],
    "poland": ["poland", "polska"], "switzerland": ["switzerland", "schweiz", "suisse"],
    "austria": ["austria", "osterreich", "österreich"], "united kingdom": ["united kingdom", "uk"],
    "usa": ["usa", "united states", "us"],
}


def find_chart_playlist(country):
    words = ALIASES.get(country.lower(), [country])
    for word in words:
        found = _get_json("https://api.deezer.com/search/playlist?" + urllib.parse.urlencode({"q": "Top " + word, "limit": 25}))
        for p in found.get("data") or []:
            user = (p.get("user") or {}).get("name", "")
            title = names.norm(p.get("title"))
            if user.lower() != "deezer charts":
                continue
            if title.startswith("top") and any(names.norm(w) and names.norm(w) in title for w in words):
                return p
    raise SourceError("No Deezer chart found for %s - try the Ask tab ('top 50 %s right now')" % (country, country))


def _deezer_track(t):
    return {"artist": (t.get("artist") or {}).get("name", ""),
            "title": t.get("title_short") or t.get("title") or "",
            "note": (t.get("album") or {}).get("title", "")}


# ---------------------------------------------------------------------- Claude
MODEL = "claude-opus-5-5"
SONGS_TOOL = {
    "name": "submit_songs",
    "description": "Hand over the final list of songs, in order.",
    "strict": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "songs": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "artist": {"type": "string", "description": "Main artist as credited"},
                        "title": {"type": "string", "description": "Song title without (Official Video) etc."},
                        "note": {"type": "string", "description": "Short context: chart position, year, album"},
                    },
                    "required": ["artist", "title", "note"],
                    "additionalProperties": False,
                },
            },
            "summary": {"type": "string", "description": "One sentence on where the list comes from"},
        },
        "required": ["songs", "summary"],
        "additionalProperties": False,
    },
}
SYSTEM = (
    "You build song lists for a personal music library. The user describes the list they want "
    "(an artist's most-played songs, a country's chart of a given year, songs for a mood...). "
    "Use web search whenever the answer depends on charts, streaming numbers or anything recent, "
    "and prefer official chart sources (e.g. Ultratop for Belgium). Then call submit_songs once "
    "with the songs in order, using the artist and title as credited, no video annotations. "
    "If the user asks for N songs, give exactly N when that many exist."
)


def ask_claude(prompt, api_key=None, client=None):
    """Songs for a free-form prompt; returns (songs, summary)."""
    if client is None:
        try:
            import anthropic
        except ImportError:
            raise SourceError("The anthropic package is not installed (pip install -r organizer/requirements.txt)")
        key = api_key or os.environ.get("ANTHROPIC_API_KEY")
        client = anthropic.Anthropic(api_key=key) if key else anthropic.Anthropic()
    messages = [{"role": "user", "content": prompt}]
    for _ in range(6):  # pause_turn: the server-side search loop paused; send it back to resume
        response = client.messages.create(
            model=MODEL,
            max_tokens=16000,
            system=SYSTEM,
            output_config={"effort": "medium"},
            tools=[{"type": "web_search_20260209", "name": "web_search", "max_uses": 6}, SONGS_TOOL],
            messages=messages,
            # A false-positive safety decline is retried on Anthropic's recommended fallback.
            extra_headers={"anthropic-beta": "server-side-fallback-2026-07-01"},
            extra_body={"fallbacks": "default"},
        )
        if response.stop_reason == "refusal":
            raise SourceError("Claude declined this request; try wording it differently")
        call = next((b for b in response.content if b.type == "tool_use" and b.name == "submit_songs"), None)
        if call is not None:
            songs = call.input.get("songs") if isinstance(call.input, dict) else None
            if not isinstance(songs, list):
                raise SourceError("Claude's answer had no song list")
            return ([{"artist": str(s.get("artist", "")), "title": str(s.get("title", "")),
                      "note": str(s.get("note", ""))} for s in songs if isinstance(s, dict) and s.get("title")],
                    str(call.input.get("summary", "")))
        if response.stop_reason == "pause_turn":
            messages = [messages[0], {"role": "assistant", "content": response.content}]
            continue
        # Answered in text instead of with the tool: ask once more, keeping the turn.
        text = " ".join(b.text for b in response.content if b.type == "text").strip()
        found = parse_list(text)
        if found:
            return found, "From Claude's answer"
        messages = [messages[0], {"role": "assistant", "content": response.content},
                    {"role": "user", "content": "Please hand over the list with submit_songs."}]
    raise SourceError("Claude did not return a list; try again")
