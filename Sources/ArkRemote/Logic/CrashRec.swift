// The always-on freeze & error recorder (the user approved it 2026-09-28 for the web page). Ported from
// maa-automation/web/crash-rec.js; the record is the same JSON (kind "crash-rec"), so scripts/mac/diag-pull.py and
// whatever reads ~/Claude/ark-diag/crash/ read the app's records too.
//
// WHAT IS RECORDED (the same three things as the page)
//   · errors: the page's window "error" / "unhandledrejection" have no Swift counterpart (a Swift error is either
//     handled or kills the process). What reaches here: `CrashRec.shared.error(...)` (for a caller that catches
//     something unexpected), an uncaught Objective-C exception on iOS (NSSetUncaughtExceptionHandler) and an uncaught
//     Kotlin exception on Android (Main.kt → ArkRemoteAppDelegate.onUncaughtException), both saved synchronously
//     before the process dies, and on iOS MetricKit's crash / hang diagnostics of earlier runs (with their call stack
//     trees), delivered at a later start; on Android (11+) the 「应用无响应」 exits of earlier runs from
//     ActivityManager.getHistoricalProcessExitReasons, read at the next start (Main.kt AnrScan, a "stall" with how
//     "anr" and the main thread's stack from the ANR trace). Identical errors (type + message + file:line:col) are one entry with a count;
//   · actions: a ring of the last RING_N touches (Logic/FluencyRec.swift TouchFeed: the iOS window's touches, Android's
//     MainActivity.dispatchTouchEvent). The page names the control under the finger; the app has no DOM to ask, so an
//     action carries the point (x, y in points) and the tab instead, ctl "";
//   · gaps: a heartbeat every BEAT_MS on the main actor (a Task loop, not a timer: the beat runs only when the main
//     thread is free, so a blocked main thread shows as a gap). Every gap over STALL_MS is kept (GAPS_N newest),
//     tagged vis / vis_changed / focused / focus_changed / phase like the page; it is a STALL when it began visible and
//     no visibility change came before the next tick confirmed it. The page's `dialog` tag does not apply (a native
//     alert does not block the main thread). A hide right after a gap carries no event timestamp here (the lifecycle
//     callbacks have none), so — the page's own rule for a hide without a usable timeStamp — it is never a stall:
//     a freeze the user leaves by going home is reported by the unclean-exit check if the system kills it.
//     Unlike the page the beat stops while the app is in the background (the process keeps running on Android).
//   · unclean exit: a marker {sid, v, beat, vis, ended, tab} written at most every PERSIST_MS by the beat and at once
//     on a hide. The next start reports the previous run as "died while frozen / crashed" when its last beat was while
//     visible, no hide came after it and that beat is older than 2 × PERSIST_MS. Going to the app switcher / home
//     hides first (onPause), so a swipe-away is not reported; a crash while visible is.
//
// NO KEYS IN A RECORD: every recorded string goes through scrub() (crash-rec.js scrub: from a ? or # to the next
// space / quote / bracket / colon goes, any run of 32+ token characters becomes […]).
// FLOOD CONTROL / STORAGE: one record per launch updated in place while unsent, uploaded at most once plus once more
// for a later stall; DAY_MAX PUTs a day. The recorder's own files stay under OWN_MAX bytes together, oldest queued
// record dropped first. The files live in Application Support/diag-rec/ (not UserDefaults: on Android every
// UserDefaults write rewrites the whole preferences file, which holds the cached state; the marker is written every
// 1.5 s), named by the page's localStorage keys.
// WHERE IT GOES: DiagUpload (anonymous PUT, diag/crash/<local YYYYMMDD-HHMMSS>-<16 hex>.json). Nothing is sent
// without an error, a stall or an unclean exit. The queue goes 1.5 s after start, on every return to the foreground
// and when the network comes back.

import Foundation
#if !os(Android) && canImport(UIKit)
import UIKit
#endif
#if !os(Android) && canImport(MetricKit)
import MetricKit
#endif

// MARK: - Shared by both recorders

