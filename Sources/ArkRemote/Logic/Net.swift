// Ported from maa-automation/web/net.js
//
// Mailbox protocol: send / readMessages / envelope / joinChunks / unwrap / latestState.
// The page globals that net.js reads from view.js (NTFY, cfg, snap, save_cache) live here too,
// on `Relay`, because this is the lowest layer of the logic. Rendering is left to SwiftUI
// observation, so view.js's render() has no counterpart.
//
// Not a straight port: the browser's DecompressionStream("gzip") → `Gzip.inflate` below, the system zlib on every
// platform (the iOS / macOS SDKs and the Android Swift SDK each ship a `zlib` module that links libz).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
#if !SKIP   // a C module: kept out of the Kotlin skipstone generates for this file (Kotlin has no `zlib`)
import zlib
#endif
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported (skipstone warning)

/// view.js: `const NTFY = "https://ntfy.sh"`.
let ntfyDefaultBase = "https://ntfy.sh"

/// The mailbox server: ntfy.sh, unless the replay test (scripts/replay/run.py) has pointed UserDefaults
/// "ark-ntfy-base" at its local ntfy server (scripts/replay/ntfy_local.py). Only this machine's loopback or the Android
/// emulator's alias of the host (10.0.2.2) is taken, so the key can never send a mailbox anywhere else; nothing in
/// the app writes it.
var ntfyBase: String {
    var v = (UserDefaults.standard.string(forKey: "ark-ntfy-base") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    while v.hasSuffix("/") { v.removeLast() }
    guard !v.isEmpty, let u = URL(string: v), u.scheme == "http" || u.scheme == "https",
          ["127.0.0.1", "localhost", "10.0.2.2"].contains(u.host ?? "") else { return ntfyDefaultBase }
    return v
}

/// The Tencent COS bucket the machine stores its whole state in (maa-automation relay/ark_relay/phone.py
/// `state_cos`, COS_BUCKET / COS_REGION of the machine's .env). Since 2026-10-02 (the user, 22:22) a big state
/// is no longer cut into ntfy pieces: the relay PUTs the envelope there, public-read, and posts only
/// `state <ts> <bytes>` on the topic.
let cosBase = "https://ark-evidence-1315873325.cos.ap-shanghai.myqcloud.com"

/// net.js `now()`: whole seconds since the epoch.
func nowSec() -> Int { Int(Date().timeIntervalSince1970) }
/// JS `Date.now()`: milliseconds since the epoch.
func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

// MARK: - JSON value

/// A JSON value. The relay's snapshot is a free-form object read by deep paths
/// (`snap.master[game].values[path]`), so it stays untyped; this enum keeps it Sendable and Codable.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }
    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
    func encodedString() -> String {
        String(decoding: encoded(), as: UTF8.self)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// JS `Number(x)`: numbers as is, numeric strings parsed, booleans 0/1, null 0; nil for NaN.
    var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d.isNaN ? nil : d
        case .bool(let b): return b ? 1 : 0
        case .null: return 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            return Double(t)
        default: return nil
        }
    }
    /// JS truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }
    /// JS `String(x)`.
    var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return jsNumberString(d)
        case .string(let s): return s
        case .array(let a): return a.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }
}

/// JS number → string for the values the relay sends (integers print without ".0").
func jsNumberString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
    return String(d)
}

/// `Int(d)` traps on a value that is infinite or outside Int's range; a number from the machine, COS or a game's API
/// that big is no usable number, so it reads as missing (edge audit 18: an `at` of 1e20 ended the app).
func safeInt(_ d: Double?) -> Int? {
    guard let d, d.isFinite, d >= Double(Int.min), d < Double(Int.max) else { return nil }
    return Int(d)
}

/// Two-digit zero pad, `String(x).padStart(2, "0")`.
func pad2(_ x: Int) -> String { x < 10 ? "0\(x)" : String(x) }

/// `new Date(ms).toTimeString().slice(0, 5)`: local "HH:MM".
func clockHHMM(ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
}

/// view.js `ago(ts)` (seconds), used by the status lines in live.js.
func ago(_ ts: Int) -> String {
    let s = max(0, nowSec() - ts)
    if s < 60 { return "\(s) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时 \(s % 3600 / 60) 分前" }
    return "\(s / 86400) 天前"
}

