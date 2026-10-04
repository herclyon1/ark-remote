import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

// The app's 诊断记录 and 运行自检. The web page's versions run in the browser (?diag=1 injects seg-frames-logger.js,
// 自检 runs web/accept.js); the app records what it can see itself — the network requests, the ntfy push stream
// and the network on / off changes — and its self check asks the outside once per tap. Nothing here polls: events
// are written where they happen (httpFetch, NtfyStream) or when an observed value changes.
// Leaving the phone is the web's 件 B / 件 C (seg-frames-logger.js:45-53, 437-548): nothing is sent until the user taps
// 「就是这里」 (DiagUI.mark); the marked record is PUT to the diagnostic bucket (DiagUpload), a failure is queued on the
// phone and retried on the next upload and the next start, and every state is written on the bottom line (DiagUI.line).

/// The diagnostics log: off unless the switch is on, the newest `maxEvents` kept, saved for the next start.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()
    static let enabledKey = "ark-diag"            // the web page's key
    static let storeKey = "ark-diag-events"
    static let maxEvents = 400
    /// Saving rewrites the whole list, so it happens at most once per this many ms (and on export).
    static let saveGapMs: Double = 5000

    private let lock = NSLock()
    private var on: Bool
    private var events: [JSONValue] = []
    private var lastSave: Double = 0
    private var dirty = false

    private init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: Self.enabledKey)
        if let raw = d.string(forKey: Self.storeKey), let v = try? JSONValue.parse(raw), case .array(let a) = v {
            events = a
        }
    }

    var enabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        on = value
        lock.unlock()
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value { record("diag", ["state": "on"]) }
        Task { @MainActor in DiagUI.shared.setOn(value) }
    }

    /// One event: `{t: epoch ms, kind, ...fields}`. A no-op while the switch is off.
    func record(_ kind: String, _ fields: [String: String] = [:]) {
        lock.lock()
        guard on else { lock.unlock(); return }
        var o: [String: JSONValue] = ["t": .double(nowMs()), "kind": .string(kind)]
        for (k, v) in fields { o[k] = .string(v) }
        events.append(.object(o))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        dirty = true
        let save = nowMs() - lastSave >= Self.saveGapMs
        lock.unlock()
        if save { persist() }
        Task { @MainActor in DiagCounter.shared.count += 1 }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }

    func clear() {
        lock.lock()
        events = []
        dirty = true
        lock.unlock()
        persist()
        Task { @MainActor in DiagCounter.shared.count += 1 }
    }

    private func persist() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = JSONValue.array(events)
        dirty = false
        lastSave = nowMs()
        lock.unlock()
        UserDefaults.standard.set(snapshot.encodedString(), forKey: Self.storeKey)
    }

    /// The exported record: what the app is, every event (oldest first) and this phone's last 运行自检
    /// (`selfcheck`, view.js lastSelfcheck(): null = never run here; kept across restarts, LastSelfCheck).
    func exportObject(appVersion: String) -> [String: JSONValue] {
        persist()
        lock.lock()
        let list = events
        lock.unlock()
        var o: [String: JSONValue] = [
            "app": .string("ArkRemote"),
            "version": .string(appVersion),
            "page_version": .string(appVersion),
            "exportedAt": .double(nowMs()),
            "events": .array(list),
            "selfcheck": LastSelfCheck.summary(),
        ]
        #if os(Android)
        o["platform"] = .string("android")
        #else
        o["platform"] = .string("darwin")
        #endif
        return o
    }

    func exportJSON(appVersion: String) -> String {
        JSONValue.object(exportObject(appVersion: appVersion)).encodedString()
    }

    /// A URL for the log without secrets: query dropped, and on ntfy the first path segment (the mailbox name) masked.
    static func redact(_ urlString: String) -> String {
        guard let u = URL(string: urlString), let host = u.host else { return "?" }
        var parts = u.path.split(separator: "/").map(String.init)
        if urlString.hasPrefix(ntfyBase), !parts.isEmpty { parts[0] = "<信箱>" }
        // the state object's name is as good as the topic for reading the state
        if urlString.hasPrefix(cosBase), parts.first == "state", parts.count > 1 { parts[1] = "<状态>" }
        return host + "/" + parts.joined(separator: "/")
    }
}

/// Bumped on every event so the page's count and share item redraw.
@MainActor @Observable final class DiagCounter {
    static let shared = DiagCounter()
    var count = 0
}