/// The helpers crash-rec.js and fluency-rec.js each define for themselves (hex, scrub, cut, iso, own storage).
enum RecKit {
    /// Where the recorders keep their own files.
    static let dir: URL = URL.applicationSupportDirectory.appendingPathComponent("diag-rec", isDirectory: true)

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    /// localStorage.getItem for the recorders' own keys.
    static func get(_ name: String) -> String? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// localStorage.setItem; false when the disk refused it (QuotaExceeded on the page).
    @discardableResult static func set(_ name: String, _ v: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(v.utf8).write(to: url(name), options: .atomic)
            return true
        } catch { return false }
    }

    static func parse(_ s: String?) -> JSONValue? {
        guard let s, !s.isEmpty else { return nil }
        return try? JSONValue.parse(s)
    }

    /// A monotonic clock in ms (the base of UITouch.timestamp and CADisplayLink.timestamp on iOS).
    static func mono() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    /// performance.now()'s zero: the recorders' start. A record's `pn` is mono() − t0.
    static let t0: Double = ProcessInfo.processInfo.systemUptime * 1000

    static func hex(_ n: Int) -> String {
        var g = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var s = ""
        for _ in 0..<n { let b = UInt8.random(in: 0...255, using: &g); s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 15)]) }
        return s
    }

    nonisolated(unsafe) private static let reQuery = try? Regex(#"[?#][^\s"'`<>()\[\]{}:,]*"#)
    nonisolated(unsafe) private static let reToken = try? Regex(#"[A-Za-z0-9_\-+=]{32,}"#)
    /// crash-rec.js scrub(): no URL query / hash, no long token.
    static func scrub(_ s: String) -> String {
        var o = s
        if let r = reQuery { o = o.replacing(r, with: "") }
        if let r = reToken { o = o.replacing(r, with: "[…]") }
        return o
    }

    static func cut(_ s: String, _ n: Int) -> String {
        let t = scrub(s)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    private static func pad(_ v: Int, _ w: Int = 2) -> String {
        var s = String(v)
        while s.count < w { s = "0" + s }
        return s
    }

    private static func parts(_ ms: Double, _ tz: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// Date#toISOString(): UTC with milliseconds.
    static func iso(_ ms: Double) -> String {
        let c = parts(ms, TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!)
        let msPart = Int(ms.truncatingRemainder(dividingBy: 1000))
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))T\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0)):\(pad(c.second ?? 0)).\(pad(max(0, msPart), 3))Z"
    }

    /// YYYYMMDD-HHMMSS in the phone's own time (crash-rec.js keyFor).
    static func localStamp(_ ms: Double) -> String {
        let c = parts(ms, TimeZone.current)
        return "\(pad(c.year ?? 0, 4))\(pad(c.month ?? 0))\(pad(c.day ?? 0))-\(pad(c.hour ?? 0))\(pad(c.minute ?? 0))\(pad(c.second ?? 0))"
    }

    /// The local day as crash-rec.js today() writes it: `${y}-${m+1}-${d}` (no padding).
    static func localDay(_ ms: Double) -> String {
        let c = parts(ms, TimeZone.current)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// fluency-rec.js tokyo(): YYYYMMDDHHMMSS in Tokyo time (UTC+9, no daylight saving).
    static func tokyoStamp(_ ms: Double) -> String {
        let c = parts(ms, TimeZone(secondsFromGMT: 9 * 3600)!)
        return "\(pad(c.year ?? 0, 4))\(pad(c.month ?? 0))\(pad(c.day ?? 0))\(pad(c.hour ?? 0))\(pad(c.minute ?? 0))\(pad(c.second ?? 0))"
    }

    /// The page's ?v= script version: the app's own version.
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? ""
        let b = info?["CFBundleVersion"] as? String ?? ""
        let s = b.isEmpty || b == v ? v : "\(v) (\(b))"
        return s.isEmpty ? "local" : s
    }()

    /// navigator.userAgent: the app, its version and the system.
    static let ua: String = {
        #if os(Android)
        let os = "Android"
        #else
        let os = "iOS"
        #endif
        return "ArkRemote/\(version) (\(os); \(ProcessInfo.processInfo.operatingSystemVersionString))"
    }()

    /// location.origin + location.pathname: which client wrote the record.
    #if os(Android)
    static let client = "app:android"
    #else
    static let client = "app:ios"
    #endif

    /// The open tab as the page names it (ContentView's @AppStorage("tab") raw value → the tab bar's words).
    static func tabNow() -> String {
        switch UserDefaults.standard.string(forKey: "tab") ?? "status" {
        case "arknights": return "方舟"
        case "endfield": return "终末地"
        case "wuwa": return "鸣潮"
        case "phone": return "手机"
        default: return "状态"
        }
    }

    private static let screenLock = NSLock()
    nonisolated(unsafe) private static var _viewport: JSONValue = .null
    nonisolated(unsafe) private static var _dpr: JSONValue = .null
    nonisolated(unsafe) private static var _a11y: JSONValue = .object(["reduce_motion": .null, "reduce_transparency": .null])
    /// [innerWidth, innerHeight, devicePixelRatio]; null where unknown (Android).
    static var viewport: JSONValue { screenLock.lock(); defer { screenLock.unlock() }; return _viewport }
    static var dpr: JSONValue { screenLock.lock(); defer { screenLock.unlock() }; return _dpr }
    static var a11y: JSONValue { screenLock.lock(); defer { screenLock.unlock() }; return _a11y }
    static func setScreen(width: Double, height: Double, scale: Double, reduceMotion: Bool?, reduceTransparency: Bool?) {
        screenLock.lock(); defer { screenLock.unlock() }
        _viewport = .array([.double(width), .double(height), .double(scale)])
        _dpr = .double(scale)
        _a11y = .object(["reduce_motion": reduceMotion.map { JSONValue.bool($0) } ?? JSONValue.null,
                         "reduce_transparency": reduceTransparency.map { JSONValue.bool($0) } ?? JSONValue.null])
    }

    static func num(_ v: Double) -> JSONValue { .double(v.rounded()) }
}

