"""Android emulator driver: adb input + uiautomator dump (derived from the pass-1 driver). Coordinates are pixels.

The app's UserDefaults are Skip's SharedPreferences file shared_prefs/defaults.xml. The release APK is not debuggable,
so reading / writing it needs `adb root` (Google APIs emulator images allow it; Google Play images do not).
"""
import html
import os
import re
import subprocess
import time
import xml.sax.saxutils as su

PKG = "com.herclyon.arkremote"
PREFS = f"/data/data/{PKG}/shared_prefs/defaults.xml"


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

    def adb(self, *a, timeout=60, binary=False):
        r = subprocess.run([self.adb_bin, "-s", self.serial, *a], capture_output=True, timeout=timeout)
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
        pass

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
    def dump(self):
        out = ""
        for _ in range(4):
            out = self.adb("exec-out", "uiautomator", "dump", "/dev/tty", timeout=30)
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
        safe = text.replace(" ", "%s")
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

    def gate_press(self, x1, y1, x2, y2, gap_ms, hold_ms):
        self.sh(f"input tap {x1} {y1}; sleep {gap_ms / 1000:.3f}; input motionevent DOWN {x2} {y2}; "
                f"sleep {hold_ms / 1000:.3f}; input motionevent UP {x2} {y2}")

    # ---- the 400 ms gate, measured (raw touches + the app's own frame stats)
    def touch_dev(self):
        """/dev/input/eventN of the touchscreen InputReader maps to the main display (Touch Input Mapper mode DIRECT)."""
        if getattr(self, "_touch_dev", None):
            return self._touch_dev
        text = self.sh("dumpsys input")
        path = None
        # InputReader lists "  Device N: <name>" blocks with their mappers; EventHub lists "    N: <name>" then "Path:"
        for block in re.split(r"\n  Device \d+: ", text)[1:]:
            if "Touch Input Mapper (mode - DIRECT)" in block:
                name = block.split("\n", 1)[0].strip()
                m = re.search(r"\n\s+\d+: " + re.escape(name) + r"\n(?:[^\n]*\n){0,12}?\s+Path: (/dev/input/event\d+)", text)
                if m:
                    path = m.group(1)
                    break
        if not path:
            raise RuntimeError("no DIRECT touchscreen in dumpsys input")
        self._touch_dev = path
        return path

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

    # ---- crash check
    def log_marker(self):
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
