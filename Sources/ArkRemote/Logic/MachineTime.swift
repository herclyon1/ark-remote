import Foundation

// The machine's clock is Beijing (relay config.py SERVER_TZ = Asia/Shanghai): a receipt's at / sent are "%m-%d %H:%M"
// (modes.py:584-587), debug mode's end and the echo farm's 从 / 到 "%Y-%m-%d %H:%M" (modes.py:217, echofarm.py:355-357),
// all Beijing wall-clock strings with no zone. The page's own times (已寄出, 最后心跳, 体力读取) are the phone's clock —
// Tokyo for the user — so the machine's are converted here for display only (审查 B4: on one screen 「已寄出 10:00」 sat
// above 「09:00 发出 · 09:00 执行」). Every comparison (skip notes, the estop match, Beijing days) keeps the raw strings.

private func timeFormatter(_ format: String, _ zone: TimeZone?) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = format
    return f
}

/// The machine's zone (relay config.py SERVER_TZ).
let machineZone = TimeZone(identifier: "Asia/Shanghai")

/// "yyyy-MM-dd HH:mm" on the machine's clock → that moment; nil when unreadable.
func machineDate(full s: String) -> Date? {
    timeFormatter("yyyy-MM-dd HH:mm", machineZone).date(from: s.trimmingCharacters(in: .whitespaces))
}

/// "MM-dd HH:mm" on the machine's clock (a receipt: no year) → that moment. The year is the machine's current one, or the
/// one before when that would put it more than a day ahead (a December receipt read in January); nil when unreadable.
func machineDate(stamp s: String) -> Date? {
    let year = timeFormatter("yyyy", machineZone).string(from: Date())
    guard let d = machineDate(full: "\(year)-\(s)") else { return nil }
    if d.timeIntervalSinceNow > 86400, let y = Int(year), let prev = machineDate(full: "\(y - 1)-\(s)") { return prev }
    return d
}

/// A machine "MM-dd HH:mm" as the phone's "MM-dd HH:mm"; an unreadable one as given.
func phoneStamp(fromMachine s: String) -> String {
    guard let d = machineDate(stamp: s) else { return s }
    return timeFormatter("MM-dd HH:mm", TimeZone.current).string(from: d)
}

/// A machine "yyyy-MM-dd HH:mm" as the phone's "HH:mm" (localClockWithDay); an unreadable one as given.
func localClock(fromMachineFull s: String) -> String {
    guard let d = machineDate(full: s) else { return s }
    return localClockWithDay(d)
}

/// The phone's "HH:mm", with the day in front when it is not today: 「昨天 23:10」 / 「明天 08:30」 / 「10月3日 08:30」
/// (审查 C2: a bare 「最后心跳 22:34」 read the next morning does not say which day).
func localClockWithDay(_ d: Date) -> String {
    let cal = Calendar.current
    let hm = timeFormatter("HH:mm", TimeZone.current).string(from: d)
    if cal.isDateInToday(d) { return hm }
    if cal.isDateInYesterday(d) { return "昨天 \(hm)" }
    if cal.isDateInTomorrow(d) { return "明天 \(hm)" }
    let c = cal.dateComponents([.month, .day], from: d)
    return "\(c.month ?? 0)月\(c.day ?? 0)日 \(hm)"
}

/// The machine's clock now, "HH:mm": an "HH:MM" the relay is sent is read on that clock (echofarm.py resolve_until).
func machineNowHHMM() -> String {
    timeFormatter("HH:mm", machineZone).string(from: Date())
}
