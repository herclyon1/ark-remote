import SwiftUI
import XCTest
@testable import ArkRemote

/// The 班次 list on 状态, built by StatusData.from. Defects guarded:
/// - a shift row whose time already came today keeps a working switch, although the switch sends skip_today, which the
///   relay takes for today only; flipping it then changes nothing while the row names a time that is still to come;
/// - the tile's next run, or a row's next run, is given without its day (「10:00」 read at 12:57 looks past);
/// - the rows come in the plan's order instead of by time, as one list (Clock's alarms);
/// - a shift skipped today loses its time (the plan leaves it out) although the snapshot gives the shift's 时刻;
/// - a maintenance line sits in the footer instead of under the game it is about;
/// - the skip words differ between the row, the 今天实际 line and the pending / review lines.
/// And the echo-farm time: picked on the phone's clock, sent on the machine's (one clock on the page).
@MainActor final class StatusShiftTests: XCTestCase {
    /// The plan of the real machine on 10-14 (plan.py next_plan): 早班 09:00 / 晚班 21:30 on the machine's clock, the
    /// 终末地 maintenance line before the first time, 晚班 listed first here to check the ordering.
    static func snap(skipped: [String] = [], times: Bool = true) throws -> JSONValue {
        let t1 = times ? #", "时刻": ["09:00"]"# : "", t2 = times ? #", "时刻": ["21:30"]"# : ""
        // a skip turns the shift's timer off, so the plan has no row for it (plan.py lists timed shifts only)
        let evening = skipped.contains("晚班") ? "" : "🕘 21:30　东京 22:30\\n▸ 明日方舟\\n　理智 YW-4（固定）\\n\\n"
        let skip = skipped.map { "\"\($0)\"" }.joined(separator: ", ")
        return try JSONValue.parse("""
            {"at": \(Int(nowMs() / 1000) - 60), "config": {"MAA": {"关卡": "1-7"}},
             "queues": [{"名": "早班", "定时": true, "脚本": ["MAA", "OK-WW", "MaaEnd"]\(t1)},
                        {"名": "晚班", "定时": true, "脚本": ["MAA"]\(t2)}],
             "plan": "📅 明日安排\\n⚠️ 终末地 明天 07:00–13:00 停服维护：这一班先跳过它，13:00 开服后单独补跑\\n\(evening)🕘 09:00　东京 10:00\\n▸ 明日方舟\\n▸ 鸣潮\\n　体力刷 无音区\\n▸ 终末地\\n　理智用于 钱币收集\\n⏻ 跑完自动关机",
             "relay": {"今天跳过队列": [\(skip)], "最近指令": []}}
            """)
    }

