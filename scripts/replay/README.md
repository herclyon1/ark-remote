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

# the local ntfy server (one time: Go + build, ~1 minute; Homebrew's ntfy has no server on macOS)
brew install go && scripts/replay/ntfy_local.py build          # -> ~/.local/bin/ntfy-server
scripts/replay/ntfy_local.py flood 300                          # 300 posts back to back, no 429

# ntfy.sh instead of the local server (anonymous daily quota; the runner checks it first)
scripts/replay/run.py ... --ntfy-public
# no ntfy at all (states injected into the app's cache, sends stop at the confirmation)
scripts/replay/run.py ... --offline

# the plan only (no device, no network)
scripts/replay/run.py --platform ios --dry-run
```

Useful options: `--only status,monthcard` (pages: setup status gate shift receipts d39 monthcard arknights endfield wuwa
phone layout), `--from <step id>` / `--to <step id>` (see `--list`), `--pin` (default 0000), `--state <file>` (a saved
base state), `--out <dir>` (default `scripts/replay/out/<platform>-<time>/`), `--timeout` (default 8 s per step),
`--verbose`. Exit code 0 = all 对, 1 = some 不对, 2 = refused to run, 3 = aborted by the safety check, 4 = the
Android app data could not be put back (the backup path is printed).

A step reads 对, 不对, 跳过（reason） (it ran but is not judged, e.g. 额度) or 不判（reason） (not judgeable on this
device, e.g. the 400 ms guard on the Android emulator, which draws 2-3 frames a second). The summary counts all four.

## The local ntfy server (default)

By default the runner starts the real ntfy server (`ntfy_local.py`, v2.28.0 built from source) on `127.0.0.1:8932`
with a throwaway cache in a temporary directory, and points the app at it through its UserDefaults key `ark-ntfy-base`
(Net.swift `ntfyBase`; only 127.0.0.1 / localhost / 10.0.2.2 are taken, anything else falls back to ntfy.sh):
`http://127.0.0.1:8932` on the iOS simulator, `http://10.0.2.2:8932` on the Android emulator (its alias of the host's
loopback). The runner's own posts and its subscription go to the same server. Loopback is exempt from ntfy's request
and daily message limits there, so there is no quota: every send step runs and is judged. If a server already answers
on 8932 (another run) it is reused; a run stops only the server it started, at exit. The key is in `RESET_KEYS`;
afterwards it is deleted on iOS and restored with `defaults.xml` on Android, so the app goes back to ntfy.sh.
Caveat: a run that started the server stops it when it ends, even under a concurrent run that reused it; start
`ntfy_local.py serve` in a terminal first when running iOS and Android side by side.

## --offline

With `--ntfy-public`, when ntfy.sh's anonymous daily quota is spent (HTTP 429 on IPv4 and IPv6;
the runner checks before it starts) nothing can be posted to or sent through the throwaway mailbox. With `--offline`:

* No quota check and no ntfy traffic from the runner. A machine state (`base`, `dup`, `noef`, `farm` = 刷声骸 in
  progress, `times` = two test receipts, one with sent ≠ at) is injected the way the manual passes did it: stop the app,
  write the state with `at` = now into the app's cache key `ark-remote-cfg-snap`, start the app (it adopts only a newer
  state). Every state step is therefore a cold start.
* No heartbeat can arrive, so the device card reads 「关机」 throughout: 停止一切 and 开始刷 show the
  「机器关着…所以这次没有发」 notice instead of a confirmation (judged), and the 「心跳回来」 half is not run.
* A send step runs up to its last tap, checks the confirmation is there (the step before), then closes it (再想想 / 取消 /
  ✕) and reads 「跳过（额度）」. Steps that need a send first (receipts for what the app sent, D207 queued, 「不等了，清掉」)
  read 「跳过（额度）」 too. Values the app refuses before sending (理智药 1000, 周本 251) are still pressed and judged:
  nothing leaves the phone.
* Android: the app's whole `defaults.xml` is backed up before the run and put back byte for byte afterwards.

## Never the real machine

* `--topic` must be a throwaway ntfy topic. The runner reads the real mailbox name (`ARK_PHONE_TOPIC`) from
  `~/.config/ark/密钥总表.md` / `push.env` at run time, keeps only its SHA-256, and refuses to start when `--topic` is it.
  It never prints it. Do not commit a topic name or its hash: this repository is public.
* Before the app is ever launched the runner stops it and reads the mailbox stored in the app (iOS: both copies, the
  data container's `Library/Preferences/<bundle>.plist` the app writes and the simulator home domain `simctl spawn
  defaults` uses, the container one wins in the app; Android `shared_prefs/defaults.xml` as root). If it is the real mailbox it refuses
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
  the morning shift without 终末地, `farm`, `times`), receipts (also D207 `queued`), heartbeats, the commands the app
  sent; `OfflineMailbox` writes the states into the app's cache instead (`--offline`).
* `guard.py` — the real-topic check.
* `ntfy_local.py` — the local ntfy server (`serve`, `flood <n>`, `build`); port 8932.

## What it covers

Status page (refresh, run now, stop all, 4C boss menu, the 刷到几点 time picker (iOS wheels 23:30 / 0:05, Android
dialog), start farming, the save bar and confirmation
sheet, D207 queued receipt 「排队中 · 跑完执行」, 「不等了，清掉」, heartbeat expiry and the machine-off branch, shifts),
the 400 ms confirmation guard (an early long press must not send, a late tap must), receipts page and D39 (tab reselect
pops pushed pages and scrolls to the top on every tab), month card page (stepper, register, align with the iOS keyboard
「完成」 key), 方舟 (field checks, menu, switches, send, discard), 终末地 (stock page, more settings, the 执行周期 picker
that crashed on Android, mode menu, protocol picker, title text), 鸣潮 (the 无音区 picker that crashed on Android, the
weekly boss field), 手机 (diagnostic switch, self test, clear, share sheet, copy link, paste junk), a shift change that
removes the tab on screen (pushed live in chunks, no refresh), two identical receipts in one minute, 刷声骸 in progress
(改成刷到几点 shows the machine's end time, wheels to 23:30), two-time receipt lines (time under the text), the ✕ of the
save bar putting the keyboard away (理智药, 周本, 循环执行), the 诊断记录 bottom inset on every tab (last line above
「就是这里」, flush with the tab bar when off), and launches with a link / text / nothing on the clipboard, configured or
not (iOS; the system paste alert is answered 「Allow Paste」).

Steps known to be timing-sensitive on emulators: the 400 ms guard steps (`gate.*`: 不判 on Android; on iOS a press that
may have landed after the gate reads 不判（模拟器）) and the live-state step (`noef.jump`). Confirmation alerts and review
sheets ignore presses in their first 400 ms, so the table waits 0.5 s before pressing a button on them. The iOS picker
wheels are turned with synthesized drags, not `adjust(toPickerWheelValue:)`, which waits for an idle app (60 s a time
when it never idles).
