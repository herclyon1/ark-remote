// Ported from maa-automation/web/stamina.js
//
// Stamina numbers: the app asks the games' official APIs itself, not through the machine.
// 森空岛 (明日方舟 理智, 终末地 理智) and 库街区 (鸣潮 波片). The 森空岛 session (cred, signing token,
// device id, account ids) is handed over by the machine in the state snapshot (`密钥.sk`) and kept
// on this phone; the 库街区 token and device id are pasted in 「手机 › 游戏账号」.
//
// Reads only on the user's action (open, pull to refresh, the 刷新 tile); repeats within a minute
// reuse the last answer. No timers.
//
// 森空岛 signing (ported from relay/ark_relay/skland.py):
//   secret = path + query + timestamp + JSON({platform,timestamp,dId,vName})
//   sign   = md5(hex(hmac_sha256(token, secret)))
// The timestamp is the server's: GET /web/v1/auth/refresh first, it returns timestamp and a new token.
//
// Not a straight port: WebCrypto's HMAC-SHA256 has no Foundation counterpart on Android (CryptoKit
// is Apple-only), so SHA-256 and HMAC are written out in `Hash` next to the MD5 stamina.js already had.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported (skipstone warning)

/// One 森空岛 game's reading (明日方舟 / 终末地), same keys as the snapshot's 体力 object.
struct GameStamina: Codable, Sendable, Equatable {
    var error: String? = nil
    var current: Int? = nil
    var max: Int? = nil
    var fullAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case error = "错误", current = "理智", max = "上限", fullAt = "回满"
    }
}

/// The 鸣潮 reading from the 库街区 widget.
struct WuwaStamina: Codable, Sendable, Equatable {
    var error: String? = nil
    var waveplates: Int? = nil
    var max: Int? = nil
    var reserve: Int? = nil
    var reserveMax: Int? = nil
    var weekly: Int? = nil
    var weeklyMax: Int? = nil
    var activity: Int? = nil
    var activityMax: Int? = nil
    var fullAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case error = "错误", waveplates = "波片", max = "上限", reserve = "备用", reserveMax = "备用上限"
        case weekly = "周本", weeklyMax = "周本上限", activity = "活跃", activityMax = "活跃上限", fullAt = "回满"
    }
}

/// stamina.js refresh() result: `{明日方舟, 终末地, 鸣潮, 取自: "HH:MM"}`.
struct StaminaReading: Codable, Sendable, Equatable {
    var arknights: GameStamina
    var endfield: GameStamina
    var wuwa: WuwaStamina
    var takenAt: String

    enum CodingKeys: String, CodingKey {
        case arknights = "明日方舟", endfield = "终末地", wuwa = "鸣潮", takenAt = "取自"
    }
}

/// The signing token and the server clock skew from skRefresh.
struct SkTokenSkew: Sendable {
    let token: String
    let skew: Int
}

/// JS `Number(v)` for a value that may be absent (`undefined` → NaN → nil).
func jsNumber(_ v: JSONValue?) -> Double? {
    guard let v else { return nil }
    return v.number
}

/// JS `x || ""` for a string field.
func jsStr(_ v: JSONValue?) -> String {
    guard let v, v.truthy else { return "" }
    return v.jsString
}

/// JSON.stringify of a string.
func jsonQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if u.value < 0x20 {
                let hex = Array("0123456789abcdef")
                out += "\\u00" + String(hex[Int(u.value >> 4)]) + String(hex[Int(u.value & 15)])
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

/// URLSearchParams(...).toString(): application/x-www-form-urlencoded.
func formEncode(_ pairs: [(String, String)]) -> String {
    func enc(_ s: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F:
                out.unicodeScalars.append(Unicode.Scalar(b))
            case 0x20:
                out += "+"
            default:
                out += "%" + String(hex[Int(b >> 4)]) + String(hex[Int(b & 15)])
            }
        }
        return out
    }
    return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
}

/// stamina.js stampFrom(epoch): local "MM-DD HH:MM".
func stampFrom(_ epoch: Double?) -> String {
    guard let epoch, epoch != 0 else { return "" }
    let d = Date(timeIntervalSince1970: epoch)
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
    return "\(pad2(c.month ?? 0))-\(pad2(c.day ?? 0)) \(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
}

