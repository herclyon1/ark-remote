#!/usr/bin/env python3
"""One-command replay test of ark-remote: clicks through every page and button and prints 「步骤 → 对 / 不对」.

  scripts/replay/run.py --platform ios --device <udid> --topic zz-replay-ios-<random>
  scripts/replay/run.py --platform android --serial emulator-5554 --topic zz-replay-and-<random>
  scripts/replay/run.py --platform ios --dry-run            # print the plan, touch nothing

See README.md. By default the app and the runner use a local ntfy server (ntfy_local.py, port 8932: no daily quota);
--ntfy-public uses ntfy.sh. The app must never talk to the real machine: the runner refuses to start when --topic or the app's
stored mailbox is the real one, publishes only to --topic, and re-checks the stored mailbox after every step.
"""
import argparse
import atexit
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
              "tab", "ark-diag", "ark-diag-events", "ark-remote-tokens", "ark-remote-link-taken", "ark-remote-hb",
              "ark-ntfy-base"]
NTFY_BASE_KEY = "ark-ntfy-base"                # Net.swift ntfyBase: the app's mailbox server (the local one by default)
DIAG_BLACKHOLE = "http://127.0.0.1:9"          # ark-diag-bucket override: diag / crash / fluency uploads go nowhere


class StepFail(Exception):
    pass


class Abort(Exception):
    pass