/// A mutable JSON object kept by reference (the page mutates its action / gap / incident objects in place).
final class RecBox {
    var o: [String: JSONValue]
    init(_ o: [String: JSONValue]) { self.o = o }
    subscript(_ k: String) -> JSONValue? {
        get { o[k] }
        set { o[k] = newValue }
    }
    var json: JSONValue { .object(o) }
}

// MARK: - crash-rec

final class CrashRec: @unchecked Sendable {
    static let shared = CrashRec()

    static let RING_N = 50, INC_MAX = 30, GAPS_N = 20, VAL_MAX = 200
    static let BEAT_MS = 500.0, STALL_MS = 1000.0, PERSIST_MS = 1500.0, SETTLE_MS = 2500.0, SAVE_MS = 1000.0
    static let OWN_MAX = 100_000, RING_MAX = 25_000, BODY_MAX = 40_000, DAY_MAX = 12
    static let RKEY = "ark-crash-ring", MKEY = "ark-crash-alive", QKEY = "ark-crash-queue", DKEY = "ark-crash-day"

    let sid = RecKit.hex(4)
    private let lock = NSLock()
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private var started = false
    private var ring: [RecBox] = []
    private var incidents: [RecBox] = []
    private var gaps: [RecBox] = []
    private var errIndex: [String: RecBox] = [:]
    private var dirty = false, stallSeq = 0, stallSentSeq = 0, loadSent = false, stallBonus = false
    private var curKey: String?
    private var saveDue = false
    private var settleGen = 0, settleLate = false
    private var sentKeys = Set<String>()
    private var inflight: String?
    private var busy = false, again = false
    private(set) var sent = 0
    private(set) var lastErr: String?

    // heartbeat state (crash-rec.js `visible, last, epoch, cand, persistAt, focusAtLast, focusEpochAtLast`)
    private var visible = false
    private var focused: Bool? = nil
    private var focusEpoch = 0, focusEpochAtLast = 0
    private var focusAtLast: Bool? = nil
    private var loadedAt = Double.infinity
    private var last = 0.0, epoch = 0, persistAt = -1e9
    private struct Cand { let g: RecBox; let epoch: Int; let from: Double; let end: Double }
    private var cand: Cand?
    private var online: Bool? = nil
    private var beatGen = 0
    private var ringBytes = 0, markerBytes = 0, dayBytes = 0
    private var scrollAt = -1e9

    private init() {}

    // MARK: start

