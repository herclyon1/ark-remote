# Replay test

One command clicks through every page and button of ark-remote on an iOS simulator or an Android emulator and prints
one line per step, `<n> <step> → 对` or `<n> <step> → 不对  <why>`, then a summary. A screenshot is saved only for a
failing step. iOS and Android can run at the same time (each with its own throwaway topic).

```
# iOS simulator (installs nothing unless --install is given)
scripts/replay/run.py --platform ios --device <udid> --topic zz-replay-ios-$(openssl rand -hex 6) \
    [--install path/to/ArkRemote.app]

# Android emulator (needs `adb root`: a Google APIs image, not Google Play)
scripts/replay/run.py --platform android --serial emulator-5554 --topic zz-replay-and-$(openssl rand -hex 6) \
    [--install path/to/app-release.apk]

# the plan only (no device, no network)
scripts/replay/run.py --platform ios --dry-run
```

Useful options: `--only status,monthcard` (pages: setup status gate shift receipts d39 monthcard arknights endfield wuwa
phone layout), `--from <step id>` / `--to <step id>` (see `--list`), `--pin` (default 0000), `--state <file>` (a saved
base state), `--out <dir>` (default `scripts/replay/out/<platform>-<time>/`), `--timeout` (default 8 s per step),
`--verbose`. Exit code 0 = all 对, 1 = some 不对, 2 = refused to run, 3 = aborted by the safety check.

## Never the real machine

* `--topic` must be a throwaway ntfy topic. The runner reads the real mailbox name (`ARK_PHONE_TOPIC`) from
  `~/.config/ark/密钥总表.md` / `push.env` at run time, keeps only its SHA-256, and refuses to start when `--topic` is it.
  It never prints it. Do not commit a topic name or its hash: this repository is public.
* Before the app is ever launched the runner stops it and reads the mailbox stored in the app (iOS
  `simctl spawn defaults read`, Android `shared_prefs/defaults.xml` as root). If it is the real mailbox it refuses
  (clear the app's data yourself, after backing it up). Otherwise it writes `{topic, pin}` of the throwaway mailbox,
  points `ark-diag-bucket` at `http://127.0.0.1:9` so diagnostic / crash / fluency uploads go nowhere, and clears the
  pending-change and cache keys. After every step the stored mailbox is read again; any other topic stops the app and
  aborts the run.
* Every POST (state, heartbeat) goes through the same check and only to `--topic` / `--topic`-hb.
* The base state is the real machine's state object read once from COS (read-only, the same GET the app does), with the
  `密钥` section removed, cached in `out/state-base.json` for 12 hours. It is re-posted to the throwaway mailbox in the
  relay's chunked `pack_chunks` format with the test PIN, and heartbeats `hb <n>` play the machine being on.
* The step table never taps 「就是这里」 (it uploads to the real diagnostic bucket) and pastes only junk into 「粘贴密钥串」.
* The simulator / emulator clipboard is set to a harmless string before launch (the app takes a `#k=` link from it).

## Files

* `run.py` — CLI, step runner, checks (expected texts, commands in the mailbox, crashes, the guard).
* `steps.py` — the step table (format in its docstring). Each step: actions, texts expected present / absent, commands
  the app must send, timeout. Elements are found by text / accessibility label, scrolling as needed, not coordinates.
* `drv_ios.py` + `xcuitest/` — iOS: `simctl` plus an XCUITest runner (real HID touches through XCTest's synthesized
  events, element-tree snapshots). It is built once into `out/xcdd` and talks to the runner over a local HTTP port
  derived from the UDID (`--port` to override).
* `drv_android.py` — Android: `adb shell input`, `uiautomator dump`, `logcat` (crash buffer and fatal lines of the app's
  pid after every step).
* `mailbox.py` — throwaway mailbox: base state variants (`base`, `dup` = two identical receipts in one minute, `noef` =
  the morning shift without 终末地), receipts (also D207 `queued`), heartbeats, the commands the app sent.
* `guard.py` — the real-topic check.

## What it covers

Status page (refresh, run now, stop all, 4C boss menu, time field check, start farming, the save bar and confirmation
sheet, D207 queued receipt 「排队中 · 跑完执行」, 「不等了，清掉」, heartbeat expiry and the machine-off branch, shifts),
the 400 ms confirmation guard (an early long press must not send, a late tap must), receipts page and D39 (tab reselect
pops pushed pages and scrolls to the top on every tab), month card page (stepper, register, align with the iOS keyboard
「完成」 key), 方舟 (field checks, menu, switches, send, discard), 终末地 (stock page, more settings, the 执行周期 picker
that crashed on Android, mode menu, protocol picker, title text), 鸣潮 (the 无音区 picker that crashed on Android, the
weekly boss field), 手机 (diagnostic switch, self test, clear, share sheet, copy link, paste junk), a shift change that
removes the tab on screen (pushed live in chunks, no refresh), and two identical receipts in one minute.

Steps known to be timing-sensitive on emulators: the 400 ms guard steps (`gate.*`) and the live-state step (`noef.jump`).