/// Writes a line when the device goes on / off the network, the reachability of the outside flips, or the
/// machine status line changes. Re-armed after each change (Observation), so it costs nothing while nothing moves.
@MainActor enum DiagWatch {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        arm()
    }

    private static func arm() {
        let live = Live.shared, relay = Relay.shared
        let before = (live.deviceOnline, live.netOk, relay.statusText)
        withObservationTracking {
            _ = live.deviceOnline
            _ = live.netOk
            _ = relay.statusText
        } onChange: {
            Task { @MainActor in
                let now = (live.deviceOnline, live.netOk, relay.statusText)
                if now.0 != before.0 { DiagLog.shared.record("network", ["device": now.0 ? "online" : "offline"]) }
                if now.1 != before.1 { DiagLog.shared.record("reach", ["netOk": now.1 ? "yes" : "no"]) }
                if now.2 != before.2 { DiagLog.shared.record("status", ["text": now.2, "state": relay.statusState]) }
                arm()
            }
        }
    }
}

struct SelfCheckItem: Sendable, Equatable {
    var name: String
    var ok: Bool
    var detail: String
}

/// 运行自检: the checks the app can make on its own, one pass per tap.
@MainActor enum SelfCheck {
    static func run() async -> [SelfCheckItem] {
        var out: [SelfCheckItem] = []
        let relay = Relay.shared, live = Live.shared, stamina = StaminaStore.shared

        // 1. configuration
        let cfg = relay.config
        let cfgOk = cfg.map { !$0.topic.isEmpty && !$0.pin.isEmpty } ?? false
        out.append(SelfCheckItem(name: "信箱和 PIN", ok: cfgOk, detail: cfgOk ? "已填" : "没填，先用免输入链接打开一次"))
        let acc = stamina.tokens == nil ? "" : stamina.status()
        out.append(SelfCheckItem(name: "游戏账号", ok: !acc.isEmpty, detail: acc.isEmpty ? "没有密钥，体力读不到" : acc))

        // 2. the phone's own network
        out.append(SelfCheckItem(name: "手机网络", ok: live.deviceOnline, detail: live.deviceOnline ? "系统说有网" : "系统说没网"))

        guard let cfg, cfgOk else { return out }

        // 3. the relay mailbox: one read of the last 10 minutes
        let t0 = nowMs()
        do {
            let msgs = try await Relay.pollTopic(cfg.topic, since: "10m")   // one-shot: one read per 运行自检 tap
            out.append(SelfCheckItem(name: "连得上中继", ok: true, detail: "\(Int(nowMs() - t0)) ms，最近 10 分钟 \(msgs.count) 条消息"))
        } catch {
            out.append(SelfCheckItem(name: "连得上中继", ok: false, detail: Live.why(error)))
        }

        // 4. the push stream: open one, wait for ntfy's `open` event, close it
        let pushMs = await pushProbe(topic: cfg.topic)
        out.append(SelfCheckItem(name: "推送通道", ok: pushMs != nil,
                                 detail: pushMs.map { "\($0) ms 连上" } ?? "8 秒内没连上"))

        // 5. the machine, as the status line has it now
        out.append(SelfCheckItem(name: "机器", ok: relay.statusState == "on",
                                 detail: relay.statusText.isEmpty ? "还没问过" : relay.statusText))

        // 6. the game accounts, when there are any: one forced read
        if !acc.isEmpty {
            if let r = await stamina.refresh(force: true) {
                let errs = [("明日方舟", r.arknights.error), ("终末地", r.endfield.error), ("鸣潮", r.wuwa.error)]
                    .compactMap { n, e in e.map { "\(n)：\($0)" } }
                out.append(SelfCheckItem(name: "体力接口", ok: errs.isEmpty, detail: errs.isEmpty ? "三个都读到了" : errs.joined(separator: "；")))
            } else {
                out.append(SelfCheckItem(name: "体力接口", ok: false, detail: stamina.err.isEmpty ? "没读到" : stamina.err))
            }
        }

        for i in out { DiagLog.shared.record("selfcheck", ["name": i.name, "ok": i.ok ? "yes" : "no", "detail": i.detail]) }
        LastSelfCheck.save(out)
        return out
    }