/// `encodeURIComponent`.
func encodeURIComponent(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    // CharacterSet.alphanumerics includes non-ASCII letters; restrict to ASCII as JS does.
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.isASCII, allowed.contains(scalar) {
            out.unicodeScalars.append(scalar)
        } else {
            for b in String(scalar).utf8 {
                let hex = Array("0123456789ABCDEF")
                out += "%" + String(hex[Int(b >> 4)]) + String(hex[Int(b & 15)])
            }
        }
    }
    return out
}

// MARK: - Errors

/// An error whose message is shown to the user as is (the JS `new Error("…")`).
struct AppError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The `e.message` of a thrown error.
func errorMessage(_ error: Error) -> String {
    if let e = error as? AppError { return e.message }
    if let e = error as? NtfyLimit { return e.errorDescription ?? "" }
    if let e = error as? URLError { return "URLError \(e.code.rawValue): \(e.localizedDescription)" }
    return error.localizedDescription
}

/// ntfy refused a send with 429. Its body says which limit (maa-automation relay/ark_relay/phone.py _ntfy_code, ntfy
/// server/errors.go): 42901 the request burst, back in seconds; 42908 the day's messages per IP, back at UTC midnight
/// ("every day at midnight (UTC)", docs.ntfy.sh/config visitor-message-daily-limit). 「歇几秒再点」 was wrong for the
/// second, the one usually hit (edge audit 26); and a limit is not a lost network (edge audit 12).
struct NtfyLimit: LocalizedError, Sendable {
    let daily: Bool
    var errorDescription: String? {
        guard daily else { return "太频繁了，歇几秒再点（429）" }
        let next = (nowSec() / 86400 + 1) * 86400   // the next UTC midnight, said on this phone's clock
        return "今天信箱的发送额度用完了，\(clockHHMM(ms: Double(next) * 1000)) 恢复（429）"
    }
}

// MARK: - HTTP

/// `fetch(url, {cache: "no-store", ...})` with the basic `URLSession.data(for:)` call only.
func httpFetch(_ urlString: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
               noStore: Bool = true) async throws -> (Data, Int) {
    guard let url = URL(string: urlString) else { throw AppError("网址不对：\(urlString)") }
    var req = URLRequest(url: url)
    req.httpMethod = method
    if noStore { req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData }
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    let t0 = nowMs()
    let data: Data, resp: URLResponse
    do {
        (data, resp) = try await URLSession.shared.data(for: req)
    } catch {
        // 诊断记录 (Pages/Phone/PhoneDiag.swift): a no-op unless the switch is on
        DiagLog.shared.record("fetch", ["method": method, "url": DiagLog.redact(urlString), "ms": "\(Int(nowMs() - t0))", "error": errorMessage(error)])
        throw error
    }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    DiagLog.shared.record("fetch", ["method": method, "url": DiagLog.redact(urlString), "ms": "\(Int(nowMs() - t0))", "status": "\(status)", "bytes": "\(data.count)"])
    return (data, status)
}

// MARK: - Relay config and snapshot (view.js globals)

/// view.js `cfg = {topic, pin}`, stored under `ark-remote-cfg` like the page.
struct RelayConfig: Codable, Sendable, Equatable {
    var topic: String
    var pin: String
}

/// view.js ask(title, msg, "好", false, { single: true }): an alert with one 「好」 (a reason is a sentence, not a toast).
struct AlertNote: Sendable, Equatable {
    let title: String
    let message: String
}

/// net.js pinScan: how many states the mailbox held and how many matched the PIN.
struct PinScan: Sendable, Equatable {
    var seen = 0
    var matched = 0
}

/// The relay mailbox plus the page state net.js depends on.
@MainActor @Observable final class Relay {
    static let shared = Relay()

    static let cfgKey = "ark-remote-cfg"          // view.js LS
    static let snapKey = "ark-remote-cfg-snap"    // view.js LS + "-snap"

