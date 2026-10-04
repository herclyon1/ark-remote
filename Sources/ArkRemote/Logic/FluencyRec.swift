// The always-on gesture recorder (D96, the user 09-29 04:1x 「做出能检测实际检测这两个的工具」; privacy and "send only when
// something happened" = D92, the same rules as crash-rec). Ported from maa-automation/web/fluency-rec.js; a line and an
// upload are the same JSON as the page's (kind "flu", diag/flu/<Tokyo YYYYMMDDHHMMSS>-<sid>-<n>.json), so the same
// scripts read both.
//
// ONE GESTURE (finger down … SETTLE_MS after the lift, at most HARD_MS) = one line, judged at once. Of the page's rules:
//   long   a frame interval > 100 ms anywhere in the gesture (the main thread was blocked)
//   jank   a glass gesture with a frame interval ≥ 50 ms         } the app draws no glass lens of its own, so `glass` is
//   choppy a glass gesture with ≥ 6 intervals in a row > 25 ms    } always "" and these two never fire (kept for parity)
//   wait   the press reached the app's main thread > 100 ms late (handled − the touch's own timestamp)
//   rage   the same control pressed 3 times within 2 s — the app has no element identity to compare, so "the same
//          control" is a tap within RAGE_PT points of the two before it
//   err    an error recorded by CrashRec between the press and the end of the gesture
//   slow   the first UI commit after the lift > 200 ms after it (react)                      } approximations, see below;
//   inp    the press → the first UI commit after the press was handled > 200 ms (et.dur)     } the page's 200 ms lines
// slow / inp read a "the UI was committed" signal: iOS 18+ = UIUpdateLink, a passive link (requiresContinuousUpdates false:
// "the system only calls its actions while producing a UI update in response to some kind of event, such as a gesture or
// layer change") with an action in its afterCATransactionCommit phase; Android = ViewTreeObserver.OnDrawListener on the
// activity's window ("invoked when the view tree is about to be drawn", Main.kt). Both cover the whole window, not the
// control's region, so where the page's slow counts the first change of the page (MutationObserver, from the press on) the
// app counts the first commit after the lift — the press highlight is a commit too, before the lift — and inp is the press
// → the next commit, where the page reads the browser's Event Timing entry (the longest of pointerdown / pointerup / click).
// What they catch is the main thread holding the next commit back. iOS 17 has no such link (none found): there both stay
// null as before, and the line's `commit` says which signal was there ("link" / "draw" / null).
// Not ported: dead needs the kind of control pressed, whether it was already on or disabled, and its region (fluency-rec.js
// :141, :150); SwiftUI / Compose give a touch no control. near / scene / was_on / disabled stay as before.
// Frames: iOS = CADisplayLink (the display's frames, the base of UITouch.timestamp); Android = a main-actor tick every
// TICK_MS. Choreographer.getInstance() on the main thread would do as well (one per Looper thread, not per Activity); the
// tick stays so that `long` on Android reads as it did in the records so far. The line says which in `clock` ("vsync" / "tick").
// Touches: TouchFeed below, fed by TouchProbe (iOS, a window gesture recognizer that only watches) and by
// ArkRemoteAppDelegate.onTouch (Android, MainActivity.dispatchTouchEvent). It also feeds crash-rec's action ring.
//
// NEVER RECORDED: what is typed, the screen, the stored settings, any 32+ character token (RecKit.scrub).
// SENDING (D92): lines stay in memory (RING_N newest). The first hit schedules one upload SEND_MS later; going to the
// background sends a pending hit at once. One upload = the lines with a hit since the last upload + up to CTX_N earlier
// lines each as context. At most DAY_MAX uploads and DAY_BYTES a day; every upload is queued in the recorder's own file
// before its PUT and waits there on failure for the next start / foreground / network.

import Foundation
#if !os(Android) && canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import QuartzCore
#endif

// MARK: - Touches

