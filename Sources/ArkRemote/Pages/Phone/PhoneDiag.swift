import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

// The app's 诊断记录 and 运行自检. The web page's versions run in the browser (?diag=1 injects seg-frames-logger.js,
// 自检 runs web/accept.js); the app records what it can see itself — the network requests, the ntfy push stream
// and the network on / off changes — and its self check asks the outside once per tap. Nothing here polls: events
// are written where they happen (httpFetch, NtfyStream) or when an observed value changes.

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

    /// The exported file: what the app is, then every event, oldest first.
    func exportJSON(appVersion: String, selfCheck: [SelfCheckItem]) -> String {
        persist()
        lock.lock()
        let list = events
        lock.unlock()
        var o: [String: JSONValue] = [
            "app": .string("ArkRemote"),
            "version": .string(appVersion),
            "exportedAt": .double(nowMs()),
            "events": .array(list),
        ]
        #if os(Android)
        o["platform"] = .string("android")
        #else
        o["platform"] = .string("darwin")
        #endif
        if !selfCheck.isEmpty {
            o["selfCheck"] = .array(selfCheck.map { .object(["name": .string($0.name), "ok": .bool($0.ok), "detail": .string($0.detail)]) })
        }
        return JSONValue.object(o).encodedString()
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
