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
        self.sh(f"am start -n {PKG}/.MainActivity")
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
        for k in keys:
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

    def hide_keyboard(self):
        if self.keyboard_up([]):
            self.back()

    def gate_press(self, x1, y1, x2, y2, gap_ms, hold_ms):
        self.sh(f"input tap {x1} {y1}; sleep {gap_ms / 1000:.3f}; input motionevent DOWN {x2} {y2}; "
                f"sleep {hold_ms / 1000:.3f}; input motionevent UP {x2} {y2}")

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