@MainActor @Observable final class StaminaStore {
    static let shared = StaminaStore()

    static let tokensKey = "ark-remote-tokens"
    /// The last good reading, shown at once on the next open (behaviour 2, 2026-09-19).
    static let cacheKey = "ark-remote-stamina"
    static let zonai = "https://zonai.skland.com"
    static let kuroBase = "https://api.kurobbs.com"
    static let minGapMs: Double = 60 * 1000

    var data: StaminaReading?
    var at: Double = 0
    /// When `data` was read (ms), also for the stored one (`at` is 0 then, so it is read again): 取自 is a bare "HH:MM",
    /// and a reading from yesterday said only 「08:10 读取」 (审查 C2). 0 = unknown.
    var takenMs: Double = 0
    var busy = false
    /// A forced read asked for while one was running (new tokens from a link): run again when it ends.
    @ObservationIgnored private var again = false
    /// Bumped by clear(); a read records it when it starts (readGen). A read that was out when 「清除密钥」 was tapped
    /// wrote the tokens back (skRefresh / kuro saveTokens) and the reading and its cache after it, so the clear did not
    /// hold (edge audit 21): such a read now keeps nothing.
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var readGen = 0
    /// `{sk: {cred, token, dId, uid, efRole, efServer}, kuro: {token, did, roleId, serverId}}`, kept as JSON
    /// because the machine hands the 森空岛 part over as is.
    var tokens: JSONValue?
    var err = ""
    /// The reading on screen is the stored one from an earlier open.
    var cached = false

    init() {
        // only a configured phone has a reading worth restoring
        if loadTokens() != nil { loadCache() }
    }

    // MARK: credentials in and out

    @discardableResult
    func loadTokens() -> JSONValue? {
        if let raw = UserDefaults.standard.string(forKey: Self.tokensKey), let v = try? JSONValue.parse(raw), !v.isNull {
            tokens = v
        } else {
            tokens = nil
        }
        return tokens
    }

    func saveTokens(_ t: JSONValue) {
        tokens = t
        UserDefaults.standard.set(t.encodedString(), forKey: Self.tokensKey)
    }

    /// `{...cur, key: value}`.
    private func merged(_ cur: JSONValue?, _ key: String, _ value: JSONValue) -> JSONValue {
        var o = cur?.object ?? [:]
        o[key] = value
        return .object(o)
    }

    static func decodeB64(_ s: String) throws -> JSONValue {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { throw AppError("base64 解不开") }
        return try JSONValue.parse(data)
    }

    /// stamina.js fromLink(): a link carrying `#t=<base64 JSON>`. The page read location.hash; the app
    /// passes the opened URL (the deep-link hookup is the page step's).
    @discardableResult
    func fromLink(_ url: URL) -> Bool {
        guard let frag = url.fragment, !frag.isEmpty else { return false }
        let hash = "#" + frag
        guard let re = try? Regex("[#&]t=([A-Za-z0-9_-]+)"), let m = hash.firstMatch(of: re),
              m.output.count > 1, let sub = m.output[1].substring else { return false }
        guard let j = try? Self.decodeB64(String(sub)) else { return false }
        if j["sk"] == nil && j["kuro"] == nil { return false }
        saveTokens(j)
        return true
    }

    /// stamina.js fromPaste(s): two lines KUROBBS_TOKEN=… / KUROBBS_DID=… (as in ~/.config/ark/.env),
    /// or a whole JSON object.
    @discardableResult
    func fromPaste(_ s: String) throws -> JSONValue {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var j: JSONValue? = nil
        if str.hasPrefix("{") || str.hasPrefix("[") {
            j = try JSONValue.parse(str)
        } else {
            var kv: [String: String] = [:]
            let splitter = try Regex("\\r?\\n|[;,\\s]+(?=KUROBBS_)")
            let keyRe = try Regex("^\\s*(KUROBBS_TOKEN|KUROBBS_DID)\\s*[=:]\\s*(\\S+)")
            for line in str.split(separator: splitter) {
                if let m = line.firstMatch(of: keyRe), m.output.count > 2,
                   let k = m.output[1].substring, let v = m.output[2].substring {
                    kv[String(k)] = String(v)
                }
            }
            if let token = kv["KUROBBS_TOKEN"], let did = kv["KUROBBS_DID"] {
                j = .object(["kuro": .object(["token": .string(token), "did": .string(did)])])
            }
        }
        guard let j, j["sk"] != nil || j["kuro"] != nil else {
            throw AppError("没认出密钥：要 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行")
        }
        var cur = (tokens ?? loadTokens())?.object ?? [:]
        for (k, v) in j.object ?? [:] { cur[k] = v }
        saveTokens(.object(cur))
        return j
    }

