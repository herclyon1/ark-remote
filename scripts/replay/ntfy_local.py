#!/usr/bin/env python3
"""A local ntfy server for the replay test, so a run never meets ntfy.sh's anonymous daily quota (HTTP 429).

  scripts/replay/ntfy_local.py serve           # run it in the foreground until Ctrl-C (port 8932)
  scripts/replay/ntfy_local.py flood 300       # post 300 messages as fast as possible, count them back
  scripts/replay/ntfy_local.py build           # build the server binary (Homebrew's ntfy has no `serve`)

run.py starts it by itself (unless --ntfy-public). The app reaches it at http://127.0.0.1:8932 from the iOS simulator
and http://10.0.2.2:8932 from the Android emulator (the emulator's alias of the host loopback), through the app's
UserDefaults key `ark-ntfy-base` (Net.swift ntfyBase), which run.py writes.

The server is the real ntfy (v2.28.0 at the time of writing), not a look-alike. Homebrew's macOS bottle is built with the
`noserver` tag, so `build` compiles the same tag from source with the upstream Makefile target `cli-darwin-server`
(needs Go: `brew install go`) into ~/.local/bin/ntfy-server. `NTFY_SERVER=<path>` overrides the binary.

Limits (docs.ntfy.sh/config, "Rate limiting"; cmd/serve.go + server/server.go of v2.28.0): an unset
visitor-message-daily-limit is NOT unlimited, it is derived from visitor-request-limit-replenish. Loopback is listed
in visitor-request-limit-exempt-hosts, which skips both the request limiter and the daily message limiter
(server_middleware.go, server.go MessageAllowed); the daily limit and the request burst are raised as well in case a
request ever arrives from another address. The subscription limit (30 by default) and the topic-creation limiter are
not covered by the exemption, so they are raised / disabled.

The cache and the config live in a fresh temporary directory that is removed when the server stops. Only the PID this
module started is ever stopped; a server that was already listening on the port is reused and left alone.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PORT = 8932
VERSION_TAG = "v2.28.0"
DEFAULT_BIN = os.path.expanduser("~/.local/bin/ntfy-server")
IOS_BASE = f"http://127.0.0.1:{PORT}"       # the simulator shares the Mac's network stack
ANDROID_BASE = f"http://10.0.2.2:{PORT}"    # the emulator's alias of the host loopback

CONFIG = """\
listen-http: "127.0.0.1:{port}"
base-url: "http://127.0.0.1:{port}"
cache-file: "{dir}/cache.db"
cache-duration: "12h"
visitor-request-limit-exempt-hosts: "127.0.0.1,::1"
visitor-message-daily-limit: 100000000
visitor-request-limit-burst: 100000
visitor-request-limit-replenish: "1ms"
visitor-subscription-limit: 1000
visitor-topic-creation-limit-burst: 0
log-level: "warn"
"""


def binary():
    b = os.environ.get("NTFY_SERVER") or DEFAULT_BIN
    if not os.access(b, os.X_OK):
        raise RuntimeError(f"没有 ntfy 服务端程序 {b}：先跑 scripts/replay/ntfy_local.py build（要 Go：brew install go）")
    return b


def base_for(platform):
    return ANDROID_BASE if platform == "android" else IOS_BASE


def healthy(port=PORT, timeout=2):
    """True when an ntfy server answers /v1/health on 127.0.0.1:port."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=timeout) as r:
            return json.loads(r.read()).get("healthy") is True
    except Exception:
        return False