    /// ms until the stream's `open` event, or nil after 8 s.
    private static func pushProbe(topic: String) async -> Int? {
        let t0 = nowMs()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let done = OnceFlag()
            var stream: NtfyStream?
            stream = NtfyStream(topics: topic, since: "\(Int(t0 / 1000))") { e in
                if e["event"]?.string == "open", done.take() {
                    stream?.close()
                    cont.resume(returning: Int(nowMs() - t0))
                }
            }
            stream?.open()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if done.take() {
                    stream?.close()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// This phone's last 运行自检, kept for the next start (the web keeps accept.js's result in localStorage ark-accept and
/// every diagnostic record carries it, view.js:3045-3053 lastSelfcheck).
enum LastSelfCheck {
    static let key = "ark-accept"   // the web page's key

    static func save(_ items: [SelfCheckItem]) {
        let fails = items.filter { !$0.ok }.count
        let o: JSONValue = .object([
            "at": .double(nowMs()),
            "total": .int(items.count),
            "fails": .int(fails),
            "rows": .array(items.map { .object(["name": .string($0.name), "ok": .bool($0.ok), "detail": .string($0.detail)]) }),
        ])
        UserDefaults.standard.set(o.encodedString(), forKey: key)
    }

    /// The whole stored result (the 「自检结果」 sheet copies / shares this one).
    static func stored() -> JSONValue? {
        guard let raw = UserDefaults.standard.string(forKey: key), let a = try? JSONValue.parse(raw), a["rows"]?.array != nil else { return nil }
        return a
    }

    /// view.js lastSelfcheck(): {at, total, fails, failRows}; null when it never ran on this phone.
    static func summary() -> JSONValue {
        guard let a = stored(), let rows = a["rows"]?.array else { return .null }
        return .object([
            "at": a["at"] ?? .null,
            "total": a["total"] ?? .null,
            "fails": a["fails"] ?? .null,
            "failRows": .array(rows.filter { $0["ok"]?.bool == false }),
        ])
    }
}

/// KB with one decimal, as the web writes it (Math.round(len / 1024 * 10) / 10: 12 not 12.0).
func diagKB(_ text: String) -> String {
    let v = (Double(text.utf8.count) / 1024 * 10).rounded() / 10
    return v == v.rounded() ? "\(Int(v))" : "\(v)"
}

/// The diagnostics' own surfaces (the web's #diagmark, #diagline, #diagsheet) and the upload behind them
/// (seg-frames-logger.js 件 B 「就是这里」 and 件 C, view.js:3054-3087 showDiagSheet).
@MainActor @Observable final class DiagUI {
    static let shared = DiagUI()
    static let queueKey = "ark-diag-queue"   // the web page's key
    /// The web keeps at most LOCAL_N = 10 records on the phone; the queue of unsent ones is held to the same count.
    static let keepMax = 10
    /// seg-frames-logger.js:440 MARK_WORDS, and the panel's last row 「直接发（不选词）」 (word nil).
    static let markWords = ["不该动", "动错了", "卡住了", "慢半拍", "位置不对"]
    /// seg-frames-logger.js:497, the line while nothing has been sent yet.
    static let startLine = "诊断记录开着：点过的控件记在手机里，不送；出问题按右下角「就是这里」，只送那一份和它前面 3 份"

    /// The 诊断记录 switch, mirrored here so the mark button and the line appear / go at once.
    var on = DiagLog.shared.enabled
    /// #diagline's text.
    var line = DiagUI.startLine
    /// The record #diagsheet shows (`upload` = where it got to; refreshed live, view.js showDiagSheet._live).
    var sheetRecord: JSONValue?
    /// #diagsheet open, from a tap on the line or the first failed upload of this run.
    var sheetOpen = false

    @ObservationIgnored private var lastMarked: JSONValue?
    @ObservationIgnored private var sentN = 0
    @ObservationIgnored private var keptN = 0
    @ObservationIgnored private var sheetShown = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var flushing = false

    func setOn(_ value: Bool) {
        on = value
        if value { line = Self.startLine; start() } else { sheetOpen = false }
    }

    /// Once per run while the switch is on (the web's recorder loads with the page and calls flush() at once):
    /// the queue left from earlier runs goes out first.
    func start() {
        guard on, !started else { return }
        started = true
        keptN = readQ().count
        Task { await flush() }
    }

    /// 「就是这里」 (seg-frames-logger.js markNow): the user's word goes into the record and the record leaves the phone.
    /// The app has no per-gesture records, so the marked record is the whole log at this moment.
    func mark(_ word: String?) {
        let m: JSONValue = .object(["at": .double(nowMs()), "word": word.map { JSONValue.string($0) } ?? .null])
        var o = DiagLog.shared.exportObject(appVersion: PhoneLink.appVersion)
        o["kind"] = .string("mark")
        o["record_id"] = .string(Self.rid())
        o["marks"] = .array([m])
        o["marked"] = .bool(true)
        let rec = JSONValue.object(o)
        lastMarked = rec
        Task { await upload(o) }
    }

    /// A tap on the line: the latest marked record while it is not in the bucket (the line then says 「点这行可复制 / 分享」),
    /// otherwise the log as it is now, unsent (upWord 「没标记，留在手机里没送」).
    func openSheet() {
        prepareSheet()
        sheetOpen = true
    }

    /// Sets the record the sheet shows without presenting it (the 手机 page's own row presents its own sheet).
    func prepareSheet() {
        if let m = lastMarked, m["upload"]?["state"]?.string != "sent" {
            sheetRecord = m
        } else {
            var o = DiagLog.shared.exportObject(appVersion: PhoneLink.appVersion)
            o["record_id"] = .string(Self.rid())
            o["upload"] = .object(["state": .string("local"), "at": .double(nowMs())])
            sheetRecord = .object(o)
        }
    }

    /// view.js showDiagSheet msg(): what the record is and where its upload got to.
    static func sheetMessage(_ rec: JSONValue) -> (json: String, text: String, sent: Bool) {
        let json = rec.encodedString()
        let n = rec["events"]?.array?.count ?? 0
        let marks = rec["marks"]?.array ?? []
        let mk = marks.isEmpty ? "" : "你标了 \(marks.count) 处（\(marks.map { $0["word"]?.string ?? "未选词" }.joined(separator: "、"))）。"
        let u = rec["upload"]
        let state = u?["state"]?.string
        let up: String
        if u == nil || state == nil { up = "上传：还在送" }
        else if state == "sent" { up = "上传：已送达" }
        else if state == "local" { up = "没标记，留在手机里没送" }
        else { up = "上传：没送到（\(u?["detail"]?.string ?? "原因不明")）" }
        return (json, "\(mk)一份 JSON，\(diagKB(json)) KB，\(n) 条。\(up)。送不到时复制后粘到聊天里，或用分享发出。", state == "sent")
    }

    // MARK: 件 C

    private func upload(_ rec: [String: JSONValue]) async {
        let body = JSONValue.object(rec).encodedString()
        let key = Self.keyFor(), kb = diagKB(body)
        if await DiagUpload.put(name: key, data: Data(body.utf8)) {
            sentN += 1
            report(rec, "sent", "已送达 \(sentN) 份（这份 \(kb) KB）", key)
            await flush()
        } else {
            // DiagUpload.put says only yes / no, so the web's reason is 「原因不明」 here (view.js upWord's own fallback)
            keep(key, body)
            report(rec, "kept", "没送到（原因不明），已存在手机里共 \(keptN) 份；点这行可复制 / 分享", key)
        }
    }

    /// seg-frames-logger.js report(): the record learns where it got to, the line says it, and the first failure of a run
    /// opens the copy / share sheet (after that the line does it on a tap).
    private func report(_ rec: [String: JSONValue], _ state: String, _ detail: String, _ key: String) {
        var o = rec
        o["upload"] = .object(["state": .string(state), "detail": .string(detail), "key": .string(key), "at": .double(nowMs())])
        let r = JSONValue.object(o)
        if lastMarked?["record_id"] == r["record_id"] { lastMarked = r }
        if sheetRecord?["record_id"] == r["record_id"] { sheetRecord = r }
        line = detail
        if state != "sent", !sheetShown {
            sheetShown = true
            sheetRecord = r
            sheetOpen = true
        }
    }

    /// The queue left on the phone, oldest first, until one does not go.
    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        var a = readQ()
        while let it = a.first {
            guard let key = it["key"]?.string, let body = it["body"]?.string else { a.removeFirst(); writeQ(a); continue }
            guard await DiagUpload.put(name: key, data: Data(body.utf8)) else { break }
            a.removeFirst()
            writeQ(a)
            sentN += 1
            line = "补送成功，本地还剩 \(a.count) 份"
        }
    }

    private func readQ() -> [JSONValue] {
        guard let raw = UserDefaults.standard.string(forKey: Self.queueKey), let v = try? JSONValue.parse(raw) else { return [] }
        return v.array ?? []
    }

    private func writeQ(_ list: [JSONValue]) {
        var a = list
        var dropped = 0
        while a.count > Self.keepMax { a.removeFirst(); dropped += 1 }
        UserDefaults.standard.set(JSONValue.array(a).encodedString(), forKey: Self.queueKey)
        keptN = a.count
        if dropped > 0 { line = "本地存不下，扔掉最早的 \(dropped) 份；现存 \(a.count) 份" }
    }

    private func keep(_ key: String, _ body: String) {
        var a = readQ()
        a.append(.object(["key": .string(key), "body": .string(body), "why": .string("原因不明"), "at": .double(nowMs())]))
        writeQ(a)
    }

    /// seg-frames-logger.js keyFor(): diag/YYYYMMDD-HHMMSS-<32 hex>.json in the phone's local time.
    static func keyFor() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        func z(_ n: Int?) -> String { let s = String(n ?? 0); return s.count < 2 ? "0" + s : s }
        return "diag/\(c.year ?? 0)\(z(c.month))\(z(c.day))-\(z(c.hour))\(z(c.minute))\(z(c.second))-\(rid()).json"
    }

    /// 16 random bytes in hex (seg-frames-logger.js rid()).
    static func rid() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