/// Every primary touch of the app, from either platform's source, to both recorders.
enum TouchFeed {
    /// A touch that moved more than this many points is a drag / scroll, not a tap.
    static let MOVE_PT = 10.0
    private static let lock = NSLock()
    nonisolated(unsafe) private static var downAt: (x: Double, y: Double)?

    /// pointerdown (isPrimary). `waitMs`: how late it reached the main thread (handled − the touch's timestamp).
    static func down(x: Double, y: Double, waitMs: Double) {
        lock.lock(); downAt = (x, y); lock.unlock()
        CrashRec.shared.touchDown(x: x, y: y)
        FluencyRec.shared.start(x: x, y: y, waitMs: waitMs)
    }

    /// pointerup / pointercancel of that touch. `waitMs`: as for down (the lift is stamped with the touch's own time, so slow
    /// does not depend on whether a control's action ran before this got the touch).
    static func up(x: Double, y: Double, cancelled: Bool, waitMs: Double) {
        lock.lock()
        let d = downAt
        downAt = nil
        lock.unlock()
        let moved = d.map { abs($0.x - x) > MOVE_PT || abs($0.y - y) > MOVE_PT } ?? false
        CrashRec.shared.touchUp(x: x, y: y, moved: moved || cancelled)
        FluencyRec.shared.lift(moved: moved || cancelled, waitMs: waitMs)
    }
}

#if !os(Android) && canImport(UIKit)
/// Watches every touch of the app's windows without taking part: it never recognizes, cancels and delays nothing, and
/// runs alongside every other recognizer. It fails at the end of each touch sequence, which resets it for the next.
final class TouchProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var tracking: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// Adds one probe to each window of the app (again on every foreground: a new window gets one), and notes the
    /// screen for the records (viewport / devicePixelRatio / prefers-reduced-*).
    static func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows where !(w.gestureRecognizers ?? []).contains(where: { $0 is TouchProbe }) {
                w.addGestureRecognizer(TouchProbe(target: nil, action: nil))
                if #available(iOS 18.0, *) { addCommitLink(w) }
            }
            if let w = ws.windows.first(where: \.isKeyWindow) ?? ws.windows.first {
                RecKit.setScreen(width: Double(w.bounds.width), height: Double(w.bounds.height), scale: Double(ws.screen.scale),
                                 reduceMotion: UIAccessibility.isReduceMotionEnabled, reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
            }
        }
    }

    /// The UI-commit signal for slow / inp (header): a passive UIUpdateLink on the window, its action after each
    /// update's CATransaction commit. Kept here for the app's life, one per window that got a probe.
    private static var links: [AnyObject] = []
    @available(iOS 18.0, *) private static func addCommitLink(_ w: UIWindow) {
        let l = UIUpdateLink(view: w)
        l.addAction(to: .afterCATransactionCommit) { _, _ in FluencyRec.shared.commit(ts: RecKit.mono()) }
        l.isEnabled = true
        links.append(l)
        FluencyRec.commitSrc = "link"
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard tracking == nil, let t = touches.first else { return }
        tracking = t
        let p = t.location(in: view)
        TouchFeed.down(x: Double(p.x), y: Double(p.y), waitMs: max(0, RecKit.mono() - t.timestamp * 1000))
        FrameClock.shared.run()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        end(touches, event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        end(touches, event, cancelled: true)
    }

    private func end(_ touches: Set<UITouch>, _ event: UIEvent, cancelled: Bool) {
        if let t = tracking, touches.contains(t) {
            let p = t.location(in: view)
            tracking = nil
            TouchFeed.up(x: Double(p.x), y: Double(p.y), cancelled: cancelled, waitMs: max(0, RecKit.mono() - t.timestamp * 1000))
        }
        // the last finger is up: fail, so UIKit resets the probe for the next touch sequence
        if (event.allTouches ?? touches).allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) { state = .failed }
    }

    override func reset() {
        super.reset()
        tracking = nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// requestAnimationFrame for the gesture being timed: a CADisplayLink that runs only while a gesture is open.
@MainActor final class FrameClock: NSObject {
    static let shared = FrameClock()
    private var link: CADisplayLink?

    func run() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        if !FluencyRec.shared.frame(ts: l.timestamp * 1000) {
            l.invalidate()
            link = nil
        }
    }
}
#else
/// requestAnimationFrame's stand-in on Android: a main-actor tick every TICK_MS while a gesture is open.
@MainActor enum FrameClock {
    static let TICK_MS: UInt64 = 16
    private static var running = false

