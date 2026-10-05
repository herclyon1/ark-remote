// Touch / element-tree driver for scripts/replay/run.py on an iOS simulator.
//
// Derived from the pass-1 C1 runner (real HID-level touches through XCTest's private XCSynthesizedEventRecord /
// XCPointerEventPath, the same path WebDriverAgent uses). It runs only when TEST_RUNNER_REPLAY_URL is set (xcodebuild
// forwards TEST_RUNNER_* env vars to the test without the prefix); otherwise the test is skipped.
//
// Protocol: the runner long-polls GET <url>/next; the answer is a batch of newline-separated commands ("quit" ends
// the test). After the batch it POSTs <url>/result with one line per command: "<command word>\t<output>".
//   ax                    the app's element tree as one JSON line {"state": n, "els": [[type, label, id, value, x, y, w, h, enabled, selected], ...]}
//   tap <x> <y> [ms]      one finger down/up at (x, y) pt, held ms (default 50)
//   path <x,y,dt|...>     one finger path: dt = ms after the previous point (first point = touch-down), the last point lifts
//   type <text>           type into the focused element
//   del <n>               n delete keys into the focused element
//   back                  tap the navigation bar's back button (the leftmost button of the top-most navigation bar)
//   wait <ms>
//   state                 XCUIApplication.State raw value of the app (4 = running in foreground)
//   activate              bring the app to the front
//   pbclear               empty the simulator's general pasteboard (no items, so hasStrings is false)
//   pbset <text>          put a string on the general pasteboard
//   pick <n> <value>      turn the app's n-th picker wheel to <value> (XCUIElement.adjust(toPickerWheelValue:)), e.g. the
//                         DatePicker wheels "23" / "30" (the 检查 pass-7 runner's command); answers the wheel's new value
import XCTest
import UIKit

final class ReplayUITests: XCTestCase {
    let bundleID = ProcessInfo.processInfo.environment["REPLAY_BUNDLE"] ?? "com.herclyon.arkremote"
    lazy var app = XCUIApplication(bundleIdentifier: bundleID)
    var base = ""

    func http(_ path: String, body: String? = nil, timeout: Double) -> String? {
        guard let u = URL(string: base + path) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body = body { req.httpMethod = "POST"; req.httpBody = Data(body.utf8) }
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { d, _, e in
            if e == nil { out = String(decoding: d ?? Data(), as: UTF8.self) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }

    func testReplay() throws {
        guard let url = ProcessInfo.processInfo.environment["REPLAY_URL"], !url.isEmpty else { throw XCTSkip("no REPLAY_URL") }
        base = url
        var misses = 0
        while true {
            guard let batch = http("/next", timeout: 50) else {
                misses += 1
                if misses > 30 { break }   // the Python side is gone
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            misses = 0
            if batch == "quit" { break }
            if batch.isEmpty { continue }
            var out: [String] = []
            for raw in batch.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let word = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let res = run(line).replacingOccurrences(of: "\n", with: " ")
                out.append("\(word)\t\(res)")
            }
            _ = http("/result", body: out.joined(separator: "\n"), timeout: 10)
        }
    }

    func run(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let rest = line.count > parts[0].count ? String(line.dropFirst(parts[0].count + 1)) : ""
        switch parts[0] {
        case "ax": return dump()
        case "state": return "\(app.state.rawValue)"
        case "activate": app.activate(); return "ok"
        case "pbclear": UIPasteboard.general.items = []; return "ok \(UIPasteboard.general.hasStrings)"
        case "pbset": UIPasteboard.general.string = rest; return "ok"
        case "pick":
            let n = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            let val = parts.dropFirst(2).joined(separator: " ")
            let w = app.pickerWheels.element(boundBy: n)
            guard w.waitForExistence(timeout: 3) else { return "error no wheel \(n) (\(app.pickerWheels.count))" }
            w.adjust(toPickerWheelValue: val)
            return "ok \(String(describing: w.value ?? ""))"
        case "wait":
            Thread.sleep(forTimeInterval: (Double(parts.count > 1 ? parts[1] : "0") ?? 0) / 1000); return "ok"
        case "tap":
            let x = Double(parts[1]) ?? 0, y = Double(parts[2]) ?? 0, hold = parts.count > 3 ? (Double(parts[3]) ?? 50) : 50
            do { try synthesize(points: [(x, y, 0), (x, y, hold)]); return "ok" }
            catch {
                let c = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
                if hold > 300 { c.press(forDuration: hold / 1000) } else { c.tap() }
                return "ok public (\(error.localizedDescription))"
            }
        case "path":
            var pts: [(Double, Double, Double)] = []
            for seg in rest.split(separator: "|") {
                let c = seg.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                if c.count >= 3 { pts.append((c[0], c[1], c[2])) }
            }
            guard pts.count >= 2 else { return "error bad path" }
            do { try synthesize(points: pts); return "ok" } catch { return "error \(error.localizedDescription)" }
        case "type":
            app.typeText(rest); return "ok"
        case "del":
            let n = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n)); return "ok"
        case "back":
            let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            for bar in bars.reversed() {
                let b = bar.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.min { $0.frame.minX < $1.frame.minX }
                if let b = b, b.frame.minX < 120 { b.tap(); return "ok \(b.label)" }
            }
            return "none"
        default:
            return "error unknown command"
        }
    }

