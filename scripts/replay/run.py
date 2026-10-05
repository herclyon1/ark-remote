#!/usr/bin/env python3
"""One-command replay test of ark-remote: clicks through every page and button and prints 「步骤 → 对 / 不对」.

  scripts/replay/run.py --platform ios --device <udid> --topic zz-replay-ios-<random>
  scripts/replay/run.py --platform android --serial emulator-5554 --topic zz-replay-and-<random>
  scripts/replay/run.py --platform ios --dry-run            # print the plan, touch nothing

See README.md. The app must never talk to the real machine: the runner refuses to start when --topic or the app's
stored mailbox is the real one, publishes only to --topic, and re-checks the stored mailbox after every step.
"""
import argparse
import json
import os
import signal
import re
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import guard as guardmod   # noqa: E402
import steps as stepsmod   # noqa: E402

BACKGROUND_ACTIONS = {"refresh", "watch"}      # sent by the app on its own (open / refresh), never a test failure
RESET_KEYS = ["ark-remote-pending", "ark-remote-acked", "ark-remote-estop", "ark-remote-cfg-queue", "ark-remote-cfg-snap",
              "tab", "ark-diag", "ark-diag-events", "ark-remote-tokens", "ark-remote-link-taken", "ark-remote-hb"]
DIAG_BLACKHOLE = "http://127.0.0.1:9"          # ark-diag-bucket override: diag / crash / fluency uploads go nowhere


class StepFail(Exception):
    pass


class Abort(Exception):
    pass


# ---------------------------------------------------------------- selectors
def _match_one(sel, node):
    if sel == "":
        return True
    for t in node["texts"]:
        if sel.startswith("~"):
            if sel[1:] in t:
                return True
        elif sel.startswith("re:"):
            if re.search(sel[3:], t):
                return True
        elif t == sel:
            return True
    return False


def norm_sel(sel):
    """str | list[str] | dict -> dict(t=[alternatives], kind=None, nth=0, region=...)"""
    if isinstance(sel, dict):
        d = dict(sel)
        t = d.get("t", [])
        d["t"] = t if isinstance(t, list) else [t]
        return d
    return {"t": sel if isinstance(sel, list) else [sel]}


def sel_text(sel):
    d = norm_sel(sel)
    return "|".join(d["t"]) + (f"[{d['kind']}]" if d.get("kind") else "")


