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
              "ark-ntfy-base", "ark-skland-base", "ark-need-url"]
NTFY_BASE_KEY = "ark-ntfy-base"                # Net.swift ntfyBase: the app's mailbox server (the local one by default)
# ("skland", "on"): the 库存 page with numbers - 森空岛 and the need table answered by skland_local.py on this Mac
# (Stamina.swift StaminaStore.skBaseKey, Inventory.swift InventoryStore.needURLKey; both loopback only) and a made-up
# 森空岛 session that only that stand-in ever sees
SKLAND_KEYS = ["ark-skland-base", "ark-need-url", "ark-remote-tokens"]
REPLAY_SK = {"sk": {"cred": "replay", "token": "replay", "dId": "replay", "uid": "replay", "efRole": "1", "efServer": "1"}}
DIAG_BLACKHOLE = "http://127.0.0.1:9"          # ark-diag-bucket override: diag / crash / fluency uploads go nowhere


class StepFail(Exception):
    pass


class Abort(Exception):
    pass


class NoJudge(Exception):
    """The step could not test what it claims on this run (e.g. a busy Mac): it reads 不判 with the reason."""


DISCARD_SEL = ["放弃", "xmark"]       # the save bar's ✕ (steps.DISCARD)
DISCARD_OK = "放弃改动"                # its confirmation (Pages/Shell/SaveBar.swift)
CLEAR_SEL = "不再显示进度"             # steps.CLEAR
PENDING_LINE = "re:项改动"             # the pending line under the title, iOS (Pages/Shell/PendingBarView.swift)


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
            if reg == "upper" and n["y"] >= H * 0.8:   # anywhere above the tab bar (a page title, not the tab's label)
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
        android = self.drv.platform == "android"
        nodes = self.dump(False)["nodes"] if (self.cache or android) else []
        top, bottom = self.drv.content_box(nodes)
        span = (bottom - top) * (0.35 if short else 0.6)
        x = W // 2
        y0 = int(top + (bottom - top) * 0.8)
        if direction == "up":       # content moves up = scroll down the page
            if android:
                y0 = self.free_y(nodes, x, y0, -1, top, bottom)
            self.drv.swipe(x, y0, x, int(y0 - span), 300)
        else:
            y1 = int(top + (bottom - top) * 0.2)
            if android:
                y1 = self.free_y(nodes, x, y1, 1, top, bottom)
            self.drv.swipe(x, y1, x, int(y1 + span), 300)
        time.sleep(0.6)
        self.invalidate()

    def free_y(self, nodes, x, y, step, top, bottom):
        """Android: a swipe's start height near y (moving by step toward the middle) that is on no clickable row.
        An `input swipe` from a row now and then reads as a tap on that row: the ("top", 3) of ef.ticket.open started at
        0.2 of the content area, on the 终末地 page's 库存 row, and opened 库存 (ark37 10-14, run 7 step 79 and a probe:
        tab 终末地 + top 3 -> the 库存 page). Containers taller than half the content area (the list itself) are not rows."""
        rows = [n for n in nodes if n["clickable"] and 0 < n["h"] < (bottom - top) / 2
                and abs(n["x"] - x) <= n["w"] / 2]
        lo, hi = top + 20, bottom - 20
        for i in range(0, int((bottom - top) * 0.4), 12):
            yy = y + step * i
            if lo <= yy <= hi and not any(abs(n["y"] - yy) <= n["h"] / 2 + 6 for n in rows):
                return int(yy)
        return y

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
        elif kind == "discard":
            # the save bar's ✕ asks first (Pages/Shell/SaveBar.swift: 「放弃这 N 项改动？」 → 放弃改动)
            self.act(("tap", DISCARD_SEL, {"region": "top"}), step)
            # the action sheet takes no touch while it is still coming up (UIKit): tap 放弃改动 until the sheet is gone
            self.tap_until_gone(DISCARD_OK, step)
        elif kind == "clear":
            # 「不再显示进度」: iOS asks from the pending line under the title (Pages/Shell/PendingBarView.swift
            # SubtitleLine); Android keeps the button on the row, which asks the same question (PendingBarView)
            if self.drv.platform == "ios":
                # right after a send the review sheet is still closing and a tap on the line can be lost (app-r1 local
                # ntfy run, step 75 ef.protocol right after ef.send): tap the line again while its sheet is not up
                for _ in range(3):
                    self.act(("tap", PENDING_LINE), step)
                    if self.wait_for(CLEAR_SEL, 4):
                        break
                self.tap_until_gone(CLEAR_SEL, step)
                # the action sheet leaves the element tree as its dismissal starts, and the line under the title goes
                # with it, so the list moves up; a touch during that transition is not delivered to the page (app-r1
                # fix round 2: ark.battle.discard's 作战开关 toggle right after the clear was lost 2 of 2 times, and
                # passed once the step waited about a second). Wait for the line to go, then for the transition.
                self.wait_for(PENDING_LINE, 4, gone=True)
                time.sleep(0.6)
            else:
                self.act(("tap", CLEAR_SEL), step)
                self.tap_until_gone(CLEAR_SEL, step)   # the dialog's button of the same name
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
            if self.drv.platform == "ios":
                self.caret_to_end(target)
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
            self.ctx["at_end"] = False
            for _ in range(rest[0] if rest else 8):
                self.scroll("up")
                sig = [(n["label"], n["y"]) for n in self.dump(True)["nodes"] if n["label"] and self.on_screen(n)]
                if sig == prev:
                    self.ctx["at_end"] = True   # a swipe moved nothing: the page is at its end (check_last)
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
        elif kind == "skland":
            # ("skland", "on" | "off"): stop the app, point it at the local stand-in with a made-up session (or take
            # both away again), start it
            self.drv.terminate()
            if rest[0] == "on":
                if not self.ctx.get("skland"):
                    import skland_local
                    self.ctx["skland"] = skland_local.LocalSkland(log=lambda m: print(m, flush=True)).start()
                base = __import__("skland_local").base_for(self.a.platform)
                self.drv.write_default("ark-skland-base", base)
                self.drv.write_default("ark-need-url", base + "/need.json")
                self.drv.write_default("ark-remote-tokens", json.dumps(REPLAY_SK, separators=(",", ":")))
            else:
                self.drv.delete_defaults(SKLAND_KEYS)
            self.check_stored_config()
            self.drv.launch()
            self.ctx["crash_marker"] = self.drv.log_marker()
        elif kind == "appearance":
            # ("appearance", "dark" | "light"): the system's dark mode (simctl ui appearance / cmd uimode night)
            self.drv.appearance(rest[0] == "dark")
            self.ctx["dark"] = rest[0] == "dark"
            time.sleep(1.5)
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
        elif kind == "sheet_steady":
            self.sheet_steady(rest[0])
        elif kind == "clipboard":
            if rest and rest[0] == "@link":
                self.drv.set_clipboard(self.own_link())
            elif rest and rest[0] == "@oldlink":
                self.drv.set_clipboard(self.own_link(old=True))
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
            # the picture plus the element tree beside it (centres and sizes in points), for measuring overlaps
            self.drv.screenshot(os.path.join(self.out, rest[0] + ".png"))
            with open(os.path.join(self.out, rest[0] + ".json"), "w") as f:
                json.dump(self.dump(True)["nodes"], f, ensure_ascii=False)
        else:
            raise StepFail(f"未知动作 {kind}")
        self.invalidate()

    def pick_time(self, label, hh, mm):
        """iOS compact DatePicker (StatusPage.swift hhmmBinding): tap the capsule, wait for the two wheels, set
        hour / minute (XCUIElement.adjust), then close the popover with a tap in the right margin at the capsule's
        height (outside the cards: a tap on a row below would also hit that row, pass 7 doubt 3)."""
        if self.drv.platform == "android":
            # a TextView button with the time (「8:30 AM」 / 「08:30」) right of the row title opens a Material3 dialog;
            # the title is the label alone since the page went to one clock (8b6d488 dropped 「（机器时间）」)
            n = self.locate(label)
            n = self.steady(label, n, {})
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
            for sel in ("放弃改动", "再想想", "取消", "好"):
                hits = [h for h in self.find(sel, dump) if self.on_screen(h)]
                if hits:
                    self.drv.tap(hits[-1]["x"], hits[-1]["y"])
                    # wait until it is really gone before looking again: a closing popover still lists 放弃改动 for a
                    # moment, and SwiftUI runs the button's action only after the close, so the ✕ also stays up till
                    # then. A second tap at that place went to the 状态 page under it, the 开始刷 row (y 146 pt), and
                    # brought the 「机器关着」 notice back (simulator video of the app-r1 offline run, 100.0-102.5 s:
                    # 放弃改动 tapped, popover gone at 101.5 with 待保存 2 项 still shown, edits gone and the notice up
                    # at 102.5)
                    self.invalidate()
                    if not self.wait_for(sel, 4, gone=True):
                        break
                    if sel == "放弃改动":
                        self.wait_for(DISCARD_SEL, 4, gone=True, region="top")
                    time.sleep(0.3)
                    break
            else:
                # iOS 27 draws a confirmationDialog attached to its button as a popover with no 取消 ("the cancel action
                # is implicit by tapping anywhere else", WWDC25 284): tap the right margin, outside the popover and the rows
                if self.drv.platform == "ios" and any(n.get("id") == "PopoverDismissRegion" or n["kind"] == "Popover"
                                                      for n in dump["nodes"]):
                    self.drv.tap(self.drv.size[0] - 6, self.drv.size[1] // 2)
                    time.sleep(0.8)
                    continue
                hits = self.find(DISCARD_SEL, dump, "top")
                if hits:
                    self.drv.tap(hits[0]["x"], hits[0]["y"])
                    time.sleep(0.8)
                    continue
                return

    def review_sheet_top(self, shot):
        """Android: the review sheet's top edge on the screen (px), from a screenshot; None when no sheet is up. The
        accessibility tree does not follow the sheet: uiautomator kept the large detent's bounds for 寄出 while the
        sheet stood at medium (0.5.2 r3), so a press aimed by the dump fell on the dimmed page and closed the sheet."""
        from PIL import Image
        self.drv.screenshot(shot)
        im = Image.open(shot).convert("RGB")
        if sum(im.getpixel((120, 180))) / 3 > 215:
            return None      # no scrim over the top bar: no sheet
        near = lambda y: all(abs(c - v) <= 6 for c, v in zip(im.getpixel((120, y)), (236, 235, 245)))
        for y in range(180, im.height - 30):
            if near(y) and near(y + 25):
                return y
        return None

    def sheet_steady(self, secs):
        """Android: the review sheet (open) stays at the medium detent, its top edge at the screen's middle, for secs.
        0.5.2 r5: it jumped between half and full height on its own (7 of 12 openings within 12 s, r5/sheet-watch.txt),
        as skip-ui took the first of a set whose order changed between evaluations of the view; the vendored patch
        shows the smallest detent (Vendor/skip-ui/VENDORED.md)."""
        if self.drv.platform != "android":
            raise StepFail("sheet_steady 只在安卓上跑")
        shot = os.path.join(self.out, "sheet-steady.png")
        mid = self.drv.size[1] // 2 - 1
        seen, t0 = [], time.time()
        while time.time() - t0 < secs:
            seen.append((round(time.time() - t0, 1), self.review_sheet_top(shot)))
        tops = sorted({t for _, t in seen}, key=str)
        self.note = f"{secs} 秒里截了 {len(seen)} 张，单子上沿 {'/'.join(str(t) for t in tops)} px（屏幕中线 {mid}）"
        if any(t is None for _, t in seen):
            raise StepFail("确认单中途不见了：" + self.note)
        if any(abs(t - mid) > 3 for _, t in seen):
            moved = [(a, t) for a, t in seen if abs(t - mid) > 3][:3]
            raise StepFail(f"确认单没停在半高、自己跳了：{moved}；" + self.note)

    def gate_trials(self, n, gap_ms, hold_ms):
        """Android 400 ms gate (SaveBar.swift go(): a press that began before opensAt does not send; opensAt is the sheet's
        onAppear + 400 ms). n trials: raw tap on ✓, after a gap a raw press on 寄出 held ~1.5 s, so the press begins inside
        the 400 ms and ends after the gate opened. Each trial is timed against the sheet window's own first frame (dumpsys
        gfxinfo framestats, the clock of the kernel touch times), and a screenshot taken while the press is held shows
        whether it reached 寄出 (its pressed state): the sheet slides in for ~600 ms and stops at the medium or the large
        detent, so an early press is on the button only some of the times. A trial that reached it, began under 380 ms
        and released on it would send but for the gate. None may send: judged by the mailbox here and by the app's own
        send log in gate.diag.check."""
        if self.drv.platform != "android":
            raise StepFail("gate_trials 只在安卓上跑")
        if "save" not in self.ctx:
            raise StepFail("门测试缺坐标（先跑记坐标的步骤）")
        x1, y1 = self.ctx["save"]
        self.ctx["gate_inwin"] = 0     # gate.diag.check judges only after trials that pressed inside the gate
        # a busy Mac stretches the emulator's touch handling and drawing by hundreds of ms (0.5.2 r3 at load 6-10: the
        # sheet's frames went missing for 7 of 8 trials and one early press sent; at load 5 no trial landed; at 2-4 they do)
        load = os.getloadavg()[0]
        if load >= 4.5:
            raise NoJudge(f"Mac 1 分钟负载 {load:.1f} ≥ 4.5，门测试没跑")

        shot = os.path.join(self.out, "gate-sheet.png")

        sheet_top = lambda: self.review_sheet_top(shot)

        BTN = 84     # 寄出's centre below the sheet's top edge (measured at both detents: 257 → 341, 1211 → 1295)

        def pressed(png, x, y):
            """Whether the screenshot taken while the press (at x, y) was held shows 寄出 in its pressed state (Material's
            pressed overlay fills the button's box: 0.66 of the box off the sheet colour against 0.09 unpressed, 0.5.2 r3)
            with the button settled under the finger. Both are needed: a sheet sliding up to the large detent can carry
            寄出 through the finger early on (pressed) and then away from it, and a release off the button sends nothing
            with or without the gate. Pressed and released on it, it would send unless the gate stopped it."""
            from PIL import Image
            im = Image.open(png).convert("RGB")
            if sum(im.getpixel((120, 180))) / 3 > 215:
                return False
            near = lambda p: all(abs(c - v) <= 6 for c, v in zip(p, (236, 235, 245)))
            top = next((y for y in range(180, im.height - 30)
                        if near(im.getpixel((120, y))) and near(im.getpixel((120, y + 25)))), None)
            if top is None:
                return False
            px = [im.getpixel((xx, yy)) for xx in range(x - 110, x + 110, 4) for yy in range(top + BTN - 75, top + BTN + 75, 4)]
            return sum(map(near, px)) / len(px) < 0.8 and abs(top + BTN - y) <= 50

        retaps = []

        def close_sheet():
            """Close the review sheet with its ✕ (再想想) and return only once it is gone. A tap on the ✕ is sometimes
            not taken: 0.5.2 r5 close-test, 1 of ~20 `input tap`s on the ✕'s centre left the sheet up and a second tap
            on the same point closed it (the button's action had not run), so the next trial's ✓ fell on the old
            sheet and its press on 寄出 sent (r4 and-gate4 / and-gate9: a sheet up for 16-17 s). So: up to three taps,
            each followed by a wait until the sheet is gone, then back; a sheet still up stops the trials (NoJudge).
            (This waited on 「确认这次修改」, the title before 64064c7, never waited, and the next ✓ fell on a sheet still
            going away.)"""
            for attempt in range(4):
                top = sheet_top()
                if top is None:
                    break
                if attempt:
                    retaps.append(attempt)
                if attempt < 3:
                    self.drv.tap(64, top + BTN)
                else:
                    self.drv.back()
                end = time.time() + 4
                while time.time() < end and sheet_top() is not None:
                    time.sleep(0.4)
            else:
                if sheet_top() is not None:
                    raise NoJudge("确认单点了三次 ✕ 又按了返回还关不掉")
            time.sleep(0.8)

        # where 寄出 sits: x from the tree, y at the medium detent, whose top edge is the screen's middle (1211 of 2424 on
        # ark37). Aimed there, a press on a large-detent sheet lands in its empty list and does nothing; aimed at the large
        # detent's button (y 341), it falls on the dimmed page over a medium sheet and closes it (0.5.2 r3)
        self.drv.tap(x1, y1)
        end = time.time() + 8
        top = None
        while top is None and time.time() < end:
            time.sleep(1.0)      # the sheet slides in for ~0.6 s; a busy Mac makes it slower
            top = sheet_top()
        if top is None:
            raise NoJudge("✓ 没点开确认单")
        self.invalidate()
        x2 = self.locate("寄出 1 项", scroll=False)["x"]
        y2 = self.drv.size[1] // 2 - 1 + BTN
        close_sheet()
        rows = []
        skipped = 0
        gone = 0
        gap = gap_ms
        for k in range(n):
            t = self.drv.gate_trial(x1, y1, x2, y2 + (k % 3), gap, hold_ms,
                                    shot=os.path.join(self.out, f"gate-trial{k + 1}-hold.png"))
            if len(t) < 4:
                raise StepFail(f"第 {k + 1} 次：getevent 没录到四次触摸（{len(t)}）")
            sheet = self.drv.sheet_frames(t[1])
            time.sleep(0.3)
            top = sheet_top()
            if top is None:
                # the sheet is gone after the release: the press sent (a gate failure, which the step's own checks then
                # read as 不对: the unsent change and the mailbox) or fell outside the sheet; no further trial
                gone = k + 1
                break
            if sheet is None:
                # gfxinfo sometimes lists no frames for the sheet's window (0.5.2 r3: 1 trial of 8, the sheet up): this
                # trial cannot be timed, so it is left out (not counted either way) and the next one runs
                skipped += 1
                close_sheet()
                continue
            first, drawn, nfr, settled = sheet
            on_button = pressed(os.path.join(self.out, f"gate-trial{k + 1}-hold.png"), x2, y2 + (k % 3))
            rows.append({"down_after_first": round(t[2] - first), "first_drawn": round(drawn - first),
                         "settled": round(settled - first), "up_after_first": round(t[3] - first),
                         "tap_to_first": round(first - t[1]), "on_button": on_button,
                         "pressed": (x2, y2), "sheet_top": top})
            # aim the next press 330 ms after the sheet's first frame began: inside the gate, late in the opening slide
            # (~600 ms on ark37), so a medium-detent sheet has 寄出 under the finger by then
            gap = max(0, gap + 330 - rows[-1]["down_after_first"])
            close_sheet()
        if gone:
            # nothing judged: the step's own checks still read 不对 if the change went out
            self.note = f"第 {gone} 次松手后确认单不在了；前面几次：{rows}"
            self.nojudge_reason = f"模拟器：第 {gone} 次松手后确认单不在了"
            return
        if not rows:
            raise NoJudge(f"{n} 次都没量到确认单的窗口帧")
        inwin = [r for r in rows if r["on_button"] and r["down_after_first"] < 380]
        self.note = (f"{n} 次（{'没量到单子帧、不算的 ' + str(skipped) + ' 次；' if skipped else ''}按到寄出上 {sum(r['on_button'] for r in rows)} 次）：按下距单子首帧开始 "
                     f"{'/'.join(str(r['down_after_first']) for r in rows)} ms，松手 {'/'.join(str(r['up_after_first']) for r in rows)} ms；"
                     f"单子首帧画完 {'/'.join(str(r['first_drawn']) for r in rows)} ms；"
                     f"按到停在手指下的寄出（按住时呈按下状态）且按下在 380 ms 内的 {len(inwin)} 次"
                     + (f"；关单时 ✕ 没接住、补点 {len(retaps)} 次" if retaps else ""))
        self.ctx["gate_rows"] = rows
        # only a press on the settled button that began inside the gate tests it: with none, a clean mailbox proves
        # nothing (r2 at Mac load 10: the first frame alone took 453-677 ms), so the step reads 不判 with the measured
        # times; a send from any trial still reads 不对 (run_step)
        self.ctx["gate_inwin"] = len(inwin)
        if not inwin:
            self.nojudge_reason = f"模拟器：{n} 次都没有在 380 ms 内按到寄出上"

    def own_link(self, old=False):
        """A 免输入链接 for the THROWAWAY mailbox (PhoneTab.swift PhoneLink.make: linkBase#k=base64url({"t","p"})); never
        the real one, so the app taking it from the clipboard keeps talking to the throwaway mailbox. old=True: the
        form copied before (PhoneLink.oldPageURL, the web page), which must still be taken."""
        import base64
        self.guard.check_publish(self.guard.topic)
        k = base64.urlsafe_b64encode(json.dumps({"t": self.guard.topic, "p": self.mb.pin}, separators=(",", ":")).encode()).decode().rstrip("=")
        return ("https://herclyon1.github.io/maa/" if old else "arkremote://link") + "#k=" + k

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

    def app_log(self, ready, secs=20):
        """The app's saved 诊断记录 (DiagLog, key ark-diag-events): [event dict]. DiagLog saves at most every 5 s, on the
        next event, and on export (分享诊断记录: DiagLog.exportObject -> persist), so this re-reads until ready(events)
        holds or secs pass. Returns (events, ready)."""
        deadline = time.time() + secs
        while True:
            raw = self.drv.read_default("ark-diag-events")
            try:
                ev = json.loads(raw) if raw else []
            except ValueError:
                ev = []
            ev = [e for e in ev if isinstance(e, dict)]
            if ready(ev):
                return ev, True
            if time.time() > deadline:
                return ev, False
            time.sleep(2)

    def app_posts(self, ev, a, b):
        """POSTs to the mailbox (url <ntfy host>/<信箱>) in the app's log between a and b (epoch s), less the ones the app
        sends on its own (BACKGROUND_ACTIONS: watch on open, refresh), as check_cmds leaves them out of every step. The
        log has no body, so each POST is paired with the mailbox's command nearest in time (ntfy's receive time, within
        3 s, each command once); a POST with no command near it is counted. Returns (counted, background) as
        [(t, status or error)]."""
        posts = sorted((e["t"] / 1000, e.get("status") or e.get("error") or "?") for e in ev
                       if e.get("kind") == "fetch" and e.get("method") == "POST" and "<信箱>" in (e.get("url") or "")
                       and a * 1000 <= e.get("t", 0) <= b * 1000)
        cmds = [[t, self.cmd_action(m), False] for t, m in self.mb.cmds(a - 5)]
        counted, background = [], []
        for t, st in posts:
            near = sorted((c for c in cmds if not c[2] and abs(c[0] - t) <= 3), key=lambda c: abs(c[0] - t))
            if near:
                near[0][2] = True
            (background if near and near[0][1] in BACKGROUND_ACTIONS else counted).append((t, st))
        return counted, background

    def check_app_posts(self, want):
        """want = {step id: 0 (no send) | n (at least n)}: the app's own send log during each of those steps' windows,
        background sends left out (app_posts). The log must be saved first: a step that opens 分享诊断记录 does that
        (DiagUI.prepareSheet -> persist). For the gate steps this waits for the gate decision the app logs on every
        release on 寄出 (SaveBar.swift go(), 「gate」 events: shown / down / now / open) instead of a later save by
        chance: gate.late's press must be there with open 1, and every gate.early press with open 0; a gate.early press
        that touched down under 400 ms after the sheet's first frame is one that tested the gate."""
        win = {k: self.windows[k] for k in want if k in self.windows}
        gates = lambda ev, k: [e for e in ev if e.get("kind") == "gate" and k in win
                               and (win[k][0] - 1) * 1000 <= e.get("t", 0) <= (win[k][1] + 2) * 1000]
        if "gate.late" in win:
            ready = lambda ev: any(e.get("open") == "1" for e in gates(ev, "gate.late"))
        else:   # no gate decision to wait on: the newest saved event must reach the last window's end
            last = max((w[1] for w in win.values()), default=time.time())
            ready = lambda ev: max((e.get("t", 0) for e in ev), default=0) / 1000 >= last
        ev, caught_up = self.app_log(ready)
        if not ev:
            raise StepFail("App 的诊断记录是空的（诊断记录没开？）")
        bad, said = [], []
        for k, n in want.items():
            if k not in win:
                bad.append(f"{k} 没跑")
                continue
            a, b = win[k]
            got, bg = self.app_posts(ev, a - 1, b + 2)
            said.append(f"{k} {len(got)} 条" + (f"（{', '.join(str(s) for _, s in got)}）" if got else "")
                        + (f"，另有后台 watch/refresh {len(bg)} 条不算" if bg else ""))
            if (n == 0 and got) or (n > 0 and len(got) < n):
                bad.append(f"{k} 应为 {'0' if n == 0 else '≥' + str(n)} 条，实际 {len(got)} 条")
        tested = 0
        if "gate.early" in win:
            g = gates(ev, "gate.early")
            opened = [e for e in g if e.get("open") == "1"]
            early = [e for e in g if int(e.get("shown") or 0) > 0
                     and (int(e.get("down") or 0) or int(e.get("now") or 0)) - int(e.get("shown")) < 400]
            tested = len(early)
            said.append(f"门测试松手在寄出上 {len(g)} 次，其中按下距单子首帧 < 400 ms 的 {tested} 次"
                        + (f"（{'/'.join(str((int(e.get('down') or 0) or int(e['now'])) - int(e['shown'])) for e in early)} ms）" if early else "")
                        + (f"，放行 {len(opened)} 次" if opened else ""))
            if opened:
                bad.append(f"门测试里门放行了 {len(opened)} 次（{', '.join(e.get('down', '?') + '-' + e.get('shown', '?') for e in opened)}）")
        if "gate.late" in win:
            gl = gates(ev, "gate.late")
            said.append(f"停稳后寄出的门记录 {len(gl)} 条（放行 {sum(e.get('open') == '1' for e in gl)}）")
            if not caught_up:
                bad.append("App 的诊断记录里没有停稳后寄出那一下的放行记录（诊断记录没存盘？）")
        self.note = "App 自己的记录：" + "；".join(said)
        if bad:
            raise StepFail("；".join(bad))
        # 「门测试 0 条」 says something only when a press reached 寄出 inside the 400 ms: by the app's own gate record, or
        # by gate_trials' screenshots when the record has none
        if "gate.early" in want and not tested and not self.ctx.get("gate_inwin"):
            self.nojudge_reason = "模拟器：门测试没有一次按在 400 ms 里，0 条不说明门拦住了"

    @staticmethod
    def cmd_action(m):
        b = m.get("body") or {}
        return b.get("action", "")

    def is_field(self, n):
        if self.drv.platform == "android":
            return n["kind"] == "EditText"
        return n["kind"] in ("TextField", "SecureTextField", "TextView")

    def machine_bool(self, want):
        """A step's switch value: True / False as written, or "machine:<game>:<path>" = the base state's value of that
        setting (the real machine's, read at the start of the run), "!machine:…" = its opposite. The machine's value is
        whatever he last set (10-15 he turned 使用刻写券 on), so a step about 「机器值」 cannot hard-code it."""
        if not isinstance(want, str):
            return want
        neg = want.startswith("!")
        _, game, path = want.lstrip("!").split(":", 2)
        v = (((self.mb.base.get("master") or {}).get(game) or {}).get("values") or {}).get(path)
        if not isinstance(v, bool):
            raise StepFail(f"机器状态里 {game} {path} 不是开关值：{v!r}")
        return (not v) if neg else v

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

    def tap_until_gone(self, sel, step):
        """Tap a confirmation's button (放弃改动 / 不再显示进度) until its sheet is gone. A sheet that comes up takes no
        touch for a moment (UIKit), so a first tap can be lost; but a sheet that is only closing slowly (a loaded Mac)
        still lists its button for a while, and a second tap at that place lands on the page under it (see dismiss()).
        So the button is tapped again only when the sheet is still up well after the last tap."""
        for _ in range(3):
            if not self.wait_for(sel, 4):
                raise StepFail(f"找不到「{sel}」")
            time.sleep(0.5)
            self.act(("tap", sel, {"last": True}), step)
            if self.wait_for(sel, 3, gone=True) or self.wait_for(sel, 6, gone=True):
                return
        raise StepFail(f"「{sel}」点了没关")

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

    def caret_to_end(self, target):
        """iOS: the tap that focuses a field leaves the cursor before its old value (循环执行 「99」: the deletes removed
        nothing and 「20」 typed read 「2099」, final pass 10-06 step 79), so tap the focused field once more at its right
        end, after its right-aligned digits, where a tap on a focused field puts the cursor. That spot under the
        keyboard's 完成 capsule is the overlap the capsule room (SkipFixes.swift KeyboardDoneBar) is there to prevent:
        不对, the number typed there would not be seen."""
        time.sleep(0.4)   # the list's scroll to the field runs with the keyboard's rise
        self.invalidate()
        nodes = self.dump(True)["nodes"]
        fields = [f for f in nodes if self.is_field(f) and self.on_screen(f) and abs(f["x"] - target["x"]) <= 6]
        if not fields:
            return
        f = min(fields, key=lambda f: abs(f["y"] - target["y"]))
        kb = [n for n in nodes if n["kind"] == "Keyboard" and n["h"] > 0]
        kb_top = min((n["y"] - n["h"] / 2 for n in kb), default=None)
        for b in nodes:
            if b["label"] != "完成" or b["kind"] != "Button" or kb_top is None or b["y"] < kb_top - 80:
                continue   # the keyboard's 完成, not the save bar's ✓ (also labelled 完成) at the top
            if b["y"] - b["h"] / 2 < f["y"] + f["h"] / 2 and f["x"] + f["w"] / 2 > b["x"] - b["w"] / 2:
                raise StepFail(f"框（y {f['y'] - f['h'] / 2:.0f}–{f['y'] + f['h'] / 2:.0f}）在键盘的「完成」"
                               f"（y {b['y'] - b['h'] / 2:.0f}–{b['y'] + b['h'] / 2:.0f}）下面")
        if not (f["value"] or "").strip():
            return
        self.drv.tap(f["x"] + f["w"] // 2 - 3, f["y"])
        time.sleep(0.3)
        self.invalidate()

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
                want = self.machine_bool(want)
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
            if step.get("group_gap") or step.get("header_gap") or step.get("large_title"):
                miss += self.check_layout(step, dump)
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
            # within 60 pt of it proves the page was scrolled to its end; a page shorter than the screen (鸣潮 since its
            # 周本 row is a Stepper, app-r1: footer at 767.5, 就是这里 at 830) ends higher, and the ("bottom") action
            # already saw a swipe move nothing, so only "above" is judged then
            near = self.ctx.get("at_end") or top - 60 <= b
            if not (near and b <= top + 1):
                return [f"最后一行下边 {b:g}，「{sel_text(step['last_above'])}」上边 {top:g}"]
        if step.get("last_bottom"):
            lo, hi = step["last_bottom"]
            if not (lo <= b <= hi):
                return [f"最后一行下边 {b:g}，应在 {lo}–{hi}"]
        return []

    def check_layout(self, step, dump):
        """Android only (regression list 0108 item 29, 「安卓那个间距太丑了」 10-07 21:0x).

        group_gap: [lo, hi] dp - every gap between two grouped sections with no header or footer text in it is in
        the range. header_gap: [lo, hi] dp - in every gap with text in it, the lowest text (the next section's header)
        ends this far above the next card (Settings, Android 17: 26 px = 9.9 dp under 「Lock display」). The cards are not in the uiautomator tree (Compose draws them), so the screenshot is read down one
        pixel column 22 dp inside the right edge (inside the cards' 16 dp inset and right of every row's own control):
        a pixel is ground when it matches the page ground at x = 8 px on the same row. Ground runs under 3 dp are row
        dividers. Reference: Settings on Android 17 (ark37, 10-14) draws its groups 16 dp apart (42 px at 420 dpi).
        large_title: sel - the tab's title is the large one in the top bar's second row (skip-ui's MediumTopAppBar with
        headlineLarge bold, Containers/Navigation.swift:505-515; AppBarMediumTokens.ContainerHeight = 112.0.dp), not an
        inline one: at least 40 dp tall, its top at
        least 100 dp down (status bar + Material's 64 dp collapsed row), its left edge 14-18 dp in (Material 3
        TopAppBarTitleInset = 16.dp, compose material3 AppBar.kt)."""
        if self.drv.platform != "android":
            return []
        d = self.drv.density
        miss, said = [], []
        if step.get("large_title"):
            hits = [n for n in self.find(step["large_title"], dump, "upper") if self.on_screen(n)]
            if not hits:
                miss.append(f"没有大标题「{sel_text(step['large_title'])}」")
            else:
                n = hits[0]
                left, top, h = (n["x"] - n["w"] / 2) / d, (n["y"] - n["h"] / 2) / d, n["h"] / d
                said.append(f"大标题 高 {h:.1f} dp、上边 {top:.1f} dp、左边 {left:.1f} dp")
                if h < 40 or top < 100 or not 14 <= left <= 18:
                    miss.append(f"「{sel_text(step['large_title'])}」不是大标题（高 {h:.1f}、上边 {top:.1f}、左边 {left:.1f} dp）")
        if step.get("group_gap") or step.get("header_gap"):
            path = os.path.join(self.out, f"layout-{step['id']}.png")
            self.drv.screenshot(path)
            texts = [n for n in dump["nodes"] if (n["texts"] or n["label"]) and n["h"] > 0]
            plain, titled = group_gaps(path, d, self.drv.content_box(dump["nodes"]), texts)
            for key, gaps, name in (("group_gap", plain, "分组间距"), ("header_gap", titled, "组标题到下一组")):
                if not step.get(key):
                    continue
                lo, hi = step[key]
                said.append(f"{name} " + ("、".join(f"{g:.1f}" for g in gaps) or "无") + " dp")
                if not gaps:
                    miss.append(f"屏幕上量不到{name}")
                bad = [g for g in gaps if not lo <= g <= hi]
                if bad:
                    miss.append(f"{name} {'、'.join(f'{g:.1f}' for g in bad)} dp，应在 {lo}–{hi}")
        self.note = "；".join(said) or None
        return miss

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
        # set by an action whose run could not test what the step claims (gate_trials); read only when nothing failed
        self.nojudge_reason = None
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
        except NoJudge as e:
            self.nojudge_reason = str(e)
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
        if ok and self.nojudge_reason:
            verdict = f"不判（{self.nojudge_reason}）"
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
           "receipt", "clear_receipts", "hb", "remember", "gate", "gate_trials", "app_posts", "sheet_steady", "shot", "clipboard", "forget_config", "restore_config", "fluency", "skland", "appearance",
           "dismiss", "discard", "clear", "pick", "tapout", "time", "see", "point", "allow_paste"}
STEP_KEYS = {"id", "page", "say", "do", "on", "expect", "absent", "visible", "keyboard", "cmd", "nocmd", "timeout", "cmd_timeout",
             "ios", "android", "always", "settle", "pause", "relaunch_on_crash", "switch", "offline",
             "skip", "nojudge", "nojudge_fail", "below", "last_above", "last_bottom", "group_gap", "header_gap", "large_title"}


def group_gaps(png, density, box, texts):
    """Down one pixel column 22 dp inside the right edge, within box (top, bottom): (plain, titled) in dp - plain, the
    gaps between two cards with no text node centred in them; titled, for each gap with text in it (a footer and / or
    the next section's header), the lowest text's bottom edge to the next card's top. Ground runs under 3 dp (row
    dividers) and runs not closed by a card on both sides are left out. See Runner.check_layout."""
    from PIL import Image   # Pillow: in Homebrew's python3 and ~/.local/bin/python3.14 on this Mac
    im = Image.open(png).convert("RGB")
    px = im.load()
    W = im.size[0]
    X, M = W - round(22 * density), 8
    top, bottom = box
    runs, cur, start = [], None, top
    for y in range(top, bottom):
        a, b = px[X, y], px[M, y]
        kind = "ground" if sum(abs(a[k] - b[k]) for k in range(3)) <= 6 else "card"
        if kind != cur:
            if cur:
                runs.append((cur, start, y))
            cur, start = kind, y
    runs.append((cur, start, bottom))
    plain, titled = [], []
    for k in range(1, len(runs) - 1):
        kind, a, b = runs[k]
        if kind != "ground" or runs[k - 1][0] != "card" or runs[k + 1][0] != "card" or b - a < 3 * density:
            continue
        inside = [n for n in texts if a <= n["y"] <= b]
        if not inside:
            plain.append((b - a) / density)
            continue
        # One block of text hugging the card above is that card's footer, and the next section has no header (方舟's
        # 作战 split into two cards, f8626ed: footer, then the untitled switches card 12.8 dp lower). Measuring it as a
        # header gap took the footer for a header. A header is a second block (after a footer) or a block that starts
        # well below the card above.
        rows = sorted(inside, key=lambda n: n["y"])
        one_block = all(q["y"] - q["h"] / 2 - (p["y"] + p["h"] / 2) <= 6 * density for p, q in zip(rows, rows[1:]))
        if one_block and rows[0]["y"] - rows[0]["h"] / 2 - a <= 12 * density:
            continue
        # the lowest text in the gap is the next section's header: its bottom edge to the next card's top
        titled.append((b - max(n["y"] + n["h"] / 2 for n in inside)) / density)
    return plain, titled


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
            os.makedirs(os.path.dirname(cache), exist_ok=True)   # with --out elsewhere, out/ may not exist yet
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
        try:   # 复制免输入链接 leaves this run's throwaway link on the clipboard and the app takes a #k= link on its next
            # cold start: on ark37 10-14 an arkremote://link intent opened after a full run was overridden by it
            drv.clear_clipboard()
        except Exception as e:
            print("剪贴板没清掉：", e)
        if prefs_saved:
            try:
                drv.prefs_restore(prefs_saved, launch=False)
                print("偏好已恢复（逐字节一致）")
            except Exception as e:
                print("偏好恢复失败：", e, "备份在", prefs_saved)
                rc = rc or 4
        if (local or r.ctx.get("skland")) and not prefs_saved:
            try:   # iOS: the simulator's app goes back to ntfy.sh and 森空岛 (Android: the defaults.xml restore above did it)
                drv.delete_defaults(([NTFY_BASE_KEY] if local else []) + (SKLAND_KEYS if r.ctx.get("skland") else []))
            except Exception:
                pass
        try:   # a run that turned dark mode on and stopped before turning it off
            if r.ctx.get("dark"):
                drv.appearance(False)
        except Exception:
            pass
        drv.stop()
        mb.stop()
        if local:
            local.stop()
        if r.ctx.get("skland"):
            r.ctx["skland"].stop()
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