    /// Once per process, when the root view first appears (ArkRemoteApp.swift).
    func start() {
        _ = RecKit.t0
        let first: Bool = locked {
            if started { return false }
            started = true
            // the previous run (crash-rec.js "the previous session")
            let prevRing = RecKit.parse(RecKit.get(Self.RKEY))
            if let prev = RecKit.parse(RecKit.get(Self.MKEY)), let psid = prev["sid"]?.string, !psid.isEmpty,
               prev["vis"]?.string == "visible", prev["ended"] != .bool(true), let beat = Self.number(prev["beat"]),
               nowMs() - beat > 2 * Self.PERSIST_MS {
                let tab = prev["tab"] ?? .null
                var acts: JSONValue = .array([])
                if let pr = prevRing, pr["sid"]?.string == psid, let a = pr["a"], a.array != nil { acts = a }
                var r = base()
                r["reasons"] = .array([.string("unclean-exit")])
                r["incidents"] = .array([.object(["type": .string("unclean-exit"), "prev_sid": .string(psid), "prev_v": prev["v"] ?? .null,
                                                  "last_beat": .string(RecKit.iso(beat)), "tab": tab, "since_last_beat_ms": RecKit.num(nowMs() - beat)])])
                r["tab"] = tab
                r["actions"] = acts
                r["gaps"] = .array([])
                var a = readQ(); a.append((key: keyFor(), body: body(r))); writeQ(a)
            }
            visible = true
            focused = true
            focusAtLast = true
            loadedAt = RecKit.mono()
            last = RecKit.mono()
            persistAt = last
            marker(false)
            persistRing()
            return true
        }
        guard first else { return }
        startBeat()
        Task.detached { try? await Task.sleep(nanoseconds: 1_500_000_000); await CrashRec.shared.flush(mine: false) }
        #if !os(Android) && canImport(UIKit)
        CrashRecApple.install()
        #endif
        #if os(Android)
        Self.androidAnrScan?()   // earlier runs' ANRs (Main.kt AnrScan → ArkRemoteAppDelegate.onPastAnr → past)
        #endif
    }

    /// Main.kt AnrScan.scan, set once from AndroidAppMain.onCreate (registerAnrScan); it runs on its own thread.
    nonisolated(unsafe) static var androidAnrScan: (() -> Void)?

