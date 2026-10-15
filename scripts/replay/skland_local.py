#!/usr/bin/env python3
"""A stand-in for 森空岛 and for the relay's need table, on this Mac's loopback, so the replay test can open the 库存 page
with numbers on it without anyone's 森空岛 session and without publishing a table.

  scripts/replay/skland_local.py serve        # run it in the foreground until Ctrl-C (port 8933)

run.py starts it by itself for the steps that turn it on (("skland", "on")). The app reaches it through two UserDefaults
keys it only takes on a loopback address (Net.swift loopbackOverride): `ark-skland-base` (Stamina.swift StaminaStore.zonai)
and `ark-need-url` (Inventory.swift InventoryStore.needURLKey): http://127.0.0.1:8933 from the iOS simulator,
http://10.0.2.2:8933 from the Android emulator (its alias of the host loopback).

What it answers:
  /need.json                                         Tests/Fixtures/need-1015.json, the table the relay built on
                                                     2026-10-15 16:05 (two standards: 祀 + 玉中身, then 明河 + 唤月)
  /web/v1/auth/refresh                               {"code": 0, "data": {"token": "replay"}}
  /web/v1/game/endfield/calculate/material-list      Tests/Fixtures/skland-material-list.json (森空岛's public catalogue)
  /web/v1/game/endfield/calculate/user-game-data     made-up counts (see counts()): NOT anyone's warehouse
  anything else                                      {"code": 10001, "message": "回放替身不答这一项"}
No signature is checked; nothing leaves the Mac.
"""
import http.server
import json
import os
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "..", "..", "Tests", "Fixtures")
PORT = 8933
IOS_BASE = f"http://127.0.0.1:{PORT}"       # the simulator shares the Mac's network stack
ANDROID_BASE = f"http://10.0.2.2:{PORT}"    # the emulator's alias of the host loopback


def base_for(platform):
    return ANDROID_BASE if platform == "android" else IOS_BASE


def _read(name):
    with open(os.path.join(FIXTURES, name), "rb") as f:
        return f.read()


def counts(table):
    """Made-up counts for every material any standard of the table names: a third twice the need, a third half of it
    (those read 「差 N」), the rest 1.2 times (the rule of StockpileStandardsTests.counts), plus two self-select boxes."""
    out, i = {}, 0
    game = table["games"][0]
    for s in game.get("standards") or []:
        for r in s.get("rows") or []:
            rid = r.get("id") or ""
            if rid.startswith("exp:") or rid in out:
                continue
            need = int(r.get("need") or 0)
            out[rid] = need * 2 if i % 3 == 0 else need // 2 if i % 3 == 1 else need + need // 5
            i += 1
    box = (game.get("box") or {}).get("id")
    if box:
        out[box] = 2
    return out


class Handler(http.server.BaseHTTPRequestHandler):
    need = b""
    mat = b""
    ugd = b""

    def log_message(self, *_):
        pass

    def _send(self, body, ctype="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/need.json":
            self._send(self.need)
        elif path == "/web/v1/auth/refresh":
            self._send(json.dumps({"code": 0, "message": "OK", "timestamp": str(int(time.time())),
                                   "data": {"token": "replay"}}).encode())
        elif path == "/web/v1/game/endfield/calculate/material-list":
            self._send(b'{"code":0,"message":"OK","data":' + self.mat + b"}")
        elif path == "/web/v1/game/endfield/calculate/user-game-data":
            self._send(self.ugd)
        elif path == "/health":
            self._send(b'{"ok":true}')
        else:
            self._send(json.dumps({"code": 10001, "message": "回放替身不答这一项"}, ensure_ascii=False).encode())


class LocalSkland:
    def __init__(self, port=PORT, log=print):
        self.port = port
        self.log = log
        self.server = None
        self.thread = None

    def running(self):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=1) as r:
                return r.status == 200
        except Exception:
            return False

    def start(self):
        if self.running():
            self.log(f"森空岛替身已在 127.0.0.1:{self.port}，沿用")
            return self
        table = json.loads(_read("need-1015.json"))
        Handler.need = _read("need-1015.json")
        Handler.mat = _read("skland-material-list.json")
        Handler.ugd = json.dumps({"code": 0, "message": "OK", "data": {"userGameData": {"itemCount": counts(table)}}}).encode()
        # 127.0.0.1 only: the Android emulator's 10.0.2.2 is this loopback
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.log(f"森空岛替身在 127.0.0.1:{self.port}（需求表 need-1015.json，库存是编的数）")
        return self

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        s = LocalSkland().start()
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            s.stop()
    else:
        print(__doc__)
