"""The throwaway mailbox: machine state, heartbeat and the commands the app sent.

Derived from the pass-1 publisher. The relay is played by this module: it posts a state in the relay's
`pack_chunks` format (gzip + base64, sliced into `gzp` pieces with sid / i / n, kind "state", the test PIN)
and `hb <n>` on `<topic>-hb`. Every POST goes through Guard.check_publish first.

The base state comes from the real machine READ-ONLY (one GET of its COS state object, the same object the app
reads), with the 密钥 section removed (the game sessions never go to the throwaway mailbox), and is cached in the
output directory. Nothing is ever sent to the real mailbox. `--state <file>` reuses a saved base state instead.
"""
import base64
import copy
import gzip
import socket
import threading
import hashlib
import json
import time
import urllib.error
import urllib.request

NTFY = "https://ntfy.sh"
COS = "https://ark-evidence-1315873325.cos.ap-shanghai.myqcloud.com"   # Sources/ArkRemote/Logic/Net.swift cosBase
ROOM = 4096 - 400                                                       # relay phone.py pack_chunks slice size
SHANGHAI = 8 * 3600                                                      # the machine's clock (receipt `at` / `sent`)


class NtfyLimit(RuntimeError):
    pass


# ntfy.sh counts anonymous messages per IP (250 a day) separately for IPv4 and IPv6. The runner's own posts go over the
# family with more quota left (set by quota()); only this Python process is affected, nothing on the Mac changes.
_FAMILY = {"family": 0}
_orig_getaddrinfo = socket.getaddrinfo


def _getaddrinfo(host, *a, **k):
    res = _orig_getaddrinfo(host, *a, **k)
    fam = _FAMILY["family"]
    if fam and host == "ntfy.sh":
        res = [r for r in res if r[0] == fam] or res
    return res


socket.getaddrinfo = _getaddrinfo


def quota():
    """{4: remaining, 6: remaining} anonymous ntfy.sh messages for this machine (None = family unreachable),
    and pins the runner's posts to the family with more left."""
    out = {}
    for fam, key in ((socket.AF_INET, 4), (socket.AF_INET6, 6)):
        _FAMILY["family"] = fam
        try:
            with urllib.request.urlopen(f"{NTFY}/v1/account", timeout=10) as r:
                out[key] = json.loads(r.read())["stats"]["messages_remaining"]
        except Exception:
            out[key] = None
    best = max((k for k in out if out[k] is not None), key=lambda k: out[k], default=None)
    _FAMILY["family"] = {4: socket.AF_INET, 6: socket.AF_INET6}.get(best, 0)
    return out, best


def fetch_real_state(real_topic):
    """GET the real machine's state object on COS (read-only) and return its body without 密钥."""
    h = hashlib.sha256(real_topic.strip().lower().encode()).hexdigest()[:32]
    with urllib.request.urlopen(f"{COS}/state/{h}.json", timeout=20) as r:
        m = json.loads(r.read())
    if m.get("kind") != "state":
        raise RuntimeError("the COS object is not a state envelope")
    body = m.get("body") or json.loads(gzip.decompress(base64.b64decode(m["gz"])))
    body.pop("密钥", None)
    return body


def machine_minute(ts):
    return time.strftime("%m-%d %H:%M", time.gmtime(ts + SHANGHAI))


FARM_UNTIL_MIN = 90     # the injected farm ends this many minutes after now (machine time), rounded down to 5 minutes
FARM_T0 = time.time()   # one "now" per run, so the step table (steps.FARM_HHMM) and the injected state agree


def farm_entry(now=None):
    """relay.刷声骸 of a farm that started 2 h ago and ends FARM_UNTIL_MIN later (machine clock, "YYYY-MM-DD HH:MM")."""
    now = now or FARM_T0
    until = now + FARM_UNTIL_MIN * 60
    until -= until % 300
    fmt = lambda t: time.strftime("%Y-%m-%d %H:%M", time.gmtime(t + SHANGHAI))
    return {"名字": "回放Boss", "从": fmt(now - 7200), "到": fmt(until)}