    /// stamina.js fromSnapshot(snap): the 森空岛 session the machine handed over; written only when it differs.
    @discardableResult
    func fromSnapshot(_ snap: JSONValue?) -> Bool {
        guard let sk = snap?["密钥"]?["sk"], sk.object != nil else { return false }
        if let e = sk["错误"], e.truthy { return false }
        guard let cred = sk["cred"], cred.truthy else { return false }
        let cur = tokens ?? loadTokens()
        if let old = cur?["sk"]?["cred"], old == cred { return false }
        saveTokens(merged(cur, "sk", sk))
        return true
    }

    func clear() {
        gen += 1
        tokens = nil
        data = nil
        cached = false
        UserDefaults.standard.removeObject(forKey: Self.tokensKey)
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    func loadCache() {
        guard let raw = UserDefaults.standard.string(forKey: Self.cacheKey), let c = try? JSONValue.parse(raw),
              let d = c["data"], d.truthy, let r = try? JSONDecoder().decode(StaminaReading.self, from: d.encoded()) else { return }
        data = r
        at = 0
        takenMs = c["at"]?.number ?? 0
        cached = true
    }

    // MARK: 森空岛

    func skRefresh(_ sk: JSONValue) async throws -> SkTokenSkew {
        let (body, _) = try await httpFetch("\(Self.zonai)/web/v1/auth/refresh", headers: ["cred": jsStr(sk["cred"]), "dId": jsStr(sk["dId"])],
                                            noStore: false)
        let j = try JSONValue.parse(body)
        if let code = j["code"], code != .int(0) {
            throw AppError("森空岛刷新失败：" + (j["message"].map { $0.truthy ? $0.jsString : code.jsString } ?? code.jsString))
        }
        var skew = 0
        if let t = j["timestamp"], t.truthy, let ts = t.number { skew = Int(ts) - nowSec() }
        let old = jsStr(sk["token"])
        let token = jsStr(j["data"]?["token"]).isEmpty ? old : jsStr(j["data"]?["token"])
        if token != old && readGen == gen {
            var s = sk.object ?? [:]
            s["token"] = .string(token)
            saveTokens(merged(tokens, "sk", .object(s)))
        }
        return SkTokenSkew(token: token, skew: skew)
    }

    /// A signed GET; `path` carries its own query, already encoded.
    func skGet(_ sk: JSONValue, _ ts: SkTokenSkew, _ path: String) async throws -> JSONValue {
        let stamp = String(nowSec() + ts.skew)
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathname = String(parts[0]), query = parts.count > 1 ? String(parts[1]) : ""
        let dId = jsStr(sk["dId"])
        let caJSON = "{\"platform\":\"3\",\"timestamp\":\(jsonQuote(stamp)),\"dId\":\(jsonQuote(dId)),\"vName\":\"1.0.0\"}"
        let secret = pathname + query + stamp + caJSON
        let sign = Hash.md5Hex(Array(Hash.hmacSHA256Hex(key: Array(ts.token.utf8), message: Array(secret.utf8)).utf8))
        let headers = ["cred": jsStr(sk["cred"]), "sign": sign, "platform": "3", "timestamp": stamp, "dId": dId, "vName": "1.0.0"]
        let (body, _) = try await httpFetch(Self.zonai + path, headers: headers, noStore: false)
        let j = try JSONValue.parse(body)
        if let code = j["code"], code != .int(0) {
            throw AppError((j["message"]?.truthy == true ? j["message"]!.jsString : nil) ?? ("code " + code.jsString))
        }
        if let d = j["data"], d.truthy { return d }
        return .object([:])
    }

    func skland(_ sk: JSONValue) async -> (GameStamina, GameStamina) {
        let ts: SkTokenSkew
        do { ts = try await skRefresh(sk) } catch {
            let e = GameStamina(error: Live.why(error))
            return (e, e)
        }
        var ark: GameStamina
        do {
            guard sk["uid"]?.truthy == true else { throw AppError("密钥串里没有明日方舟的 uid") }
            let d = try await skGet(sk, ts, "/api/v1/game/player/info?uid=\(encodeURIComponent(jsStr(sk["uid"])))")
            let ap = d["status"]?["ap"] ?? .object([:])
            ark = Self.arknightsLive(ap, nowSec: Double(nowSec() + ts.skew))
        } catch { ark = GameStamina(error: Live.why(error)) }
        var ef: GameStamina
        do {
            guard sk["efRole"]?.truthy == true else { throw AppError("密钥串里没有终末地的角色") }
            let server = jsStr(sk["efServer"]).isEmpty ? "1" : jsStr(sk["efServer"])
            let d = try await skGet(sk, ts, "/api/v1/game/endfield/card/detail?roleId=\(encodeURIComponent(jsStr(sk["efRole"])))&serverId=\(encodeURIComponent(server))")
            ef = Self.endfieldFromDungeon(d["detail"]?["dungeon"] ?? .object([:]))
        } catch { ef = GameStamina(error: Live.why(error)) }
        return (ark, ef)
    }

    /// Real sample (2026-09-15, player/info): ap = {current: 2, max: 210, lastApAddTime, completeRecoveryTime}.
    /// `current` is the count at lastApAddTime and 森空岛 never moves it, so the live value is derived:
    /// one point per 6 minutes, capped at max.
    nonisolated static func arknightsLive(_ ap: JSONValue, nowSec: Double) -> GameStamina {
        guard let cur = jsNumber(ap["current"]), let top = jsNumber(ap["max"]), cur.isFinite, top.isFinite else {
            return GameStamina(error: "森空岛没给理智")
        }
        var live = cur
        if let last = jsNumber(ap["lastApAddTime"]), last.isFinite, last > 0, nowSec > last {
            live = min(top, cur + ((nowSec - last) / 360).rounded(.down))
        }
        var o = GameStamina(current: safeInt(live), max: safeInt(top))
        if live < top, let full = ap["completeRecoveryTime"], full.truthy { o.fullAt = stampFrom(full.number) }
        return o
    }

    /// Real sample (2026-09-15, card/detail): dungeon = {"curStamina": "179", "maxTs": "1789490362", "maxStamina": "360"}
    /// (strings). Read those three names first; if they change, recognise by meaning; else list the names seen.
    /// Keys are taken in sorted order (a Swift dictionary has no insertion order).
    nonisolated static func endfieldFromDungeon(_ dg: JSONValue) -> GameStamina {
        let obj = dg.object ?? [:]
        let keys = obj.keys.sorted()
        if keys.isEmpty { return GameStamina(error: "森空岛没给终末地的理智") }
        func num(_ v: JSONValue?) -> Double? {
            guard let v else { return nil }
            if v.isNull { return nil }
            if case .string(let s) = v, s.isEmpty { return nil }
            return v.number
        }
        func has(_ k: String, _ words: [String]) -> Bool {
            let l = k.lowercased()
            return words.contains { l.contains($0) }
        }
        var cur = num(obj["curStamina"]), top = num(obj["maxStamina"]), full = num(obj["maxTs"])
        if cur == nil || top == nil {
            let cands = keys.filter { has($0, ["stamina", "ap", "sanity", "energy", "power"]) && num(obj[$0]) != nil }
            let big = cands.filter { has($0, ["max", "limit"]) }, small = cands.filter { !has($0, ["max", "limit"]) }
            if cur == nil, !small.isEmpty { cur = small.compactMap { num(obj[$0]) }.min() }
            if top == nil, !big.isEmpty { top = big.compactMap { num(obj[$0]) }.max() }
            if full == nil, let k = keys.first(where: { has($0, ["ts", "time", "recover", "full"]) && (num(obj[$0]) ?? 0) > 1e9 }) {
                full = num(obj[k])
            }
        }
        guard let c = cur else { return GameStamina(error: "终末地的理智没认出来：" + keys.prefix(6).joined(separator: "、")) }
        var o = GameStamina(current: safeInt(c), max: safeInt(top))
        if let f = full, f != 0, c < (top ?? .infinity) { o.fullAt = stampFrom(f) }
        return o
    }

    // MARK: 库街区

    func kuroPost(_ path: String, _ headers: [String: String], _ data: [(String, String)]) async throws -> JSONValue {
        var h = ["source": "android", "version": "3.1.3", "Content-Type": "application/x-www-form-urlencoded; charset=utf-8"]
        for (k, v) in headers { h[k] = v }
        let (body, _) = try await httpFetch(Self.kuroBase + path, method: "POST", headers: h, body: Data(formEncode(data).utf8), noStore: false)
        let j = try JSONValue.parse(body)
        if !(j["success"]?.truthy ?? false) || j["code"] != .int(200) {
            let msg = [j["msg"], j["message"]].compactMap { $0 }.first(where: { $0.truthy })?.jsString
            throw AppError(msg ?? ("code " + (j["code"]?.jsString ?? "undefined")))
        }
        var d = j["data"] ?? .null
        if case .string(let s) = d, let parsed = try? JSONValue.parse(s) { d = parsed }
        return d
    }

    func kuro(_ k: JSONValue) async -> WuwaStamina {
        do {
            var roleId = jsStr(k["roleId"]), serverId = jsStr(k["serverId"])
            if roleId.isEmpty {
                let roles = try await kuroPost("/gamer/role/list", ["token": jsStr(k["token"]), "devCode": jsStr(k["did"])], [("gameId", "3")])
                guard let w = (roles.array ?? []).first(where: { jsNumber($0["gameId"]) == 3 }) else {
                    throw AppError("库街区账号下没有鸣潮角色")
                }
                roleId = w["roleId"]?.jsString ?? "undefined"
                serverId = jsStr(w["serverId"])
                var kk = k.object ?? [:]
                kk["roleId"] = .string(roleId)
                kk["serverId"] = .string(serverId)
                if readGen == gen { saveTokens(merged(tokens, "kuro", .object(kk))) }
            }
            // getData is the widget's cached copy (cheap, never rate-limited); refresh makes 库街区 pull the game
            // again and answers 「操作频繁」 when asked a few times in a row. Read the cache; only if it is older
            // than ten minutes ask for a refresh, and keep the cache when that is refused.
            let args = [("gameId", "3"), ("serverId", serverId), ("roleId", roleId), ("type", "1"), ("sizeType", "1")]
            let hdr = ["token": jsStr(k["token"]), "did": jsStr(k["did"])]
            var w = try await kuroPost("/gamer/widget/game3/getData", hdr, args)
            let now = Date().timeIntervalSince1970
            let age: Double = (w["serverTime"]?.truthy == true) ? now - (jsNumber(w["serverTime"]) ?? .nan) : .infinity
            if age > 600 {
                if let fresh = try? await kuroPost("/gamer/widget/game3/refresh", hdr, args) { w = fresh }   // rate-limited: the cache will do
            }
            let e = w["energyData"] ?? .object([:]), st = w["storeEnergyData"] ?? .object([:])
            let wk = w["weeklyData"] ?? .object([:]), lv = w["livenessData"] ?? .object([:])
            guard let curV = e["cur"] else {
                throw AppError("库街区没给波片：" + (w.object?.keys.sorted().prefix(6).joined(separator: "、") ?? ""))
            }
            // The live count follows from the full-time stamp (1 波片 per 6 min), so a cached copy still shows the right number now.
            let full = jsNumber(e["refreshTimeStamp"]) ?? 0, total = jsNumber(e["total"]) ?? .nan
            let cur = jsNumber(curV) ?? .nan
            let live: Double = full > now ? Swift.max(cur, total - ((full - now) / 360).rounded(.up)) : (full > 0 ? total : cur)
            func int(_ v: JSONValue?) -> Int? { safeInt(jsNumber(v)) }
            let shown = Swift.min(total, live)
            var o = WuwaStamina(waveplates: safeInt(shown), max: safeInt(total),
                                reserve: int(st["cur"]), reserveMax: int(st["total"]),
                                weekly: int(wk["cur"]), weeklyMax: int(wk["total"]),
                                activity: int(lv["cur"]), activityMax: int(lv["total"]))
            if full > now && live < total { o.fullAt = stampFrom(full) }
            return o
        } catch {
            return WuwaStamina(error: Live.why(error))
        }
    }

    // MARK: entry

    /// One read. `force` skips the one-minute reuse. Same shape as the machine snapshot's object.
    @discardableResult
    func refresh(force: Bool = false) async -> StaminaReading? {
        guard let t = tokens ?? loadTokens() else { return nil }
        if !force, data != nil, nowMs() - at < Self.minGapMs { return data }
        // a forced read during a running one: the running one may have started on the old tokens (a link taken just
        // as the app came to the front, while the 森空岛-only read was out: 波片 stayed 「没配库街区」, ark37 10-03)
        if busy { if force { again = true }; return data }
        busy = true
        readGen = gen
        let sk = t["sk"].flatMap { $0.truthy ? $0 : nil }
        let ku = t["kuro"].flatMap { $0.truthy ? $0 : nil }
        async let skPart: (GameStamina, GameStamina) = sk != nil ? skland(sk!)
            : (GameStamina(error: "没配森空岛"), GameStamina(error: "没配森空岛"))
        async let wwPart: WuwaStamina = ku != nil ? kuro(ku!) : WuwaStamina(error: "没配库街区")
        let (s, ww) = await (skPart, wwPart)
        guard readGen == gen else {   // 「清除密钥」 while it was out
            busy = false
            if again {   // new tokens pasted after the clear asked for a read meanwhile
                again = false
                return await refresh(force: true)
            }
            return nil
        }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let reading = StaminaReading(arknights: s.0, endfield: s.1, wuwa: ww, takenAt: "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))")
        data = reading
        at = nowMs()
        takenMs = at
        cached = false
        // a read where every game failed (no network, a server error page) does not replace the last good one stored
        // for the next open (edge audit 7)
        let allFailed = s.0.error != nil && s.1.error != nil && ww.error != nil
        if !allFailed, let d = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reading)) {
            let c: JSONValue = .object(["at": .double(at), "data": d])
            UserDefaults.standard.set(c.encodedString(), forKey: Self.cacheKey)
        }
        busy = false
        if again {
            again = false
            return await refresh(force: true)
        }
        return reading
    }

    /// Which accounts are configured, e.g. "森空岛、库街区".
    func status() -> String {
        guard let t = tokens ?? loadTokens() else { return "" }
        return [t["sk"]?.truthy == true ? "森空岛" : "", t["kuro"]?.truthy == true ? "库街区" : ""]
            .filter { !$0.isEmpty }.joined(separator: "、")
    }
}