class Runner:
    def __init__(self, args, drv, mailbox, guard, out):
        self.a = args
        self.drv = drv
        self.mb = mailbox
        self.guard = guard
        self.out = out
        self.cache = None
        self.ctx = {}
        self.results = []

    # ---- tree access
    def dump(self, fresh=True):
        if fresh or self.cache is None:
            self.cache = self.drv.dump()
        return self.cache

    def invalidate(self):
        self.cache = None

    def find(self, sel, dump=None, region="any"):
        d = norm_sel(sel)
        dump = dump or self.dump(False)
        W, H = self.drv.size
        top, bottom = self.drv.content_box(dump["nodes"])
        reg = d.get("region", region)
        hits = []
        for n in dump["nodes"]:
            if d.get("kind") and n["kind"] not in (d["kind"] if isinstance(d["kind"], list) else [d["kind"]]):
                continue
            if not any(_match_one(s, n) for s in d["t"]):
                continue
            if n["w"] <= 0 or n["h"] <= 0:
                continue
            if reg == "content" and not (top <= n["y"] <= bottom):
                continue
            if reg == "bottom" and n["y"] < H * 0.8:
                continue
            if reg == "top" and n["y"] > H * 0.2:
                continue
            hits.append(n)
        hits.sort(key=lambda n: (n["y"], n["x"]))
        if d.get("after"):
            anchors = [n for n in dump["nodes"] if _match_one(d["after"], n) and n["h"] > 0]
            if not anchors:
                return []
            ay = min(n["y"] for n in anchors)
            hits = [n for n in hits if n["y"] > ay]
        if reg == "bottom":
            hits.sort(key=lambda n: -n["y"])
        return hits

    def on_screen(self, n):
        W, H = self.drv.size
        return 0 <= n["y"] <= H and 0 <= n["x"] <= W

    def locate(self, sel, scroll=True, region="any"):
        """A node for sel inside the content area (below the navigation bar, above the tab bar / keyboard).
        With scroll on: a match just outside the area is nudged in; otherwise scroll down to the bottom, then up."""
        d = norm_sel(sel)
        nth = d.get("nth", 0)

        def look(fresh):
            dump = self.dump(fresh)
            top, bottom = self.drv.content_box(dump["nodes"])
            hits = [n for n in self.find(sel, dump, region) if self.on_screen(n)]
            if region in ("top", "bottom"):
                inside = hits
            else:
                inside = [n for n in hits if top + 4 <= n["y"] <= bottom - 4]
            sig = tuple((tuple(n["texts"]), n["y"]) for n in dump["nodes"] if n["texts"])[:80]
            near = None
            if not inside and hits:
                near = "down" if hits[0]["y"] < top else "up"
            return (inside[nth] if len(inside) > nth else None), sig, near

        n, sig, near = look(self.cache is None)
        if n:
            return n
        if not scroll:
            raise StepFail(f"找不到「{sel_text(sel)}」")
        if near:
            self.scroll(near, short=True)
            n, sig, near = look(True)
            if n:
                return n
        for direction in ("up", "down"):
            for _ in range(8 if direction == "up" else 12):
                self.scroll(direction)
                n, sig2, near = look(True)
                if not n and near:
                    self.scroll(near, short=True)
                    n, sig2, near = look(True)
                if n:
                    return n
                if sig2 == sig:
                    break        # this end of the page reached
                sig = sig2
        raise StepFail(f"找不到「{sel_text(sel)}」")

    def scroll(self, direction, short=False):
        W, H = self.drv.size
        top, bottom = self.drv.content_box(self.dump(False)["nodes"] if self.cache else [])
        span = (bottom - top) * (0.35 if short else 0.6)
        x = W // 2
        y0 = int(top + (bottom - top) * 0.8)
        if direction == "up":       # content moves up = scroll down the page
            self.drv.swipe(x, y0, x, int(y0 - span), 300)
        else:
            y1 = int(top + (bottom - top) * 0.2)
            self.drv.swipe(x, y1, x, int(y1 + span), 300)
        time.sleep(0.6)
        self.invalidate()

    # ---- actions
    def act(self, a, step):
        kind, rest = a[0], a[1:]
        opts = rest[-1] if rest and isinstance(rest[-1], dict) and kind in ("tap", "toggle", "field", "remember") else {}
        if kind == "tap":
            if opts.get("last"):
                hits = [h for h in self.find(rest[0], self.dump(self.cache is None), opts.get("region", "any")) if self.on_screen(h)]
                if not hits:
                    hits = [h for h in self.find(rest[0], self.dump(True), opts.get("region", "any")) if self.on_screen(h)]
                if not hits:
                    raise StepFail(f"找不到「{sel_text(rest[0])}」")
                n = hits[-1]
            else:
                n = self.locate(rest[0], scroll=opts.get("scroll", True), region=opts.get("region", "any"))
            x, y = n["x"] + opts.get("dx", 0), n["y"] + opts.get("dy", 0)
            if opts.get("right"):
                x = n["x"] + n["w"] // 2 - opts["right"]
            self.drv.tap(x, y, opts.get("hold", 50))
        elif kind == "tab":
            hits = self.find({"t": rest[0], "region": "bottom"}, self.dump(self.cache is None))
            if not hits:
                hits = self.find({"t": rest[0], "region": "bottom"}, self.dump(True))
            if not hits:
                raise StepFail(f"底栏找不到「{rest[0]}」")
            self.drv.tap(hits[0]["x"], hits[0]["y"])
        elif kind == "toggle":
            self.toggle(rest[0], opts)
        elif kind == "field":
            n = self.locate(rest[0], scroll=opts.get("scroll", True))
            target = n
            if not self.is_field(n):
                fields = [f for f in self.dump(False)["nodes"] if self.is_field(f) and abs(f["y"] - n["y"]) <= max(n["h"], f["h"]) and self.on_screen(f)]
                if fields:
                    target = min(fields, key=lambda f: abs(f["y"] - n["y"]))
            self.drv.tap(target["x"] + (target["w"] // 2 - 20 if self.drv.platform == "ios" and target["w"] > 80 else 0), target["y"])
            self.drv.wait_keyboard()
            self.drv.clear_field(opts.get("clear", 12))
            if rest[1]:
                self.drv.type(rest[1])
        elif kind == "type":
            self.drv.type(rest[0])
        elif kind == "enter":
            if self.drv.platform == "android":
                self.drv.sh("input keyevent KEYCODE_ENTER")
            else:
                self.drv.type("\n")
        elif kind == "hidekb":
            self.hide_keyboard()
        elif kind == "swipe":
            for _ in range(rest[1] if len(rest) > 1 else 1):
                self.scroll(rest[0])
        elif kind == "top":
            for _ in range(rest[0] if rest else 5):
                self.scroll("down")
        elif kind == "back":
            self.drv.back()
        elif kind == "wait":
            time.sleep(rest[0])
        elif kind == "relaunch":
            self.drv.terminate()
            self.check_stored_config()
            self.drv.launch()
            self.ctx["crash_marker"] = self.drv.log_marker()
        elif kind == "state":
            self.mb.publish_state(rest[0] if rest else "base", self.ctx.get("receipts"))
        elif kind == "receipt":
            # rest = (action, queued?, ok?): answer the newest command of that action the app sent this run
            actions = rest[0] if isinstance(rest[0], list) else [rest[0]]
            cmds = self.mb.cmds(self.t_run0)
            for action in actions:
                sent = [m for _, m in cmds if self.cmd_action(m) == action]
                if not sent:
                    raise StepFail(f"信箱里没有 App 寄出的 {action}，没法回执")
                r = self.mb.receipt_for(sent[-1], queued=rest[1] if len(rest) > 1 else False, ok=rest[2] if len(rest) > 2 else True)
                self.ctx.setdefault("receipts", []).append(r)
            self.mb.publish_state("base", self.ctx["receipts"])
        elif kind == "clear_receipts":
            self.ctx["receipts"] = []
        elif kind == "hb":
            n = rest[0] if rest else 300
            self.mb.hb(n)
            self.last_hb = time.time()
            self.hb_hold = n < 60      # a short heartbeat on purpose (machine-off steps): no keep-alive until the next hb
        elif kind == "remember":
            n = self.locate(rest[0], scroll=False, region=opts.get("region", "any"))
            self.ctx[rest[1]] = (n["x"], n["y"])
        elif kind == "gate":
            # ("gate", key-of-✓, key-of-寄出, gap_ms, hold_ms)
            if rest[0] not in self.ctx or rest[1] not in self.ctx:
                raise StepFail("门测试缺坐标（先跑记坐标的步骤）")
            (x1, y1), (x2, y2) = self.ctx[rest[0]], self.ctx[rest[1]]
            self.drv.gate_press(x1, y1, x2, y2, rest[2], rest[3])
        elif kind == "clipboard":
            if rest and rest[0]:
                self.drv.set_clipboard(rest[0])
            else:
                self.drv.clear_clipboard()
        elif kind == "shot":
            self.drv.screenshot(os.path.join(self.out, rest[0] + ".png"))
        else:
            raise StepFail(f"未知动作 {kind}")
        self.invalidate()

    @staticmethod
    def cmd_action(m):
        b = m.get("body") or {}
        return b.get("action", "")

    def is_field(self, n):
        if self.drv.platform == "android":
            return n["kind"] == "EditText"
        return n["kind"] in ("TextField", "SecureTextField", "TextView")

    def toggle(self, sel, opts):
        n = self.locate(sel, scroll=opts.get("scroll", True))
        nodes = self.dump(False)["nodes"]
        if self.drv.platform == "ios":
            if n["kind"] in ("Switch", "Toggle"):
                sw = n
            else:
                cands = [s for s in nodes if s["kind"] in ("Switch", "Toggle") and abs(s["y"] - n["y"]) <= max(n["h"], 44)]
                if not cands:
                    raise StepFail(f"「{sel_text(sel)}」那行没有开关")
                sw = min(cands, key=lambda s: abs(s["y"] - n["y"]))
            # a SwiftUI Toggle's element spans the row: tap the knob at its right end
            x = sw["x"] + sw["w"] // 2 - 30 if sw["w"] > 100 else sw["x"]
            self.drv.tap(x, sw["y"])
        else:
            cands = [s for s in nodes if s["checked"] is not None and abs(s["y"] - n["y"]) <= max(n["h"], 110) and s["x"] >= n["x"] - 10]
            if not cands:
                cands = [s for s in nodes if s["checked"] is not None and abs(s["y"] - n["y"]) <= max(n["h"], 110)]
            if not cands:
                raise StepFail(f"「{sel_text(sel)}」那行没有开关")
            sw = min(cands, key=lambda s: abs(s["y"] - n["y"]))
            self.drv.tap(sw["x"], sw["y"])

    def hide_keyboard(self):
        if self.drv.platform == "android":
            self.drv.hide_keyboard()
            return
        nodes = self.dump(True)["nodes"]
        if not self.drv.keyboard_up(nodes):
            return
        done = [n for n in nodes if n["label"] in ("完成", "Done") and n["kind"] == "Button" and self.on_screen(n)]
        kb = [n for n in nodes if n["kind"] == "Keyboard"]
        if kb:   # the keyboard toolbar's 完成 sits just above the keyboard; the sheet's ✓ (also 完成) sits at the top
            ktop = kb[0]["y"] - kb[0]["h"] // 2
            done = [n for n in done if n["y"] > ktop - 80] or []
        if done:
            self.drv.tap(done[0]["x"], done[0]["y"])
        else:
            raise StepFail("iOS 键盘没有「完成」键，收不起来")

    # ---- checks
    def check_stored_config(self):
        raw = self.drv.read_default("ark-remote-cfg")
        stored = None
        if raw:
            try:
                stored = json.loads(raw).get("topic")
            except ValueError:
                stored = raw
        self.guard.check_app_topic(stored)
        if stored is not None and stored != self.guard.topic:
            raise Abort("App 存的信箱不是 --topic（已停 App）")

    def expect(self, step, t0):
        exp = step.get("expect", [])
        absent = step.get("absent", [])
        timeout = step.get("timeout", self.a.timeout)
        kb = step.get("keyboard")
        deadline = t0 + timeout
        miss = []
        while True:
            dump = self.dump(True)
            if not self.drv.alive(dump):
                raise StepFail("App 不在前台（闪退？）")
            miss = [f"缺「{sel_text(s)}」" + (f" ×{norm_sel(s)['count']}" if norm_sel(s).get("count") else "")
                    for s in exp if len(self.find(s, dump)) < norm_sel(s).get("count", 1)]
            for s in step.get("visible", []):
                top, bottom = self.drv.content_box(dump["nodes"])
                if not [n for n in self.find(s, dump) if top - 40 <= n["y"] <= bottom]:
                    miss.append(f"「{sel_text(s)}」不在屏幕上")
            miss += [f"多了「{sel_text(s)}」" for s in absent if self.find(s, dump)]
            if kb is not None and self.drv.keyboard_up(dump["nodes"]) != kb:
                miss.append("键盘还在" if not kb else "键盘没出来")
            if not miss or time.time() > deadline:
                break
            time.sleep(0.3)
        if miss:
            raise StepFail("；".join(miss))

    def check_cmds(self, step, t0):
        want = step.get("cmd")
        none_for = step.get("nocmd")
        if want is None and none_for is None:
            return
        if none_for:
            time.sleep(max(0, none_for - (time.time() - t0)))
        deadline = time.time() + step.get("cmd_timeout", 25)
        wants = want if isinstance(want, list) else ([want] if want is not None else [])
        while True:
            allc = [m for ts, m in self.mb.cmds(t0 if none_for else t0 - 2)]
            got = [m for m in allc if self.cmd_action(m) not in BACKGROUND_ACTIONS]
            if none_for:
                if got:
                    raise StepFail("不该寄出却寄出了：" + ", ".join(self.brief(m) for m in got))
                return
            missing = [w for w in wants if not any(self.cmd_matches(w, m) for m in allc)]
            if not missing:
                return
            if time.time() > deadline:
                raise StepFail("信箱没收到 " + ", ".join(json.dumps(w, ensure_ascii=False) for w in missing)
                               + (f"（收到 {', '.join(self.brief(m) for m in got)}）" if got else ""))
            time.sleep(1.5)

    @staticmethod
    def brief(m):
        return json.dumps(m.get("body"), ensure_ascii=False)[:120]

    @staticmethod
    def cmd_matches(w, m):
        body = m.get("body") or {}
        if isinstance(w, str):
            return w.lstrip("~") in json.dumps(body, ensure_ascii=False)
        return all(body.get(k) == v for k, v in w.items())

    # ---- loop
    def keep_alive(self):
        """hb 300 keeps the machine 'on' for 630 s; re-post every 4 minutes so a long run never sees it expire."""
        if not getattr(self, "hb_hold", False) and time.time() - getattr(self, "last_hb", 0) > 240:
            self.mb.hb(300)
            self.last_hb = time.time()

    def run_step(self, i, step):
        self.keep_alive()
        t0 = time.time()
        marker = self.drv.log_marker()
        err = None
        try:
            for a in step.get("do", []):
                self.act(a, step)
                if step.get("pause"):
                    time.sleep(step["pause"])
            if step.get("settle"):
                time.sleep(step["settle"])
            self.expect(step, t0)
            self.check_cmds(step, t0)
        except StepFail as e:
            err = str(e)
        except Abort:
            raise
        except Exception as e:   # a driver error is a failed step, not a dead run
            err = f"{type(e).__name__}: {e}"
            if self.a.verbose:
                traceback.print_exc()
        crash = self.drv.crashed_since(marker) if self.drv.platform == "android" else self.drv.crashed_since(marker)
        if crash:
            err = (err + "；" if err else "") + "闪退：" + crash[0][:160]
        # guard: the stored mailbox is re-read after every step
        try:
            self.check_stored_config()
        except Exception as e:
            self.drv.terminate()
            raise Abort(f"安全检查失败，已停 App：{e}")
        dt = time.time() - t0
        ok = err is None
        shot = None
        if not ok:
            shot = os.path.join(self.out, f"{i:03d}-{step['id']}.png")
            try:
                self.drv.screenshot(shot)
            except Exception:
                shot = None
        line = f"{i:3d} {step['say']} → {'对' if ok else '不对'}  ({dt:.1f}s)" + ("" if ok else f"  {err}")
        print(line, flush=True)
        self.results.append({"n": i, "id": step["id"], "say": step["say"], "ok": ok, "err": err, "sec": round(dt, 1), "shot": shot})
        if crash and step.get("relaunch_on_crash", True):
            self.drv.terminate()
            self.drv.launch()
            time.sleep(3)
        return ok


ACTIONS = {"tap", "tab", "toggle", "field", "type", "enter", "hidekb", "swipe", "top", "back", "wait", "relaunch", "state",
           "receipt", "clear_receipts", "hb", "remember", "gate", "shot", "clipboard"}
STEP_KEYS = {"id", "page", "say", "do", "on", "expect", "absent", "visible", "keyboard", "cmd", "nocmd", "timeout", "cmd_timeout",
             "ios", "android", "always", "settle", "pause", "relaunch_on_crash"}


def validate(all_steps):
    """Static check of the step table: unique ids, known keys and actions, state variants that exist."""
    seen, errs = set(), []
    for s in all_steps:
        if s["id"] in seen:
            errs.append(f"duplicate id {s['id']}")
        seen.add(s["id"])
        for k in s:
            if k not in STEP_KEYS:
                errs.append(f"{s['id']}: unknown key {k}")
        for variant in (s, s.get("ios") or {}, s.get("android") or {}):
            for a in variant.get("do", []):
                if not isinstance(a, tuple) or a[0] not in ACTIONS:
                    errs.append(f"{s['id']}: bad action {a!r}")
                elif a[0] == "state" and len(a) > 1 and a[1] not in ("base", "dup", "noef"):
                    errs.append(f"{s['id']}: unknown state variant {a[1]}")
        if s.get("on", "both") not in ("both", "ios", "android"):
            errs.append(f"{s['id']}: bad on")
    if errs:
        raise SystemExit("step table errors:\n  " + "\n  ".join(errs))


def select_steps(all_steps, platform, only=None, start=None, stop=None):
    out = []
    started = start is None
    for s in all_steps:
        if not started and s["id"] == start:
            started = True
        if not started:
            continue
        on = s.get("on", "both")
        if on != "both" and on != platform:
            continue
        if only and s.get("page") not in only and not s.get("always"):
            continue
        s = dict(s)
        s.update(s.pop(platform, {}) or {})
        s.pop("ios", None)
        s.pop("android", None)
        out.append(s)
        if stop and s["id"] == stop:
            break
    return out


def describe(a):
    return " ".join(str(x) if not isinstance(x, (dict, list)) else json.dumps(x, ensure_ascii=False) for x in a)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--platform", required=True, choices=["ios", "android"])
    p.add_argument("--device", help="iOS simulator UDID")
    p.add_argument("--serial", default="emulator-5554", help="Android adb serial")
    p.add_argument("--topic", help="the THROWAWAY ntfy topic (never the real mailbox); one per concurrent run")
    p.add_argument("--pin", default="0000")
    p.add_argument("--install", help="install this .app / .apk first")
    p.add_argument("--state", help="base state JSON (default: read the real machine's COS state read-only, cached in out/)")
    p.add_argument("--key-file", action="append", help="where ARK_PHONE_TOPIC is (default ~/.config/ark/密钥总表.md, push.env)")
    p.add_argument("--out", help="output dir (default scripts/replay/out/<platform>-<time>)")
    p.add_argument("--only", help="comma-separated pages: setup,status,monthcard,d39,gate,arknights,endfield,wuwa,phone,shift,receipts")
    p.add_argument("--from", dest="start", help="start at this step id")
    p.add_argument("--to", dest="stop", help="stop after this step id")
    p.add_argument("--timeout", type=float, default=8, help="default seconds to wait for a step's expected texts")
    p.add_argument("--port", type=int, help="iOS runner HTTP port (default derived from the UDID)")
    p.add_argument("--dry-run", action="store_true", help="print the plan and exit; touches no device and no network")
    p.add_argument("--list", action="store_true", help="list step ids and exit")
    p.add_argument("--verbose", action="store_true")
    a = p.parse_args()

    validate(stepsmod.STEPS)
    only = set(a.only.split(",")) if a.only else None
    plan = select_steps(stepsmod.STEPS, a.platform, only, a.start, a.stop)
    if a.list or a.dry_run:
        for i, s in enumerate(plan, 1):
            print(f"{i:3d} [{s.get('page', '')}] {s['id']}: {s['say']}")
            if a.dry_run:
                for act in s.get("do", []):
                    print(f"        do  {describe(act)}")
                if s.get("expect"):
                    print(f"        有  {' / '.join(sel_text(x) for x in s['expect'])}")
                if s.get("absent"):
                    print(f"        无  {' / '.join(sel_text(x) for x in s['absent'])}")
                if s.get("cmd") is not None:
                    print(f"        寄出 {json.dumps(s['cmd'], ensure_ascii=False)}")
                if s.get("nocmd"):
                    print(f"        {s['nocmd']} 秒内不寄出")
        print(f"{len(plan)} steps for {a.platform}")
        return 0

    if not a.topic:
        p.error("--topic is required (a throwaway topic)")
    if a.platform == "ios" and not a.device:
        p.error("--device <udid> is required for ios")
    try:
        g = guardmod.Guard(a.topic, a.key_file)
    except guardmod.GuardError as e:
        print("拒绝运行：", e)
        return 2

    import mailbox as mbmod
    out = a.out or os.path.join(HERE, "out", f"{a.platform}-{time.strftime('%Y%m%d-%H%M%S')}")
    os.makedirs(out, exist_ok=True)
    if a.state:
        base = json.load(open(a.state, encoding="utf-8"))
    else:
        cache = os.path.join(HERE, "out", "state-base.json")
        if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 12 * 3600:
            base = json.load(open(cache, encoding="utf-8"))
        else:
            base = mbmod.fetch_real_state(g.real_topic_for_read())
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(base, f, ensure_ascii=False)
    mb = mbmod.Mailbox(g, a.topic, a.pin, base)
    q, fam = mbmod.quota()
    print(f"ntfy.sh 今天还能发：IPv4 {q.get(4)} 条，IPv6 {q.get(6)} 条；本脚本走 IPv{fam}", flush=True)
    if fam is None or (q.get(fam) or 0) < 60:
        print("拒绝运行：ntfy.sh 本机今天的匿名消息额度不够跑一遍（一遍约 40 条状态 / 心跳 + App 自己寄出的 20 来条）")
        return 2
    app_fam = 6 if (a.platform == "ios" and q.get(6) is not None) else 4
    if (q.get(app_fam) or 0) < 25:
        print(f"注意：App 多半走 IPv{app_fam}，那边只剩 {q.get(app_fam)} 条，App 寄出的命令会被 ntfy 拒（429），"
              "「寄出」类步骤会判不对", flush=True)

    if a.platform == "ios":
        from drv_ios import IOSDriver
        drv = IOSDriver(a.device, out, port=a.port)
    else:
        from drv_android import AndroidDriver
        drv = AndroidDriver(a.serial, out)

    t_start = time.time()
    r = Runner(a, drv, mb, g, out)
    r.t_run0 = t_start
    rc = 0
    try:
        drv.start()
        drv.terminate()
        if a.install:
            print("安装", a.install)
            drv.install(a.install)
        if not drv.installed():
            print("拒绝运行：设备上没装 App（用 --install）")
            return 2
        # guard BEFORE the app is ever launched
        raw = drv.read_default("ark-remote-cfg")
        stored = None
        if raw:
            try:
                stored = json.loads(raw).get("topic")
            except ValueError:
                stored = raw
        g.check_app_topic(stored)
        drv.delete_defaults(RESET_KEYS)
        drv.write_default("ark-remote-cfg", json.dumps({"topic": a.topic, "pin": a.pin}, separators=(",", ":")))
        drv.write_default("ark-diag-bucket", DIAG_BLACKHOLE)
        r.check_stored_config()
        drv.clear_clipboard()
        mb.listen(t_start - 5)
        mb.publish_state("base")
        mb.hb(300)
        print(f"开始：{a.platform} {a.device or a.serial}，{len(plan)} 步，输出 {out}", flush=True)
        for i, s in enumerate(plan, 1):
            r.run_step(i, s)
    except Abort as e:
        print("中止：", e)
        rc = 3
    except guardmod.GuardError as e:
        print("拒绝运行：", e)
        rc = 2
    except mbmod.NtfyLimit as e:
        print("中止：", e)
        rc = 3
    except KeyboardInterrupt:
        print("中断")
        rc = 130
    finally:
        try:
            drv.terminate()
        except Exception:
            pass
        drv.stop()
        mb.stop()
    took = time.time() - t_start
    bad = [x for x in r.results if not x["ok"]]
    print(f"\n合计 {len(r.results)} 步：对 {len(r.results) - len(bad)}，不对 {len(bad)}；用时 {took / 60:.1f} 分钟")
    for x in bad:
        print(f"  不对 {x['n']:3d} {x['say']}：{x['err']}" + (f"（截图 {x['shot']}）" if x["shot"] else ""))
    with open(os.path.join(out, "results.json"), "w", encoding="utf-8") as f:
        json.dump({"platform": a.platform, "device": a.device or a.serial, "seconds": round(took), "steps": r.results},
                  f, ensure_ascii=False, indent=1)
    return rc or (1 if bad else 0)


def _term(*_):
    raise KeyboardInterrupt   # SIGTERM runs the same cleanup as Ctrl-C (stop the app and the XCUITest runner)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _term)
    sys.exit(main())