    static func run() {
        guard !running else { return }
        running = true
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: TICK_MS * 1_000_000)
                if !FluencyRec.shared.frame(ts: RecKit.mono()) { break }
            }
            running = false
        }
    }
}
#endif

// MARK: - fluency-rec

final class FluencyRec: @unchecked Sendable {
    static let shared = FluencyRec()

    static let RING_N = 300, CTX_N = 5, DAY_MAX = 200, BODY_MAX = 60_000, OWN_MAX = 60_000, FI_MAX = 600, CHOPPY_N = 6
    static let SETTLE_MS = 400.0, HARD_MS = 10_000.0, SEND_MS = 30_000.0, DAY_BYTES = 20e6, CHOPPY_MS = 25.0, RAGE_PT = 22.0
    static let QKEY = "ark-flu-queue", DKEY = "ark-flu-day", SKEY = "ark-flu-fi"
    #if os(Android)
    static let clock = "tick"
    /// The UI-commit signal slow / inp read (header): "draw" = Main.kt's OnDrawListener → ArkRemoteAppDelegate.onDraw;
    /// "link" = TouchProbe's UIUpdateLink (iOS 18+); nil = none (iOS 17), and the two rules are not judged.
    nonisolated(unsafe) static var commitSrc: String? = "draw"
    #else
    static let clock = "vsync"
    nonisolated(unsafe) static var commitSrc: String? = nil
    #endif

    let sid = RecKit.hex(4)
    private let lock = NSLock()
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private struct Gesture {
        var at: Double, pn: Double, x: Double, y: Double, wait: Double, tab: String, errs0: Int
        var down = true, up = 0.0, moved = false
        var fi: [[Double]] = []
        /// slow / inp: the commit signal there at the press, when the press was handled, the first commit after it and
        /// the first after the lift (monotonic ms, 0 = none yet), and whether the settle already waited a frame for one.
        var src: String?, handled = 0.0, cDown = 0.0, cUp = 0.0, waited = false
        var prev = 0.0
    }
    private struct Line { let pn: Double; let at: Double; let x: Double; let y: Double; let kind: String; let bad: [String]; var o: [String: JSONValue] }

    private var started = false
    private var g: Gesture?
    private var lines: [Line] = []
    private var errs: [(n: Int, m: String)] = []
    private var errN = 0
    private var seq = 0, sentUpTo = -Double.infinity, pending = false, sendDue = false, busy = false, again = 0
    private(set) var sent = 0, failed = 0, capped = 0
    private(set) var lastKey: String?, lastErr: String?

    private init() {}