    private static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d)?: return d.isFinite ? d : nil
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    // MARK: heartbeat

    /// setInterval(beat, BEAT_MS): a main-actor loop, so a busy main thread delays the beat. One loop per visible spell.
    private func startBeat() {
        let gen: Int = locked { beatGen += 1; return beatGen }
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(CrashRec.BEAT_MS * 1_000_000))
                let on = Live.shared.deviceOnline
                if !CrashRec.shared.beat(gen: gen, online: on) { break }
            }
        }
    }

    /// One tick; false = this loop is over (hidden, or a newer loop runs).
    func beat(gen: Int, online on: Bool) -> Bool {
        var flushNow = false
        let go: Bool = locked {
            guard gen == beatGen, visible else { return false }
            if online == false && on { flushNow = true }   // window "online"
            online = on
            let t = RecKit.mono(), gap = t - last
            if let c = cand {                                // the tick after a gap: confirm it only if nothing about visibility changed since
                if c.epoch == epoch && visible { stall(c.g, end: c.end) } else { c.g["vis_changed"] = .bool(true); saveSoon() }
                cand = nil
            }
            if gap > Self.STALL_MS {
                let g = gapRec(from: last, to: t, how: "timer")
                if visible { cand = Cand(g: g, epoch: epoch, from: last, end: nowMs()) }
            }
            last = t; focusAtLast = focused; focusEpochAtLast = focusEpoch
            if t - persistAt >= Self.PERSIST_MS { persistAt = t; marker(false) }
            return true
        }
        if flushNow {
            Task.detached { await CrashRec.shared.flush(mine: false) }
            Task.detached { await FluencyRec.shared.flushIfQueued() }   // fluency-rec.js listens to "online" too
        }
        return go
    }

    // MARK: visibility / focus (ArkRemoteAppDelegate onResume / onPause / onStop / onWindowFocus)

    func shown() { vis(hide: false) }
    func hidden() { vis(hide: true) }

    private func vis(hide: Bool) {
        let restart: Bool = locked {
            guard started else { return false }
            let t = RecKit.mono()
            let wasVisible = visible
            if hide && visible {
                // no event timestamp here: the page's rule for a hide without a usable timeStamp — never a stall
                if let c = cand, c.epoch == epoch { c.g["vis_changed"] = .bool(true) }
                else if t - last > Self.STALL_MS { let g = gapRec(from: last, to: t, how: "hide"); g["vis_changed"] = .bool(true) }
            }
            #if !os(Android)
            if focused != !hide { focused = !hide; focusEpoch += 1 }   // iOS: active = focused (Android: onWindowFocus)
            #endif
            epoch += 1; cand = nil; visible = !hide; last = t; focusAtLast = focused; focusEpochAtLast = focusEpoch
            persistAt = t; marker(hide)                      // immediate: the app may be suspended or killed right after this
            if hide { save(); persistRing() }
            return !hide && !wasVisible
        }
        if restart {
            startBeat()
            Task.detached { await CrashRec.shared.flush(mine: false) }   // the queue of earlier runs, as on the page's start
        }
    }

    func focus(_ has: Bool) {
        locked { if focused != has { focused = has; focusEpoch += 1 } }
    }

    func network(_ on: Bool) {
        let back: Bool = locked { let b = online == false && on; online = on; return b }
        if back { Task.detached { await CrashRec.shared.flush(mine: false) } }
    }

    // MARK: actions (TouchFeed)

    /// pointerdown: a "down" entry; the lift turns it into "tap" (no movement) or adds a "scroll" (it moved).
    func touchDown(x: Double, y: Double) {
        locked {
            guard started else { return }
            let a = RecBox(["at": RecKit.num(nowMs()), "pn": RecKit.num(RecKit.mono() - RecKit.t0), "tab": .string(RecKit.tabNow()), "kind": .string("down"),
                            "ctl": .string(""), "x": RecKit.num(x), "y": RecKit.num(y)])
            push(a)
        }
    }

    func touchUp(x: Double, y: Double, moved: Bool) {
        locked {
            guard started else { return }
            let at = nowMs()
            if moved {
                let t = RecKit.mono()
                if t - scrollAt > 800 {
                    push(RecBox(["at": RecKit.num(at), "pn": RecKit.num(t - RecKit.t0), "tab": .string(RecKit.tabNow()), "kind": .string("scroll"),
                                 "ctl": .string(""), "x": RecKit.num(x), "y": RecKit.num(y)]))
                }
                scrollAt = t
                return
            }
            // one entry per tap: the lift turns its own down (one of the last 3 entries) into "tap"
            for d in ring.suffix(3).reversed() where d["kind"] == .string("down") {
                if let dat = Self.number(d["at"]), at - dat < 1500 {
                    d["kind"] = .string("tap"); d["up_ms"] = RecKit.num(at - dat); persistRing(); return
                }
            }
            push(RecBox(["at": RecKit.num(at), "pn": RecKit.num(RecKit.mono() - RecKit.t0), "tab": .string(RecKit.tabNow()), "kind": .string("tap"),
                         "ctl": .string(""), "x": RecKit.num(x), "y": RecKit.num(y)]))
        }
    }

    private func push(_ a: RecBox) {
        ring.append(a)
        if ring.count > Self.RING_N { ring.removeFirst(ring.count - Self.RING_N) }
        persistRing()
    }

    private func ringJSON() -> String {
        var k = 0
        var s = JSONValue.object(["sid": .string(sid), "a": .array(ring.map(\.json))]).encodedString()
        while s.utf8.count > Self.RING_MAX && k < ring.count {
            k += 1
            s = JSONValue.object(["sid": .string(sid), "a": .array(ring.dropFirst(k).map(\.json))]).encodedString()
        }
        return s
    }

    private func persistRing() { let s = ringJSON(); ringBytes = s.utf8.count; store(Self.RKEY, s) }

    // MARK: errors

    /// window "error": something unexpected a caller caught. Also feeds fluency-rec's err rule.
    func error(_ message: String, file: String = #fileID, line: Int = #line, stack: String? = nil) {
        FluencyRec.shared.noteError(message + " @" + (file.split(separator: "/").last.map(String.init) ?? file) + ":\(line)")
        locked {
            guard started else { return }
            incident(RecBox(["type": .string("error"), "message": .string(RecKit.cut(message, 500)), "file": .string(RecKit.cut(file, 200)),
                             "line": .int(line), "col": .int(0), "stack": stack.map { JSONValue.string(RecKit.cut($0, 3000)) } ?? JSONValue.null]))
        }
    }

    /// An uncaught exception that is about to kill the process (iOS NSException, Android Kotlin): kept synchronously.
    func fatal(_ message: String, stack: String) {
        locked {
            let x = RecBox(["type": .string("error"), "message": .string(RecKit.cut("uncaught: " + message, 500)), "file": .string(""),
                            "line": .int(0), "col": .int(0), "stack": .string(RecKit.cut(stack, 3000)), "tab": .string(RecKit.tabNow()),
                            "count": .int(1), "first_at": RecKit.num(nowMs()), "last_at": RecKit.num(nowMs())])
            if incidents.count < Self.INC_MAX { incidents.append(x) }
            dirty = true
            save()
            persistRing()
        }
    }

    /// Diagnostics of earlier runs (iOS MetricKit, Android ANR exits): their own record, queued and sent like an unclean exit.
    func past(_ list: [[String: JSONValue]]) {
        guard !list.isEmpty else { return }
        locked {
            var r = base()
            var reasons: [JSONValue] = []
            for x in list { if let t = x["type"], !reasons.contains(t) { reasons.append(t) } }
            r["reasons"] = .array(reasons)
            r["incidents"] = .array(list.prefix(Self.INC_MAX).map { .object($0) })
            r["tab"] = .null
            r["actions"] = .array([])
            r["gaps"] = .array([])
            var a = readQ(); a.append((key: keyFor(), body: body(r))); writeQ(a)
        }
        Task.detached { await CrashRec.shared.flush(mine: false) }
    }

    // MARK: this run's record

    private func base() -> [String: JSONValue] {
        ["kind": .string("crash-rec"), "v": .string(RecKit.version), "sid": .string(sid), "ua": .string(RecKit.ua), "url": .string(RecKit.client),
         "at": .string(RecKit.iso(nowMs())), "standalone": .bool(true), "viewport": RecKit.viewport, "online": online.map { JSONValue.bool($0) } ?? JSONValue.null]
    }

    private func keyFor() -> String { "diag/crash/\(RecKit.localStamp(nowMs()))-\(RecKit.hex(8)).json" }

    private func recordNow() -> [String: JSONValue] {
        var r = base()
        var reasons: [JSONValue] = []
        for x in incidents { if let t = x["type"], !reasons.contains(t) { reasons.append(t) } }
        r["reasons"] = .array(reasons)
        r["incidents"] = .array(incidents.map(\.json))
        r["gaps"] = .array(gaps.map(\.json))
        r["tab"] = .string(RecKit.tabNow())
        r["actions"] = .array(ring.map(\.json))
        return r
    }

    private func body(_ r0: [String: JSONValue]) -> String {
        var r = r0
        var s = JSONValue.object(r).encodedString()
        if s.utf8.count > Self.BODY_MAX {
            r["actions"] = .array((r["actions"]?.array ?? []).suffix(15))
            r["gaps"] = .array((r["gaps"]?.array ?? []).suffix(5))
            r["truncated"] = .bool(true)
            s = JSONValue.object(r).encodedString()
        }
        if s.utf8.count > Self.BODY_MAX {
            r["incidents"] = .array((r["incidents"]?.array ?? []).prefix(8).map { x in
                guard case .object(var o) = x else { return x }
                if let st = o["stack"]?.string { o["stack"] = .string(String(st.prefix(600))) }
                return .object(o)
            })
            s = JSONValue.object(r).encodedString()
        }
        return s
    }

    private func incident(_ x: RecBox) {
        x["tab"] = .string(RecKit.tabNow())
        let type = x["type"]?.string ?? ""
        if type == "error" || type == "rejection" || type == "load" {
            let k = [type, x["message"]?.string ?? "", x["file"]?.string ?? "", x["line"].map { $0.encodedString() } ?? "", x["col"].map { $0.encodedString() } ?? ""].joined(separator: "|")
            if let old = errIndex[k] {
                old["count"] = .int(Int(Self.number(old["count"]) ?? 1) + 1)
                old["last_at"] = RecKit.num(nowMs())
                saveSoon(); return
            }
            x["count"] = .int(1); x["first_at"] = RecKit.num(nowMs()); x["last_at"] = RecKit.num(nowMs())
            if incidents.count >= Self.INC_MAX { return }
            errIndex[k] = x
        } else {
            if incidents.count >= Self.INC_MAX { return }
            stallSeq += 1
        }
        incidents.append(x)
        saveSoon()
        settleGen += 1
        let gen = settleGen
        Task.detached { try? await Task.sleep(nanoseconds: UInt64(CrashRec.SETTLE_MS * 1_000_000)); CrashRec.shared.settle(gen: gen) }
    }

    private func gapRec(from: Double, to: Double, how: String) -> RecBox {
        let now = RecKit.mono()
        let g = RecBox(["at": .string(RecKit.iso(nowMs() - (now - from))), "ms": RecKit.num(to - from), "how": .string(how),
                        "vis": .string(visible ? "visible" : "hidden"), "focused": focusAtLast.map { JSONValue.bool($0) } ?? JSONValue.null,
                        "dialog": .bool(false), "phase": .string(from < loadedAt + 1000 ? "load" : "interaction"), "stall": .bool(false)])
        if focusEpoch != focusEpochAtLast { g["focus_changed"] = .bool(true) }
        gaps.append(g)
        if gaps.count > Self.GAPS_N {                       // background gaps go first
            let h = gaps.firstIndex { $0["vis"] == .string("hidden") } ?? 0
            gaps.remove(at: h)
        }
        return g
    }

    private func stall(_ g: RecBox, end: Double) {
        g["stall"] = .bool(true)
        let ms = Self.number(g["ms"]) ?? 0
        let before = ring.filter { (Self.number($0["at"]) ?? 0) <= end }.suffix(10).map(\.json)
        var o: [String: JSONValue] = ["type": .string("stall"), "ms": RecKit.num(ms), "blocked_min_ms": RecKit.num(max(0, ms - Self.BEAT_MS)),
                                      "how": g["how"] ?? .null, "at": g["at"] ?? .null, "ended_at": .string(RecKit.iso(end)),
                                      "focused": g["focused"] ?? .null, "phase": g["phase"] ?? .null, "before": .array(Array(before))]
        if let fc = g["focus_changed"] { o["focus_changed"] = fc }
        incident(RecBox(o))
    }

    private func saveSoon() {
        dirty = true
        if !saveDue {
            saveDue = true
            Task.detached { try? await Task.sleep(nanoseconds: UInt64(CrashRec.SAVE_MS * 1_000_000)); CrashRec.shared.saveLocked() }
        }
    }

    private func saveLocked() { locked { if saveDue { save() } } }

    /// Write this run's record into the queue (in place while it is still unsent).
    private func save() {
        saveDue = false
        guard dirty, !incidents.isEmpty else { return }
        dirty = false
        if curKey == nil || sentKeys.contains(curKey!) || inflight == curKey { curKey = keyFor() }   // already sent / being sent: a new part
        var a = readQ()
        let s = body(recordNow())
        if let i = a.firstIndex(where: { $0.key == curKey }) { a[i].body = s } else { a.append((key: curKey!, body: s)) }
        writeQ(a)
    }

    /// The burst is over: save, then upload if this run's budget allows.
    private func settle(gen: Int) {
        let go: Bool = locked {
            guard gen == settleGen else { return false }
            if cand != nil && !settleLate {                 // a gap waits for its confirming tick: same burst
                settleLate = true
                Task.detached { try? await Task.sleep(nanoseconds: UInt64((CrashRec.BEAT_MS + 100) * 1_000_000)); CrashRec.shared.settle(gen: gen) }
                return false
            }
            settleLate = false
            save()
            if !loadSent { loadSent = true; stallSentSeq = stallSeq; return true }
            if !stallBonus && stallSeq > stallSentSeq { stallBonus = true; stallSentSeq = stallSeq; return true }
            return false
        }
        if go { Task.detached { await CrashRec.shared.flush(mine: true) } }
    }

    // MARK: storage (own files only, OWN_MAX together)

    private func marker(_ ended: Bool) {
        let s = JSONValue.object(["sid": .string(sid), "v": .string(RecKit.version), "beat": RecKit.num(nowMs()),
                                  "vis": .string(visible ? "visible" : "hidden"), "ended": .bool(ended), "tab": .string(RecKit.tabNow())]).encodedString()
        markerBytes = s.utf8.count
        store(Self.MKEY, s)
    }

    private func readQ() -> [(key: String, body: String)] {
        guard let a = RecKit.parse(RecKit.get(Self.QKEY))?.array else { return [] }
        return a.compactMap { x in
            guard let k = x["key"]?.string, let b = x["body"]?.string else { return nil }
            return (key: k, body: b)
        }
    }

    private func writeQ(_ a0: [(key: String, body: String)]) {
        var a = a0
        while true {
            let s = JSONValue.array(a.map { .object(["key": .string($0.key), "body": .string($0.body)]) }).encodedString()
            if (s.utf8.count + ringBytes + markerBytes + dayBytes <= Self.OWN_MAX || a.isEmpty) && RecKit.set(Self.QKEY, s) { return }
            if a.isEmpty { return }
            a.removeFirst()                                  // over the cap or the disk refused: drop our own oldest
        }
    }

    private func store(_ k: String, _ v: String) {
        if RecKit.set(k, v) { return }
        var a = readQ()
        while !a.isEmpty {
            a.removeFirst()
            RecKit.set(Self.QKEY, JSONValue.array(a.map { .object(["key": .string($0.key), "body": .string($0.body)]) }).encodedString())
            if RecKit.set(k, v) { return }
        }
    }

    private func day() -> (d: String, n: Int) {
        let today = RecKit.localDay(nowMs())
        if let o = RecKit.parse(RecKit.get(Self.DKEY)), o["d"]?.string == today, let n = Self.number(o["n"]) { return (today, Int(n)) }
        return (today, 0)
    }

    // MARK: upload

    /// mine: this run's own record may go (settle() only; start / foreground / online send earlier runs' records).
    func flush(mine: Bool) async {
        let enter: Bool = locked {
            if busy { again = again || mine; return false }
            busy = true
            return true
        }
        guard enter else { return }
        while true {
            let next: (key: String, body: String)? = locked {
                let a = readQ()
                if a.isEmpty { return nil }
                if day().n >= Self.DAY_MAX { lastErr = "daily cap"; return nil }
                guard let it = mine ? a.first : a.first(where: { $0.key != curKey }) else { return nil }
                if it.key == curKey && saveDue { save() }    // send the newest version of this run's record
                let cur = readQ().first { $0.key == it.key } ?? it
                inflight = cur.key
                return cur
            }
            guard let cur = next else { break }
            let ok = await DiagUpload.put(name: cur.key, data: Data(cur.body.utf8))
            let more: Bool = locked {
                inflight = nil
                guard ok else { lastErr = "refused"; return false }   // offline / refused: the rest waits for the next start
                lastErr = nil
                sentKeys.insert(cur.key); sent += 1
                let dd = day()
                let ds = JSONValue.object(["d": .string(dd.d), "n": .int(dd.n + 1)]).encodedString()
                dayBytes = ds.utf8.count
                store(Self.DKEY, ds)                         // the cap counts PUTs that landed
                writeQ(readQ().filter { $0.key != cur.key })
                if cur.key == curKey { curKey = nil }       // later news of this run starts a new part
                return true
            }
            if !more { break }
        }
        let rerun: Bool = locked { busy = false; let r = again; again = false; return r }
        if rerun { await flush(mine: true) }
    }
}

