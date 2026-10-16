// 用药 (owner 2026-10-16 Tokyo 21:0x, after oral surgery: 「我会忘记吃药的间隔…手动登记一次，我现在已经吃药了，然后下一次我
// 打开app就能看到距离上次吃药，过了多久」; 「一个是固定的时间一日三回。另一个是只要疼了就行，但是他说有个间隔，理想间隔是4~6个小时」;
// the prescription of 2026-10-16, 市立東大阪医療センター 口腔外科). The two medicines, the doses he logs, and the texts the
// 手机 tab's rows and the medicine page show. Local only: no relay, no network; the doses survive restarts in UserDefaults.
//
// Stored under "ark-meds" as a JSON string (as MonthCardStore keeps "ark-monthcard"): [{ "med": "amoxicillin", "at": 1792130400 }],
// `at` in epoch seconds. Only the rules on the prescription and in his words: 3 a day for amoxicillin, the 4–6 hour interval
// for loxoprofen, and the counts handed out (6 and 10). No other medical rule is added.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

/// The two medicines of the 2026-10-16 prescription.
enum Medication: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case amoxicillin
    case loxoprofen

    var id: String { rawValue }

    /// The name as on the prescription.
    var name: String {
        switch self {
        case .amoxicillin: return "阿莫西林胶囊 250mg"
        case .loxoprofen: return "洛索洛芬钠片 60mg"
        }
    }

    /// The short name for a pushed page's title.
    var shortName: String {
        switch self {
        case .amoxicillin: return "阿莫西林"
        case .loxoprofen: return "洛索洛芬钠"
        }
    }

    /// How to take it, as the prescription says.
    var howTo: String {
        switch self {
        case .amoxicillin: return "每天 3 次，早午晚饭后各 1 粒（共 6 粒，2 天）"
        case .loxoprofen: return "疼的时候吃 1 片，间隔 4–6 小时（共 10 片）"
        }
    }

    /// How many were handed out.
    var total: Int {
        switch self {
        case .amoxicillin: return 6
        case .loxoprofen: return 10
        }
    }

    /// 粒 for the capsule, 片 for the tablet.
    var unit: String {
        switch self {
        case .amoxicillin: return "粒"
        case .loxoprofen: return "片"
        }
    }

    /// Doses a day, for the fixed-schedule medicine only.
    var perDay: Int? { self == .amoxicillin ? 3 : nil }
}

/// One logged dose: {"med": "amoxicillin" | "loxoprofen", "at": epoch seconds}.
struct MedicationDose: Codable, Equatable, Hashable, Sendable {
    var med: String
    var at: Int
}

/// Where loxoprofen stands against the 4–6 hour interval.
enum MedicationInterval: Equatable, Sendable {
    /// Under 4 hours: this many seconds left until 4 hours.
    case wait(Int)
    /// 4 to 6 hours.
    case ready
    /// 6 hours or more.
    case past6
}

@MainActor @Observable final class MedicationStore {
    static let shared = MedicationStore()
    static let localKey = "ark-meds"

    /// Every logged dose, in the order logged.
    var doses: [MedicationDose] = []

    init() {
        doses = Self.decode(UserDefaults.standard.string(forKey: Self.localKey))
    }

    /// Logs a dose taken at `at` (never later than now).
    func log(_ med: Medication, at: Date, now: Date = Date()) {
        let t = min(at, now)
        doses.append(MedicationDose(med: med.rawValue, at: Int(t.timeIntervalSince1970.rounded(.down))))
        save()
    }

