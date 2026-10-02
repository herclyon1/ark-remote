// Ported from maa-automation/web/live.js
//
// ToDesk-style online verdict: ping / _ping, the heartbeat window, startLive, updateLive.
//
// `minAt` means "only accept a state reported after this moment". It must be passed after a save,
// otherwise the state published *before* the change can arrive and the page shows "not changed"
// (2026-08-31: the machine already had the new value, the page still showed the old one).
//
// On/off has one basis: **is the newest state fresh enough**. (2026-09-01, the user: "every time it
// takes ages, and a running machine sometimes shows as off".) An idle machine pushes no state, so the
// page depends on the reply to `refresh`:
//   · a live stream receives the reply — it arrives within a second or two of being pushed;
//   · after 4 s without it, `refresh` is sent once more, so one lost message is not fatal;
//   · at 8 s an ordinary poll is the fallback (in case the stream was cut by the network);
//   · the verdict states its basis (「没应答刷新」) instead of pretending to be certain.
//
// Presence (user 2026-09-02: "like ToDesk: open it and it says online or offline, no manual refresh, no
// polling; manual refresh is the fallback, not the routine"): on open, look once for a heartbeat in the
// last 90 s, and send `watch` — the machine beats at once, then every 30 s for 10 minutes (renewed every
// 8 minutes while in the foreground). A live stream turns the dot on at a heartbeat or state, off at
// once on `bye` (clean shutdown); a hard power cut flips after 90 s without a heartbeat. updateLive's
// timer is a local clock and touches no network. The machine does not beat blindly: ntfy.sh allows
// 250 messages per IP per day.
//
// Not a straight port:
//   · EventSource (SSE) → ntfy's `/json` stream read through a URLSessionDataDelegate (`NtfyStream`);
//     same event fields (event, topic, message, time). Reconnects after 3 s like EventSource. No polling
//     (user 2026-09-02, quoted under Presence above); FoundationNetworking hands a delegate each chunk.
//   · setInterval → Task loops started by `start()`; document.hidden → `foreground`, set by the page from
//     scenePhase; `visibilitychange` → `becameVisible()`; navigator.onLine / online / offline →
//     `deviceOnline`, set by the page.
//   · view.js render() is SwiftUI observation; `alive` replaces the 「现在在跑」 card's re-render.
//   · why(err): URLError codes are mapped as well as the browser's message words.
//   · window.__viewReady guard is gone: there is no script load order here.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class Live {
    static let shared = Live()

    /// A state younger than this means the machine is on (ms).
    static let freshMs: Double = 3 * 60 * 1000
    static let justMs: Double = 60 * 1000
    /// The verdict window at the normal pace (one beat every 30 s), ms.
    static let hbFreshMs: Double = 90 * 1000
    static let watchRenewMs: Double = 8 * 60 * 1000
    static let confirmMs: Double = 8 * 1000
    static let hbSeenKey = "ark-remote-hb"

    /// Seconds between beats, as the heartbeat message itself reports ("hb 30" / "hb 300"). At the daily
    /// cap the machine slows to one beat in 5 minutes; a fixed 90 s window would then show a false red for
    /// 3.5 of every 5 minutes. The window must not grow blindly either: that slows down its one purpose.
    var hbEvery = 30
    /// ms of the last heartbeat (0 = none / bye).
    var lastHb: Double = 0
    /// ms of the last sign of life (heartbeat, state or bye), for 「关机 · 最后心跳 HH:MM」; kept across restarts.
    var hbSeen: Double = 0
    /// Until this moment (ms) the line reads 「正在确认是否在线…」.
    var pendingUntil: Double = 0
    /// Did the last talk to the outside succeed? Without it the page cannot tell "machine off" from
    /// "I have no network", and in a weak-signal spot shows a flat 「关机」.
    var netOk = true
    /// navigator.onLine; the page sets it from the system's network state.
    var deviceOnline = true { didSet { if deviceOnline != oldValue { netOk = deviceOnline; updateLive() } } }
    /// The current verdict (the 「现在在跑」 card follows it).
    var alive = false
    /// The refresh button's busy state while `ping` runs.
    var busy = false
    /// !document.hidden; the page sets it from scenePhase.
    var foreground = true

    /// Stamina.refresh(false), run alongside `ping` (live.js asks the games at the same time).
    @ObservationIgnored var refreshStamina: (@MainActor () async -> Void)?

    @ObservationIgnored let relay: Relay
    @ObservationIgnored let pending: Pending
    @ObservationIgnored private var liveStream: NtfyStream?
    @ObservationIgnored private var pingLatest: JSONValue?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []

    init(relay: Relay = .shared, pending: Pending = .shared) {
        self.relay = relay
        self.pending = pending
        hbSeen = UserDefaults.standard.double(forKey: Self.hbSeenKey)
    }

    func hbWindowMs() -> Double {
        max(Self.hbFreshMs, Double(hbEvery) * 2000 + 30000)
    }

    func sawHb(_ ms: Double) {
        if ms > hbSeen {
            hbSeen = ms
            UserDefaults.standard.set(ms, forKey: Self.hbSeenKey)
        }
    }

    /// 「HH:MM」 of the last sign of life, else of the snapshot, else "".
    func lastBeat() -> String {
        if hbSeen > 0 { return clockHHMM(ms: hbSeen) }
        if let at = relay.snapAt, at != 0 { return clockHHMM(ms: Double(at) * 1000) }
        return ""
    }

    func offline() -> Bool { !deviceOnline || !netOk }

    /// live.js why(err): the browser's English error text means nothing to the user.
    nonisolated static func why(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .cancelled: return "等太久没回应"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return "网络不通"
            default: break
            }
        }
        let m = errorMessage(error)
        let low = m.lowercased()
        if low.contains("fetch") || low.contains("network") || low.contains("load failed") { return "网络不通" }
        if m.contains("429") { return "发得太频繁，被限流了" }
        if low.contains("abort") || low.contains("timeout") || low.contains("timed out") { return "等太久没回应" }
        return m.isEmpty ? "原因不明" : m
    }

    // MARK: ping

    /// The 刷新 action: ask the machine for a fresh state and give a verdict with its basis.
    func ping(minAt: Int? = nil) async {
        guard let cfg = relay.config, !cfg.topic.isEmpty, !cfg.pin.isEmpty else {
            relay.setStatus("还没设置信箱，先去设置里填", "off")
            return
        }
        relay.setStatus("正在问机器…", "")
        busy = true
        // stamina: asked at the same time as the machine (an action repeated within a minute reuses the last answer)
        let stam: Task<Void, Never>? = refreshStamina.map { f in Task { @MainActor in await f() } }
        await pingInner(minAt: minAt, cfg: cfg)
        if let stam { await stam.value }
        busy = false
    }

    private static func atOf(_ v: JSONValue?) -> Double? { v?["at"]?.number }

    private func pingInner(minAt: Int?, cfg: RelayConfig) async {
        let floor = Double(minAt ?? 0)
        var best = relay.snap
        pingLatest = nil

        // open the stream before sending, so the reply cannot beat the listener
        let es = NtfyStream(topics: cfg.topic, since: "30s") { [weak self] d in
            self?.onPingEvent(d, pin: cfg.pin)
        }
        es.open()
        defer { es.close() }

        do { try await relay.send(.object(["action": .string("refresh")])) } catch {
            relay.setStatus("发不出去：" + errorMessage(error), "off")
            return
        }

        let t0 = nowMs()
        var resent = false, polled = false
        while nowMs() - t0 < 11000 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let s = pingLatest, let sAt = Self.atOf(s), best == nil || sAt > (Self.atOf(best) ?? 0) { best = s }
            if let b = best, let bAt = Self.atOf(b), bAt >= floor, nowMs() - bAt * 1000 < Self.freshMs,
               relay.snapAt == nil || bAt > Double(relay.snapAt ?? 0) {
                relay.adopt(b)
                let a = nowMs() - bAt * 1000
                relay.setStatus(a < Self.justMs ? "开机中 · 刚刚更新" : "开机中 · 在忙 · 状态 \(ago(Int(bAt)))", "on")
                return
            }
            if !resent && nowMs() - t0 > 4000 {
                resent = true
                let r = relay
                Task { try? await r.send(.object(["action": .string("refresh")])) }
            }
            if !polled && nowMs() - t0 > 8000 {
                polled = true
                if let s = try? await relay.latestState(since: "2h"), let sAt = Self.atOf(s),
                   best == nil || sAt > (Self.atOf(best) ?? 0) {
                    best = s
                }
            }
        }

        // the whole wait passed without a reply: judge by the age of the newest state and say why
        if let b = best, let bAt = Self.atOf(b), relay.snapAt == nil || bAt > Double(relay.snapAt ?? 0) { relay.adopt(b) }
        guard let b = best, let bAt = Self.atOf(b) else {
            _ = try? await relay.latestState(since: "2h")
            if relay.pinScan.seen > 0 && relay.pinScan.matched == 0 {
                relay.setStatus("信箱里有 \(relay.pinScan.seen) 条消息但 PIN 对不上——检查设置里的 PIN", "off")
                return
            }
            let lb = lastBeat()
            relay.setStatus(lb.isEmpty ? "关机 · 还没有过心跳" : "关机 · 最后心跳 \(lb)", "off")
            return
        }
        let age = nowMs() - bAt * 1000
        if age < Self.justMs { relay.setStatus("开机中 · 刚刚更新", "on"); return }
        if age < Self.freshMs { relay.setStatus("开机中 · 在忙 · 状态 \(ago(Int(bAt)))", "on"); return }
        sawHb(bAt * 1000)
        relay.setStatus("关机 · 没应答刷新 · 最后心跳 \(lastBeat())", "off")
    }

    /// The ping stream's onmessage: keep the newest state whose PIN matches (chunked states are joined).
    private func onPingEvent(_ d: JSONValue, pin: String) {
        if let ev = d["event"]?.string, ev != "message" { return }
        guard let m = Relay.envelope(d), m["kind"]?.string == "state", m["pin"]?.jsString == pin else { return }
        let body: JSONValue?
        if m["gzp"] != nil { body = try? relay.joinChunks(m) } else { body = try? Relay.unwrap(m) }
        guard let body, let at = Self.atOf(body) else { return }
        if pingLatest == nil || at > (Self.atOf(pingLatest) ?? 0) { pingLatest = body }
    }

    // MARK: presence

    /// live.js updateLive(): the status line from the heartbeat verdict. Local clock only.
    func updateLive() {
        guard relay.config != nil else { return }
        let isAlive = lastHb > 0 && (nowMs() - lastHb < hbWindowMs())
        if alive != isAlive { alive = isAlive }
        if isAlive {
            // 「 · 」 separates: the status card's second line = 「实时 · 配置 1 分钟前」
            relay.setStatus("开机中 · \(hbEvery > 60 ? "每 \(Int((Double(hbEvery) / 60).rounded())) 分钟报一次" : "实时")"
                            + (relay.snapAt.map { " · 配置 \(ago($0))" } ?? ""), "on")
        } else if nowMs() < pendingUntil {
            relay.setStatus("正在确认是否在线…", "")
        } else if offline() {
            // when we cannot connect, say only that. The machine may be on; the words just cannot get through.
            relay.setStatus(relay.snapAt.map { "连不上 · 先看看你这边有没有网 · 最后状态 \(ago($0))" }
                            ?? "连不上 · 先看看你这边有没有网", "")
        } else if !lastBeat().isEmpty {
            relay.setStatus("关机 · 最后心跳 \(lastBeat())", "off")   // offline wording set by 验收 2026-09-18
        } else {
            relay.setStatus("关机 · 还没有过心跳", "off")
        }
    }

    /// 「我在看」: the machine beats at once on receipt. No answer within 8 s counts as off.
    func askWatch() {
        guard let cfg = relay.config, !cfg.topic.isEmpty, !cfg.pin.isEmpty else { return }
        if !(lastHb > 0 && nowMs() - lastHb < hbWindowMs()) { pendingUntil = nowMs() + Self.confirmMs }
        updateLive()   // show 「正在确认…」 at once, so the old 「关机」 does not hang 5 more seconds
        let r = relay
        Task { [weak self] in
            do {
                try await r.send(.object(["action": .string("watch")]))
                self?.netOk = true
            } catch {
                self?.netOk = false
                self?.updateLive()
            }
        }
    }

    /// On open / back to the foreground: read the heartbeat history once; a beat means on at once.
    func probeHb() async {
        guard let cfg = relay.config else { return }
        do {
            let (data, _) = try await httpFetch("\(ntfyBase)/\(cfg.topic)-hb/json?poll=1&since=90s&_=\(Int(nowMs()))")
            var hb: Double = 0, bye: Double = 0
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.isEmpty { continue }
                guard let e = try? JSONValue.parse(l), e["event"]?.string == "message" else { continue }
                let t = (e["time"]?.number ?? 0) * 1000
                if e["message"]?.string == "bye" {
                    bye = max(bye, t)
                } else {
                    hb = max(hb, t)
                    if let n = Self.hbPace(e["message"]) { hbEvery = n }
                }
            }
            lastHb = bye >= hb ? 0 : hb
            sawHb(max(hb, bye))
            netOk = true
        } catch {
            netOk = false
        }
    }

    /// "hb 30" → 30; anything else → nil (keeps the current pace).
    private static func hbPace(_ msg: JSONValue?) -> Int? {
        guard let s = msg?.string else { return nil }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "hb", let n = Int(parts[1]), n != 0 else { return nil }
        return n
    }

    /// live.js startLive(): one stream on the state topic and the heartbeat topic.
    func startLive() {
        liveStream?.close()
        liveStream = nil
        guard let cfg = relay.config else { return }
        let s = NtfyStream(topics: "\(cfg.topic),\(cfg.topic)-hb", since: "30s") { [weak self] d in
            self?.onLiveEvent(d, cfg: cfg)
        }
        liveStream = s
        s.open()
    }

    func stopLive() {
        liveStream?.close()
        liveStream = nil
    }

    private func onLiveEvent(_ d: JSONValue, cfg: RelayConfig) {
        if let ev = d["event"]?.string, ev != "message" { return }
        let t = (d["time"]?.number ?? 0) * 1000
        if d["topic"]?.string == cfg.topic + "-hb" {
            sawHb(t)
            if d["message"]?.string == "bye" {
                lastHb = 0
                pendingUntil = 0
            } else {
                lastHb = t
                if let n = Self.hbPace(d["message"]) { hbEvery = n }
                pending.resendStale()
            }
            updateLive()
            return
        }
        guard let text = d["message"]?.string, let m = try? JSONValue.parse(text) else { return }
        guard m["kind"]?.string == "state", m["pin"]?.jsString == cfg.pin else { return }
        guard let body = try? Relay.unwrap(m) else { return }
        relay.adopt(body)
        lastHb = max(lastHb, t)   // a state is proof of life too
        sawHb(t)
        pending.resendStale()
        updateLive()
    }

    /// live.js visibilitychange handler (also the boot sequence): stream, heartbeat history, watch.
    func becameVisible() async {
        guard relay.config != nil else { return }
        startLive()
        await probeHb()
        updateLive()
        askWatch()
    }

    /// setInterval(updateLive, 5000) and the 8-minute watch renewal while in the foreground.
    func start() {
        guard timers.isEmpty else { return }
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.updateLive()
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.watchRenewMs) * 1_000_000)
                if let self, self.foreground { self.askWatch() }
            }
        })
    }

    func stop() {
        for t in timers { t.cancel() }
        timers = []
        stopLive()
    }
}