    /// view.js `cfg`; nil until the setup screen has been filled.
    var config: RelayConfig?
    /// view.js `snap`: the newest state the machine reported (the unwrapped body).
    var snap: JSONValue?
    /// view.js setStatus(text, state): the status line and its dot ("on" / "off" / "").
    var statusText = ""
    var statusState = ""
    /// view.js ask(..., { single: true }): the alert for the page to present; nil when none is up.
    var alert: AlertNote?
    /// net.js pinScan.
    var pinScan = PinScan()
    /// The state on COS carries another PIN (cosState). Kept apart from pinScan, which latestState() zeroes and counts
    /// from ntfy alone: a normal state is on COS and the topic holds only `state <ts> <bytes>` notices (not envelopes),
    /// so a wrong PIN read as 「还没有过心跳」 (edge audit 24).
    @ObservationIgnored var cosPinBad = false
    /// ntfy's clock minus this phone's (ms), from the `time` ntfy stamps on the open / keepalive events of a stream (its
    /// own now; Live.onLiveEvent / onPingEvent). The age of a machine or ntfy stamp is taken against serverNowMs(): with
    /// the phone's clock, a phone 90 s off showed 「关机」 for a running machine, one behind kept 「开机中」 after a power
    /// cut, and a receipt check took a state from before the send as the answer (edge audit 3). 0 until the first event.
    @ObservationIgnored var clockSkewMs: Double = 0
    func serverNowMs() -> Double { nowMs() + clockSkewMs }

    /// Called after `adopt` takes a newer snapshot. view.js render() does
    /// `if (Stamina.fromSnapshot(snap)) Stamina.refresh(true)`; the stamina port hooks that in here.
    @ObservationIgnored var onNewSnapshot: (@MainActor (JSONValue) -> Void)?

    /// net.js chunkBox: sid -> (index -> slice).
    @ObservationIgnored private var chunkBox: [String: [Int: String]] = [:]

