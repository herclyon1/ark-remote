// 月卡 (web monthcard.js, user 2026-09-26 02:47; spec ~/Money/styl-work/BOARD/月卡到期提示-规格.md): the phone's own
// registrations, the merge with the relay's copy, the date rule and the sends.
//
// Data: the phone keeps its own registrations (user 09-26 03:30 「为什么月卡功能要绑定游戏机？」), computed here with the
// spec's rule (§2: not expired → last + 30 × N; expired / never registered → today + 30 × N − 1; left X → today + X),
// saved under "ark-monthcard" and shown at once. The order still goes to the relay, as the web page sends it:
//   { action: "monthcard", game, add: N,  last, at }   N 1–12, each one 30 days
//   { action: "monthcard", game, left: X, last, at }  X 0–400, the 「还剩 X 天」 the game shows
// last = the date computed here, at = the registration time (ISO, UTC, JS toISOString form).
// relay.月卡 = { 明日方舟: { 最后领取: "2026-09-29", 还剩: 3, 已过期: false, 登记于?: ISO }, … } (spec 「接口」).
// Merge, newest registration wins: a local record gives way once the relay shows the same date or a 登记于 at or after it.
// 还剩 is recounted from 最后领取 against today (Shanghai day), never taken from the relay.
// An unsynced record is sent again as { left } (idempotent, unlike add) when the first send failed or went out over 10 hours
// ago: the mailbox keeps messages 12 hours (pending.js).
//
// Differences from the web: monthcard.js drops a caught-up local record inside entry() during render and calls resend() on
// every render; here entry() is pure and the drop + resend run from MonthCardRows' tasks (Pages/Status/MonthCardRows.swift).

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

/// One local registration (monthcard.js LOCAL record).
struct MonthCardRecord: Codable, Sendable, Equatable {
    /// "YYYY-MM-DD": the last day the card pays out.
    var last: String
    /// ms of the registration.
    var at: Double
    /// ms the order went out; 0 = not sent (the first send failed).
    var sentAt: Double
}

/// What a 月卡 row shows (monthcard.js entry()).
struct MonthCardEntry: Sendable, Equatable {
    var last: String
    /// Days from today (Shanghai) to `last`; negative once lapsed.
    var left: Int
    var expired: Bool { left < 0 }
    /// From the phone's own registration, not yet confirmed by the relay.
    var local: Bool
}

@MainActor @Observable final class MonthCardStore {
    static let shared = MonthCardStore()

    /// The three names the relay takes (spec 「接口」).
    static let games = ["明日方舟", "终末地", "鸣潮"]
    /// One purchase: PRTS 月卡兑换凭证 / PS Store UB0018-PPSA18538_00-ZMDPS5GL0MONTHLY / 鸣潮 商城说明 (spec 「查到的事实」).
    static let days = 30
    static let maxAdd = 12
    static let maxLeft = 400
    static let localKey = "ark-monthcard"
    /// pending.js: the mailbox keeps 12 hours, resend after 10.
    static let resendMs: Double = 10 * 3600 * 1000

