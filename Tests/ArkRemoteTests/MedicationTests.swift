import SwiftUI
import XCTest
@testable import ArkRemote

/// 用药 (owner 10-16 21:0x): the texts the 状态 rows and the medicine page show, from the logged doses and a given now.
/// Elapsed time since the last dose, loxoprofen's 4–6 hour interval, amoxicillin's 今天已吃 n/3 on the phone's calendar
/// day, what is left of the handed-out count (never below 0), the stored JSON and the history order.
@MainActor final class MedicationTests: XCTestCase {
    /// 2026-10-16 21:00 in Osaka (UTC+9).
    let t0 = 1_792_152_000
    var osaka: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }
    private func dose(_ m: Medication, _ at: Int) -> MedicationDose { MedicationDose(med: m.rawValue, at: at) }

    func testTheReferenceMomentIsNinePmInOsaka() {
        let c = osaka.dateComponents([.year, .month, .day, .hour, .minute], from: date(t0))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 10, 16, 21, 0])
    }

    func testNothingLoggedYet() {
        XCTAssertEqual(MedicationStore.sinceLine([], .loxoprofen, now: date(t0)), "还没记录")
        XCTAssertNil(MedicationStore.intervalLine([], .loxoprofen, now: date(t0)))
        XCTAssertEqual(MedicationStore.countLine([], .loxoprofen, now: date(t0), calendar: osaka), "还剩 10 片")
        XCTAssertEqual(MedicationStore.countLine([], .amoxicillin, now: date(t0), calendar: osaka), "今天已吃 0/3 · 还剩 6 粒")
    }

    func testElapsedSinceTheNewestDose() {
        let doses = [dose(.loxoprofen, t0 - 5 * 3600), dose(.loxoprofen, t0 - (2 * 3600 + 15 * 60 + 40)), dose(.amoxicillin, t0 - 60)]
        XCTAssertEqual(MedicationStore.elapsed(doses, .loxoprofen, now: date(t0)), 2 * 3600 + 15 * 60 + 40)
        XCTAssertEqual(MedicationStore.sinceLine(doses, .loxoprofen, now: date(t0)), "离上次 2 小时 15 分")
        XCTAssertEqual(MedicationStore.sinceLine(doses, .amoxicillin, now: date(t0)), "离上次 1 分钟")
        XCTAssertEqual(MedicationStore.duration(0), "不到 1 分钟")
        XCTAssertEqual(MedicationStore.duration(59), "不到 1 分钟")
        XCTAssertEqual(MedicationStore.duration(45 * 60), "45 分钟")
        XCTAssertEqual(MedicationStore.duration(5 * 3600), "5 小时")
        XCTAssertEqual(MedicationStore.duration(26 * 3600 + 60), "26 小时 1 分")
        // a dose logged ahead of the clock counts as just taken, not a negative time
        XCTAssertEqual(MedicationStore.elapsed([dose(.loxoprofen, t0 + 100)], .loxoprofen, now: date(t0)), 0)
    }

    func testLoxoprofenInterval() {
        func line(_ ago: Int) -> String? {
            MedicationStore.intervalLine([dose(.loxoprofen, t0 - ago)], .loxoprofen, now: date(t0))
        }
        XCTAssertEqual(line(0), "再等 4 小时 才到 4 小时")
        XCTAssertEqual(line(3 * 3600), "再等 1 小时 才到 4 小时")
        XCTAssertEqual(line(2 * 3600 + 15 * 60), "再等 1 小时 45 分 才到 4 小时")
        // rounded up: 30 s short of 4 hours still waits a minute
        XCTAssertEqual(line(4 * 3600 - 30), "再等 1 分钟 才到 4 小时")
        XCTAssertEqual(line(4 * 3600), "已过 4 小时，可以吃")
        XCTAssertEqual(line(5 * 3600), "已过 4 小时，可以吃")
        XCTAssertEqual(line(6 * 3600 - 1), "已过 4 小时，可以吃")
        XCTAssertEqual(line(6 * 3600), "已过 6 小时")
        XCTAssertEqual(line(30 * 3600), "已过 6 小时")
        // amoxicillin has no interval line
        XCTAssertNil(MedicationStore.intervalLine([dose(.amoxicillin, t0 - 3600)], .amoxicillin, now: date(t0)))
        XCTAssertEqual(MedicationStore.interval(elapsed: 3600), .wait(3 * 3600))
    }

    func testTodayCountsOnThePhonesCalendarDay() {
        // 21:00 today, 13:00 today, 08:00 today, 23:50 yesterday; and the loxoprofen is not counted
        let doses = [dose(.amoxicillin, t0), dose(.amoxicillin, t0 - 8 * 3600), dose(.amoxicillin, t0 - 13 * 3600),
                     dose(.amoxicillin, t0 - (21 * 3600 + 10 * 60)), dose(.loxoprofen, t0 - 3600)]
        XCTAssertEqual(MedicationStore.takenToday(doses, .amoxicillin, now: date(t0), calendar: osaka), 3)
        XCTAssertEqual(MedicationStore.countLine(doses, .amoxicillin, now: date(t0), calendar: osaka), "今天已吃 3/3 · 还剩 2 粒")
        // 5 minutes after midnight the day starts over: only the 23:50 dose is yesterday's of the new day's view
        let justAfterMidnight = date(t0 + 3 * 3600 + 5 * 60)
        XCTAssertEqual(MedicationStore.takenToday(doses, .amoxicillin, now: justAfterMidnight, calendar: osaka), 0)
    }

    func testRemainingNeverBelowZero() {
        let many = (0..<8).map { dose(.amoxicillin, t0 - $0 * 3600) }
        XCTAssertEqual(MedicationStore.remaining(many, .amoxicillin), 0)
        XCTAssertEqual(MedicationStore.remaining(many, .loxoprofen), 10)
        let three = (0..<3).map { dose(.loxoprofen, t0 - $0 * 5 * 3600) }
        XCTAssertEqual(MedicationStore.countLine(three, .loxoprofen, now: date(t0), calendar: osaka), "还剩 7 片")
    }

    func testStoredJSONRoundTripsAndHistoryIsNewestFirst() throws {
        let doses = [dose(.amoxicillin, t0 - 7200), dose(.loxoprofen, t0 - 18000), dose(.amoxicillin, t0)]
        let raw = MedicationStore.encode(doses)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(o.first?["med"] as? String, "amoxicillin")
        XCTAssertEqual(o.first?["at"] as? Int, t0 - 7200)
        XCTAssertEqual(MedicationStore.decode(raw), doses)
        XCTAssertEqual(MedicationStore.decode(nil), [])
        XCTAssertEqual(MedicationStore.decode("not json"), [])
        XCTAssertEqual(MedicationStore.history(doses, .amoxicillin).map(\.at), [t0, t0 - 7200])
    }

    func testLogNeverStoresAFutureTimeAndRemoveTakesOne() {
        let saved = UserDefaults.standard.object(forKey: MedicationStore.localKey)
        let store = MedicationStore.shared
        let before = store.doses
        defer {
            store.doses = before
            if let saved { UserDefaults.standard.set(saved, forKey: MedicationStore.localKey) }
            else { UserDefaults.standard.removeObject(forKey: MedicationStore.localKey) }
        }
        store.doses = []
        store.log(.loxoprofen, at: date(t0 + 3600), now: date(t0))
        store.log(.amoxicillin, at: date(t0 - 60), now: date(t0))
        XCTAssertEqual(store.doses, [dose(.loxoprofen, t0), dose(.amoxicillin, t0 - 60)])
        XCTAssertEqual(MedicationStore.decode(UserDefaults.standard.string(forKey: MedicationStore.localKey)), store.doses)
        store.remove(dose(.loxoprofen, t0))
        XCTAssertEqual(store.doses, [dose(.amoxicillin, t0 - 60)])
    }

    func testTimeAndAgoTexts() {
        XCTAssertEqual(MedicationStore.timeText(t0 - 5 * 3600 + 5 * 60, now: date(t0), calendar: osaka), "16:05")
        XCTAssertEqual(MedicationStore.timeText(t0 - 22 * 3600, now: date(t0), calendar: osaka), "昨天 23:00")
        XCTAssertEqual(MedicationStore.timeText(t0 - 50 * 3600, now: date(t0), calendar: osaka), "10月14日 19:00")
        XCTAssertEqual(MedicationStore.agoText(t0 - 20, now: date(t0)), "刚刚")
        XCTAssertEqual(MedicationStore.agoText(t0 - 15 * 60, now: date(t0)), "15 分钟前")
        XCTAssertEqual(MedicationStore.agoText(t0 - 5 * 3600, now: date(t0)), "5 小时前")
        XCTAssertEqual(MedicationStore.agoText(t0 - 50 * 3600, now: date(t0)), "2 天前")
    }

    /// A medicine page left open on the 手机 tab is pushed again on a cold launch; nothing stored, or a value that is no
    /// medicine, starts at the tab's root.
    func testTheOpenMedicinePageComesBackOnLaunch() {
        let saved = UserDefaults.standard.object(forKey: phoneOpenMedicationKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: phoneOpenMedicationKey) }
            else { UserDefaults.standard.removeObject(forKey: phoneOpenMedicationKey) }
        }
        UserDefaults.standard.removeObject(forKey: phoneOpenMedicationKey)
        XCTAssertEqual(ContentView.restoredPhonePath().count, 0)
        UserDefaults.standard.set("loxoprofen", forKey: phoneOpenMedicationKey)
        var want = NavigationPath()
        want.append(PhoneRoute.medication("loxoprofen"))
        XCTAssertEqual(ContentView.restoredPhonePath(), want)
        UserDefaults.standard.set("aspirin", forKey: phoneOpenMedicationKey)
        XCTAssertEqual(ContentView.restoredPhonePath().count, 0)
    }
}