class LocalNtfy:
    """start() reuses a server already on the port, otherwise starts one; stop() stops only the one it started."""

    def __init__(self, port=PORT, log=print):
        self.port = port
        self.log = log
        self.proc = None
        self.dir = None

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def start(self, wait=15):
        if healthy(self.port):
            self.log(f"本机 ntfy 已在 {self.port} 端口（别处起的，沿用，不归本次停）")
            return self
        self.dir = tempfile.mkdtemp(prefix="ntfy-local-")
        cfg = os.path.join(self.dir, "server.yml")
        with open(cfg, "w") as f:
            f.write(CONFIG.format(port=self.port, dir=self.dir))
        logf = open(os.path.join(self.dir, "server.log"), "w")
        self.proc = subprocess.Popen([binary(), "serve", "--config", cfg], stdout=logf, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
        deadline = time.time() + wait
        while time.time() < deadline:
            if self.proc.poll() is not None:
                tail = open(os.path.join(self.dir, "server.log")).read()[-600:]
                self._cleanup()
                raise RuntimeError(f"本机 ntfy 起不来（退出码 {self.proc.returncode}）：{tail}")
            if healthy(self.port):
                self.log(f"本机 ntfy 已起：{self.url}（PID {self.proc.pid}，缓存 {self.dir}）")
                return self
            time.sleep(0.2)
        self.stop()
        raise RuntimeError(f"本机 ntfy {wait} 秒内没就绪")

    def stop(self):
        p, self.proc = self.proc, None
        if p is not None and p.poll() is None:
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(5)
        self._cleanup()

    def _cleanup(self):
        if self.dir:
            shutil.rmtree(self.dir, ignore_errors=True)
            self.dir = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.stop()


def flood(n, port=PORT, topic=None):
    """POST n messages back to back (no pause) to a fresh topic, then count them back with poll=1&since=all.
    Returns (sent ok, statuses other than 200 as {code: count}, counted back, seconds)."""
    topic = topic or f"zz-flood-{os.getpid()}-{int(time.time())}"
    base = f"http://127.0.0.1:{port}"
    ok, bad = 0, {}
    t0 = time.time()
    for i in range(n):
        req = urllib.request.Request(f"{base}/{topic}", data=f"flood {i}".encode(), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.status == 200:
                    ok += 1
                else:
                    bad[r.status] = bad.get(r.status, 0) + 1
        except urllib.error.HTTPError as e:
            bad[e.code] = bad.get(e.code, 0) + 1
    took = time.time() - t0
    with urllib.request.urlopen(f"{base}/{topic}/json?poll=1&since=all", timeout=30) as r:
        back = sum(1 for line in r.read().decode().splitlines() if json.loads(line).get("event") == "message")
    return ok, bad, back, took


def build():
    """Clone ntfy VERSION_TAG and build the server (upstream Makefile target cli-darwin-server) into DEFAULT_BIN."""
    if not shutil.which("go"):
        raise SystemExit("要先装 Go：brew install go")
    src = tempfile.mkdtemp(prefix="ntfy-src-")
    try:
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", VERSION_TAG,
                        "https://github.com/binwiederhier/ntfy", src], check=True)
        subprocess.run(["make", "cli-darwin-server", f"VERSION={VERSION_TAG.lstrip('v')}"], cwd=src, check=True)
        os.makedirs(os.path.dirname(DEFAULT_BIN), exist_ok=True)
        shutil.copy2(os.path.join(src, "dist", "ntfy_darwin_server", "ntfy"), DEFAULT_BIN)
    finally:
        shutil.rmtree(src, ignore_errors=True)
    print(subprocess.run([DEFAULT_BIN, "--version"], capture_output=True, text=True).stdout.strip(), "→", DEFAULT_BIN)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="run the local server in the foreground until Ctrl-C")
    f = sub.add_parser("flood", help="post N messages back to back and count them back (no 429 expected)")
    f.add_argument("n", type=int, nargs="?", default=300)
    sub.add_parser("build", help=f"build ntfy {VERSION_TAG} with the server into {DEFAULT_BIN}")
    p.add_argument("--port", type=int, default=PORT)
    a = p.parse_args()
    if a.cmd == "build":
        build()
        return 0
    srv = LocalNtfy(a.port)
    try:
        srv.start()
        if a.cmd == "serve":
            print(f"iOS 模拟器用 {IOS_BASE}，安卓模拟器用 {ANDROID_BASE}；Ctrl-C 停")
            while True:
                time.sleep(3600)
        ok, bad, back, took = flood(a.n, a.port)
        print(f"连发 {a.n} 条（不停顿）：成功 {ok}，其它状态 {bad or '无'}，读回 {back} 条，用时 {took:.1f} 秒")
        return 0 if ok == a.n == back and not bad else 1
    except KeyboardInterrupt:
        return 0
    finally:
        srv.stop()


if __name__ == "__main__":
    sys.exit(main())