    /// { game: record } (monthcard.js loadLocal / saveLocal).
    var records: [String: MonthCardRecord] = [:]
    @ObservationIgnored private var resending = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.localKey), let data = raw.data(using: .utf8),
           let o = try? JSONDecoder().decode([String: MonthCardRecord].self, from: data) {
            records = o
        }
        // the web resends on every render of the 状态 page; the rows that run it here sit below the fold, so the first
        // touch of the store (MonthCardReminder at the top of 状态) runs one round per launch as well
        Task { @MainActor in
            self.reconcile()
            await self.resend()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.localKey)
        }
    }

    private func remember(_ g: String, last: String, at: Double, sentAt: Double) {
        records[g] = MonthCardRecord(last: last, at: at, sentAt: sentAt)
        save()
    }

    // MARK: dates (Shanghai day, as the relay counts days)

    /// Today in Asia/Shanghai, "YYYY-MM-DD". Shanghai has kept UTC+8 with no daylight saving since 1991, so a fixed offset
    /// gives the same day as the web's Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai" }).
    static func today() -> String {
        isoDay(Int(((nowMs() + 8 * 3600 * 1000) / 86_400_000).rounded(.down)))
    }

    /// `iso` + n days (monthcard.js plus(): setUTCDate).
    static func plus(_ iso: String, _ n: Int) -> String {
        guard let d = dayNumber(iso) else { return iso }
        return isoDay(d + n)
    }

    /// Days from a to b (monthcard.js days()).
    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let x = dayNumber(a), let y = dayNumber(b) else { return nil }
        return y - x
    }

    /// 「9月29日」 (monthcard.js md()).
    static func md(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return iso }
        return "\(m)月\(d)日"
    }

    /// /^\d{4}-\d\d-\d\d$/
    static func isDay(_ v: String?) -> Bool {
        guard let v else { return false }
        let c = Array(v)
        guard c.count == 10, c[4] == "-", c[7] == "-" else { return false }
        for (i, ch) in c.enumerated() where i != 4 && i != 7 {
            guard ch.isASCII, ch.isNumber else { return false }
        }
        return true
    }

    /// Days since 1970-01-01 for "YYYY-MM-DD" (proleptic Gregorian; an out-of-range day rolls over as JS Date does).
    static func dayNumber(_ iso: String) -> Int? {
        guard isDay(iso) else { return nil }
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return daysFromCivil(y, m, d)
    }

    static func daysFromCivil(_ y0: Int, _ m0: Int, _ d: Int) -> Int {
        // month overflow / underflow normalised first (JS Date month arithmetic)
        var y = y0, m = m0
        y += (m - 1) >= 0 ? (m - 1) / 12 : -((12 - m) / 12)
        m = ((m - 1) % 12 + 12) % 12 + 1
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(_ z0: Int) -> (y: Int, m: Int, d: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func isoDay(_ z: Int) -> String {
        let c = civil(z)
        let y = String(c.y)
        return String(repeating: "0", count: max(0, 4 - y.count)) + y + "-" + pad2(c.m) + "-" + pad2(c.d)
    }

    /// JS `new Date(ms).toISOString()`: "2026-09-26T03:30:00.123Z".
    static func isoString(ms: Double) -> String {
        let t = Int(ms.rounded(.down))
        let day = t >= 0 ? t / 86_400_000 : -((-t + 86_399_999) / 86_400_000)
        let rem = t - day * 86_400_000
        let h = rem / 3_600_000, mi = rem / 60_000 % 60, s = rem / 1000 % 60, f = rem % 1000
        let fs = f < 10 ? "00\(f)" : f < 100 ? "0\(f)" : String(f)
        return "\(isoDay(day))T\(pad2(h)):\(pad2(mi)):\(pad2(s)).\(fs)Z"
    }

    /// JS Date.parse for the relay's 登记于 ("2026-09-26T03:30:00.123+08:00", or with Z / no fraction); nil = NaN.
    static func parseISO(_ s: String?) -> Double? {
        guard let s, s.count >= 10 else { return nil }
        let chars = Array(s)
        let datePart = String(chars[0..<10])
        guard let day = dayNumber(datePart) else { return nil }
        if chars.count == 10 { return Double(day) * 86_400_000 }   // date-only forms are UTC in JS
        guard chars[10] == "T" || chars[10] == " ", chars.count >= 16 else { return nil }
        let rest = Array(chars[11...])
        func num(_ a: ArraySlice<Character>) -> Int? {
            guard !a.isEmpty, a.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(a))
        }
        guard rest.count >= 5, rest[2] == ":", let h = num(rest[0..<2]), let mi = num(rest[3..<5]) else { return nil }
        var i = 5
        var sec = 0, frac = 0.0
        if i < rest.count, rest[i] == ":" {
            guard rest.count >= i + 3, let sv = num(rest[(i + 1)..<(i + 3)]) else { return nil }
            sec = sv; i += 3
            if i < rest.count, rest[i] == "." {
                var j = i + 1
                while j < rest.count, rest[j].isASCII, rest[j].isNumber { j += 1 }
                guard j > i + 1 else { return nil }
                frac = Double("0." + String(rest[(i + 1)..<j])) ?? 0
                i = j
            }
        }
        var offsetMin: Int
        if i == rest.count {
            offsetMin = TimeZone.current.secondsFromGMT() / 60   // no zone: local time, as JS reads a date-time form
        } else if rest[i] == "Z" && i + 1 == rest.count {
            offsetMin = 0
        } else if rest[i] == "+" || rest[i] == "-" {
            let z = rest[(i + 1)...].filter { $0 != ":" }
            guard z.count == 4, let zh = num(z[z.startIndex..<(z.startIndex + 2)]),
                  let zm = num(z[(z.startIndex + 2)..<(z.startIndex + 4)]) else { return nil }
            offsetMin = (zh * 60 + zm) * (rest[i] == "-" ? -1 : 1)
        } else {
            return nil
        }
        let secs = Double(day) * 86400 + Double(h * 3600 + mi * 60 + sec) - Double(offsetMin * 60)
        return (secs + frac) * 1000
    }

    // MARK: entries

    /// monthcard.js mine(g): a local record with a valid date and time.
    func mine(_ g: String) -> MonthCardRecord? {
        guard let r = records[g], Self.isDay(r.last), r.at > 0 else { return nil }
        return r
    }

    /// monthcard.js fromRelay(g): relay.月卡[g].
    private static func fromRelay(_ g: String) -> JSONValue? {
        Relay.shared.snap?["relay"]?["月卡"]?[g]
    }

    /// The relay has caught up with the local record: same date, or a 登记于 at or after it.
    private func caughtUp(_ loc: MonthCardRecord, _ rel: JSONValue?) -> Bool {
        guard let rel, let last = rel["最后领取"]?.string, Self.isDay(last) else { return false }
        if last == loc.last { return true }
        if let relAt = Self.parseISO(rel["登记于"]?.string), relAt >= loc.at { return true }
        return false
    }

    /// monthcard.js entry(g), without its write: newest registration wins; nil = never registered.
    func entry(_ g: String) -> MonthCardEntry? {
        let rel = Self.fromRelay(g)
        var loc = mine(g)
        if let l = loc, caughtUp(l, rel) { loc = nil }
        let relLast = rel?["最后领取"]?.string
        let last = loc?.last ?? (Self.isDay(relLast) ? relLast ?? "" : "")
        guard !last.isEmpty, let left = Self.daysBetween(Self.today(), last) else { return nil }
        return MonthCardEntry(last: last, left: left, local: loc != nil)
    }

    /// The write entry() skips: drop the local records the relay has caught up with.
    func reconcile() {
        var changed = false
        for g in Self.games {
            if let l = mine(g), caughtUp(l, Self.fromRelay(g)) { records[g] = nil; changed = true }
        }
        if changed { save() }
    }

    /// The machine is reachable now (live.js lastHb within its window).
    static var alive: Bool {
        let live = Live.shared
        return live.alive || (live.lastHb > 0 && nowMs() - live.lastHb < live.hbWindowMs())
    }

    /// The grey line under a local registration (monthcard.js syncNote()).
    static var syncNote: String { alive ? "正在同步到游戏机" : "游戏机开机后同步" }

    /// monthcard.js line(e).
    static func line(_ e: MonthCardEntry?) -> String {
        guard let e else { return "未登记" }
        return e.expired ? "已过期" : "最后一次领取：\(md(e.last))（还剩 \(e.left) 天）"
    }

    /// The cards with 0–5 days left (monthcard.js banner(); spec §4: the reminder starts 5 days before).
    func soon() -> [(game: String, entry: MonthCardEntry)] {
        Self.games.compactMap { g -> (game: String, entry: MonthCardEntry)? in
            guard let e = entry(g), !e.expired, e.left <= 5 else { return nil }
            return (g, e)
        }
    }

    /// The new last day for a top-up of `add` (spec §2, monthcard.js after()).
    func after(_ g: String, add: Int) -> String {
        if let e = entry(g), !e.expired { return Self.plus(e.last, Self.days * add) }
        return Self.plus(Self.today(), Self.days * add - 1)
    }

    // MARK: sending

    /// net.js send() under monthcard.js post(): the mailbox command, no 待保存 and no pending.js tracking.
    private func post(_ g: String, add: Int? = nil, left: Int? = nil, last: String?, at: Double?) async throws {
        var body: [String: JSONValue] = ["action": .string("monthcard"), "game": .string(g)]
        if let last { body["last"] = .string(last) }
        if let at { body["at"] = .string(Self.isoString(ms: at)) }
        if let add { body["add"] = .int(add) }
        if let left { body["left"] = .int(left) }
        try await Relay.shared.send(.object(body))
    }

    /// Registered here and shown at once; the relay gets its copy (a failed send is retried by resend()).
    /// monthcard.js register(): counted as sent first so a render meanwhile does not resend it beside this add.
    func register(_ g: String, add: Int? = nil, left: Int? = nil, last: String) async {
        // on ntfy's clock (Relay.clockSkewMs): the relay keeps the newest registration by `at` (monthcard.py:146) and
        // caughtUp() compares its 登记于 with this; a phone running slow had its registration ignored there and then
        // dropped here as caught up, with no word (edge audit 13)
        let at = Relay.shared.serverNowMs()
        // A top-up with nothing of ours still unsynced goes as a bare `add`: the relay adds 30 × N to its own last day
        // (monthcard.py:150-156, the same rule as after()), and with no `at` it is not dropped as older. Sent with this
        // phone's `last` and `at`, two phones topping up before either synced each sent its own sum and the newest
        // replaced the other: one purchase was lost (edge audit 13).
        let bare = add != nil && (mine(g).map { caughtUp($0, Self.fromRelay(g)) } ?? true)
        remember(g, last: last, at: at, sentAt: at)
        // no 「已登记」 toast: the rows show the new date and days left at once (HIG Feedback: "Consider integrating status
        // feedback into your interface.")
        do {
            try await post(g, add: add, left: left, last: bare ? nil : last, at: bare ? nil : at)
        } catch {
            if let r = mine(g), r.at == at { remember(g, last: last, at: at, sentAt: 0) }
        }
    }

    /// A record the relay never got: resend as left X (idempotent; add would count twice). monthcard.js resend().
    func resend() async {
        if resending { return }
        let t = Self.today(), now = nowMs()
        let due = Self.games.compactMap { g -> (String, MonthCardRecord)? in
            guard let r = records[g], Self.isDay(r.last), r.sentAt <= 0 || now - r.sentAt > Self.resendMs else { return nil }
            return (g, r)
        }
        if due.isEmpty { return }
        resending = true
        defer { resending = false }
        for (g, r) in due {
            guard let x = Self.daysBetween(t, r.last), x >= 0, x <= Self.maxLeft else { continue }   // lapsed, or beyond what the relay takes
            do {
                try await post(g, left: x, last: r.last, at: r.at)
                // only the record that went out: a registration made during the send is newer and keeps its own state
                if let cur = records[g], cur.at == r.at { remember(g, last: r.last, at: r.at, sentAt: nowMs()) }
            } catch {
                break
            }
        }
    }
}