DISCARD_SEL = ["放弃", "xmark"]       # the save bar's ✕ (steps.DISCARD)


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
        self.windows = {}      # step id -> (start, end) epoch s, for the app's own send log (app_posts)
        self.note = None

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
                # bar buttons (a sheet's 再想想 / 寄出 N 项 sit in its navigation bar, above the content area) count too
                bars = [b for b in dump["nodes"] if b["kind"] == "NavigationBar" and b["h"] > 0]
                inside = [n for n in hits if top + 4 <= n["y"] <= bottom - 4
                          or any(abs(n["y"] - b["y"]) <= b["h"] / 2 and abs(n["x"] - b["x"]) <= b["w"] / 2 for b in bars)]
            sig = tuple((tuple(n["texts"]), n["y"]) for n in dump["nodes"] if n["texts"])[:80]
            near = None
            if not inside and hits:
                near = "down" if hits[0]["y"] < top else "up"
            return (inside[nth] if len(inside) > nth else None), sig, near

        def settled(n):
            # after a scroll the list may still be gliding: hand back the place only once two reads agree
            for _ in range(6):
                time.sleep(0.3)
                m, _, _ = look(True)
                if m is None:
                    return n
                if (m["x"], m["y"]) == (n["x"], n["y"]):
                    return m
                n = m
            return n

        n, sig, near = look(self.cache is None)
        if n:
            return n
        if not scroll:
            raise StepFail(f"找不到「{sel_text(sel)}」")
        if near:
            self.scroll(near, short=True)
            n, sig, near = look(True)
            if n:
                return settled(n)
        for direction in ("up", "down"):
            same = 0
            for _ in range(8 if direction == "up" else 12):
                self.scroll(direction)
                n, sig2, near = look(True)
                if not n and near:
                    self.scroll(near, short=True)
                    n, sig2, near = look(True)
                if n:
                    return settled(n)
                same = same + 1 if sig2 == sig else 0
                if same >= 2:
                    break        # this end of the page reached (twice: one swipe can be lost on a busy simulator)
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
                n = self.steady(rest[0], n, opts)
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
                fields = [f for f in self.dump(False)["nodes"] if self.is_field(f) and abs(f["y"] - n["y"]) <= max(n["h"], f["h"], 36) and self.on_screen(f)]   # iOS 27: the field under its title
                if fields:
                    target = min(fields, key=lambda f: abs(f["y"] - n["y"]))
            tx = target["x"] + (target["w"] // 2 - 20 if self.drv.platform == "ios" and target["w"] > 80 else 0)
            self.drv.tap(tx, target["y"])
            if not self.drv.wait_keyboard() and self.drv.platform == "ios":
                # the list was still gliding under the tap: read the field's place again and tap once more
                self.invalidate()
                fresh = [f for f in self.dump(True)["nodes"] if self.is_field(f) and self.on_screen(f)
                         and abs(f["x"] - target["x"]) <= 4]
                if fresh:
                    target = min(fresh, key=lambda f: abs(f["y"] - target["y"]))
                self.drv.tap(target["x"] + (target["w"] // 2 - 20 if target["w"] > 80 else 0), target["y"])
                if not self.drv.wait_keyboard():
                    raise StepFail("点了框没出键盘")
            self.drv.clear_field(opts.get("clear", 12))
            if rest[1]:
                self.drv.type(rest[1])
                if self.drv.platform == "ios":
                    self.check_field_text(target, rest[1], opts.get("clear", 12))
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
        elif kind == "bottom":
            # ("bottom", most): scroll down until the screen stops changing (the page end), at most `most` swipes
            prev = None
            for _ in range(rest[0] if rest else 8):
                self.scroll("up")
                sig = [(n["label"], n["y"]) for n in self.dump(True)["nodes"] if n["label"] and self.on_screen(n)]
                if sig == prev:
                    break
                prev = sig
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
        elif kind == "gate_trials":
            self.gate_trials(*rest)
        elif kind == "dismiss":
            self.dismiss()
        elif kind in ("until", "gone"):
            # ("until" | "gone", sel, seconds[, {"region": ...}]): wait for sel to show on screen / to leave it
            if not self.wait_for(rest[0], rest[1], gone=kind == "gone", region=opts_of(rest).get("region", "any")):
                raise StepFail(f"等了 {rest[1]} 秒「{sel_text(rest[0])}」{'还在' if kind == 'gone' else '没出现'}；屏上：{self.seen()}")
        elif kind == "nokb":
            # ("nokb", seconds): put the keyboard away (if up) and wait until it has left the screen
            self.wait_no_keyboard(rest[0] if rest else 5)
        elif kind == "retry":
            # ("retry", tries, [actions], check): run the actions, then the check (an until / gone / nokb action);
            # when the check fails run the actions again, at most `tries` times in all (a press lost under load)
            for i in range(rest[0]):
                for sub in rest[1]:
                    self.act(sub, step)
                try:
                    self.act(rest[2], step)
                    break
                except StepFail:
                    if i == rest[0] - 1:
                        raise
                    self.invalidate()
        elif kind == "pick":
            # ("pick", wheel index, value): iOS DatePicker wheels (the capsule opened first)
            res = self.drv.call(f"pick {rest[0]} {rest[1]}")[0]
            if not res.startswith("ok"):
                raise StepFail(f"转盘 {rest[0]} 拨不到 {rest[1]}：{res}")
        elif kind == "allow_paste":
            # ("allow_paste", s): within s seconds press 「Allow Paste」 on the system paste permission alert, if it comes
            # (it can come twice: once for the link, once more for the runner's own pasteboard write)
            t_end, n = time.time() + (rest[0] if rest else 8), 0
            while time.time() < t_end:
                res = self.drv.call("sysalert Allow Paste|允许粘贴", timeout=40)[0]
                if res.startswith("ok"):
                    n += 1
                    self.note = f"点了系统粘贴许可框 Allow Paste ×{n}"
                time.sleep(0.5)
        elif kind == "point":
            # ("point", fx, fy): a tap at that fraction of the screen (outside a system panel, which has no button)
            self.drv.tap(int(self.drv.size[0] * rest[0]), int(self.drv.size[1] * rest[1]))
        elif kind == "see":
            # ("see", sel): scroll until sel is inside the content area, without tapping
            self.locate(rest[0])
        elif kind == "time":
            # ("time", DatePicker label, hour, minute): open the compact capsule, turn both wheels, close by a tap outside
            self.pick_time(rest[0], rest[1], rest[2])
        elif kind == "tapout":
            # close a popover (the DatePicker wheels) by a tap in the right margin beside the row of sel, outside the cards
            n = self.locate(rest[0], scroll=False)
            self.drv.tap(self.drv.size[0] - 8, n["y"])
        elif kind == "app_posts":
            self.check_app_posts(rest[0])
        elif kind == "clipboard":
            if rest and rest[0] == "@link":
                self.drv.set_clipboard(self.own_link())
            elif rest and rest[0]:
                self.drv.set_clipboard(rest[0])
            else:
                self.drv.clear_clipboard()
        elif kind == "forget_config":
            # the 第一次使用 screen: no stored mailbox (and no remembered link, so a copied link is taken again)
            self.drv.terminate()
            for _ in range(3):
                self.drv.delete_defaults(["ark-remote-cfg", "ark-remote-link-taken"])
                if self.drv.read_default("ark-remote-cfg") is None:
                    break
                time.sleep(0.5)
            else:
                raise StepFail("删不掉 App 存的信箱（ark-remote-cfg）")
        elif kind == "restore_config":
            self.drv.terminate()
            self.drv.write_default("ark-remote-cfg", json.dumps({"topic": self.guard.topic, "pin": self.mb.pin}, separators=(",", ":")))
            self.check_stored_config()
        elif kind == "fluency":
            self.fluency(*rest)
        elif kind == "shot":
            self.drv.screenshot(os.path.join(self.out, rest[0] + ".png"))
        else:
            raise StepFail(f"未知动作 {kind}")
        self.invalidate()

    def pick_time(self, label, hh, mm):
        """iOS compact DatePicker (StatusPage.swift hhmmBinding): tap the capsule, wait for the two wheels, set
        hour / minute (XCUIElement.adjust), then close the popover with a tap in the right margin at the capsule's
        height (outside the cards: a tap on a row below would also hit that row, pass 7 doubt 3)."""
        if self.drv.platform == "android":
            # a TextView button with the time (「8:30 AM」 / 「08:30」) right of the row title opens a Material3 dialog
            n = self.locate(f"{label}（机器时间）")
            n = self.steady(f"{label}（机器时间）", n, {})
            pat = re.compile(r"^\d{1,2}:\d\d( [AP]M)?$")
            btns = [b for b in self.dump(True)["nodes"] if any(pat.match(t) for t in b["texts"]) and b["x"] > n["x"]
                    and abs(b["y"] - n["y"]) <= 120 and self.on_screen(b)]
            if not btns:
                raise StepFail(f"「{label}」那行没有时间按钮")
            b = min(btns, key=lambda b: abs(b["y"] - n["y"]))
            self.drv.tap(b["x"], b["y"])
            time.sleep(1.0)
            self.drv.set_time_dialog(int(hh), int(mm))
            time.sleep(0.6)
            return
        sel = {"t": label, "kind": "DatePicker"}
        for _ in range(2):
            self.locate(sel)
            self.invalidate()
            n = self.locate(sel, scroll=False)      # where it is after the nudge
            self.drv.tap(n["x"], n["y"])
            time.sleep(0.9)
            self.invalidate()
            if any(x["kind"] == "PickerWheel" for x in self.dump(True)["nodes"]):
                break
        else:
            raise StepFail(f"点「{label}」胶囊没出转盘")
        self.turn_wheel(0, int(hh), 24)
        self.turn_wheel(1, int(mm), 60)
        self.drv.tap(self.drv.size[0] - 8, n["y"])
        time.sleep(0.8)
        self.invalidate()
        if any(x["kind"] == "PickerWheel" for x in self.dump(True)["nodes"]):
            raise StepFail("点外面没关掉转盘")

    def turn_wheel(self, i, want, mod):
        """Turn picker wheel i to the value want with synthesized touches (XCUIElement.adjust waits for the app to go
        idle, 60 s per wait when it never does): a slow drag of about 32 pt per row for big moves (no fling: the finger
        rests before it lifts), a tap on the neighbouring row for the last ones, reading the wheel back each time."""
        for _ in range(16):
            wheels = sorted([n for n in self.dump(True)["nodes"] if n["kind"] == "PickerWheel"], key=lambda n: n["x"])
            if len(wheels) <= i:
                raise StepFail(f"没有第 {i + 1} 个转盘")
            w = wheels[i]
            m = re.match(r"\s*(\d+)", w["value"] or "")
            if not m:
                raise StepFail(f"转盘值读不懂：{w['value']!r}")
            d = (want - int(m.group(1))) % mod
            if d > mod // 2:
                d -= mod
            if d == 0:
                return
            x, y = w["x"], w["y"]
            if abs(d) <= 2:
                self.drv.tap(x, y + (32 if d > 0 else -32))
            else:
                k = max(-6, min(6, d))
                y0 = y + 80 if k > 0 else y - 80
                y1 = y0 - 32 * k
                self.drv.call(f"path {x},{y0},0|{x},{y0 + (y1 - y0) // 20},30|{x},{(y0 + y1) // 2},500|{x},{y1},500|{x},{y1},400")
            time.sleep(0.9)
        raise StepFail(f"转盘 {i + 1} 拨不到 {want}")

    def dismiss(self):
        """Close what a skipped send left open: a review sheet (再想想), a confirm alert (取消), a notice (好), then
        throw the edits away (✕), so the next step starts from the page as it was."""
        for _ in range(4):
            dump = self.dump(True)
            for sel in ("再想想", "取消", "好"):
                hits = [h for h in self.find(sel, dump) if self.on_screen(h)]
                if hits:
                    self.drv.tap(hits[-1]["x"], hits[-1]["y"])
                    time.sleep(0.8)
                    break
            else:
                hits = self.find(DISCARD_SEL, dump, "top")
                if hits:
                    self.drv.tap(hits[0]["x"], hits[0]["y"])
                    time.sleep(0.8)
                    continue
                return

    def gate_trials(self, n, gap_ms, hold_ms):
        """Android 400 ms gate (EWLive.swift go(): a press that began before armedAt does not send; armedAt is set 400 ms
        after the sheet's onAppear). n trials: raw tap on ✓, after gap_ms a raw press on 寄出 (its position with the sheet
        fully up, remembered as "send") held hold_ms, so the press begins early and ends after the gate opened. Each trial
        is timed against the sheet window's own first frame (dumpsys gfxinfo framestats, same clock as the kernel touch
        times). None may send: judged by the mailbox here and by the app's own send log in the step (appsent=0)."""
        if self.drv.platform != "android":
            raise StepFail("gate_trials 只在安卓上跑")
        if "save" not in self.ctx or "send" not in self.ctx:
            raise StepFail("门测试缺坐标（先跑记坐标的步骤）")
        (x1, y1), (x2, y2) = self.ctx["save"], self.ctx["send"]
        rows = []
        gap = gap_ms
        for k in range(n):
            t = self.drv.gate_trial(x1, y1, x2 + (k % 2), y2 + (k % 3), gap, hold_ms)
            if len(t) < 4:
                raise StepFail(f"第 {k + 1} 次：getevent 没录到四次触摸（{len(t)}）")
            sheet = self.drv.sheet_frames(t[1])
            if sheet is None:
                raise StepFail(f"第 {k + 1} 次：没找到确认单的窗口帧（✓ 没点开？）")
            first, drawn, nfr = sheet
            # where 寄出 sits once the sheet is up: the sheet opens at the medium or the large detent, so a press
            # aimed at the remembered spot is on the button only when this trial's sheet stopped at the same height
            self.invalidate()
            b = self.locate("寄出 1 项", scroll=False)
            for _ in range(8):
                time.sleep(0.4)
                self.invalidate()
                b2 = self.locate("寄出 1 项", scroll=False)
                if (b2["x"], b2["y"]) == (b["x"], b["y"]):
                    break
                b = b2
            on_button = abs(b["y"] - y2) <= b["h"] // 2 and abs(b["x"] - x2) <= b["w"] // 2
            rows.append({"down_after_first": round(t[2] - first), "first_drawn": round(drawn - first),
                         "up_after_first": round(t[3] - first), "tap_to_first": round(first - t[1]), "on_button": on_button})
            self.ctx["send"] = (x2, y2) = (b["x"], b["y"])    # aim the next trial where the button was this time
            # aim the next press just after this trial's first frame was done, if that is still inside the 400 ms
            target = min(rows[-1]["first_drawn"] + 30, 380)
            gap = max(0, gap + target - rows[-1]["down_after_first"])
            # the sheet stays open when nothing was sent: close it with 再想想
            n_ = self.locate("再想想", scroll=False)
            self.drv.tap(n_["x"], n_["y"])
            end = time.time() + 12
            while time.time() < end and self.find("确认这次修改", self.dump(True)):
                time.sleep(0.5)
        inwin = [r for r in rows if r["on_button"] and r["first_drawn"] <= r["down_after_first"] < 400]
        self.note = (f"{n} 次（按在寄出停稳的位置上 {sum(r['on_button'] for r in rows)} 次）：按下距单子首帧开始 {min(r['down_after_first'] for r in rows)}–{max(r['down_after_first'] for r in rows)} ms，"
                     f"松手 {min(r['up_after_first'] for r in rows)}–{max(r['up_after_first'] for r in rows)} ms；"
                     f"单子首帧画完要 {min(r['first_drawn'] for r in rows)}–{max(r['first_drawn'] for r in rows)} ms；"
                     f"落在「首帧已画完且不到 400 ms」的 {len(inwin)} 次")
        self.ctx["gate_rows"] = rows

    def own_link(self):
        """A 免输入链接 for the THROWAWAY mailbox (PhoneTab.swift PhoneLink.make: pageURL#k=base64url({"t","p"})); never
        the real one, so the app taking it from the clipboard keeps talking to the throwaway mailbox."""
        import base64
        self.guard.check_publish(self.guard.topic)
        k = base64.urlsafe_b64encode(json.dumps({"t": self.guard.topic, "p": self.mb.pin}, separators=(",", ":")).encode()).decode().rstrip("=")
        return "https://herclyon1.github.io/maa/#k=" + k

    def fluency(self, cycles=3):
        """Android: switch the five tabs `cycles` times (1.5 s apart) and read the app's own FluencyRec lines for those
        presses (files/diag-rec/ark-flu-queue.json: a line goes there when its gesture hit a rule, e.g. long = a frame
        interval > 100 ms; the upload goes to the blackholed diag bucket, so the queue keeps it). Only when the Mac is
        idle: 1-minute load below 8 before and after."""
        if self.drv.platform != "android":
            raise StepFail("fluency 只在安卓上跑")
        load0 = os.getloadavg()[0]
        if load0 >= 8:
            raise StepFail(f"Mac 1 分钟负载 {load0:.1f} ≥ 8，没量")
        tabs = ["方舟", "终末地", "鸣潮", "手机", "状态"]
        dump = self.dump(True)
        pos = {}
        for t in tabs:
            hits = self.find({"t": t, "region": "bottom"}, dump)
            if not hits:
                raise StepFail(f"底栏找不到「{t}」")
            pos[t] = (hits[0]["x"], hits[0]["y"])
        m0 = time.time()
        dev = int(self.drv.sh("date +%s%3N").strip() or 0)
        off = dev - (m0 + time.time()) / 2 * 1000
        self.drv.sh("dumpsys gfxinfo com.herclyon.arkremote reset > /dev/null")
        taps = []
        for _ in range(cycles):
            for t in tabs:
                taps.append((t, time.time() * 1000 + off))
                self.drv.tap(*pos[t])
                time.sleep(1.5)
        gfx = self.drv.sh("dumpsys gfxinfo com.herclyon.arkremote")
        pct = {k: v for k, v in re.findall(r"^(50th|90th|99th) percentile: (\d+)ms", gfx, re.M)}
        load1 = os.getloadavg()[0]
        # FluencyRec queues a hit's upload SEND_MS (30 s) after the first hit
        lines, deadline = [], time.time() + 60
        while time.time() < deadline:
            time.sleep(5)
            raw = self.drv.sh("cat /data/data/com.herclyon.arkremote/files/diag-rec/ark-flu-queue.json")
            lines = []
            try:
                for rec in json.loads(raw or "[]"):
                    body = json.loads(rec.get("body") or "{}")
                    lines += [ln for ln in body.get("lines", []) if ln.get("kind") == "tap" and ln.get("at", 0) >= taps[0][1] - 500]
            except ValueError:
                continue
            if lines and max(ln["at"] for ln in lines) >= taps[-1][1] - 2000:
                break
        per = []
        for t, at in taps:
            ln = min((ln for ln in lines if at - 200 <= ln["at"] <= at + 1400), key=lambda ln: ln["at"], default=None)
            per.append((t, ln))

        def say(target):
            got = [ln for t, ln in per if t == target]
            longs = [ln["max"] for ln in got if ln and "long" in (ln.get("bad") or [])]
            return f"切到{target} {len(got)} 次里 long {len(longs)} 次" + (f"（{'/'.join(str(m) for m in longs)} ms）" if longs else "")
        maxes = [ln["max"] for _, ln in per if ln]
        self.note = (f"负载 {load0:.1f}→{load1:.1f}；{say('终末地')}；{say('鸣潮')}；"
                     f"记下的 {len(maxes)}/{len(per)} 次里最长一帧 {max(maxes) if maxes else '—'} ms"
                     f"（其余没命中规则，≤100 ms）；同段 gfxinfo 帧 p50 {pct.get('50th', '?')} / p90 {pct.get('90th', '?')} / p99 {pct.get('99th', '?')} ms")
        self.ctx["fluency"] = per
        if load1 >= 8:
            raise StepFail(f"量完 Mac 1 分钟负载 {load1:.1f} ≥ 8，这组数不作数")

    def app_posts(self, since, until):
        """The app's own send log: 诊断记录 (DiagLog, key ark-diag-events) fetch events with method POST to the mailbox
        (url <ntfy host>/<信箱>) between since and until (epoch s). DiagLog saves at most every 5 s, on the next event, so
        this waits until the saved log reaches past `until`. Returns [(t, status or error)], or None if the log
        never caught up (诊断记录 off?)."""
        deadline = time.time() + 20
        while True:
            raw = self.drv.read_default("ark-diag-events")
            try:
                ev = json.loads(raw) if raw else []
            except ValueError:
                ev = []
            newest = max((e.get("t", 0) for e in ev if isinstance(e, dict)), default=0) / 1000
            if newest >= until:
                return [(e["t"] / 1000, e.get("status") or e.get("error") or "?") for e in ev
                        if isinstance(e, dict) and e.get("kind") == "fetch" and e.get("method") == "POST"
                        and "<信箱>" in (e.get("url") or "") and since * 1000 <= e.get("t", 0) <= until * 1000 + 2000]
            if time.time() > deadline:
                return None
            time.sleep(2)

    def check_app_posts(self, want):
        """want = {step id: 0 (no send) | n (at least n)}: the app's own send log during each of those steps' windows.
        The log must be saved first (a step that opens 分享诊断记录 does that: DiagUI.prepareSheet -> persist)."""
        posts = self.app_posts(min(self.windows[k][0] for k in want if k in self.windows) - 1, time.time() - 1)
        if posts is None:
            raise StepFail("App 的诊断记录没有跟上（诊断记录没开？）")
        bad, said = [], []
        for k, n in want.items():
            if k not in self.windows:
                bad.append(f"{k} 没跑")
                continue
            a, b = self.windows[k]
            got = [p for p in posts if a - 1 <= p[0] <= b + 2]
            said.append(f"{k} {len(got)} 条" + (f"（{', '.join(str(s) for _, s in got)}）" if got else ""))
            if (n == 0 and got) or (n > 0 and len(got) < n):
                bad.append(f"{k} 应为 {'0' if n == 0 else '≥' + str(n)} 条，实际 {len(got)} 条")
        self.note = "App 自己的发送记录：" + "；".join(said)
        if bad:
            raise StepFail("；".join(bad))

    @staticmethod
    def cmd_action(m):
        b = m.get("body") or {}
        return b.get("action", "")

    def is_field(self, n):
        if self.drv.platform == "android":
            return n["kind"] == "EditText"
        return n["kind"] in ("TextField", "SecureTextField", "TextView")

    def switch_on_row(self, n, nodes):
        """The switch on the row of node n (iOS: Switch / Toggle element; Android: the checkable node), or None."""
        if self.drv.platform == "ios":
            if n["kind"] in ("Switch", "Toggle"):
                return n
            cands = [s for s in nodes if s["kind"] in ("Switch", "Toggle") and abs(s["y"] - n["y"]) <= max(n["h"], 44)]
        else:
            cands = [s for s in nodes if s["checked"] is not None and abs(s["y"] - n["y"]) <= max(n["h"], 110) and s["x"] >= n["x"] - 10]
            if not cands:
                cands = [s for s in nodes if s["checked"] is not None and abs(s["y"] - n["y"]) <= max(n["h"], 110)]
        return min(cands, key=lambda s: abs(s["y"] - n["y"])) if cands else None

    def steady(self, sel, n, opts):
        """iOS: a page still sliding in (push, sheet) or a list still gliding moves the element under the tap; tap
        only once two reads agree on where it is (stable: up to 8 reads 0.4 s apart, else 3 reads 0.25 s apart)."""
        tries = 8 if opts.get("stable") else (3 if self.drv.platform == "ios" else 0)
        for _ in range(tries):
            time.sleep(0.4 if opts.get("stable") else 0.25)
            self.invalidate()
            # still gliding, it may have left the content area: find it again (nudging it back in when allowed)
            m = self.locate(sel, scroll=opts.get("scroll", True), region=opts.get("region", "any"))
            if (m["x"], m["y"]) == (n["x"], n["y"]):
                return m
            n = m
        return n

    def wait_for(self, sel, secs, gone=False, region="any"):
        """Poll the element tree until sel is on screen (or, gone=True, off it); False on timeout."""
        t_end = time.time() + secs
        while True:
            hits = [h for h in self.find(sel, self.dump(True), region) if self.on_screen(h)]
            if bool(hits) != gone:
                self.invalidate()
                return True
            if time.time() >= t_end:
                return False
            time.sleep(0.3)

    def seen(self, limit=140):
        """What is on screen now (labels in tree order), for a failure line."""
        nodes = self.dump(True)["nodes"]
        self.invalidate()
        labels = [n["label"] or n.get("value") or "" for n in nodes if self.on_screen(n) and n["kind"] != "Keyboard"]
        out = "、".join(dict.fromkeys(x for x in labels if x))
        if self.drv.platform == "ios" and self.drv.keyboard_up(nodes):
            out = "（键盘开着）" + out
        return out[:limit]

    def wait_no_keyboard(self, secs):
        if self.drv.platform == "android":
            self.drv.hide_keyboard()
            return
        t_end, pressed = time.time() + secs, False
        while True:
            nodes = self.dump(True)["nodes"]
            if not self.drv.keyboard_up(nodes):
                self.invalidate()
                return
            if not pressed:
                self.hide_keyboard()
                pressed = True
            if time.time() >= t_end:
                raise StepFail(f"等了 {secs} 秒键盘没收起；屏上：{self.seen()}")
            time.sleep(0.3)

    def check_field_text(self, target, text, clear):
        """iOS: read the field back after typing; when characters were lost or old ones stayed (seen under load:
        「2511」 for 251), clear it and type once more; still wrong -> 不对 with what the field holds."""
        def value_now():
            nodes = [f for f in self.dump(True)["nodes"] if self.is_field(f) and self.on_screen(f)
                     and abs(f["x"] - target["x"]) <= 6]
            self.invalidate()
            if not nodes:
                return None
            return (min(nodes, key=lambda f: abs(f["y"] - target["y"]))["value"] or "").strip()
        v = value_now()
        if v is None or v == text:
            return
        self.drv.clear_field(max(clear, len(v) + 4))
        self.drv.type(text)
        v = value_now()
        if v is not None and v != text:
            raise StepFail(f"框里是「{v}」，要填的是「{text}」（清掉重输过一次）")

    def toggle(self, sel, opts):
        n = self.locate(sel, scroll=opts.get("scroll", True))
        n = self.steady(sel, n, opts)
        sw = self.switch_on_row(n, self.dump(False)["nodes"])
        if sw is None:
            raise StepFail(f"「{sel_text(sel)}」那行没有开关")
        if self.drv.platform == "ios" and sw["w"] > 100:
            self.drv.tap(sw["x"] + sw["w"] // 2 - 30, sw["y"])   # a SwiftUI Toggle's element spans the row: tap the knob
        else:
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
        for stored in stored_topics(self.drv):
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
            for s, want in (step.get("switch") or {}).items():
                rows = [n for n in self.find(s, dump) if self.on_screen(n)]
                sw = self.switch_on_row(rows[0], dump["nodes"]) if rows else None
                if sw is None:
                    miss.append(f"「{sel_text(s)}」那行没有开关")
                elif sw["checked"] != want:
                    miss.append(f"「{sel_text(s)}」开关是{'开' if sw['checked'] else '关'}，应为{'开' if want else '关'}")
            for s in step.get("visible", []):
                top, bottom = self.drv.content_box(dump["nodes"])
                if not [n for n in self.find(s, dump) if top - 40 <= n["y"] <= bottom]:
                    miss.append(f"「{sel_text(s)}」不在屏幕上")
            miss += [f"多了「{sel_text(s)}」" for s in absent if self.find(s, dump)]
            for up, low in step.get("below", []):
                # the lower element starts at or under the upper one's bottom edge (no overlap), and on screen
                u = [n for n in self.find(up, dump) if self.on_screen(n)]
                lo = [n for n in self.find(low, dump) if self.on_screen(n)]
                if not u or not lo:
                    miss.append(f"「{sel_text(up)}」/「{sel_text(low)}」不在屏幕上")
                elif lo[0]["y"] - lo[0]["h"] / 2 < u[0]["y"] + u[0]["h"] / 2 - 1:
                    miss.append(f"「{sel_text(low)}」（上边 {lo[0]['y'] - lo[0]['h'] / 2:g}）压着「{sel_text(up)}」（下边 {u[0]['y'] + u[0]['h'] / 2:g}）")
            if step.get("last_above") or step.get("last_bottom"):
                miss += self.check_last(step, dump)
            if kb is not None and self.drv.keyboard_up(dump["nodes"]) != kb:
                k = [n for n in dump["nodes"] if n["kind"] == "Keyboard"]
                miss.append(("键盘还在" + (f"（y {k[0]['y']} 高 {k[0]['h']}）" if k else "")) if not kb else "键盘没出来")
            if not miss or time.time() > deadline:
                break
            time.sleep(0.3)
        if miss:
            raise StepFail("；".join(miss))

    def content_bottom(self, dump):
        """The lowest bottom edge of the page's own content: the nodes before the tab bar / toolbar in the tree (the
        diagnostic button and strip float after them), without containers and scroll bars."""
        nodes = dump["nodes"]
        cut = next((k for k, n in enumerate(nodes) if n["kind"] in ("TabBar", "Toolbar")), len(nodes))
        H = self.drv.size[1]
        body = [n for n in nodes[:cut] if n["kind"] not in ("Application", "Window", "Other", "ScrollView", "Table",
                                                              "CollectionView", "NavigationBar")
                and n["h"] < H * 0.6 and 0 <= n["y"] <= H]
        return max((n["y"] + n["h"] / 2 for n in body), default=None)

    def check_last(self, step, dump):
        """last_above: sel - scrolled to the bottom, the page's last line ends at or above sel's top edge (and within
        60 pt of it, so the page really is at its end). last_bottom: [lo, hi] - that edge lies in this range."""
        b = self.content_bottom(dump)
        if b is None:
            return ["页面内容为空"]
        if step.get("last_above"):
            hits = [n for n in self.find(step["last_above"], dump) if self.on_screen(n)]
            if not hits:
                return [f"没有「{sel_text(step['last_above'])}」"]
            top = hits[0]["y"] - hits[0]["h"] / 2
            if not (top - 60 <= b <= top + 1):
                return [f"最后一行下边 {b:g}，「{sel_text(step['last_above'])}」上边 {top:g}"]
        if step.get("last_bottom"):
            lo, hi = step["last_bottom"]
            if not (lo <= b <= hi):
                return [f"最后一行下边 {b:g}，应在 {lo}–{hi}"]
        return []

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
        self.note = None
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
        self.__dict__.setdefault("windows", {})[step["id"]] = (t0, time.time())
        ok = err is None
        verdict = "对" if ok else "不对"
        if ok and step.get("skip"):
            verdict = f"跳过（{step['skip']}）"
        if step.get("nojudge_fail") and not ok and not crash:
            verdict, ok, err = f"不判（{step['nojudge_fail']}：{err}）", True, None
        if step.get("nojudge") and (ok or not crash):
            verdict, ok, err = f"不判（{step['nojudge']}）", True, None
        shot = None
        if not ok:
            shot = os.path.join(self.out, f"{i:03d}-{step['id']}.png")
            try:
                self.drv.screenshot(shot)
            except Exception:
                shot = None
        line = (f"{i:3d} {step['say']} → {verdict}  ({dt:.1f}s)" + ("" if ok else f"  {err}")
                + (f"  [{self.note}]" if self.note else ""))
        print(line, flush=True)
        self.results.append({"n": i, "id": step["id"], "say": step["say"], "ok": ok, "verdict": verdict, "err": err,
                             "sec": round(dt, 1), "shot": shot,
                             "note": self.note})
        if crash and step.get("relaunch_on_crash", True):
            self.drv.terminate()
            self.drv.launch()
            time.sleep(3)
        return ok


ACTIONS = {"bottom", "until", "gone", "nokb", "retry", "tap", "tab", "toggle", "field", "type", "enter", "hidekb", "swipe", "top", "back", "wait", "relaunch", "state",
           "receipt", "clear_receipts", "hb", "remember", "gate", "gate_trials", "app_posts", "shot", "clipboard", "forget_config", "restore_config", "fluency",
           "dismiss", "pick", "tapout", "time", "see", "point", "allow_paste"}
STEP_KEYS = {"id", "page", "say", "do", "on", "expect", "absent", "visible", "keyboard", "cmd", "nocmd", "timeout", "cmd_timeout",
             "ios", "android", "always", "settle", "pause", "relaunch_on_crash", "switch", "offline",
             "skip", "nojudge", "nojudge_fail", "below", "last_above", "last_bottom"}


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
        for variant in (s, s.get("ios") or {}, s.get("android") or {}, s.get("offline") or {}):
            for a in variant.get("do", []):
                if not isinstance(a, tuple) or a[0] not in ACTIONS:
                    errs.append(f"{s['id']}: bad action {a!r}")
                elif a[0] == "state" and len(a) > 1 and a[1] not in ("base", "dup", "noef", "farm", "times"):
                    errs.append(f"{s['id']}: unknown state variant {a[1]}")
        if s.get("on", "both") not in ("both", "ios", "android"):
            errs.append(f"{s['id']}: bad on")
    if errs:
        raise SystemExit("step table errors:\n  " + "\n  ".join(errs))


def stored_topics(drv):
    """The mailbox topic of every stored copy of ark-remote-cfg ([None] when there is none)."""
    raws = [v for _, v in drv.read_defaults_all("ark-remote-cfg")] if hasattr(drv, "read_defaults_all") \
        else [drv.read_default("ark-remote-cfg")]
    out = []
    for raw in raws:
        if not raw:
            continue
        try:
            out.append(json.loads(raw).get("topic"))
        except ValueError:
            out.append(raw)
    return out or [None]


def select_steps(all_steps, platform, only=None, start=None, stop=None, offline=False):
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
        off = s.pop("offline", None)
        if offline:
            s.pop("cmd", None) if off is not None else None
            if off is not None:
                s.update(off.get(platform, off) if isinstance(off, dict) and platform in off else off)
                s.pop("ios", None)
                s.pop("android", None)
            elif s.get("cmd") is not None:
                # a send step: everything but its last tap, then close what is open (confirm / review sheet, edits)
                s["do"] = list(s.get("do", []))[:-1] + [("dismiss",)]
                s["skip"] = "额度"
                for k in ("cmd", "expect", "absent"):
                    s.pop(k, None)
        if not offline:
            s.pop("skip", None) if s.get("skip") == "额度" else None
        out.append(s)
        if stop and s["id"] == stop:
            break
    return out


def opts_of(rest):
    return rest[-1] if rest and isinstance(rest[-1], dict) else {}


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
    p.add_argument("--ntfy-public", action="store_true",
                   help="use ntfy.sh (anonymous daily quota, HTTP 429 when spent) instead of the local ntfy server "
                        "ntfy_local.py starts on 127.0.0.1:8932 (the default: no quota, every send step runs)")
    p.add_argument("--offline", action="store_true",
                   help="post nothing to ntfy (anonymous quota used up): states go into the app's cache, send steps stop "
                        "at their confirm / review sheet and count as 跳过（额度）")
    p.add_argument("--dry-run", action="store_true", help="print the plan and exit; touches no device and no network")
    p.add_argument("--list", action="store_true", help="list step ids and exit")
    p.add_argument("--verbose", action="store_true")
    a = p.parse_args()

    validate(stepsmod.STEPS)
    only = set(a.only.split(",")) if a.only else None
    plan = select_steps(stepsmod.STEPS, a.platform, only, a.start, a.stop, offline=a.offline)
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
    local = None
    if a.offline:
        mb = mbmod.OfflineMailbox(g, a.topic, a.pin, base)
        print("离线：不往 ntfy 发任何东西；机器状态写进 App 的缓存，寄出类步骤停在确认单、记「跳过（额度）」", flush=True)
    elif not a.ntfy_public:
        # the local ntfy server: no daily quota, so the send steps run (the app is pointed at it through NTFY_BASE_KEY)
        import ntfy_local
        try:
            local = ntfy_local.LocalNtfy(log=lambda m: print(m, flush=True)).start()
            atexit.register(local.stop)   # stop() is idempotent and stops only the PID it started
        except RuntimeError as e:
            print("拒绝运行：", e)
            return 2
        mb = mbmod.Mailbox(g, a.topic, a.pin, base, server=local.url)
    else:
        mb = mbmod.Mailbox(g, a.topic, a.pin, base)
        q, fam = mbmod.quota()
        print(f"ntfy.sh 今天还能发：IPv4 {q.get(4)} 条，IPv6 {q.get(6)} 条；本脚本走 IPv{fam}", flush=True)
        if fam is None or (q.get(fam) or 0) < 60:
            print("拒绝运行：ntfy.sh 本机今天的匿名消息额度不够跑一遍（一遍约 40 条状态 / 心跳 + App 自己寄出的 20 来条）；"
                  "去掉 --ntfy-public 用本机 ntfy")
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
    mb.drv = drv

    t_start = time.time()
    r = Runner(a, drv, mb, g, out)
    r.t_run0 = t_start
    rc = 0
    prefs_saved = None
    try:
        drv.start()
        drv.terminate()
        if a.install:
            print("安装", a.install)
            drv.install(a.install)
        if not drv.installed():
            print("拒绝运行：设备上没装 App（用 --install）")
            return 2
        # guard BEFORE the app is ever launched (every stored copy: iOS keeps a container and a home-domain one)
        for stored in stored_topics(drv):
            g.check_app_topic(stored)
        if hasattr(drv, "prefs_backup"):
            # Android: the whole defaults.xml goes back byte for byte at the end (the emulator's app keeps its own data)
            prefs_saved = drv.prefs_backup()
            print("偏好已备份", prefs_saved)
        drv.delete_defaults(RESET_KEYS)
        drv.write_default("ark-remote-cfg", json.dumps({"topic": a.topic, "pin": a.pin}, separators=(",", ":")))
        drv.write_default("ark-diag-bucket", DIAG_BLACKHOLE)
        if local:
            drv.write_default(NTFY_BASE_KEY, ntfy_local.base_for(a.platform))
            print(f"App 的信箱服务器：{ntfy_local.base_for(a.platform)}（本机 ntfy）", flush=True)
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
        if prefs_saved:
            try:
                drv.prefs_restore(prefs_saved, launch=False)
                print("偏好已恢复（逐字节一致）")
            except Exception as e:
                print("偏好恢复失败：", e, "备份在", prefs_saved)
                rc = rc or 4
        if local and not prefs_saved:
            try:   # iOS: the simulator's app goes back to ntfy.sh (Android: the defaults.xml restore above did it)
                drv.delete_defaults([NTFY_BASE_KEY])
            except Exception:
                pass
        drv.stop()
        mb.stop()
        if local:
            local.stop()
    took = time.time() - t_start
    bad = [x for x in r.results if not x["ok"]]
    n_ok = sum(1 for x in r.results if x.get("verdict") == "对")
    n_skip = sum(1 for x in r.results if (x.get("verdict") or "").startswith("跳过"))
    n_nj = sum(1 for x in r.results if (x.get("verdict") or "").startswith("不判"))
    print(f"\n合计 {len(r.results)} 步：对 {n_ok}，不对 {len(bad)}，跳过 {n_skip}，不判 {n_nj}；用时 {took / 60:.1f} 分钟")
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