    func dump() -> String {
        var els: [[Any]] = []
        let state = app.state.rawValue
        if let snap = try? app.snapshot() {
            func walk(_ s: XCUIElementSnapshot) {
                let f = s.frame
                let v = s.value.map { String(describing: $0) } ?? ""
                let interesting: [XCUIElement.ElementType] = [.button, .switch, .toggle, .textField, .secureTextField, .cell, .slider,
                                                                .segmentedControl, .picker, .alert, .sheet, .keyboard, .tabBar,
                                                                .navigationBar, .menu, .menuItem, .stepper]
                if !s.label.isEmpty || !s.identifier.isEmpty || !v.isEmpty || interesting.contains(s.elementType) {
                    els.append([typeName(s.elementType), s.label, s.identifier, v, Int(f.midX), Int(f.midY), Int(f.width), Int(f.height),
                                s.isEnabled, s.isSelected])
                }
                for c in s.children { walk(c) }
            }
            walk(snap)
        }
        let obj: [String: Any] = ["state": state, "els": els]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{\"state\":\(state),\"els\":[]}" }
        return String(decoding: d, as: UTF8.self)
    }

    func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "Application"; case .window: return "Window"; case .other: return "Other"; case .button: return "Button"
        case .staticText: return "StaticText"; case .switch: return "Switch"; case .cell: return "Cell"; case .table: return "Table"
        case .collectionView: return "CollectionView"; case .navigationBar: return "NavigationBar"; case .scrollView: return "ScrollView"
        case .image: return "Image"; case .textField: return "TextField"; case .toggle: return "Toggle"; case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"; case .searchField: return "SearchField"; case .segmentedControl: return "SegmentedControl"
        case .slider: return "Slider"; case .link: return "Link"; case .group: return "Group"; case .sheet: return "Sheet"; case .alert: return "Alert"
        case .tabBar: return "TabBar"; case .toolbar: return "Toolbar"; case .checkBox: return "CheckBox"; case .datePicker: return "DatePicker"
        case .keyboard: return "Keyboard"; case .key: return "Key"; case .stepper: return "Stepper"; case .menuItem: return "MenuItem"
        case .menu: return "Menu"; case .secureTextField: return "SecureTextField"; case .textView: return "TextView"
        case .scrollBar: return "ScrollBar"; case .popover: return "Popover"
        default: return "type\(t.rawValue)"
        }
    }

    // ---- private touch synthesis (XCSynthesizedEventRecord + XCPointerEventPath, XCTRunnerDaemonSession.synthesizeEvent:completion:)
    func synthesize(points: [(Double, Double, Double)]) throws {
        guard let recCls = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let pathCls = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let sessCls = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type else {
            throw NSError(domain: "replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "private XCT classes missing"])
        }
        typealias InitRec = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias MoveTo = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias LiftUp = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        // (BOOL, NSError*): typing the error as NSError? retained the BOOL and crashed the runner (pass-1 C1 runner note)
        typealias Synth = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, UnsafeRawPointer?) -> Void) -> Void
        func imp<T>(_ obj: AnyObject, _ sel: String, _ type: T.Type) throws -> (T, Selector) {
            let s = NSSelectorFromString(sel)
            guard let m = class_getInstanceMethod(object_getClass(obj), s) else {
                throw NSError(domain: "replay", code: 2, userInfo: [NSLocalizedDescriptionKey: "no method \(sel)"])
            }
            return (unsafeBitCast(method_getImplementation(m), to: type), s)
        }
        let recAlloc = class_createInstance(recCls, 0)! as AnyObject
        let (initRec, sInitRec) = try imp(recAlloc, "initWithName:interfaceOrientation:", InitRec.self)
        let rec = initRec(recAlloc, sInitRec, "replay" as NSString, 1 /* portrait */)
        let pathAlloc = class_createInstance(pathCls, 0)! as AnyObject
        let (initPath, sInitPath) = try imp(pathAlloc, "initForTouchAtPoint:offset:", InitPath.self)
        let p0 = points[0]
        let path = initPath(pathAlloc, sInitPath, CGPoint(x: p0.0, y: p0.1), 0)
        let (moveTo, sMove) = try imp(path, "moveToPoint:atOffset:", MoveTo.self)
        let (liftUp, sLift) = try imp(path, "liftUpAtOffset:", LiftUp.self)
        var t = 0.0
        for (i, p) in points.enumerated() where i > 0 {
            t += p.2 / 1000
            if i < points.count - 1 || (p.0 != points[i - 1].0 || p.1 != points[i - 1].1) { moveTo(path, sMove, CGPoint(x: p.0, y: p.1), t) }
        }
        liftUp(path, sLift, t)
        let (addPath, sAdd) = try imp(rec, "addPointerEventPath:", AddPath.self)
        addPath(rec, sAdd, path)
        guard let session = sessCls.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() else {
            throw NSError(domain: "replay", code: 3, userInfo: [NSLocalizedDescriptionKey: "no daemon session"])
        }
        let (synth, sSynth) = try imp(session, "synthesizeEvent:completion:", Synth.self)
        let sem = DispatchSemaphore(value: 0)
        synth(session, sSynth, rec) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + t + 15)
    }
}