    /// A moment on the machine's clock today ("HH:mm", Beijing).
    static func machineAt(_ hhmm: String) -> Date {
        let day = { () -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = machineZone
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        return machineDate(full: "\(day) \(hhmm)")!
    }

    func data(_ snap: JSONValue, at now: Date, queue: String = "早班") -> StatusData {
        Relay.shared.snap = snap
        return StatusData.from(relay: Relay.shared, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                               currentQueue: queue, estopAt: 0, now: now)
    }

    /// The day words assume the phone's day turns within a few hours of the machine's (Tokyo is one hour ahead).
    func requireNearBeijing() throws {
        let diff = abs(TimeZone.current.secondsFromGMT() - (machineZone?.secondsFromGMT() ?? 0))
        if diff > 3 * 3600 { throw XCTSkip("phone zone too far from the machine's for the day words") }
    }

    func testRowsByTimeWithDayAndSwitchState() throws {
        try requireNearBeijing()
        let guardState = SharedStateGuard()
        defer { guardState.restore() }
        // 11:57 on the machine (12:57 Tokyo): 早班 09:00 is over today, 晚班 21:30 is still to come
        let d = data(try Self.snap(), at: Self.machineAt("11:57"))
        XCTAssertEqual(d.plan.map(\.queueName), ["早班", "晚班"], "one list ordered by time")
        let morning = try XCTUnwrap(d.plan.first), evening = try XCTUnwrap(d.plan.last)
        XCTAssertTrue(morning.passedToday, "早班's 09:00 is over: its switch can change nothing")
        XCTAssertFalse(evening.passedToday)
        let m = phoneHHMM(fromMachine: "09:00"), e = phoneHHMM(fromMachine: "21:30")
        XCTAssertEqual(morning.nextRun, "明天 \(m)")
        XCTAssertEqual(evening.nextRun, "今天 \(e)")
        XCTAssertEqual(morning.switchLine, "今天这班已过 · 明天 \(m) 照常")
        XCTAssertEqual(evening.switchLine, "今天跑")
        XCTAssertEqual(d.nextAt, "明天 \(m)", "the tile says the day of 早班's next run")
        XCTAssertEqual(data(try Self.snap(), at: Self.machineAt("11:57"), queue: "晚班").nextAt, "今天 \(e)")
        XCTAssertEqual(morning.machineNote, m == "09:00" ? "" : "游戏机上是 09:00")
        // before 09:00 both are still to come
        let early = data(try Self.snap(), at: Self.machineAt("08:10"))
        XCTAssertEqual(early.plan.map(\.passedToday), [false, false])
        XCTAssertEqual(early.nextAt, "今天 \(m)")
    }

    func testSkippedShiftKeepsItsTimeAndSaysNotToday() throws {
        try requireNearBeijing()
        let guardState = SharedStateGuard()
        defer { guardState.restore() }
        // the plan has no 晚班 row; the queue's 时刻 gives its time back
        let s = try Self.snap(skipped: ["晚班"])
        let d = data(s, at: Self.machineAt("11:57"))
        let evening = try XCTUnwrap(d.plan.first { $0.queueName == "晚班" })
        XCTAssertEqual(evening.time, "21:30")
        XCTAssertEqual(evening.shownTime, phoneHHMM(fromMachine: "21:30"))
        XCTAssertFalse(evening.runsToday)
        XCTAssertEqual(evening.switchLine, "今天不跑，明天照常")
        XCTAssertEqual(d.todayActual, "早班 跑 · 晚班 不跑")
        // an older relay without 时刻: the row has the shift's name alone
        let old = data(try Self.snap(skipped: ["晚班"], times: false), at: Self.machineAt("11:57"))
        XCTAssertNotNil(old.plan.first { $0.queueName == "晚班" })
    }

    func testMaintenanceLineGoesUnderItsGame() throws {
        let guardState = SharedStateGuard()
        defer { guardState.restore() }
        let d = data(try Self.snap(), at: Self.machineAt("11:57"))
        let ef = try XCTUnwrap(d.plan.first { $0.queueName == "早班" }?.games.first { $0.name == "终末地" })
        XCTAssertEqual(ef.warning, "明天 07:00–13:00 停服维护：这一班先跳过它，13:00 开服后单独补跑")
        XCTAssertFalse(d.planFoot.contains { $0.contains("停服维护") }, "said once, under the game")
        XCTAssertEqual(d.plan.first { $0.queueName == "晚班" }?.games.first?.warning, "", "晚班 does not run 终末地")
    }

    func testSkipWordsAreTheRowsWords() {
        let skip = EWEdit(label: "早班 · 10:00", src: "relay", from: .bool(true), to: .bool(false),
                          body: .object(["action": .string("skip_today"), "queue": .string("早班")]))
        let unskip = EWEdit(label: "晚班 · 22:30", src: "relay", from: .bool(false), to: .bool(true),
                            body: .object(["action": .string("unskip_today"), "queue": .string("晚班")]))
        XCTAssertEqual(EWSave.review(["a": skip, "b": unskip]).map(\.title), ["今天不跑：早班（10:00）", "今天跑：晚班（22:30）"])
        let p = PendingEdit(label: "早班", src: "relay", from: .bool(true), to: .bool(false), sentAt: 0, body: skip.body)
        XCTAssertEqual(Pending.shared.valueLabel(p, .bool(false)), "今天不跑")
        XCTAssertEqual(Pending.shared.valueLabel(p, .bool(true)), "今天跑")
    }

    /// The farm end is picked on the phone's clock and sent on the machine's; the relay (echofarm.py resolve_until) reads a
    /// machine time not after its clock now as tomorrow's, so the converted time must name the same moment there.
    func testEchoFarmTimeIsSentOnTheMachinesClock() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        guard TimeZone.current == tokyo || TimeZone.current.secondsFromGMT() == tokyo.secondsFromGMT() else {
            throw XCTSkip("the hour difference below is Tokyo's")
        }
        let at1900 = Self.machineAt("18:00")   // 19:00 Tokyo
        XCTAssertEqual(machineHHMM(fromPhone: "09:30", now: at1900), "08:30", "tomorrow morning")
        XCTAssertEqual(machineHHMM(fromPhone: "00:05", now: at1900), "23:05", "after the phone's midnight, before the machine's")
        XCTAssertEqual(machineHHMM(fromPhone: "23:30", now: at1900), "22:30")
        XCTAssertNil(machineHHMM(fromPhone: "25:00", now: at1900))
        XCTAssertEqual(phoneHHMM(fromMachine: "08:30"), "09:30", "the start default is the moment of the old 08:30")
    }