    init() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.cfgKey), let data = raw.data(using: .utf8) {
            config = try? JSONDecoder().decode(RelayConfig.self, from: data)
        }
        if let raw = d.string(forKey: Self.snapKey), let v = try? JSONValue.parse(raw), !v.isNull {
            snap = v
        }
    }

    /// The setup screen's 「开始使用」: topic and PIN trimmed. The topic keeps its case: ntfy topic names are case-sensitive
    /// and the relay posts / listens on ARK_PHONE_TOPIC as written in .env (phone.py:576 strips only, config.py:137), so a
    /// lower-cased copy of a name with capitals would send every command to another mailbox (审查 A6).
    func saveConfig(topic: String, pin: String) {
        let c = RelayConfig(topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
                            pin: pin.trimmingCharacters(in: .whitespacesAndNewlines))
        config = c
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.cfgKey)
        }
    }

    /// The `at` of the snapshot (seconds), or nil.
    var snapAt: Int? { safeInt(snap?["at"]?.number) }

    /// Bumped by each saveCache; only the newest one's text is written.
    @ObservationIgnored private var cacheGen = 0

    /// view.js save_cache(). The whole state is encoded off the main thread (it ran on the main actor inside every adopt,
    /// on the refresh path of the 423 ms 状态 stall, see cosState) and written back on it. An encode that finishes after a
    /// newer adopt's is dropped, so the stored state is never older than the newest one. The write lands a few ms after
    /// adopt; only init reads this key (a process killed in between starts from the state before).
    func saveCache() {
        let s = snap ?? .null
        cacheGen &+= 1
        let gen = cacheGen
        Task.detached(priority: .utility) { [self] in
            let text = s.encodedString()
            await MainActor.run {
                guard self.cacheGen == gen else { return }
                UserDefaults.standard.set(text, forKey: Relay.snapKey)
            }
        }
    }

    /// Takes a newer state (view.js: `if (!snap || s.at > snap.at) { snap = s; save_cache(); render(); }`).
    @discardableResult
    func adopt(_ s: JSONValue?) -> Bool {
        guard let s, let at = s["at"]?.number else { return false }
        if let cur = snapAt, Double(cur) >= at { return false }
        snap = s
        saveCache()
        onNewSnapshot?(s)
        return true
    }

    func setStatus(_ text: String, _ state: String) {
        if statusText != text { statusText = text }
        if statusState != state { statusState = state }
    }

    /// The web page's toast. There is no toast in the App: the text goes to the status line under the tab titles
    /// (Feedback.status). Each remaining call picks its native pattern instead (Pages/Shell/Feedback.swift).
    @available(*, deprecated, message: "no toasts: Feedback.status, a disabled button with its footer, ShareLink, or the control's own state (Pages/Shell/Feedback.swift)")
    func showToast(_ text: String, ms: Int = 2600) {
        Feedback.status(text)
    }

    /// view.js ask(title, msg, "好", false, { single: true }). One alert at a time (view.js:46, UIAlertController presents
    /// one): the page's single `.alert` shows `alert`; a newer note replaces it rather than being dropped, so a failure is
    /// never swallowed when nothing has cleared an earlier one.
    func showAlert(_ title: String, _ message: String) {
        alert = AlertNote(title: title, message: message)
    }

    // MARK: mailbox

    /// net.js send(body).
    func send(_ body: JSONValue) async throws {
        guard let cfg = config else { throw AppError("还没设置信箱") }
        // ts on ntfy's clock (clockSkewMs): the relay drops an order whose ts is more than 24 h off its own clock
        // (phone.py MAX_AGE), so a phone clock that far off had every order dropped with no receipt (edge audit 3)
        let msg: JSONValue = .object(["v": .int(1), "kind": .string("cmd"), "pin": .string(cfg.pin),
                                      "ts": .int(safeInt(serverNowMs() / 1000) ?? nowSec()), "body": body])
        let (data, status) = try await httpFetch("\(ntfyBase)/\(cfg.topic)", method: "POST", body: msg.encoded())
        if status == 429 { throw NtfyLimit(daily: (try? JSONValue.parse(data))?["code"]?.number == 42908) }
        if !(200..<300).contains(status) { throw AppError("HTTP \(status)") }
    }

    /// net.js readMessages(since): the `message` events of the topic. `cache: no-store` plus a changing
    /// parameter, both (2026-08-31: a cached answer made a running machine look switched off).
    func readMessages(since: String = "48h") async throws -> [JSONValue] {
        guard let cfg = config else { throw AppError("还没设置信箱") }
        return try await Self.pollTopic(cfg.topic, since: since)
    }

    /// One `/json?poll=1` read of a topic list ("a" or "a,b"); only `message` events.
    nonisolated static func pollTopic(_ topics: String, since: String) async throws -> [JSONValue] {
        let url = "\(ntfyBase)/\(topics)/json?poll=1&since=\(since)&_=\(Int(nowMs()))"
        let (data, status) = try await httpFetch(url)
        if !(200..<300).contains(status) { throw AppError("读不到 \(status)") }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line -> JSONValue? in
            guard let e = try? JSONValue.parse(String(line)) else { return nil }
            return e["event"]?.string == "message" ? e : nil
        }
    }

    /// net.js envelope(e): an ntfy message → our envelope object (must carry `kind`).
    nonisolated static func envelope(_ e: JSONValue) -> JSONValue? {
        guard let text = e["message"]?.string, let m = try? JSONValue.parse(text) else { return nil }
        guard let kind = m["kind"], kind.truthy else { return nil }
        return m
    }

    /// net.js joinChunks(m): a large state arrives as several messages with the same sid and their own i/n;
    /// only a complete set is restored, never half a state.
    func joinChunks(_ m: JSONValue) throws -> JSONValue? {
        try Self.joinChunks(m, box: &chunkBox)
    }

    /// joinChunks into a box of the caller's: the live stream keeps its own (Live.liveChunks), as latestState empties
    /// this one on every read and would drop a set half-arrived on the stream.
    nonisolated static func joinChunks(_ m: JSONValue, box chunkBox: inout [String: [Int: String]]) throws -> JSONValue? {
        guard let slice = m["gzp"] else { return nil }
        let sid = m["sid"]?.jsString ?? ""
        let i = safeInt(m["i"]?.number) ?? 0
        let n = safeInt(m["n"]?.number) ?? 0
        guard n > 0 else { return nil }   // `0..<n` traps on a negative count
        var got = chunkBox[sid] ?? [:]
        got[i] = slice.string ?? slice.jsString
        chunkBox[sid] = got
        if got.count < n { return nil }
        chunkBox[sid] = nil
        let blob = (0..<n).map { got[$0] ?? "" }.joined()
        return try Self.unwrap(.object(["gz": .string(blob)]))
    }

    /// net.js unwrap(m): plain `body`, or `gz` = base64 of gzip of the JSON text.
    nonisolated static func unwrap(_ m: JSONValue) throws -> JSONValue? {
        if let body = m["body"] { return body }
        guard let gz = m["gz"]?.string, !gz.isEmpty else { return nil }
        guard let bin = Data(base64Encoded: gz, options: .ignoreUnknownCharacters) else { throw AppError("base64 解不开") }
        let raw = try Gzip.inflate(bin)
        return try JSONValue.parse(raw)
    }

    // MARK: the state on COS

    /// phone.py state_key(topic): `state/` + the first 32 hex digits of sha256(topic) + `.json`. The topic is
    /// lower-cased here for the hash only (the stored topic keeps its case, saveConfig); the relay lower-cases too, so both
    /// name the same object.
    nonisolated static func stateURL(topic: String) -> String {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let h = Hash.hex(Hash.sha256(Array(t.utf8)))
        return "\(cosBase)/state/\(String(h.prefix(32))).json"
    }

    /// phone.py hb_key(topic): the heartbeat object next to the state, `state/<same hash>.hb.json`.
    nonisolated static func hbURL(topic: String) -> String {
        String(stateURL(topic: topic).dropLast(".json".count)) + ".hb.json"
    }

    /// needtable.py need_key(topic): the need table the relay rebuilds every server day, `state/<same hash>.need.json`
    /// (maa-automation relay/ark_relay/features/needtable/needtable.py; public-read like the state).
    nonisolated static func needURL(topic: String) -> String {
        String(stateURL(topic: topic).dropLast(".json".count)) + ".need.json"
    }

    /// The GET cosHb() makes; tests replace it so no request leaves the Mac.
    @ObservationIgnored var fetchHb: (String) async throws -> (Data, Int) = { try await httpFetch($0) }

    /// One GET of the relay's heartbeat on COS: {"at": s, "every": s, "cos_every": s} (+ "bye": true on a service
    /// stop). nil when there is none (an older relay, a machine without COS) or the network fails.
    func cosHb() async -> JSONValue? {
        guard let cfg = config, !cfg.topic.isEmpty else { return nil }
        guard let (data, status) = try? await fetchHb(Self.hbURL(topic: cfg.topic)),
              status == 200, let m = try? JSONValue.parse(data), m["at"]?.number != nil else { return nil }
        return m
    }

    /// The relay's notice that a new state is on COS: `state <ts> <bytes>` (not JSON, so older readers skip it).
    nonisolated static func isStateNotice(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.hasPrefix("state ")
    }

    /// One GET of the state object; the body is the same envelope a single ntfy state message carries
    /// (`kind`, `pin`, `body` or `gz`), so it is decoded exactly like one. nil when there is none yet
    /// (an older relay, a machine without COS), the PIN does not match, or the network fails.
    func cosState() async -> JSONValue? {
        guard let cfg = config, !cfg.topic.isEmpty else { return nil }
        guard let (data, status) = try? await httpFetch(Self.stateURL(topic: cfg.topic)), status == 200 else { return nil }
        // Decoded off the main thread: the whole state (base64 → the Swift inflater below → JSONValue's try-each-type
        // decoder) ran on the main actor after the GET, the first thing a pull to refresh does (Live.ping → pingInner).
        // The fluency audit (10-05) puts the 423 ms stall on the user's Android phone (0.4.0 状态 page, starting 381 ms
        // after a drag was released) most likely here; on Android the main actor runs on the UI thread's Looper. Same
        // result, only computed elsewhere.
        let pin = cfg.pin
        let got = await Task.detached(priority: .userInitiated) { Relay.decodeCosState(data, pin: pin) }.value
        guard let pinOK = got.pinOK else { return nil }   // not a state envelope
        if !pinOK {
            pinScan = PinScan(seen: 1, matched: 0)
            cosPinBad = true
            return nil
        }
        cosPinBad = false
        return got.state
    }

    /// cosState's decoding: the envelope, its PIN, then `body` / `gz` (unwrap). pinOK: nil when the object is not a state
    /// envelope, false for a state under another PIN (state nil), true when it matched (state nil if unwrap failed).
    nonisolated static func decodeCosState(_ data: Data, pin: String) -> (state: JSONValue?, pinOK: Bool?) {
        guard let m = try? JSONValue.parse(data), m["kind"]?.string == "state" else { return (nil, nil) }
        if m["pin"]?.jsString != pin { return (nil, false) }
        let state = try? unwrap(m)
        return (state, true)
    }

    /// The status line when the PIN cannot be right (no state matched it on ntfy, or the one on COS carries another),
    /// else nil. It points at what the App has: there is no settings screen; a 免输入链接 pasted in 「手机 › 粘贴密钥串」
    /// replaces the mailbox and PIN (PhoneTab pasteTokens → PhoneLink.open → saveConfig).
    func pinMismatchNote() -> String? {
        let ntfyBad = pinScan.seen > 0 && pinScan.matched == 0
        guard ntfyBad || cosPinBad else { return nil }
        return (ntfyBad ? "信箱里有 \(pinScan.seen) 条消息但 PIN 对不上" : "机器存的状态 PIN 对不上")
            + "——到「手机」页点「粘贴密钥串」，粘贴免输入链接重设"
    }

    /// Reads the state object once and takes it when it is newer. Called on open, on refresh and on the
    /// relay's notice only - never on a timer (the user, 15:27: 「又在轮询。」).
    @discardableResult
    func readCosState() async -> Bool {
        adopt(await cosState())
    }

    /// net.js latestState(since): newest state whose PIN matches; counts pinScan on the way.
    func latestState(since: String = "48h") async throws -> JSONValue? {
        guard let cfg = config else { return nil }
        let msgs = try await readMessages(since: since)
        pinScan = PinScan()
        chunkBox.removeAll()
        for e in msgs.reversed() {
            guard let m = Self.envelope(e), m["kind"]?.string == "state" else { continue }
            pinScan.seen += 1
            if m["pin"]?.jsString != cfg.pin { continue }
            pinScan.matched += 1
            if m["gzp"] != nil {
                // slices are met newest to oldest; restore once complete, else keep looking further back
                if let done = try? joinChunks(m) { return done }
                continue
            }
            do { return try Self.unwrap(m) } catch { return nil }
        }
        return nil
    }
}