    /// Once per process (ArkRemoteApp.swift): an upload left over from an earlier run goes 2 s later.
    func start() {
        let first: Bool = locked { if started { return false }; started = true; return true }
        guard first else { return }
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await FluencyRec.shared.flushIfQueued()
        }
    }

    func flushIfQueued() async {
        let has: Bool = locked { !readQ().isEmpty }
        if has { await flush(background: false) }
    }

    /// The rules' pure part (fluency-rec.js FluRules.runOver).
    static func runOver(_ ms: [Double], _ lim: Double) -> Int {
        var n = 0, best = 0
        for x in ms { n = x > lim ? n + 1 : 0; if n > best { best = n } }
        return best
    }

    // MARK: errors (CrashRec.error)

    func noteError(_ m: String) {
        locked {
            errN += 1
            errs.append((n: errN, m: RecKit.cut(m, 160)))
            if errs.count > 200 { errs.removeFirst(100) }
        }
    }

    // MARK: one gesture

    func start(x: Double, y: Double, waitMs: Double) {
        locked {
            if g != nil { finish(settled: false, hidden: false) }
            let t = RecKit.mono()
            g = Gesture(at: nowMs() - waitMs, pn: t - waitMs, x: x, y: y, wait: waitMs.rounded(), tab: RecKit.tabNow(), errs0: errN)
            g!.src = Self.commitSrc
            g!.handled = t
        }
    }

    func lift(moved: Bool, waitMs: Double) {
        locked {
            guard g != nil, g!.down else { return }
            g!.down = false
            g!.up = RecKit.mono() - max(0, waitMs)
            g!.moved = moved
        }
    }

    /// The UI was committed (iOS: UIUpdateLink after the CATransaction commit; Android: the view tree about to be drawn),
    /// ts = now on the monotonic clock. On the main thread; does nothing without an open gesture.
    func commit(ts: Double) {
        locked {
            guard g != nil, g!.src != nil else { return }
            if g!.cDown == 0 && ts >= g!.handled { g!.cDown = ts }
            if g!.cUp == 0 && !g!.down && ts >= g!.up { g!.cUp = ts }
        }
    }

    /// One frame (ts = the frame's time on the monotonic clock, ms). false = no gesture left to time: stop the clock.
    func frame(ts: Double) -> Bool {
        locked {
            guard var G = g else { return false }
            if G.prev > 0 { G.fi.append([((ts - G.prev) * 10).rounded() / 10, (G.prev - G.pn).rounded()]) }
            else { G.fi.append([max(0, ((ts - G.pn) * 10).rounded() / 10), 0]) }   // fi[0] = the press → the first frame
            G.prev = ts
            g = G
            let now = RecKit.mono()
            let quiet = !G.down && now - G.up > Self.SETTLE_MS
            // a main thread held up past SETTLE_MS after the lift gives this frame first and the commit after it, in the same
            // update (UIUpdateActionPhase: CADisplayLink dispatch, then the CATransaction commit): wait one frame more for it
            if quiet && G.src != nil && G.cUp == 0 && !G.waited && now - G.pn <= Self.HARD_MS { g!.waited = true; return true }
            if quiet || now - G.pn > Self.HARD_MS {
                finish(settled: true, hidden: false)
                return g != nil
            }
            return true
        }
    }

    private func rage(_ kind: String, _ x: Double, _ y: Double, _ at: Double) -> Bool {
        guard kind == "tap", lines.count >= 2 else { return false }
        let a = lines[lines.count - 1], b = lines[lines.count - 2]
        let near = { (l: Line) in l.kind == "tap" && abs(l.x - x) <= Self.RAGE_PT && abs(l.y - y) <= Self.RAGE_PT }
        return near(a) && near(b) && at - b.at <= 2000
    }

    private func finish(settled: Bool, hidden: Bool) {
        guard let G = g else { return }
        g = nil
        if hidden && G.fi.count < 2 { return }
        let tEnd = RecKit.mono()
        let ms = G.fi.map { $0[0] }
        let kind = G.moved ? "drag" : "tap"
        let n50 = ms.filter { $0 >= 50 }.count, n100 = ms.filter { $0 > 100 }.count, run25 = Self.runOver(ms, Self.CHOPPY_MS)
        let big = G.fi.sorted { $0[0] > $1[0] }.prefix(5).filter { $0[0] >= 34 }.map { JSONValue.array([.double($0[0]), .double($0[1])]) }
        let e = errs.filter { $0.n > G.errs0 }.prefix(5).map(\.m)
        let glass = ""
        var bad: [String] = []
        if !e.isEmpty { bad.append("err") }
        if n100 > 0 { bad.append("long") }
        if !glass.isEmpty && n50 > 0 { bad.append("jank") }
        if !glass.isEmpty && run25 >= Self.CHOPPY_N { bad.append("choppy") }
        if G.wait > 100 { bad.append("wait") }
        let press: Double? = G.up > 0 ? G.up - G.pn : nil
        let first: Double? = G.cUp > 0 ? G.cUp - G.pn : nil
        let react: Double? = first.flatMap { f in press.map { f - $0 } }
        let etDur: Double? = G.cDown > 0 ? G.cDown - G.pn : nil
        if let r = react, r > 200 { bad.append("slow") }
        if let d = etDur, d > 200 { bad.append("inp") }
        if rage(kind, G.x, G.y, G.at) { bad.append("rage") }
        let pn0 = RecKit.t0
        var o: [String: JSONValue] = [
            "at": RecKit.num(G.at), "pn": RecKit.num(G.pn - pn0), "v": .string(RecKit.version), "ctl": .string(""), "id": .int(0), "kind": .string(kind),
            "watched": RecKit.num(tEnd - G.pn), "glass": .string(glass), "tab": .string(G.tab), "wait": RecKit.num(G.wait),
            "press": G.up > 0 ? RecKit.num(G.up - G.pn) : .null, "first": first.map { RecKit.num($0) } ?? .null,
            "react": react.map { RecKit.num($0) } ?? .null, "near": .null,
            "was_on": .bool(false), "disabled": .bool(false), "scene": .null,
            "nf": .int(ms.count), "max": ms.isEmpty ? .null : RecKit.num(ms.max()!), "n50": .int(n50), "n100": .int(n100), "run25": .int(run25),
            "big": .array(Array(big)), "span": RecKit.num(max((G.up > 0 ? G.up : tEnd) - G.pn, 0)), "settled": .bool(settled),
            "bad": .array(bad.map { .string($0) }), "draws": .null, "dfr": .null, "d_rate": .null, "wa": .null,
            "x": RecKit.num(G.x), "y": RecKit.num(G.y), "clock": .string(Self.clock), "commit": G.src.map { .string($0) } ?? .null,
        ]
        if let d = etDur { o["et"] = .object(["name": .string("pointerdown"), "dur": RecKit.num(d), "delay": RecKit.num(G.wait), "proc": .null]) }
        if !e.isEmpty { o["err"] = .array(e.map { .string($0) }) }
        if !bad.isEmpty {                                    // frames ride along only the first time for version × rule × control (K12)
            var seen = (RecKit.parse(RecKit.get(Self.SKEY))?.array ?? []).compactMap(\.string)
            let fresh = bad.map { RecKit.version + "|" + $0 + "|" }.filter { !seen.contains($0) }
            if !fresh.isEmpty {
                o["fi"] = .array(ms.prefix(Self.FI_MAX).map { .double($0) })
                seen.append(contentsOf: fresh)
                RecKit.set(Self.SKEY, JSONValue.array(seen.suffix(200).map { .string($0) }).encodedString())
            }
            pending = true
            if !sendDue {                                    // hits within SEND_MS of the first go as one upload
                sendDue = true
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(FluencyRec.SEND_MS * 1_000_000))
                    await FluencyRec.shared.flush(background: false)
                }
            }
        }
        lines.append(Line(pn: G.pn, at: G.at, x: G.x, y: G.y, kind: kind, bad: bad, o: o))
        if lines.count > Self.RING_N { lines.removeFirst(lines.count - Self.RING_N) }
    }

    // MARK: background (ArkRemoteAppDelegate onPause)

    func hidden() {
        let send: Bool = locked {
            if g != nil { finish(settled: false, hidden: true) }
            return pending
        }
        if send { Task.detached { await FluencyRec.shared.flush(background: true) } }
    }

    // MARK: storage (own files only) and sending

    private func day() -> (d: String, n: Int, b: Int) {
        let d = String(RecKit.tokyoStamp(nowMs()).prefix(8))
        if let o = RecKit.parse(RecKit.get(Self.DKEY)), o["d"]?.string == d {
            func n(_ v: JSONValue?) -> Int { switch v { case .int(let i)?: return i; case .double(let x)?: return Int(x); default: return 0 } }
            return (d, n(o["n"]), n(o["b"]))
        }
        return (d, 0, 0)
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
        let own = (RecKit.get(Self.DKEY) ?? "").utf8.count + (RecKit.get(Self.SKEY) ?? "").utf8.count
        while true {
            let s = JSONValue.array(a.map { .object(["key": .string($0.key), "body": .string($0.body)]) }).encodedString()
            if (s.utf8.count + own <= Self.OWN_MAX || a.isEmpty) && RecKit.set(Self.QKEY, s) { return }
            if a.isEmpty { return }
            a.removeFirst()
        }
    }

    /// The hit lines since the last upload + CTX_N lines before each.
    private func build(_ why: String) -> (body: String, upTo: Double)? {
        var idx = Set<Int>()
        for (i, l) in lines.enumerated() where l.pn > sentUpTo && !l.bad.isEmpty {
            for k in max(0, i - Self.CTX_N)...i where lines[k].pn > sentUpTo { idx.insert(k) }   // a line already sent is not sent again
        }
        guard !idx.isEmpty, let lastPn = lines.last?.pn else { return nil }
        var ls = idx.sorted().map { lines[$0].o }
        func mk() -> String {
            JSONValue.object(["kind": .string("flu"), "why": .string(why), "v": .string(RecKit.version), "sid": .string(sid), "sent": RecKit.num(nowMs()),
                              "ua": .string(RecKit.ua), "url": .string(RecKit.client), "dpr": RecKit.dpr, "viewport": RecKit.viewport,
                              "standalone": .bool(true), "a11y": RecKit.a11y, "lines": .array(ls.map { .object($0) })]).encodedString()
        }
        var body = mk()
        if body.utf8.count > Self.BODY_MAX { ls = ls.map { var l = $0; l["fi"] = nil; return l }; body = mk() }
        while body.utf8.count > Self.BODY_MAX && ls.count > 1 { ls = Array(ls.dropFirst((ls.count + 3) / 4)); body = mk() }
        return (body, lastPn)
    }

    func flush(background: Bool) async {
        let enter: Bool = locked {
            sendDue = false
            if pending {                                     // into the queue BEFORE the PUT: a run hidden then killed keeps it for the next start
                pending = false
                if let b = build(background ? "background" : "hit") {
                    sentUpTo = b.upTo
                    seq += 1
                    var q = readQ()
                    q.append((key: "diag/flu/\(RecKit.tokyoStamp(nowMs()))-\(sid)-\(seq).json", body: b.body))
                    writeQ(q)
                }
            }
            if busy { again = max(again, background ? 2 : 1); return false }   // the running upload sends it when it is done
            busy = true
            return true
        }
        guard enter else { return }
        let items: [(key: String, body: String)] = locked { readQ() }
        for it in items {
            let go: Bool = locked {
                let dd = day()
                if dd.n >= Self.DAY_MAX || Double(dd.b + it.body.utf8.count) > Self.DAY_BYTES { capped += 1; lastErr = "daily cap"; return false }
                return true
            }
            guard go else { break }                          // it stays queued for tomorrow
            let ok = await DiagUpload.put(name: it.key, data: Data(it.body.utf8))
            let more: Bool = locked {
                guard ok else { failed += 1; lastErr = "refused"; return false }   // offline / refused: the rest waits for the next start
                sent += 1; lastKey = it.key
                let dd = day()
                RecKit.set(Self.DKEY, JSONValue.object(["d": .string(dd.d), "n": .int(dd.n + 1), "b": .int(dd.b + it.body.utf8.count)]).encodedString())
                writeQ(readQ().filter { $0.key != it.key })
                return true
            }
            if !more { break }
        }
        let next: Int = locked { busy = false; let a = again; again = 0; return a }
        if next != 0 {
            let has: Bool = locked { !readQ().isEmpty }
            if has { await flush(background: next == 2) }
        }
    }
}