    func testEchoFarmCommandSendsMachineTime() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        guard TimeZone.current.secondsFromGMT() == tokyo.secondsFromGMT() else { throw XCTSkip("Tokyo only") }
        var ask: StatusAsk? = nil
        var queue = "早班"
        var edits: [String: EWEdit] = [:]
        var d = StatusData()
        d.machineOff = false
        let a = StatusCommands.actions(d, ask: Binding(get: { ask }, set: { ask = $0 }),
                                       storedQueue: Binding(get: { queue }, set: { queue = $0 }),
                                       edits: Binding(get: { edits }, set: { edits = $0 }))
        let q = try XCTUnwrap(a.startEchoFarm(1, "09:30"))
        XCTAssertEqual(q.body["until"]?.string, "08:30", "the machine's clock")
        XCTAssertTrue(q.message.contains("到 09:30"), "the phone's clock in the question: \(q.message)")
        XCTAssertFalse(q.message.contains("机器时间"))
        let c = try XCTUnwrap(a.changeEchoFarmUntil("09:30"))
        XCTAssertEqual(c.body["until"]?.string, "08:30")
    }

    /// 2026-10-22: 打哪个 listed only 讨伐强敌, so a weekly-boss farm had to be set up by hand (「做了半截导致我现在还得手动找你」).
    /// The menu now lists the weekly bosses after them; picking one sends its 战歌重奏 position with weekly: true
    /// (echofarm.py start, weekly=), and 讨伐强敌's 1 stays a separate choice without it.
    func testEchoFarmWeeklyBossIsSentAsWeekly() throws {
        var ask: StatusAsk? = nil
        var queue = "早班"
        var edits: [String: EWEdit] = [:]
        var d = StatusData()
        d.machineOff = false
        d.bosses = statusBosses + [StatusBoss(index: 1, name: "周本第 1 个 · 天演溯心", weekly: true),
                                   StatusBoss(index: 2, name: "周本第 2 个", weekly: true)]
        let a = StatusCommands.actions(d, ask: Binding(get: { ask }, set: { ask = $0 }),
                                       storedQueue: Binding(get: { queue }, set: { queue = $0 }),
                                       edits: Binding(get: { edits }, set: { edits = $0 }))
        XCTAssertEqual(Set(d.bosses.map(\.id)).count, d.bosses.count, "every menu choice has its own tag")
        let w = try XCTUnwrap(a.startEchoFarm(StatusBoss.weeklyBase + 1, "09:30"))
        XCTAssertEqual(w.body["boss"]?.number, 1, "the 战歌重奏 position, not the menu tag")
        XCTAssertEqual(w.body["weekly"]?.bool, true)
        XCTAssertEqual(w.body["name"]?.string, "周本第 1 个 · 天演溯心")
        XCTAssertTrue(w.message.contains("周本第 1 个"), w.message)
        let o = try XCTUnwrap(a.startEchoFarm(1, "09:30"))
        XCTAssertEqual(o.body["boss"]?.number, 1)
        XCTAssertNil(o.body["weekly"], "an overworld boss goes out as before")
        XCTAssertEqual(o.body["name"]?.string, "天傀劫煞")
    }

    /// The 早班 / 晚班 control has no title, and since the 班次 list shows every shift nothing on 状态 changes when it is
    /// flipped. Defect guarded: the control without a line saying what it picks (the game tabs' shift and the shift
    /// 现在跑一趟 runs), so a first-time reader cannot tell what it does.
    func testShiftPickerSaysWhatItPicks() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        let section = try XCTUnwrap(RepoFiles.body(after: "listSection(\"status-shift\"", in: lines), "the shift control's section")
        let text = section.joined(separator: "\n")
        XCTAssertTrue(text.contains(".pickerStyle(.segmented)"), "the section holds the 早班 / 晚班 control")
        guard let foot = text.range(of: "footer:") else { return XCTFail("the control's section has no footer") }
        let after = String(text[foot.upperBound...])
        XCTAssertTrue(after.contains("现在跑一趟") && after.contains("设置"),
                      "the footer says the game tabs' settings and 现在跑一趟 follow the choice")
    }
}
