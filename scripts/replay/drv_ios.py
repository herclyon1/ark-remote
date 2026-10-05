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
        self.simctl("terminate", self.udid, BUNDLE)

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

    def read_default(self, key):
        r = self.simctl("spawn", self.udid, "defaults", "read", BUNDLE, key)
        return r.stdout.strip() if r.returncode == 0 else None

    def write_default(self, key, value):
        r = self.simctl("spawn", self.udid, "defaults", "write", BUNDLE, key, "-string", value)
        if r.returncode:
            raise RuntimeError("defaults write failed: " + r.stderr[-300:])

    def delete_defaults(self, keys):
        for k in keys:
            self.simctl("spawn", self.udid, "defaults", "delete", BUNDLE, k)

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
        env = dict(os.environ, TEST_RUNNER_REPLAY_URL=f"http://127.0.0.1:{self.port}", TEST_RUNNER_REPLAY_BUNDLE=BUNDLE)
        self.runner_log = open(os.path.join(self.out, "xcuitest-runner.log"), "w")
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

    def call(self, batch, timeout=60):
        if self.proc and self.proc.poll() is not None:
            raise RuntimeError("the XCUITest runner exited (see xcuitest-runner.log)")
        while not self.hub.results.empty():
            self.hub.results.get_nowait()
        self.hub.cmds.put(batch)
        try:
            res = self.hub.results.get(timeout=timeout)
        except queue.Empty:
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
        self.call("type " + text)

    def clear_field(self, n=12):
        self.call(f"del {n}")

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
        return any(n["kind"] == "Keyboard" for n in nodes)