    /// Removes one logged dose (its first match).
    func remove(_ dose: MedicationDose) {
        if let i = doses.firstIndex(of: dose) {
            doses.remove(at: i)
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(Self.encode(doses), forKey: Self.localKey)
    }

    // MARK: storage

    static func encode(_ doses: [MedicationDose]) -> String {
        guard let data = try? JSONEncoder().encode(doses) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The stored doses; an unreadable or missing value is no doses.
    static func decode(_ raw: String?) -> [MedicationDose] {
        guard let raw, let data = raw.data(using: .utf8),
              let o = try? JSONDecoder().decode([MedicationDose].self, from: data) else { return [] }
        return o
    }

    // MARK: what the rows show (pure, `now` passed in)

    /// The doses of one medicine, newest first.
    static func history(_ doses: [MedicationDose], _ med: Medication) -> [MedicationDose] {
        doses.filter { $0.med == med.rawValue }.sorted { $0.at > $1.at }
    }

    /// The newest dose of one medicine.
    static func last(_ doses: [MedicationDose], _ med: Medication) -> MedicationDose? {
        history(doses, med).first
    }

    /// Seconds since the newest dose (0 for one logged in the future); nil when none is logged.
    static func elapsed(_ doses: [MedicationDose], _ med: Medication, now: Date) -> Int? {
        guard let l = last(doses, med) else { return nil }
        return max(0, Int(now.timeIntervalSince1970.rounded(.down)) - l.at)
    }

    /// Doses of `med` on the phone's calendar day of `now`.
    static func takenToday(_ doses: [MedicationDose], _ med: Medication, now: Date, calendar: Calendar = .current) -> Int {
        doses.filter {
            $0.med == med.rawValue && calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0.at)), inSameDayAs: now)
        }.count
    }

    /// What is left of the handed-out count, never below 0.
    static func remaining(_ doses: [MedicationDose], _ med: Medication) -> Int {
        max(0, med.total - doses.filter { $0.med == med.rawValue }.count)
    }

    /// Loxoprofen's interval: under 4 h, 4–6 h, 6 h or more.
    static func interval(elapsed: Int) -> MedicationInterval {
        if elapsed < 4 * 3600 { return .wait(4 * 3600 - elapsed) }
        return elapsed < 6 * 3600 ? .ready : .past6
    }

    /// 「2 小时 15 分」, 「15 分钟」, 「不到 1 分钟」: a duration, minutes rounded down.
    static func duration(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m == 0 { return "不到 1 分钟" }
        if m < 60 { return "\(m) 分钟" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
    }

    /// 「离上次 2 小时 15 分」 or 「还没记录」.
    static func sinceLine(_ doses: [MedicationDose], _ med: Medication, now: Date) -> String {
        guard let e = elapsed(doses, med, now: now) else { return "还没记录" }
        return "离上次 \(duration(e))"
    }

    /// The line under 离上次 for loxoprofen; nil for amoxicillin or before the first dose.
    static func intervalLine(_ doses: [MedicationDose], _ med: Medication, now: Date) -> String? {
        guard med == .loxoprofen, let e = elapsed(doses, med, now: now) else { return nil }
        switch interval(elapsed: e) {
        case .wait(let left):
            // minutes rounded up, so it never says 「还要等 不到 1 分钟」 while short of 4 hours
            return "还要等 \(duration((left + 59) / 60 * 60))"
        case .ready:
            return "已过 4 小时，可以吃"
        case .past6:
            return "已过 6 小时，可以吃"
        }
    }

    /// 「今天已吃 2/3 · 还剩 3 粒」 (amoxicillin) or 「还剩 9 片」 (loxoprofen).
    static func countLine(_ doses: [MedicationDose], _ med: Medication, now: Date, calendar: Calendar = .current) -> String {
        let left = "还剩 \(remaining(doses, med)) \(med.unit)"
        guard let perDay = med.perDay else { return left }
        return "今天已吃 \(takenToday(doses, med, now: now, calendar: calendar))/\(perDay) · " + left
    }

    /// A dose's time: 「21:05」 today, 「昨天 21:05」, else 「10月14日 21:05」 (the phone's calendar).
    static func timeText(_ at: Int, now: Date, calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at))
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: d)
        let mi = c.minute ?? 0
        let hm = "\(c.hour ?? 0):" + (mi < 10 ? "0" : "") + "\(mi)"
        if calendar.isDate(d, inSameDayAs: now) { return hm }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "昨天 " + hm }
        return "\(c.month ?? 0)月\(c.day ?? 0)日 " + hm
    }

    /// 「刚刚」, 「15 分钟前」, 「5 小时前」, 「2 天前」.
    static func agoText(_ at: Int, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince1970.rounded(.down)) - at)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 48 * 3600 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}