/// An ntfy subscription read as a stream: `GET /<topics>/json?since=…` keeps the connection open and writes
/// one JSON event per line (ntfy sends an `open` event at once and a `keepalive` every 45 s). Events are
/// delivered on the main actor. Reconnects 3 s after a drop until closed, from the last message id seen.
///
/// No polling fallback, like live.js (user 2026-09-02, see the file header). On Android, FoundationNetworking's
/// NativeProtocol.didReceive(data:) passes each libcurl chunk to `urlSession(_:dataTask:didReceive:)`
/// as it arrives (swift-corelibs-foundation main, NativeProtocol.swift:96-141), so the stream works there.
final class NtfyStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let topics: String
    private let since: String
    private let onEvent: @MainActor (JSONValue) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var buffer = Data()
    private var closed = false
    private var lastId: String?

    init(topics: String, since: String, onEvent: @escaping @MainActor (JSONValue) -> Void) {
        self.topics = topics
        self.since = since
        self.onEvent = onEvent
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, session == nil,
              let url = URL(string: "\(ntfyBase)/\(topics)/json?since=\(lastId ?? since)") else { return }
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: q)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 24 * 3600
        session = s
        buffer = Data()
        s.dataTask(with: req).resume()
        DiagLog.shared.record("stream", ["state": "connecting"])
    }

    func close() {
        lock.lock()
        closed = true
        let s = session
        session = nil
        lock.unlock()
        s?.invalidateAndCancel()
    }

    private func deliver(_ events: [JSONValue]) {
        lock.lock()
        if let id = events.last?["id"]?.string { lastId = id }
        let isClosed = closed
        lock.unlock()
        if events.contains(where: { $0["event"]?.string == "open" }) { DiagLog.shared.record("stream", ["state": "open"]) }
        if isClosed { return }
        let f = onEvent
        for e in events { Task { @MainActor in f(e) } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        let events = lines.compactMap { $0.isEmpty ? nil : try? JSONValue.parse($0) }
        if !events.isEmpty { deliver(events) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let reconnect = !closed && self.session === session
        if reconnect { self.session = nil }
        lock.unlock()
        session.finishTasksAndInvalidate()
        DiagLog.shared.record("stream", ["state": reconnect ? "dropped" : "closed", "error": error.map { errorMessage($0) } ?? ""])
        guard reconnect else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.open() }
    }
}
