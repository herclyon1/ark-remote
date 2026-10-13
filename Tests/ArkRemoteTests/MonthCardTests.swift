import XCTest
@testable import ArkRemote

/// Regression 0108 #15: 10-05 01:48 「我遥控器app怎么没有月卡功能。网页搬过去的时候怎么还能出现这种问题。」 The pages are
/// covered by the replay steps mc.open … mc.tabpop (scripts/replay/steps.py); this is the date rule under them
/// (spec BOARD/月卡到期提示-规格.md §2, web monthcard.js): days counted on Shanghai's calendar, so the day turns at
/// Shanghai midnight; a top-up of N adds 30 × N to a card still running and counts from today − 1 for a lapsed or
/// never-registered one; two top-ups add up; the relay's copy replaces the phone's once it has caught up.
@MainActor final class MonthCardTests: XCTestCase {
    /// ms of an ISO UTC time.
    private func ms(_ iso: String) throws -> Double { try XCTUnwrap(MonthCardStore.parseISO(iso)) }

    func testTheDayTurnsAtShanghaiMidnight() throws {
        XCTAssertEqual(MonthCardStore.today(try ms("2026-10-14T15:59:59.999Z")), "2026-10-14")
        XCTAssertEqual(MonthCardStore.today(try ms("2026-10-14T16:00:00.000Z")), "2026-10-15")
        XCTAssertEqual(MonthCardStore.today(try ms("2026-12-31T16:00:00Z")), "2027-01-01")
        // the same moment written with Shanghai's offset
        XCTAssertEqual(MonthCardStore.today(try ms("2026-10-15T00:00:00+08:00")), "2026-10-15")
        XCTAssertEqual(MonthCardStore.today(try ms("2026-10-14T23:59:59+08:00")), "2026-10-14")
    }

    func testDayArithmetic() throws {
        XCTAssertEqual(MonthCardStore.plus("2026-01-31", 30), "2026-03-02")
        XCTAssertEqual(MonthCardStore.plus("2028-02-28", 1), "2028-02-29")
        XCTAssertEqual(MonthCardStore.plus("2026-12-31", 1), "2027-01-01")
        XCTAssertEqual(MonthCardStore.daysBetween("2026-10-14", "2026-11-13"), 30)
        XCTAssertEqual(MonthCardStore.daysBetween("2026-10-14", "2026-10-11"), -3)
        XCTAssertNil(MonthCardStore.daysBetween("2026-10-14", "10-14"))
        for d in stride(from: -800, through: 40_000, by: 97) {
            XCTAssertEqual(MonthCardStore.dayNumber(MonthCardStore.isoDay(d)), d)
        }
        let t = 1_791_955_800_123.0
        XCTAssertEqual(try XCTUnwrap(MonthCardStore.parseISO(MonthCardStore.isoString(ms: t))), t, accuracy: 0.5)
        XCTAssertEqual(MonthCardStore.md("2026-09-29"), "9月29日")
    }

    func testTopUpRuleAndTwoTopUpsAddUp() {
        let saved = UserDefaults.standard.object(forKey: MonthCardStore.localKey)
        let guardState = SharedStateGuard()
        defer {
            guardState.restore()
            if let saved { UserDefaults.standard.set(saved, forKey: MonthCardStore.localKey) }
            else { UserDefaults.standard.removeObject(forKey: MonthCardStore.localKey) }
        }
        Relay.shared.snap = nil
        let store = MonthCardStore()
        let today = MonthCardStore.today(), now = nowMs()
        store.records = [:]

        // never registered: today + 30 × N − 1
        XCTAssertNil(store.entry("终末地"))
        XCTAssertEqual(MonthCardStore.line(nil), "未登记")
        XCTAssertEqual(store.after("终末地", add: 1), MonthCardStore.plus(today, 29))
        XCTAssertEqual(store.after("终末地", add: 2), MonthCardStore.plus(today, 59))

        // running, 10 days left: last + 30 × N; a second top-up adds on top of the first
        let last = MonthCardStore.plus(today, 10)
        store.records["终末地"] = MonthCardRecord(last: last, at: now, sentAt: now)
        XCTAssertEqual(store.entry("终末地"), MonthCardEntry(last: last, left: 10, local: true))
        XCTAssertEqual(MonthCardStore.line(store.entry("终末地")), "还剩 10 天 · \(MonthCardStore.md(last))最后一次领取")
        let first = store.after("终末地", add: 1)
        XCTAssertEqual(first, MonthCardStore.plus(today, 40))
        store.records["终末地"] = MonthCardRecord(last: first, at: now + 1, sentAt: now + 1)
        XCTAssertEqual(store.after("终末地", add: 1), MonthCardStore.plus(today, 70))

        // lapsed 3 days ago: counted from today again
        store.records["终末地"] = MonthCardRecord(last: MonthCardStore.plus(today, -3), at: now, sentAt: now)
        XCTAssertEqual(store.entry("终末地")?.expired, true)
        XCTAssertEqual(MonthCardStore.line(store.entry("终末地")), "已过期")
        XCTAssertEqual(store.after("终末地", add: 1), MonthCardStore.plus(today, 29))

        // 0–5 days left is the reminder's window
        store.records["终末地"] = MonthCardRecord(last: MonthCardStore.plus(today, 5), at: now, sentAt: now)
        XCTAssertEqual(store.soon().map(\.game), ["终末地"])
        store.records["终末地"] = MonthCardRecord(last: MonthCardStore.plus(today, 6), at: now, sentAt: now)
        XCTAssertEqual(store.soon().map(\.game), [])
    }

    func testRelayCopyTakesOverOnceCaughtUp() throws {
        let saved = UserDefaults.standard.object(forKey: MonthCardStore.localKey)
        let guardState = SharedStateGuard()
        defer {
            guardState.restore()
            if let saved { UserDefaults.standard.set(saved, forKey: MonthCardStore.localKey) }
            else { UserDefaults.standard.removeObject(forKey: MonthCardStore.localKey) }
        }
        let store = MonthCardStore()
        let today = MonthCardStore.today(), now = nowMs()
        let mine = MonthCardStore.plus(today, 40), relays = MonthCardStore.plus(today, 10)
        store.records = ["明日方舟": MonthCardRecord(last: mine, at: now, sentAt: now)]
        // the relay still has the older day and an older 登记于: the phone's registration shows
        Relay.shared.snap = try JSONValue.parse("""
            {"relay": {"月卡": {"明日方舟": {"最后领取": "\(relays)", "登记于": "\(MonthCardStore.isoString(ms: now - 60_000))"}}}}
            """)
        XCTAssertEqual(store.entry("明日方舟"), MonthCardEntry(last: mine, left: 40, local: true))
        // the relay caught up (登记于 at or after the phone's): its day wins and the local record goes
        Relay.shared.snap = try JSONValue.parse("""
            {"relay": {"月卡": {"明日方舟": {"最后领取": "\(relays)", "登记于": "\(MonthCardStore.isoString(ms: now + 1000))"}}}}
            """)
        XCTAssertEqual(store.entry("明日方舟"), MonthCardEntry(last: relays, left: 10, local: false))
        store.reconcile()
        XCTAssertNil(store.records["明日方舟"])
    }
}
