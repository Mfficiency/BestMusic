#!/usr/bin/env python3
"""Best Music Organizer: organize the music on this computer and sync it to the music server Pi.

  python organizer/organizer.py [--port 8770] [--no-browser] [--local <settings folder>]

Opens http://127.0.0.1:8770 in the browser. Settings, the song index and the organizer's own
trash live in organizer/local/ (not in git).
"""
import argparse
import os
import sys
import threading
import webbrowser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mo.config import Config  # noqa: E402
from mo.server import serve  # noqa: E402


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--port", type=int)
    p.add_argument("--no-browser", action="store_true")
    p.add_argument("--local", help="folder for settings and the index (default organizer/local)")
    args = p.parse_args()
    cfg = Config(args.local)
    httpd = serve(cfg, args.port)
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]
    print("Best Music Organizer on %s  (Ctrl+C to stop)" % url, flush=True)
    app = httpd.RequestHandlerClass.app
    if cfg.music and os.path.isdir(cfg.music):
        app.start_scan()
    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
