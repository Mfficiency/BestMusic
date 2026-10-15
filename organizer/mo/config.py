"""Settings, kept in organizer/local/config.json (git ignores local/)."""
import json
import os
import threading

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LOCAL = os.path.join(HERE, "local")

DEFAULTS = {
    "musicFolder": "",          # the library on this computer
    "piHost": "hally",          # SSH host of the music server Pi (as in ~/.ssh/config)
    "piMusicFolder": "",        # '' = ask the Pi (mirror.json music.folder, else /srv/music)
    "piScanAfterSync": False,   # 'sudo mirrorctl music scan' after a sync
    "pattern": "{artist}/{title}",  # where downloads and "Group into folders" put songs
    "downloadFormat": "mp3",    # mp3 (re-encoded, plays everywhere) or m4a (YouTube's own audio)
    "anthropicApiKey": "",      # for "Ask for a list"; ANTHROPIC_API_KEY works too
    "port": 8770,
}
SECRET = {"anthropicApiKey"}


class Config:
    def __init__(self, local_dir=None):
        self.local = os.path.abspath(local_dir or DEFAULT_LOCAL)
        os.makedirs(self.local, exist_ok=True)
        self.path = os.path.join(self.local, "config.json")
        self.lock = threading.Lock()
        self.data = dict(DEFAULTS)
        try:
            with open(self.path, encoding="utf-8") as f:
                saved = json.load(f)
            self.data.update({k: v for k, v in saved.items() if k in DEFAULTS})
        except (OSError, ValueError):
            pass

    def __getitem__(self, key):
        return self.data.get(key, DEFAULTS.get(key))

    def update(self, values):
        with self.lock:
            for k, v in values.items():
                if k not in DEFAULTS:
                    continue
                if k in SECRET and v == "********":
                    continue  # the masked value the page shows: unchanged
                if isinstance(DEFAULTS[k], bool):
                    v = bool(v)
                elif isinstance(DEFAULTS[k], int):
                    v = int(v)
                else:
                    v = str(v).strip()
                self.data[k] = v
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2)
            os.replace(tmp, self.path)

    def public(self):
        out = dict(self.data)
        for k in SECRET:
            out[k] = "********" if out.get(k) else ""
        return out

    @property
    def music(self):
        return os.path.abspath(self.data["musicFolder"]) if self.data["musicFolder"] else ""
