#!/usr/bin/env python3.14
"""check-apk-install.py <apk> [--serial emulator-5554] - the release APK stays small and quick to install.

Regression 0108 #13. The owner, 10-02 17:1x, on installing an update: 「反正在我小米手机上是特别慢的。」 (the phone's
system check of the install package). Install time grows with the package: the installer reads and verifies every byte
and, with compressed native libraries (Android/app/build.gradle.kts packaging, useLegacyPackaging = true), extracts the
.so files. The APK was ~33.8 MB when he said it (v0.3.0-0.3.3) and has stayed there since the arm64-only / stripped /
compressed / minified work (v0.5.1 34,197,803 bytes). This check stops it from growing again, which nothing else did:
  1. size: the APK must stay under MAX_BYTES (another ABI added ~130 MB, uncompressed libraries ~60 MB);
  2. install time on the emulator: the APK is pushed once, then `pm install -r` is timed RUNS times on the device (the
     device-side part: verification, extraction, dexopt) and the median must stay under MAX_INSTALL_S. Judged only while
     the Mac's 1-minute load is under 8 before and after (a busy Mac slows the emulator, not the APK).
Exit 0 = both under their caps, 1 = over a cap, 2 = could not judge (no device, Mac busy, install failed).
"""
import argparse, os, statistics, subprocess, sys, time

MAX_BYTES = 36_000_000      # 0.5.2: 34,242,809; ~5 % headroom over the size he found slow, then stop
MAX_INSTALL_S = 7.2         # the one earlier emulator measurement (regression list row 13: 「只在模拟器量过 7.2 秒」)
RUNS = 3
PKG = "com.herclyon.arkremote"
ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")


def adb(serial, *a, timeout=180):
    return subprocess.run([ADB, "-s", serial, *a], capture_output=True, text=True, timeout=timeout)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("apk")
    p.add_argument("--serial", default="emulator-5554")
    p.add_argument("--size-only", action="store_true", help="only the size cap (no device)")
    a = p.parse_args()
    size = os.path.getsize(a.apk)
    ok_size = size <= MAX_BYTES
    print(f"size {size:,} bytes (max {MAX_BYTES:,}) -> {'ok' if ok_size else 'OVER'}")
    if a.size_only:
        return 0 if ok_size else 1
    if adb(a.serial, "get-state").stdout.strip() != "device":
        print(f"no device {a.serial}"); return 2
    load0 = os.getloadavg()[0]
    if load0 >= 8:
        print(f"Mac 1-minute load {load0:.1f} >= 8: install time not judged"); return 2
    remote = "/data/local/tmp/check-apk-install.apk"
    r = adb(a.serial, "push", a.apk, remote)
    if r.returncode:
        print("push failed: " + (r.stderr or r.stdout).strip()[-200:]); return 2
    took = []
    try:
        for _ in range(RUNS):
            t0 = time.monotonic()
            r = adb(a.serial, "shell", "pm", "install", "-r", remote)
            dt = time.monotonic() - t0
            if "Success" not in r.stdout:
                print("install failed: " + (r.stdout + r.stderr).strip()[-200:]); return 2
            took.append(dt)
    finally:
        adb(a.serial, "shell", "rm", "-f", remote)
    load1 = os.getloadavg()[0]
    if load1 >= 8:
        print(f"Mac 1-minute load {load1:.1f} >= 8 after the runs: install time not judged"); return 2
    med = statistics.median(took)
    ok_time = med <= MAX_INSTALL_S
    print(f"pm install -r median {med:.1f} s over {RUNS} ({', '.join(f'{t:.1f}' for t in took)}; max {MAX_INSTALL_S} s;"
          f" Mac load {load0:.1f}->{load1:.1f}) -> {'ok' if ok_time else 'OVER'}")
    return 0 if ok_size and ok_time else 1


if __name__ == "__main__":
    sys.exit(main())