// MARK: - Hashes

/// MD5 (森空岛's sign needs it), SHA-256 and HMAC-SHA256, in plain Swift: CryptoKit and WebCrypto are not on Android.
enum Hash {
    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 15)]) }
        return s
    }

    /// stamina.js md5(str), on the UTF-8 bytes.
    static func md5Hex(_ message: [UInt8]) -> String {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64((abs(sin(Double($0 + 1))) * 4294967296.0).rounded(.down))) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var msg = message
        let bitLen = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLen >> (8 * UInt64(i)))) }
        func rotl(_ x: UInt32, _ c: UInt32) -> UInt32 { (x << c) | (x >> (32 - c)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(msg[j]) | UInt32(msg[j + 1]) << 8 | UInt32(msg[j + 2]) << 16 | UInt32(msg[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ rotl(f, s[i])
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        var out: [UInt8] = []
        for w in [a0, b0, c0, d0] { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: w >> (8 * UInt32(i)))) } }
        return hex(out)
    }

    static func sha256(_ message: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = message
        let bitLen = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8(truncatingIfNeeded: bitLen >> (8 * UInt64(i)))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for v in h { for i in (0..<4).reversed() { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        return out
    }

    /// stamina.js hmacHex(key, msg): HMAC-SHA256 as lower-case hex.
    static func hmacSHA256Hex(key: [UInt8], message: [UInt8]) -> String {
        var k = key.count > 64 ? sha256(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = sha256(k.map { $0 ^ 0x36 } + message)
        return hex(sha256(k.map { $0 ^ 0x5c } + inner))
    }
}
