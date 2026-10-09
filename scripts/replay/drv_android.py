"""Android emulator driver: adb input + uiautomator dump (derived from the pass-1 driver). Coordinates are pixels; the
runner finds every element by its text / content-desc in dump() (run.py find / locate), never by a fixed position.

The app's UserDefaults are Skip's SharedPreferences file shared_prefs/defaults.xml. The release APK is not debuggable,
so reading / writing it needs `adb root` (Google APIs emulator images allow it; Google Play images do not).
"""
import html
import json
import os
import re
import subprocess
import threading
import time
import xml.sax.saxutils as su

PKG = "com.herclyon.arkremote"
PREFS = f"/data/data/{PKG}/shared_prefs/defaults.xml"


class GateUnavailable(RuntimeError):
    """Raw touches cannot be written on this device: the 400 ms gate is not judged here."""


class Profile:
    """REPLAY_PROFILE=1: time every adb call by kind and every time.sleep (the runner's too), per step. A step starts at
    run.py run_step's drv.log_marker() call; each finished step is one line of <out>/profile.jsonl:
    {"step", "wall", "kinds": {kind: [calls, seconds]}, "sleep": [calls, seconds], "sleep_sites": {"file:line func":
    [calls, seconds]}, "rest": wall - adb - sleep}."""
    KINDS = (("uiautomator dump", "dump"), ("input tap", "tap"), ("input motionevent", "tap"), ("input text", "text"),
             ("input keyevent", "key"), ("input swipe", "swipe"), ("screencap", "screencap"), ("pidof", "pidof"),
             ("logcat", "logcat"), ("dumpsys input_method", "kb"), ("dumpsys", "dumpsys"), ("defaults.xml", "prefs"),
             ("date ", "date"), ("am start", "launch"), ("am force-stop", "stop"), ("push", "push"), ("install", "install"))

    def __init__(self, path):
        self.path = path
        self.step, self.t0, self.kinds, self.sleep, self.sites = None, None, {}, [0, 0.0], {}
        self._sleep = time.sleep
        prof = self

        def sleep(s):
            t = time.time()
            prof._sleep(s)
            if threading.current_thread() is threading.main_thread():   # not the mailbox listener's retries
                dt = time.time() - t
                prof.sleep[0] += 1
                prof.sleep[1] += dt
                import sys
                f = sys._getframe(1)
                site = prof.sites.setdefault(f"{os.path.basename(f.f_code.co_filename)}:{f.f_lineno} {f.f_code.co_name}", [0, 0.0])
                site[0] += 1
                site[1] += dt
        time.sleep = sleep      # the runner calls time.sleep through the module too

    def kind(self, argv):
        s = " ".join(argv)
        return next((k for pat, k in self.KINDS if pat in s), "other")

    def add(self, argv, dt):
        k = self.kinds.setdefault(self.kind(argv), [0, 0.0])
        k[0] += 1
        k[1] += dt

    def mark(self, step):
        now = time.time()
        if self.step is not None:
            adb = sum(v[1] for v in self.kinds.values())
            row = {"step": self.step, "wall": round(now - self.t0, 3),
                   "kinds": {k: [v[0], round(v[1], 3)] for k, v in sorted(self.kinds.items())},
                   "sleep": [self.sleep[0], round(self.sleep[1], 3)],
                   "sleep_sites": {k: [v[0], round(v[1], 3)] for k, v in self.sites.items()},
                   "rest": round(now - self.t0 - adb - self.sleep[1], 3)}
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.step, self.t0, self.kinds, self.sleep, self.sites = step, now, {}, [0, 0.0], {}


