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
import hashlib
import json
import time
import urllib.request

NTFY = "https://ntfy.sh"
COS = "https://ark-evidence-1315873325.cos.ap-shanghai.myqcloud.com"   # Sources/ArkRemote/Logic/Net.swift cosBase
ROOM = 4096 - 400                                                       # relay phone.py pack_chunks slice size
SHANGHAI = 8 * 3600                                                      # the machine's clock (receipt `at` / `sent`)


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


class Mailbox:
    def __init__(self, guard, topic, pin, base_state):
        self.guard = guard
        self.topic = topic
        self.pin = pin
        base = copy.deepcopy(base_state)
        base.pop("密钥", None)
        self.base = base

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
        req = urllib.request.Request(f"{NTFY}/{topic}", data=data, method="POST",
                                     headers={"User-Agent": "ark-replay", "Title": title})
        with urllib.request.urlopen(req, timeout=20) as r:
            if r.status >= 300:
                raise RuntimeError(f"ntfy answered {r.status}")

    # ---- what the app sent
    def cmds(self, since_ts):
        """kind=cmd envelopes the app posted to the throwaway topic since since_ts (s): [(ntfy time, envelope)]."""
        url = f"{NTFY}/{self.topic}/json?poll=1&since={int(since_ts)}"
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