def farm_until_hhmm(now=None):
    return farm_entry(now)["到"][-5:]


class Mailbox:
    def __init__(self, guard, topic, pin, base_state, server=NTFY):
        self.guard = guard
        self.server = server.rstrip("/")   # ntfy.sh, or the local server (ntfy_local.py) the app is pointed at too
        self.topic = topic
        self.pin = pin
        base = copy.deepcopy(base_state)
        base.pop("密钥", None)
        self.base = base
        self.seen = []          # (ntfy time, envelope) of every kind=cmd message on the topic since listen()
        self.lock = threading.Lock()
        self.listening = False

    def listen(self, since_ts):
        """One long-lived ntfy subscription for the whole run (ntfy.sh limits requests per IP: polling per step
        would spend them, and the app on the same Mac shares that budget)."""
        self.listening = True
        self.listen_ok = threading.Event()

        def loop():
            since = int(since_ts)
            while self.listening:
                try:
                    with urllib.request.urlopen(f"{self.server}/{self.topic}/json?since={since}", timeout=90) as r:
                        self.listen_ok.set()
                        for raw in r:
                            if not self.listening:
                                return
                            self._take(raw.decode("utf-8", "replace"))
                            since = max(since, int(time.time()) - 5)
                except Exception:
                    time.sleep(3)
        threading.Thread(target=loop, daemon=True).start()
        self.listen_ok.wait(20)

    def _take(self, line):
        try:
            e = json.loads(line)
        except ValueError:
            return
        if e.get("event") != "message":
            return
        try:
            m = json.loads(e.get("message", ""))
        except ValueError:
            return
        if isinstance(m, dict) and m.get("kind") == "cmd":
            with self.lock:
                if not any(e.get("id") == i for i, _, _ in self.seen):
                    self.seen.append((e.get("id"), e.get("time", 0), m))

    def stop(self):
        self.listening = False

    # ---- states
    def normalized(self):
        """The base state with the parts the steps depend on put in a known shape: nothing running, no skip,
        no 'keep on', debug off, no echo farming."""
        b = copy.deepcopy(self.base)
        b["at"] = int(time.time())
        b.setdefault("run", {})["在跑的"] = []
        r = b.setdefault("relay", {})
        r["今天跳过"] = ""
        r["今天跳过队列"] = []
        r["下次别关机"] = False
        r["调试模式"] = ""
        r["刷声骸"] = {}
        return b

    def variant(self, name, extra_receipts=None):
        b = self.normalized()
        qs = b.get("queues") or []
        if name == "base":
            pass
        elif name == "dup":       # two identical receipts in the same minute
            t = machine_minute(time.time())
            e = {"at": t, "action": "weekly_boss", "ok": True, "text": "周本：打第 2 个", "sent": t}
            b["relay"].setdefault("最近指令", []).extend([dict(e), dict(e)])
        elif name == "noef":      # the morning shift without 终末地 (MaaEnd)
            if qs:
                qs[0]["脚本"] = [s for s in qs[0].get("脚本", []) if s != "MaaEnd"]
        elif name == "farm":      # 刷 4C 声骸 in progress (relay.刷声骸, as the 检查 passes 7-8 injected it)
            b["relay"]["刷声骸"] = farm_entry()
        elif name == "times":     # two test receipts: one time, and sent ≠ at (the two-time line, ce8ebc3)
            now = time.time()
            b["relay"].setdefault("最近指令", []).extend([
                {"at": machine_minute(now - 900), "action": "weekly_boss", "ok": True, "text": "回放单时间回执", "sent": machine_minute(now - 900)},
                {"at": machine_minute(now - 600), "action": "weekly_boss", "ok": True,
                 "text": "回放两时间回执：这一行字故意写长一点，看它和两个时间排不排得开", "sent": machine_minute(now - 1380)}])
        else:
            raise ValueError(f"unknown state variant {name}")
        if extra_receipts:
            b["relay"].setdefault("最近指令", []).extend(extra_receipts)
        return b

    def publish_state(self, name="base", extra_receipts=None):
        b = self.variant(name, extra_receipts)
        raw = json.dumps(b, ensure_ascii=False, separators=(",", ":"))
        blob = base64.b64encode(gzip.compress(raw.encode())).decode()
        sid = hashlib.sha1(f"{time.time()}{len(blob)}".encode()).hexdigest()[:10]
        pieces = [blob[i:i + ROOM] for i in range(0, len(blob), ROOM)] or [""]
        now = int(time.time())
        for i, s in enumerate(pieces):
            m = json.dumps({"v": 1, "kind": "state", "pin": self.pin, "ts": now, "sid": sid, "i": i, "n": len(pieces), "gzp": s},
                           ensure_ascii=False, separators=(",", ":"))
            self._post(self.topic, m.encode(), "state")
        return len(pieces)

    def hb(self, every=300):
        self._post(self.topic + "-hb", f"hb {every}".encode(), "hb")

    def _post(self, topic, data, title):
        self.guard.check_publish(topic)
        req = urllib.request.Request(f"{self.server}/{topic}", data=data, method="POST",
                                     headers={"User-Agent": "ark-replay", "Title": title})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                if r.status >= 300:
                    raise RuntimeError(f"ntfy answered {r.status}")
        except urllib.error.HTTPError as e:
            if e.code == 429:
                raise NtfyLimit(f"{self.server} 限额（429）：{e.read()[:200]!r}")
            raise

    # ---- what the app sent
    def cmds(self, since_ts):
        """kind=cmd envelopes the app posted to the throwaway topic since since_ts (s): [(ntfy time, envelope)]."""
        if self.listening:
            with self.lock:
                return [(t, m) for _, t, m in self.seen if t >= int(since_ts)]
        url = f"{self.server}/{self.topic}/json?poll=1&since={int(since_ts)}"
        out = urllib.request.urlopen(url, timeout=20).read().decode()
        res = []
        for line in out.splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") != "message":
                continue
            try:
                m = json.loads(e.get("message", ""))
            except ValueError:
                continue
            if isinstance(m, dict) and m.get("kind") == "cmd":
                res.append((e.get("time", 0), m))
        return res

    @staticmethod
    def receipt_for(env, queued=False, ok=True, text="replay"):
        """A relay receipt (modes.py add_receipt shape) answering the command envelope `env`."""
        body = env.get("body") or {}
        action = body.get("action") or ("set_master" if "master" in json.dumps(body) else "set_config")
        sent = machine_minute(env.get("ts", time.time()))
        r = {"at": machine_minute(time.time()), "action": action, "ok": ok, "text": text, "sent": sent}
        if queued:
            r["queued"] = True
        return r