def find_adb():
    for p in (os.environ.get("ADB"), os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"), "adb"):
        if p and (p == "adb" or os.path.exists(p)):
            return p
    return "adb"


class AndroidDriver:
    platform = "android"

    def __init__(self, serial, out_dir, log=print):
        self.serial = serial
        self.out = out_dir
        self.log = log
        self.adb_bin = find_adb()
        self.size = (1080, 2400)
        self.pid = None
        self.prof = Profile(os.path.join(out_dir, "profile.jsonl")) if os.environ.get("REPLAY_PROFILE") == "1" else None

    def adb(self, *a, timeout=60, binary=False):
        t = time.time()
        r = subprocess.run([self.adb_bin, "-s", self.serial, *a], capture_output=True, timeout=timeout)
        if any(c in s for s in a for c in self.INPUT_CMDS):
            self._last_input = time.time()
        if self.prof:
            self.prof.add(a, time.time() - t)
        return r.stdout if binary else r.stdout.decode("utf-8", "replace")

    def sh(self, cmd, timeout=60):
        return self.adb("shell", cmd, timeout=timeout)

    # ---- device / app
    def booted(self):
        return self.sh("getprop sys.boot_completed").strip() == "1"

    def ensure_root(self):
        if self.sh("id -u").strip() == "0":
            return True
        out = self.adb("root", timeout=30)
        time.sleep(2)
        self.adb("wait-for-device", timeout=60)
        if self.sh("id -u").strip() != "0":
            raise RuntimeError("adb root is not available on this device (" + out.strip()[:120] + "); "
                               "the guard cannot read the app's stored mailbox, refusing to run")
        return True

    def start(self):
        if not self.booted():
            raise RuntimeError(f"{self.serial} is not booted")
        self.ensure_root()
        m = re.search(r"(\d+)x(\d+)", self.sh("wm size"))
        if m:
            self.size = (int(m.group(1)), int(m.group(2)))

    def stop(self):
        self._dumper_stop()
        if self.prof:
            self.prof.mark(None)

    def install(self, path):
        out = self.adb("install", "-r", path, timeout=300)
        if "Success" not in out:
            raise RuntimeError("adb install failed: " + out[-300:])

    def installed(self):
        return f"package:{PKG}" in self.sh(f"pm list packages {PKG}")

    def terminate(self):
        self.sh(f"am force-stop {PKG}")
        self.pid = None

    def launch(self):
        if not getattr(self, "activity", None):
            lines = [l.strip() for l in self.sh(f"cmd package resolve-activity --brief {PKG}").splitlines() if "/" in l]
            self.activity = lines[-1] if lines else f"{PKG}/ark.remote.MainActivity"
        self.sh(f"am start -n {self.activity}")
        for _ in range(40):
            p = self.sh(f"pidof {PKG}").strip()
            if p:
                self.pid = p
                return
            time.sleep(0.25)
        raise RuntimeError("the app did not start")

    def current_pid(self):
        return self.sh(f"pidof {PKG}").strip() or None

    def screenshot(self, path):
        with open(path, "wb") as f:
            f.write(self.adb("exec-out", "screencap", "-p", binary=True))

    def clear_clipboard(self):
        # the app takes a #k= link copied in the last 10 minutes; make sure the clipboard holds nothing like that
        self.sh("cmd clipboard set-text ark-replay 2>/dev/null || true")

    def set_clipboard(self, text):
        self.sh(f"cmd clipboard set-text '{text}' 2>/dev/null || true")

    # ---- SharedPreferences (app must be stopped while writing)
    def _prefs(self):
        return self.sh(f"cat {PREFS} 2>/dev/null")

    def read_default(self, key):
        m = re.search(r'<string name="%s">(.*?)</string>' % re.escape(su.escape(key)), self._prefs(), re.S)
        return html.unescape(m.group(1)) if m else None

    def write_default(self, key, value):
        xml = self._prefs()
        line = '<string name="%s">%s</string>' % (su.escape(key, {'"': "&quot;"}), su.escape(value, {'"': "&quot;"}))
        pat = re.compile(r'<string name="%s">.*?</string>' % re.escape(su.escape(key)), re.S)
        if not xml.strip():
            xml = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n    %s\n</map>\n" % line
        elif pat.search(xml):
            xml = pat.sub(lambda _: line, xml)
        elif "<map />" in xml:
            xml = xml.replace("<map />", "<map>\n    %s\n</map>" % line)
        else:
            xml = xml.replace("</map>", "    %s\n</map>" % line)
        self._push_prefs(xml)

    def _push_prefs(self, xml):
        owner = self.sh(f"stat -c %u:%g /data/data/{PKG}").strip()
        tmp = os.path.join(self.out, "defaults.xml")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(xml)
        self.adb("push", tmp, "/data/local/tmp/ark-replay-defaults.xml")
        os.remove(tmp)
        self.sh(f"mkdir -p /data/data/{PKG}/shared_prefs && cp /data/local/tmp/ark-replay-defaults.xml {PREFS} && "
                f"rm /data/local/tmp/ark-replay-defaults.xml && chown -R {owner} /data/data/{PKG}/shared_prefs && "
                f"chmod 660 {PREFS} && restorecon -R /data/data/{PKG}/shared_prefs 2>/dev/null; true")

    def delete_defaults(self, keys):
        xml = self._prefs()
        if not xml.strip():
            return
        n0 = len(xml)
        for k in list(keys) + ["__unrepresentable__:" + k for k in keys]:
            ek = re.escape(su.escape(k))
            xml = re.sub(r'\s*<(\w+) name="%s"(?:[^>]*?/>|[^>]*>.*?</\1>)' % ek, "", xml, flags=re.S)
        if len(xml) != n0:
            self._push_prefs(xml)

    # ---- element tree
    # The resident dumper (dumper/ReplayDumper.java): the same XML as `uiautomator dump`, the same 1 s idle wait, without
    # the ~0.86 s process start + accessibility connect each `uiautomator dump` pays. One UiAutomation connection at a
    # time per device: while it is up, a `uiautomator dump` from elsewhere is killed. On by default (paired runs 10-06
    # 23:36 / 23:40, status + arknights: 253 s -> 184 s, 34 verdicts identical); REPLAY_DUMPER=0 keeps the old path.
    # If it cannot start or stops answering, dump() falls back to `uiautomator dump` for the rest of the run.
    DUMPER_DEX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dumper", "replay-dumper.dex")
    DUMPER_IDLE_MS = (1000, 10000)   # DumpCommand's waitForIdle(1000, 10000)
    DUMPER_SETTLE = 1.9              # s after the last input before the tree is read (a `uiautomator dump`'s floor)
    INPUT_CMDS = ("input ", "am start", "am force-stop", "/dev/input/")

    def _dumper(self):
        if getattr(self, "_dp", None) is not None:
            return self._dp if self._dp.poll() is None else None
        if os.environ.get("REPLAY_DUMPER") == "0" or getattr(self, "_dp_off", False) or not os.path.exists(self.DUMPER_DEX):
            return None
        self.adb("push", self.DUMPER_DEX, "/data/local/tmp/replay-dumper.dex", timeout=30)
        self._dp = subprocess.Popen(
            [self.adb_bin, "-s", self.serial, "shell", "CLASSPATH=/system/framework/uiautomator.jar:"
             "/data/local/tmp/replay-dumper.dex exec app_process /system/bin ReplayDumper"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self._dp_buf = b""
        self._dp_pid = None
        if self._dp_read(b"<<REPLAY-READY ", 20) is None or (pid := self._dp_read(b">>\n", 5)) is None:
            self._dumper_off("did not start")
            return None
        self._dp_pid = pid.decode().strip()
        return self._dp

    def _dp_read(self, marker, timeout):
        """Bytes from the dumper up to marker (marker excluded); None on timeout / exit."""
        import select
        end, fd = time.time() + timeout, self._dp.stdout.fileno()
        while marker not in self._dp_buf:
            left = end - time.time()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                return None
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                return None
            self._dp_buf += chunk
        out, self._dp_buf = self._dp_buf.split(marker, 1)
        return out

    def _dumper_off(self, why):
        self.log(f"resident dumper off ({why}); using `uiautomator dump`")
        self._dp_off = True
        self._dumper_stop()

    def _dumper_stop(self):
        """Close the dumper; its device process holds the device's one UiAutomation slot, so when it does not leave on
        its own (stuck in waitForIdle / getRootInActiveWindow) kill it there too: otherwise every fallback
        `uiautomator dump` is killed."""
        dp, self._dp = getattr(self, "_dp", None), None
        if dp is None:
            return
        try:
            dp.stdin.close()
            dp.wait(timeout=3)
        except Exception:
            dp.kill()
        pid = getattr(self, "_dp_pid", None)
        if pid and pid.isdigit():
            self.sh(f"kill -9 {pid} 2>/dev/null; true", timeout=10)

    def _dump_xml(self):
        dp = self._dumper()
        if dp is None:
            return self.adb("exec-out", "uiautomator", "dump", "/dev/tty", timeout=30)
        t = time.time()
        try:
            settle = max(0.0, getattr(self, "_last_input", 0) + self.DUMPER_SETTLE - time.time())
            dp.stdin.write(("%d %d %d\n" % ((int(settle * 1000),) + self.DUMPER_IDLE_MS)).encode())
            dp.stdin.flush()
        except OSError:
            self._dumper_off("pipe closed")
            return self._dump_xml()
        raw = self._dp_read(b"\n<<REPLAY-END ", 30)
        tail = self._dp_read(b">>\n", 5) if raw is not None else None
        if self.prof:
            self.prof.add(("uiautomator dump",), time.time() - t)
        if raw is None or tail is None:
            self._dumper_off("no answer in 30 s")
            return self._dump_xml()
        return raw.decode("utf-8", "replace") if tail.startswith(b"ok") else ""

    def dump(self):
        out = ""
        for _ in range(4):
            out = self._dump_xml()
            if "<hierarchy" in out:
                break
            time.sleep(0.3)
        nodes = []
        for m in re.finditer(r"<node ([^>]*?)/?>", out):
            at = dict(re.findall(r'(\S+?)="([^"]*)"', m.group(1)))
            b = list(map(int, re.findall(r"-?\d+", at.get("bounds", "[0,0][0,0]"))))
            x0, y0, x1, y1 = b if len(b) == 4 else (0, 0, 0, 0)
            t, d = html.unescape(at.get("text", "")), html.unescape(at.get("content-desc", ""))
            if at.get("package") and at.get("package") != PKG and at.get("package") != "android":
                continue
            nodes.append({"texts": [s for s in (t, d) if s], "label": t or d, "value": t, "id": at.get("resource-id", ""),
                          "kind": at.get("class", "").split(".")[-1], "x": (x0 + x1) // 2, "y": (y0 + y1) // 2,
                          "w": x1 - x0, "h": y1 - y0, "enabled": at.get("enabled") == "true",
                          "selected": at.get("selected") == "true",
                          "checked": (at.get("checked") == "true") if at.get("checkable") == "true" else None,
                          "clickable": at.get("clickable") == "true", "focused": at.get("focused") == "true"})
        pkg_ok = f'package="{PKG}"' in out
        return {"state": 4 if pkg_ok else 0, "nodes": nodes, "raw_ok": "<hierarchy" in out}

    def alive(self, dump=None):
        p = self.current_pid()
        return bool(p) and (self.pid is None or p == self.pid)

    def content_box(self, nodes):
        h = self.size[1]
        return int(h * 0.11), int(h * 0.86)

    def keyboard_up(self, nodes):
        return "mInputShown=true" in self.sh("dumpsys input_method | grep mInputShown")

    # ---- input
    def tap(self, x, y, hold_ms=50):
        if hold_ms > 200:
            self.sh(f"input motionevent DOWN {x} {y}; sleep {hold_ms / 1000:.3f}; input motionevent UP {x} {y}")
        else:
            self.sh(f"input tap {x} {y}")

    def swipe(self, x0, y0, x1, y1, ms=300):
        self.sh(f"input swipe {x0} {y0} {x1} {y1} {ms}")

    def type(self, text):
        """`input text`, then read the focused field back: in the offline pass (2026-10-05 21:52, Mac load ~6) 「CE-6」
        typed into 关卡 right after 理智药 arrived as 「CE」. When the focused EditText does not end with the text,
        clear it and type once more."""
        safe = text.replace(" ", "%s")
        self.sh(f"input text '{safe}'")
        for _ in range(2):
            time.sleep(0.3)
            f = [n for n in self.dump()["nodes"] if n["kind"] == "EditText" and n["focused"]]
            if not f or f[0]["value"].endswith(text):
                return
            self.clear_field(len(f[0]["value"]) + 2)
            self.sh(f"input text '{safe}'")

    def clear_field(self, n=12):
        self.sh("input keyevent KEYCODE_MOVE_END; input keyevent " + " ".join(["KEYCODE_DEL"] * n))

    def back(self):
        self.sh("input keyevent KEYCODE_BACK")
        return "ok"

    def wait_keyboard(self, timeout=4):
        t = time.time()
        while time.time() - t < timeout:
            if self.keyboard_up([]):
                time.sleep(0.4)      # the input connection follows the keyboard
                return True
            time.sleep(0.2)
        return False

    def hide_keyboard(self):
        if self.keyboard_up([]):
            self.back()

    # ---- the Material3 time picker dialog (skip-ui RenderTimePicker, DatePicker.swift:235-246)
    # The 「刷到几点」 / 「改成刷到几点」 rows are a text button showing the time in the phone's 12/24-hour format
    # ("8:30 AM" / "08:30"). Tapping it opens a dialog with only a TimePicker: no OK / Cancel, every change is written
    # back at once, back / a tap outside closes it. uiautomator sees (ark37, en-US, 2026-10-05):
    #   header  View 'Select hour' > TextView '08' desc "8 o'clock"; View 'Select minutes' > TextView '30' desc
    #           '30 minutes'; View 'Select AM or PM' > TextView 'AM' / 'PM' (12-hour only; `selected` is not exposed)
    #   dial    hour mode: Views desc "12 o'clock" .. "11 o'clock" (24-hour: also the inner ring);
    #           minute mode: Views desc '0 minutes', '5 minutes' .. '55 minutes'
    def clock_24h(self):
        """The phone shows 24-hour times (settings time_12_24 = 24); unset = the locale's default (en-US: 12-hour)."""
        return self.sh("settings get system time_12_24").strip() == "24"

    @staticmethod
    def time_label(hh, mm, h24=False):
        """The row's text for HH:MM: "8:30 AM" / "12:05 AM" (12-hour) or "08:30" (24-hour)."""
        if h24:
            return f"{hh:02d}:{mm:02d}"
        return f"{hh % 12 or 12}:{mm:02d} {'AM' if hh < 12 else 'PM'}"

    def _descs(self, nodes, pat):
        out = []
        for n in nodes:
            for t in n["texts"]:
                m = re.fullmatch(pat, t)
                if m:
                    out.append((int(m.group(1)), n))
        return out

    @staticmethod
    def _dial_point(marks, value, per_turn):
        """Where `value` sits on a dial whose labelled marks are [(value, node)]: centre = mean of the marks, radius =
        their mean distance, 0 at the top, clockwise."""
        import math
        cx = sum(n["x"] for _, n in marks) / len(marks)
        cy = sum(n["y"] for _, n in marks) / len(marks)
        r = sum(math.hypot(n["x"] - cx, n["y"] - cy) for _, n in marks) / len(marks)
        a = 2 * math.pi * (value % per_turn) / per_turn
        return int(round(cx + r * math.sin(a))), int(round(cy - r * math.cos(a)))

    def time_dialog_open(self, nodes=None):
        nodes = nodes if nodes is not None else self.dump()["nodes"]
        return any("Select hour" in n["texts"] for n in nodes)

    def set_time_dialog(self, hh, mm, close=True):
        """With the time dialog open, dial it to hh:mm (24-hour values) by the dial's own labels: tap the hour header,
        the hour on the dial, the minute on the dial (multiples of 5 by label, others by angle), AM / PM. Checks the
        header reads hh:mm, then closes the dialog with back when close. Returns the header as "HH:MM[ AM|PM]"."""
        nodes = self.dump()["nodes"]
        if not self.time_dialog_open(nodes):
            raise RuntimeError("the time dialog is not open (no 'Select hour')")
        h24 = not any(n["texts"] == ["AM"] for n in nodes)
        head = [n for n in nodes if "Select hour" in n["texts"]][0]
        self.tap(head["x"], head["y"])
        time.sleep(0.6)
        nodes = self.dump()["nodes"]
        want_h = hh if h24 else (hh % 12 or 12)
        hours = [(v, n) for v, n in self._descs(nodes, r"(\d+) (?:o'clock|hours?)") if not n["value"]]
        hit = [n for v, n in hours if v == want_h or (h24 and v % 24 == want_h % 24)]
        if hit:
            self.tap(hit[0]["x"], hit[0]["y"])
        elif len(hours) >= 3 and not h24:
            self.tap(*self._dial_point(hours, want_h, 12))
        else:
            raise RuntimeError(f"hour {want_h} not on the dial ({len(hours)} labels)")
        time.sleep(0.6)
        nodes = self.dump()["nodes"]
        mins = [(v, n) for v, n in self._descs(nodes, r"(\d+) minutes?") if not n["value"]]
        if not mins:      # the picker did not move on to minutes by itself
            sel = [n for n in nodes if "Select minutes" in n["texts"]]
            if sel:
                self.tap(sel[0]["x"], sel[0]["y"])
                time.sleep(0.6)
                nodes = self.dump()["nodes"]
                mins = [(v, n) for v, n in self._descs(nodes, r"(\d+) minutes?") if not n["value"]]
        if len(mins) < 3:
            raise RuntimeError("the minute dial did not show")
        hit = [n for v, n in mins if v == mm]
        if hit:
            self.tap(hit[0]["x"], hit[0]["y"])
            time.sleep(0.5)
        else:
            # a tap on the minute dial snaps to a multiple of 5 (tapping at 7 gave 05); a drag keeps single minutes
            # but lands about one short (a drag ending at 7 gave 06): drag from the previous label, re-aim by the miss
            aim = mm + 0.5
            for _ in range(4):
                x0, y0 = self._dial_point(mins, mm - mm % 5, 60)
                x1, y1 = self._dial_point(mins, aim, 60)
                self.swipe(x0, y0, x1, y1, 400)
                time.sleep(0.6)
                cur = self._descs([n for n in self.dump()["nodes"] if n["value"]], r"(\d+) minutes?")
                if not cur or cur[0][0] == mm:
                    break
                aim += mm - cur[0][0]
        if not h24:
            nodes = self.dump()["nodes"]
            ap = [n for n in nodes if n["texts"] == ["AM" if hh < 12 else "PM"]]
            if not ap:
                raise RuntimeError("no AM / PM in the dialog")
            self.tap(ap[0]["x"], ap[0]["y"])
            time.sleep(0.5)
        nodes = self.dump()["nodes"]
        hv = [n["value"] for n in nodes if n["value"] and "Select hour" not in n["texts"] and self._descs([n], r"(\d+) (?:o'clock|hours?)")]
        mv = [n["value"] for n in nodes if n["value"] and self._descs([n], r"(\d+) minutes?")]
        got = f"{hv[0] if hv else '?'}:{mv[0] if mv else '?'}"
        want = f"{want_h:02d}:{mm:02d}"
        if got != want:
            raise RuntimeError(f"the dialog reads {got}, wanted {want}")
        if close:
            self.back()
            time.sleep(0.6)
        # the selected AM / PM is not exposed in the tree; the row's text after closing shows it
        return got if h24 else f"{got} {'AM' if hh < 12 else 'PM'}"

    # ---- cached machine state (offline: the ntfy quota is spent, the app's mailbox host is fixed)
    # The app keeps the newest machine state it saw in UserDefaults ark-remote-cfg-snap (Net.swift:275 snapKey, the
    # state body as JSON text, "at" = the machine's epoch seconds) and shows it on the next launch until something
    # newer arrives from ntfy / COS. Writing it needs the app stopped (it rewrites the file from memory). Only the
    # one key is rewritten (write_default replaces <string name=KEY> by name): pass 8 rewrote every "at": in the file
    # and broke ark-monthcard's 13-digit ms. ark-remote-hb is a Double stored as raw long bits next to an int
    # __unrepresentable__:ark-remote-hb = 1; these helpers never touch it (writing it needs both entries).
    SNAP_KEY = "ark-remote-cfg-snap"

    def prefs_backup(self, path=None):
        """Copy the whole defaults.xml to out/ (path) as the original to restore. Returns the path."""
        path = path or os.path.join(self.out, "defaults-backup.xml")
        raw = self._prefs()
        if not raw.strip():
            raise RuntimeError("defaults.xml is empty or unreadable (adb root?)")
        with open(path, "w", encoding="utf-8") as f:
            f.write(raw)
        self._prefs_backup = path
        return path

    def prefs_restore(self, path=None, launch=True):
        """Stop the app, put the backed-up defaults.xml back byte for byte, start the app again."""
        path = path or getattr(self, "_prefs_backup", None) or os.path.join(self.out, "defaults-backup.xml")
        with open(path, encoding="utf-8") as f:
            xml = f.read()
        self.terminate()
        self._push_prefs(xml)
        if self._prefs() != xml:
            raise RuntimeError("defaults.xml differs from the backup after the restore")
        if launch:
            self.launch()

    def read_snap(self):
        raw = self.read_default(self.SNAP_KEY)
        return json.loads(raw) if raw else None

    def _write_snap(self, body, launch):
        self.terminate()
        self.write_default(self.SNAP_KEY, json.dumps(body, ensure_ascii=False, separators=(",", ":")))
        if launch:
            self.launch()

    def inject_state(self, body, at=None, launch=True):
        """Stop the app, store `body` (a machine state object; "at" set to `at` or now) as the cached state, relaunch."""
        body = dict(body)
        body["at"] = int(at if at is not None else time.time())
        self._write_snap(body, launch)
        return body

    def inject_receipt(self, receipt, launch=True):
        """Append a receipt (mailbox.receipt_for shape) to relay.最近指令 of the cached state, at = now, relaunch."""
        body = self.read_snap()
        if body is None:
            raise RuntimeError("no cached state to add a receipt to")
        body.setdefault("relay", {}).setdefault("最近指令", []).append(receipt)
        return self.inject_state(body, launch=launch)

    def age_state(self, seconds_ago, launch=True):
        """Make the cached state `seconds_ago` old (the machine-off branch reads its age); only its top-level "at"."""
        body = self.read_snap()
        if body is None:
            raise RuntimeError("no cached state to age")
        return self.inject_state(body, at=time.time() - seconds_ago, launch=launch)

    def gate_press(self, x1, y1, x2, y2, gap_ms, hold_ms):
        self.sh(f"input tap {x1} {y1}; sleep {gap_ms / 1000:.3f}; input motionevent DOWN {x2} {y2}; "
                f"sleep {hold_ms / 1000:.3f}; input motionevent UP {x2} {y2}")

    # ---- the 400 ms gate, measured (raw touches + the app's own frame stats)
    def touch_dev(self, wait_s=15):
        """/dev/input/eventN of the touchscreen InputReader maps to the main display (Touch Input Mapper mode DIRECT).

        ark37 (API 37) lists eleven virtio_input_multi_touch_N devices; ten belong to the emulator's extra (virtual)
        displays and read `mode - DISABLED`, one (virtio_input_multi_touch_1 = /dev/input/event1 on 2026-10-05) is
        DIRECT. Right after a boot / snapshot load InputReader may not have configured the viewport yet and every
        touch mapper reads DISABLED (out/probe-and.log 17:2x), so poll up to wait_s; then fall back to the device whose
        Motion Ranges X span the display width. Raises GateUnavailable when none is found: the 400 ms gate steps then
        fail on their own and the run goes on (the manual passes already ruled the gate unjudgeable on the emulator,
        which draws 2-3 frames a second)."""
        if getattr(self, "_touch_dev", None):
            return self._touch_dev
        end = time.time() + wait_s
        text = ""
        while True:
            text = self.sh("dumpsys input")
            path = self._touch_path(text, direct=True)
            if path or time.time() > end:
                break
            time.sleep(1)
        path = path or self._touch_path(text, direct=False)
        if not path:
            raise GateUnavailable("no DIRECT touchscreen in dumpsys input (gate not judged on this emulator)")
        self._touch_dev = path
        return path

    def _touch_path(self, text, direct=True):
        """EventHub path of an InputReader device: direct=True the one whose touch mapper is DIRECT; direct=False the
        one with a TOUCHSCREEN source whose X motion range spans the display width."""
        for block in re.split(r"\n  Device -?\d+: ", text)[1:]:
            name = block.split("\n", 1)[0].strip()
            if direct:
                if "Touch Input Mapper (mode - DIRECT)" not in block:
                    continue
            else:
                m = re.search(r"\n\s+X: source=[^\n]*TOUCHSCREEN[^\n]*max=([\d.]+)", block)
                if not m or abs(float(m.group(1)) - (self.size[0] - 1)) > 2:
                    continue
            m = re.search(r"\n\s+-?\d+: " + re.escape(name) + r"\n(?:[^\n]*\n){0,12}?\s+Path: (/dev/input/event\d+)", text)
            if m:
                return m.group(1)
        return None

    def gate_supported(self):
        """True when raw touches can be written (a touchscreen device was found)."""
        try:
            self.touch_dev(wait_s=3)
            return True
        except GateUnavailable:
            return False

    def _touch_blob(self, path, events):
        """Write raw input_event structs (arm64: timeval 16 bytes, type u16, code u16, value s32) to a device file; one
        `cat blob > /dev/input/eventN` is then one write, so a press lands within a millisecond (six sendevent calls
        took 150-450 ms)."""
        import struct
        data = b"".join(struct.pack("<qqHHi", 0, 0, t, c, v) for t, c, v in events)
        local = os.path.join(self.out, os.path.basename(path))
        with open(local, "wb") as f:
            f.write(data)
        self.adb("push", local, path, timeout=30)

    def _down_events(self, x, y, tid):
        w, h = self.size
        return [(3, 47, 0), (3, 57, tid), (3, 53, x * 32767 // w), (3, 54, y * 32767 // h), (3, 58, 60), (0, 0, 0)]

    def gate_trial(self, x1, y1, x2, y2, gap_ms, hold_ms):
        """Raw touches: tap (x1, y1), wait gap_ms, press (x2, y2) for hold_ms. Returns the kernel times (ms, CLOCK_MONOTONIC,
        the clock of the frame stats) of [tap down, tap up, press down, press up], read from a getevent -t running alongside."""
        d = self.touch_dev()
        self._touch_blob("/data/local/tmp/replay-a.bin", self._down_events(x1, y1, 11))
        self._touch_blob("/data/local/tmp/replay-b.bin", self._down_events(x2, y2, 12))
        self._touch_blob("/data/local/tmp/replay-u.bin", [(3, 47, 0), (3, 57, -1), (0, 0, 0)])
        self.sh("dumpsys gfxinfo %s reset > /dev/null" % PKG)
        t = "/data/local/tmp/replay-"
        script = (f"D={d}; rm -f {t}ge.txt; getevent -t $D > {t}ge.txt & GP=$!; sleep 0.4; "
                  f"cat {t}a.bin > $D; sleep 0.06; cat {t}u.bin > $D; sleep {gap_ms / 1000:.3f}; cat {t}b.bin > $D; "
                  f"sleep {hold_ms / 1000:.3f}; cat {t}u.bin > $D; sleep 0.3; kill $GP; cat {t}ge.txt")
        out = self.sh(script, timeout=30)
        syn = [float(m.group(1)) * 1000 for m in re.finditer(r"\[\s*([\d.]+)\]\s+0000 0000 00000000", out)]
        return syn[:4]

    def frame_windows(self):
        """dumpsys gfxinfo framestats: [{"name", "frames": [{column: ns}, ...]}] per window of the app (a sheet is its own window)."""
        text = self.sh(f"dumpsys gfxinfo {PKG} framestats")
        wins, cur, hdr, inprof = [], None, None, False
        for ln in text.splitlines():
            if ln.startswith("Window: "):
                cur = {"name": ln[8:], "frames": []}
                wins.append(cur)
            elif ln.startswith("---PROFILEDATA---"):
                inprof, hdr = not inprof, None
            elif inprof and cur is not None:
                if ln.startswith("Flags,"):
                    hdr = ln.rstrip(",").split(",")
                elif hdr:
                    v = ln.rstrip(",").split(",")
                    if len(v) >= len(hdr):
                        try:
                            cur["frames"].append(dict(zip(hdr, map(int, v))))
                        except ValueError:
                            pass
        return wins

    def sheet_frames(self, after_ms):
        """Frames of the window that first drew after after_ms (the sheet's dialog window), as
        (first frame traversal start ms, first frame completed ms, number of frames); None if no such window."""
        best = None
        for i, w in enumerate(self.frame_windows()):
            fr = [f for f in w["frames"] if f.get("PerformTraversalsStart", 0) > 0]
            if i == 0 or not fr or not (fr[0].get("Flags", 0) & 1):
                continue      # window 0 is the activity; a new window's first frame carries flag 1
            t0 = fr[0]["PerformTraversalsStart"] / 1e6
            if t0 < after_ms - 50:
                continue
            cand = (t0, fr[0]["FrameCompleted"] / 1e6, len(fr))
            if best is None or cand[0] < best[0]:
                best = cand
        return best

    # ---- 400 ms gate moments logged by a DEBUG build (gatelog-1006: EWLive.swift `#if DEBUG` logger.info("ArkGate ..."))
    def gate_log(self, marker):
        """The app's ArkGate lines since marker, oldest first: [(event, {key: int})], event in sheet-up, gate-open,
        press-down, go, go-blocked, go-send. Values are RecKit.mono() ms (one clock inside the app). A release build
        logs none (returns [])."""
        out = []
        for ln in self.sh(f"logcat -d -b main -T '{marker}'").splitlines():
            m = re.search(r"ArkGate (\S+)(.*)$", ln)
            if not m:
                continue
            kv = {k: (v == "true") if v in ("true", "false") else int(v)
                  for k, v in re.findall(r"(\w+)=(-?\d+|true|false)", m.group(2))}
            out.append((m.group(1), kv))
        return out

    # ---- crash check
    def log_marker(self):
        if self.prof:
            import sys
            f = sys._getframe(1)
            if f.f_code.co_name == "run_step":
                self.prof.mark(f.f_locals["step"]["id"])
        return self.sh("date '+%m-%d %H:%M:%S.000'").strip()

    def crashed_since(self, marker):
        lines = []
        crash = self.sh(f"logcat -d -b crash -T '{marker}'")
        fatal = self.sh(f"logcat -d -b main -T '{marker}' '*:F'")
        for ln in (crash + "\n" + fatal).splitlines():
            parts = ln.split()
            ours = PKG in ln or (self.pid is not None and len(parts) > 2 and parts[2] == str(self.pid))
            if ours and ("FATAL" in ln or "Fatal signal" in ln or (len(parts) > 4 and parts[4] == "F")):
                lines.append(ln.strip())
        pid_gone = self.pid is not None and self.current_pid() != self.pid
        if pid_gone:
            lines.append(f"app process {self.pid} gone (now {self.current_pid()})")
        return lines