// MARK: - iOS: uncaught Objective-C exceptions and MetricKit

#if !os(Android) && canImport(UIKit)
enum CrashRecApple {
    nonisolated(unsafe) private static var previous: NSUncaughtExceptionHandler?
    nonisolated(unsafe) private static var installed = false
    #if canImport(MetricKit)
    nonisolated(unsafe) private static var subscriber: AnyObject?
    #endif

    static func install() {
        guard !installed else { return }
        installed = true
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { e in
            CrashRec.shared.fatal("\(e.name.rawValue): \(e.reason ?? "")", stack: e.callStackSymbols.joined(separator: "\n"))
            CrashRecApple.previous?(e)
        }
        #if canImport(MetricKit)
        let s = MetricSubscriber()
        subscriber = s
        MXMetricManager.shared.add(s)
        #endif
    }
}

#if canImport(MetricKit)
/// MetricKit's crash and hang diagnostics of earlier runs (iOS 14+), delivered at a later start with call stack trees.
/// A crash → an "error" incident, a hang of STALL_MS or more → a "stall" incident (how "metrickit"), in the page's types.
final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var list: [[String: JSONValue]] = []
        for p in payloads {
            let at = JSONValue.string(RecKit.iso(p.timeStampEnd.timeIntervalSince1970 * 1000))
            for c in p.crashDiagnostics ?? [] {
                var what: [String] = []
                if let t = c.exceptionType { what.append("exception \(t)") }
                if let s = c.signal { what.append("signal \(s)") }
                if let r = c.terminationReason { what.append(r) }
                if let m = c.virtualMemoryRegionInfo { what.append(m) }
                let stack = String(decoding: c.callStackTree.jsonRepresentation(), as: UTF8.self)
                list.append(["type": .string("error"), "message": .string(RecKit.cut("crash: " + what.joined(separator: "; "), 500)), "file": .string(""),
                             "line": .int(0), "col": .int(0), "stack": .string(RecKit.cut(stack, 3000)), "metrickit": .bool(true),
                             "prev_v": .string(c.applicationVersion), "at": at, "count": .int(1)])
            }
            for h in p.hangDiagnostics ?? [] {
                let ms = h.hangDuration.converted(to: .milliseconds).value
                guard ms >= CrashRec.STALL_MS else { continue }
                let stack = String(decoding: h.callStackTree.jsonRepresentation(), as: UTF8.self)
                list.append(["type": .string("stall"), "ms": RecKit.num(ms), "blocked_min_ms": RecKit.num(ms), "how": .string("metrickit"),
                             "at": at, "stack": .string(RecKit.cut(stack, 3000)), "prev_v": .string(h.applicationVersion)])
            }
        }
        CrashRec.shared.past(list)
    }
}
#endif
#endif