class OfflineMailbox(Mailbox):
    """--offline: ntfy.sh is out of anonymous quota, so nothing is posted at all. A machine state reaches the app the
    way the 检查 passes 5-8 did it by hand: stop the app, write the state (its `at` = now) into the app's own cache
    ark-remote-cfg-snap (Net.swift Relay.snapKey; the app adopts only a newer state, Net.swift:353), start the app.
    No heartbeat can arrive, so the machine reads as off. The app's sends are never made (the runner skips the last
    tap of a send step), so there is nothing to listen to."""
    offline = True

    def __init__(self, guard, topic, pin, base_state, drv=None):
        super().__init__(guard, topic, pin, base_state)
        self.drv = drv

    def listen(self, since_ts):
        self.listening = False

    def stop(self):
        pass

    def cmds(self, since_ts):
        return []

    def hb(self, every=300):
        pass

    def publish_state(self, name="base", extra_receipts=None):
        b = self.variant(name, extra_receipts)
        b["at"] = int(time.time())
        self.drv.terminate()
        self.drv.write_default("ark-remote-cfg-snap", json.dumps(b, ensure_ascii=False, separators=(",", ":")))
        self.drv.launch()
        return 0

    def _post(self, topic, data, title):
        raise NtfyLimit("--offline: nothing is posted")