// MARK: - gzip

/// gzip (RFC 1952) as the relay writes it with Python's gzip.compress (relay/ark_relay/phone.py:86), decoded by the
/// system zlib: inflateInit2 with windowBits 16 + MAX_WBITS reads the gzip header and checks the CRC32 / ISIZE trailer
/// (zlib manual, https://www.zlib.net/manual.html, inflateInit2).
enum Gzip {
    static func inflate(_ data: Data) throws -> Data {
        guard data.count >= 18, data.starts(with: [0x1f, 0x8b, 8]) else { throw AppError("不是 gzip 数据") }
        var z = z_stream()
        guard inflateInit2_(&z, 16 + MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AppError("gzip 解不开")
        }
        defer { inflateEnd(&z) }
        var input = [UInt8](data)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var out = Data()
        var ret = Z_OK
        input.withUnsafeMutableBufferPointer { inp in
            z.next_in = inp.baseAddress
            z.avail_in = uInt(inp.count)
            repeat {
                let n = chunk.withUnsafeMutableBufferPointer { buf in
                    z.next_out = buf.baseAddress
                    z.avail_out = uInt(buf.count)
                    ret = zlib.inflate(&z, Z_NO_FLUSH)
                    return buf.count - Int(z.avail_out)
                }
                out.append(contentsOf: chunk[0..<n])
            } while ret == Z_OK
        }
        guard ret == Z_STREAM_END else { throw AppError(ret == Z_BUF_ERROR ? "gzip 数据不完整" : "gzip 数据损坏") }
        return out
    }
}
