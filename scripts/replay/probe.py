#!/usr/bin/env python3
"""Step-authoring helper: keep one driver session open and run single actions against it.

  probe.py serve --platform ios --device <udid> --topic <throwaway> [--port 9390]   (keeps running)
  probe.py ui                       compact element list of the screen (text, kind, centre, size)
  probe.py do 'tap 查看全部'         one action in step-table form: tap / tab / toggle / field <sel> <text> / back /
                                    swipe up|down / hidekb / enter / state <variant> / hb <n> / relaunch / shot <name>
  probe.py cmds                     commands the app sent to the throwaway topic since serve started

  Android helpers (drv_android.py), as `probe.py do '<cmd>'`:
    time HH:MM [row selector]       tap the time button on the row (default: the first 「刷到几点」 / 「改成刷到几点」 row),
                                    dial the Material3 dialog to HH:MM, close it with back; prints the row's text
    inject <variant>                stop the app, write that state (base / dup / noef / ...) as its cached state, start it
    receipt <action> [queued]       add a receipt for <action> to the cached state, restart the app
    age <seconds>                   make the cached state that old (machine-off branch), restart the app
    backup / restore                save defaults.xml to out/probe-android/ / put it back byte for byte (app restarted)
    kbd / crash                     is the keyboard up (dumpsys input_method mInputShown) / crash lines since serve began

  serve uses the local ntfy server (ntfy_local.py, 127.0.0.1:8932, no daily quota) unless --ntfy-public.
  serve --offline: post nothing to ntfy (anonymous quota used up): no quota check, states go into the app's cache
  (mailbox.OfflineMailbox), heartbeats are dropped, `cmds` is empty. serve backs up defaults.xml before it resets
  the app's keys and, with --restore, puts the backup back when it stops.

The serve process applies the same guard as run.py (refuses the real mailbox; writes the throwaway config before the
first launch) and re-checks the stored mailbox after every action.
"""
import argparse
import http.server
import json
import os
import signal
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def serve(a):
    import guard as guardmod
    import mailbox as mbmod
    import run as runmod
    g = guardmod.Guard(a.topic)
    cache = os.path.join(HERE, "out", "state-base.json")
    if a.state:
        base = json.load(open(a.state, encoding="utf-8"))
    elif os.path.exists(cache):
        base = json.load(open(cache, encoding="utf-8"))
    else:
        base = mbmod.fetch_real_state(g.real_topic_for_read())
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        json.dump(base, open(cache, "w", encoding="utf-8"), ensure_ascii=False)
    out = os.path.join(HERE, "out", f"probe-{a.platform}")
    os.makedirs(out, exist_ok=True)
    if a.platform == "ios":
        from drv_ios import IOSDriver
        drv = IOSDriver(a.device, out)
    else:
        from drv_android import AndroidDriver
        drv = AndroidDriver(a.serial, out)
    if a.offline:
        if not hasattr(mbmod, "OfflineMailbox"):
            raise SystemExit("--offline needs mailbox.OfflineMailbox")
        mb = mbmod.OfflineMailbox(g, a.topic, a.pin, base, drv)
        print("offline: nothing is posted to ntfy", flush=True)
    elif not a.ntfy_public:
        import atexit
        import ntfy_local
        local = ntfy_local.LocalNtfy(log=lambda m: print(m, flush=True)).start()
        atexit.register(local.stop)   # stops only the PID it started
        mb = mbmod.Mailbox(g, a.topic, a.pin, base, server=local.url)
    else:
        mb = mbmod.Mailbox(g, a.topic, a.pin, base)
        print("ntfy quota", mbmod.quota(), flush=True)
    args = argparse.Namespace(timeout=8, verbose=True)
    r = runmod.Runner(args, drv, mb, g, out)
    t0 = time.time()
    r.t_run0 = t0
    drv.start()
    drv.terminate()
    drv.clear_clipboard()
    raw = drv.read_default("ark-remote-cfg")
    stored = json.loads(raw).get("topic") if raw else None
    g.check_app_topic(stored)
    backup = None
    if a.platform == "android":
        backup = drv.prefs_backup(os.path.join(out, "defaults-before-serve.xml"))
        print("defaults.xml backed up to", backup, flush=True)
    drv.delete_defaults(runmod.RESET_KEYS)
    drv.write_default("ark-remote-cfg", json.dumps({"topic": a.topic, "pin": a.pin}, separators=(",", ":")))
    drv.write_default("ark-diag-bucket", runmod.DIAG_BLACKHOLE)
    if not a.offline and not a.ntfy_public:
        drv.write_default(runmod.NTFY_BASE_KEY, ntfy_local.base_for(a.platform))
    r.check_stored_config()
    mb.listen(t0 - 5)
    mb.publish_state("base")
    mb.hb(300)
    if not drv.current_pid():
        drv.launch()
    marker0 = drv.log_marker() if a.platform == "android" else None
    print("probe ready on port", a.port, flush=True)

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            try:
                res = handle(body)
            except Exception as e:
                res = f"ERROR {type(e).__name__}: {e}"
            self.send_response(200)
            self.end_headers()
            self.wfile.write(res.encode())

    def handle(body):
        if body == "reload":
            import importlib
            import drv_ios
            import drv_android
            for m in (guardmod, runmod, drv_ios, drv_android):
                importlib.reload(m)
            drv.__class__ = (drv_ios.IOSDriver if a.platform == "ios" else drv_android.AndroidDriver)
            r.__class__ = runmod.Runner
            return "reloaded"
        if body == "uiall":
            d = r.dump(True)
            return "\n".join(f'{n["kind"][:12]:12} {n["x"]:4},{n["y"]:4} {n["w"]}x{n["h"]} chk={n["checked"]} {" | ".join(n["texts"])[:90]}' for n in d["nodes"])
        if body == "ui":
            d = r.dump(True)
            lines = [f"state={d['state']} size={drv.size} box={drv.content_box(d['nodes'])}"]
            for n in d["nodes"]:
                if n["texts"] or n["kind"] in ("Switch", "Toggle", "TextField", "EditText", "Button", "Keyboard", "TabBar", "NavigationBar"):
                    extra = "" if n["checked"] is None else (" ON" if n["checked"] else " off")
                    lines.append(f'{n["kind"][:12]:12} {n["x"]:4},{n["y"]:4} {n["w"]}x{n["h"]}{extra} {" | ".join(n["texts"])[:90]}')
            return "\n".join(lines)
        if body.startswith("step "):
            import importlib
            import steps as stepsmod
            importlib.reload(stepsmod)
            ids = body.split()[1:]
            plan = runmod.select_steps(stepsmod.STEPS, a.platform)
            if len(ids) == 2 and ids[0].endswith(".."):
                # "step a.. b": run from a to b
                i0 = [s["id"] for s in plan].index(ids[0][:-2])
                i1 = [s["id"] for s in plan].index(ids[1])
                chosen = plan[i0:i1 + 1]
            else:
                chosen = [s for s in plan if s["id"] in ids or any(i.endswith("*") and s["id"].startswith(i[:-1]) for i in ids)]
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                for k, st in enumerate(chosen, 1):
                    r.invalidate()
                    r.run_step(k, st)
            return buf.getvalue()
        if body == "cmds":
            return "\n".join(f"{ts} {json.dumps(m.get('body'), ensure_ascii=False)}" for ts, m in mb.cmds(t0))
        parts = body.split(" ", 1)
        kind, rest = parts[0], (parts[1] if len(parts) > 1 else "")
        if a.platform == "android" and kind in ANDROID_HELPERS:
            res = android_helper(kind, rest)
            r.invalidate()
            r.check_stored_config()
            return res
        if kind == "field":
            sel, text = rest.rsplit(" ", 1)
            act = ("field", sel, text)
        elif kind in ("swipe",):
            act = ("swipe", rest or "up", 1)
        elif kind in ("hb",):
            act = ("hb", int(rest or 300))
        elif kind in ("back", "hidekb", "enter", "relaunch"):
            act = (kind,)
        else:
            act = (kind, rest) if rest else (kind,)
        r.invalidate()
        r.act(act, {})
        r.check_stored_config()
        return "ok"

    ANDROID_HELPERS = {"time", "inject", "receipt", "age", "backup", "restore", "kbd", "crash"}

    def android_helper(kind, rest):
        import re
        if kind == "time":
            hhmm, _, row = rest.partition(" ")
            hh, mm = (int(x) for x in hhmm.split(":"))
            row = row or ["刷到几点（机器时间）", "改成刷到几点（机器时间）"]
            n = r.locate(row)
            nodes = r.dump(False)["nodes"]
            btn = [b for b in nodes if b["texts"] and re.fullmatch(r"\d{1,2}:\d\d(?: [AP]M)?", b["texts"][0])
                   and abs(b["y"] - n["y"]) <= max(n["h"], b["h"]) and b["x"] > n["x"]]
            if not btn:
                return f"ERROR no time button on the row of {row}"
            drv.tap(btn[0]["x"], btn[0]["y"])
            time.sleep(1.0)
            got = drv.set_time_dialog(hh, mm)
            r.invalidate()
            now = [b["texts"][0] for b in r.dump(True)["nodes"] if b["texts"] and re.fullmatch(r"\d{1,2}:\d\d(?: [AP]M)?", b["texts"][0])]
            want = drv.time_label(hh, mm, drv.clock_24h())
            return f"dialog {got}; row {now}; want {want} -> {'ok' if want in now else 'MISMATCH'}"
        if kind == "inject":
            mb.guard.check_publish(mb.topic)
            body = drv.inject_state(mb.variant(rest or "base", r.ctx.get("receipts")))
            return f"injected {rest or 'base'} at {body['at']}"
        if kind == "receipt":
            act, _, q = rest.partition(" ")
            rc = mb.receipt_for({"body": {"action": act}, "ts": time.time()}, queued=bool(q))
            drv.inject_receipt(rc)
            return f"receipt {json.dumps(rc, ensure_ascii=False)}"
        if kind == "age":
            body = drv.age_state(int(rest or 3600))
            return f"cached state at {body['at']}"
        if kind == "backup":
            return "backed up to " + drv.prefs_backup(os.path.join(out, "defaults-probe.xml"))
        if kind == "restore":
            drv.prefs_restore(rest or os.path.join(out, "defaults-probe.xml"))
            return "restored"
        if kind == "kbd":
            return f"keyboard up: {drv.keyboard_up([])}"
        if kind == "crash":
            return "\n".join(drv.crashed_since(marker0)) or "no crash"
        return "ERROR"

    try:
        http.server.ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
    finally:
        drv.terminate()
        if a.restore and backup:
            drv.prefs_restore(backup, launch=False)
            print("defaults.xml restored from", backup, flush=True)
        drv.stop()
        mb.stop()


