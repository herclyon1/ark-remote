"""iOS simulator driver: xcrun simctl + the XCUITest runner in xcuitest/ (real HID touches, element tree).

The runner long-polls a small HTTP server run here (127.0.0.1:<port>) for command batches and posts the results back,
so no files are read out of the simulator. Coordinates are points.
"""
import glob
import http.server
import json
import os
import plistlib
import queue
import subprocess
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = "com.herclyon.arkremote"


class _Hub:
    def __init__(self):
        self.cmds = queue.Queue()
        self.results = queue.Queue()
        self.polled = threading.Event()


def _handler(hub):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            body = ""
            if self.path.startswith("/next"):
                hub.polled.set()
                try:
                    body = hub.cmds.get(timeout=40)
                except queue.Empty:
                    body = ""
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body.encode())

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(n).decode()
            if self.path.startswith("/result"):
                hub.results.put(data)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
    return H


class IOSDriver:
    platform = "ios"

    def __init__(self, udid, out_dir, port=None, log=print):
        self.udid = udid
        self.out = out_dir
        self.port = port or (9400 + int(udid.replace("-", "")[:6], 16) % 90)
        self.log = log
        self.hub = _Hub()
        self.server = None
        self.proc = None
        self.dd = os.path.join(HERE, "out", "xcdd")   # shared build cache (xctestrun embeds absolute paths)
        self.size = (402, 874)

    # ---- simctl
    def simctl(self, *a, check=False, timeout=60):
        return subprocess.run(["xcrun", "simctl", *a], capture_output=True, text=True, timeout=timeout, check=check)

    def install(self, path):
        r = self.simctl("install", self.udid, path, timeout=300)
        if r.returncode:
            raise RuntimeError("simctl install failed: " + r.stderr[-400:])

    def terminate(self):
        """Stop the app and wait until its process is gone, so a defaults write / delete that follows is not undone
        by the app's own last write (a deleted ark-remote-cfg came back once: run 10-05 22:5x, clip.first.empty)."""
        self.simctl("terminate", self.udid, BUNDLE)
        t_end = time.time() + 5
        while time.time() < t_end:
            r = self.simctl("spawn", self.udid, "launchctl", "list")
            if "UIKitApplication:" + BUNDLE not in (r.stdout or ""):
                break
            time.sleep(0.3)
        time.sleep(0.3)

    def launch(self):
        r = self.simctl("launch", self.udid, BUNDLE)
        if r.returncode:
            raise RuntimeError("simctl launch failed: " + r.stderr[-400:])

    def installed(self):
        return self.simctl("get_app_container", self.udid, BUNDLE).returncode == 0

    def booted(self):
        out = self.simctl("list", "devices", "-j").stdout
        for devs in json.loads(out)["devices"].values():
            for d in devs:
                if d["udid"] == self.udid:
                    return d["state"] == "Booted"
        return False

    def screenshot(self, path):
        self.simctl("io", self.udid, "screenshot", path)

    # The app's preferences live in two places on the simulator: its data container's Library/Preferences/<bundle>.plist
    # (everything the app itself writes) and the simulator home's domain <bundle> (what `simctl spawn defaults <bundle>`
    # reads and writes). The app reads the container first and falls back to the home domain, so a key the app once
    # wrote in its container shadows any home-domain write or delete (10-05 23:1x: a deleted ark-remote-cfg kept the app
    # configured; the stored mailbox the guard reads must be the container's). Reads take the container first; writes
    # go to the container and clear the home copy; deletes clear both.
    def _container_prefs(self):
        r = self.simctl("get_app_container", self.udid, BUNDLE, "data")
        if r.returncode:
            return None
        return os.path.join(r.stdout.strip(), "Library", "Preferences", BUNDLE)

    def _defaults(self, *a):
        return self.simctl("spawn", self.udid, "defaults", *a)

    def read_default(self, key):
        path = self._container_prefs()
        if path:
            r = self._defaults("read", path, key)
            if r.returncode == 0:
                return r.stdout.strip()
        r = self._defaults("read", BUNDLE, key)
        return r.stdout.strip() if r.returncode == 0 else None

    def read_defaults_all(self, key):
        """Every stored copy of key: [(where, value)] - the guard checks all of them."""
        out = []
        path = self._container_prefs()
        for where, dom in (("container", path), ("home", BUNDLE)):
            if dom:
                r = self._defaults("read", dom, key)
                if r.returncode == 0:
                    out.append((where, r.stdout.strip()))
        return out

    def write_default(self, key, value):
        path = self._container_prefs()
        r = self._defaults("write", path or BUNDLE, key, "-string", value)
        if r.returncode:
            raise RuntimeError("defaults write failed: " + r.stderr[-300:])
        if path:
            self._defaults("delete", BUNDLE, key)

    def delete_defaults(self, keys):
        path = self._container_prefs()
        for k in keys:
            if path:
                self._defaults("delete", path, k)
            self._defaults("delete", BUNDLE, k)

    def clear_clipboard(self):
        # an EMPTY pasteboard (simctl pbcopy always leaves a string): the app reads a #k= link from the clipboard on
        # foreground, and its iOS detectPatterns path traps when the pasteboard holds any string (see steps.py)
        return self.call("pbclear")[0]

    def set_clipboard(self, text):
        self.call("pbset " + text)

    def crash_reports(self):
        return set(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/ArkRemote*")))

    # ---- runner
    def build_runner(self):
        xctestrun = glob.glob(os.path.join(self.dd, "Build/Products/*.xctestrun"))
        src = os.path.join(HERE, "xcuitest/ReplayDriverUITests/ReplayUITests.swift")
        if xctestrun and os.path.getmtime(xctestrun[0]) > os.path.getmtime(src):
            return
        self.log("building the XCUITest runner (once) ...")
        with open(os.path.join(HERE, "out", "xcbuild.log"), "w") as lf:
            r = subprocess.run(["xcodebuild", "build-for-testing", "-project", os.path.join(HERE, "xcuitest/ReplayDriver.xcodeproj"),
                                "-scheme", "ReplayDriverUITests", "-destination", "generic/platform=iOS Simulator",
                                "-derivedDataPath", self.dd], stdout=lf, stderr=subprocess.STDOUT)
        if r.returncode:
            raise RuntimeError("XCUITest runner build failed, see out/xcbuild.log")

    def start(self):
        os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
        self.build_runner()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), _handler(self.hub))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.spawn_runner()

    def spawn_runner(self):
        """Start (again) the XCUITest runner: an XCTest failure inside a command (an element gone between query and
        use) ends the test and so the runner; the run goes on with a new one (each in its own log)."""
        self.runs = getattr(self, "runs", 0) + 1
        self.hub.polled.clear()
        while not self.hub.cmds.empty():
            self.hub.cmds.get_nowait()
        env = dict(os.environ, TEST_RUNNER_REPLAY_URL=f"http://127.0.0.1:{self.port}", TEST_RUNNER_REPLAY_BUNDLE=BUNDLE)
        name = "xcuitest-runner.log" if self.runs == 1 else f"xcuitest-runner-{self.runs}.log"
        self.runner_log = open(os.path.join(self.out, name), "w")
        self.proc = subprocess.Popen(["xcodebuild", "test-without-building", "-project", os.path.join(HERE, "xcuitest/ReplayDriver.xcodeproj"),
                                      "-scheme", "ReplayDriverUITests", "-destination", f"id={self.udid}", "-derivedDataPath", self.dd,
                                      "-only-testing:ReplayDriverUITests/ReplayUITests/testReplay"],
                                     env=env, stdout=self.runner_log, stderr=subprocess.STDOUT)
        if not self.hub.polled.wait(240):
            raise RuntimeError("the XCUITest runner did not come up in 240 s (see xcuitest-runner.log)")
        self.log(f"XCUITest runner up (pid {self.proc.pid}, port {self.port})")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.hub.cmds.put("quit")
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.terminate()     # our own xcodebuild child only
                try:
                    self.proc.wait(10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        if self.server:
            self.server.shutdown()

    def runner_ended(self):
        if self.proc and self.proc.poll() is not None:
            return True
        try:
            with open(self.runner_log.name, errors="ignore") as f:
                return "Tear Down" in f.read()
        except OSError:
            return False

    def restart_runner(self, why):
        if self.runs >= 6:
            raise RuntimeError(f"the XCUITest runner ended again ({why}); 5 restarts used up")
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()         # our own xcodebuild child only
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.spawn_runner()

    def call(self, batch, timeout=60):
        if self.runner_ended():
            self.restart_runner("before " + batch[:30])
        while not self.hub.results.empty():
            self.hub.results.get_nowait()
        self.hub.cmds.put(batch)
        t_end = time.time() + timeout
        while True:
            try:
                res = self.hub.results.get(timeout=2)
                break
            except queue.Empty:
                if self.runner_ended():
                    log = os.path.basename(self.runner_log.name)
                    self.restart_runner(batch[:30])
                    raise RuntimeError(f"XCUITest runner 在「{batch[:30]}」时结束（XCTest 失败，见 {log}），已重启")
                if time.time() > t_end:
                    raise RuntimeError(f"runner did not answer in {timeout} s: {batch[:60]}")
        return [ln.split("\t", 1)[1] if "\t" in ln else "" for ln in res.split("\n")]

    # ---- the common driver interface
    def dump(self):
        raw = self.call("ax")[0]
        d = json.loads(raw)
        nodes = []
        for t, label, ident, value, x, y, w, h, en, sel in d["els"]:
            nodes.append({"texts": [s for s in (label, "" if t in ("Switch", "Toggle") else value) if s], "label": label, "value": value,
                          "id": ident, "kind": t, "x": x, "y": y, "w": w, "h": h, "enabled": en, "selected": sel,
                          "checked": (value == "1") if t in ("Switch", "Toggle") else None})
        for n in nodes:
            if n["kind"] == "Application" and n["w"] > 0:
                self.size = (n["w"], n["h"])
        return {"state": d["state"], "nodes": nodes}

    def alive(self, dump=None):
        st = dump["state"] if dump else int(self.call("state")[0] or 0)
        return st == 4

    def content_box(self, nodes):
        """(top, bottom) of the scrollable content: below the navigation bar, above the tab bar / keyboard."""
        top, bottom = 100, self.size[1] - 90
        for n in nodes:
            if n["kind"] == "TabBar" and n["h"] > 0:
                bottom = min(bottom, n["y"] - n["h"] // 2)
            if n["kind"] == "Keyboard" and n["h"] > 0:
                bottom = min(bottom, n["y"] - n["h"] // 2)
            if n["kind"] == "NavigationBar" and n["h"] > 0:
                top = max(top, n["y"] + n["h"] // 2)
        return top, bottom

    def tap(self, x, y, hold_ms=50):
        self.call(f"tap {x} {y} {hold_ms}")

    def swipe(self, x0, y0, x1, y1, ms=300):
        mid = ((x0 + x1) // 2, (y0 + y1) // 2)
        self.call(f"path {x0},{y0},0|{x0},{y0 + (y1 - y0) // 10},30|{mid[0]},{mid[1]},{ms // 2}|{x1},{y1},{ms // 2}|{x1},{y1},120")

    def type(self, text):
        res = self.call("type " + text)[0]
        if res.startswith("error"):
            raise RuntimeError(f"type: {res}")

    def clear_field(self, n=12):
        res = self.call(f"del {n}")[0]
        if res.startswith("error"):
            raise RuntimeError(f"del: {res}")

    def back(self):
        return self.call("back")[0]

    def gate_press(self, x1, y1, x2, y2, gap_ms, hold_ms):
        """Tap (x1, y1), then gap_ms after that tap lifts press (x2, y2) and hold it hold_ms."""
        self.call(f"tap {x1} {y1} 40\nwait {gap_ms}\ntap {x2} {y2} {hold_ms}")

    def log_marker(self):
        return self.crash_reports()

    def crashed_since(self, marker):
        new = self.crash_reports() - marker
        return sorted(new)

    def wait_keyboard(self, timeout=4):
        t = time.time()
        while time.time() - t < timeout:
            if any(n["kind"] == "Keyboard" for n in self.dump()["nodes"]):
                time.sleep(0.2)
                return True
            time.sleep(0.2)
        return False

    def keyboard_up(self, nodes):
        # a keyboard sliding away stays in the tree for a while below the screen edge: count it only while it shows
        H = self.size[1]
        return any(n["kind"] == "Keyboard" and n["h"] > 0 and n["y"] - n["h"] / 2 < H - 40 for n in nodes)