def client(port, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body.encode(), method="POST")
    print(urllib.request.urlopen(req, timeout=300).read().decode())


def _term(*_):
    raise KeyboardInterrupt   # SIGTERM runs the same cleanup as Ctrl-C (stop the app and the XCUITest runner)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _term)
    p = argparse.ArgumentParser()
    p.add_argument("cmd")
    p.add_argument("rest", nargs="*")
    p.add_argument("--platform", default="ios")
    p.add_argument("--device")
    p.add_argument("--serial", default="emulator-5554")
    p.add_argument("--topic")
    p.add_argument("--pin", default="0000")
    p.add_argument("--state")
    p.add_argument("--offline", action="store_true", help="post nothing to ntfy (states go into the app's cache)")
    p.add_argument("--ntfy-public", action="store_true", help="use ntfy.sh instead of the local ntfy server (ntfy_local.py)")
    p.add_argument("--restore", action="store_true", help="Android: put the backed-up defaults.xml back when serve stops")
    p.add_argument("--port", type=int, default=int(os.environ.get("PROBE_PORT", "9390")))
    a = p.parse_args()
    if a.cmd == "serve":
        serve(a)
    elif a.cmd == "step":
        client(a.port, "step " + " ".join(a.rest))
    elif a.cmd in ("ui", "uiall", "cmds", "reload"):
        client(a.port, a.cmd)
    elif a.cmd == "do":
        client(a.port, " ".join(a.rest))
