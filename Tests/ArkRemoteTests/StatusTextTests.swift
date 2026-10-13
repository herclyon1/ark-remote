import XCTest
@testable import ArkRemote

/// The 状态 page's text after the HIG review (app-1013 review 状态 7 / 9, 月卡-回执 1 / 5).
/// - A plan hint from the machine reads in Chinese typography: full-width comma and brackets, no space between two
///   Chinese characters, nothing cut.
/// - A receipt's time is 「12:57」 today and 「昨天 20:23」 yesterday, so the time column stays narrow.
final class StatusTextTests: XCTestCase {
    func testPlanHintPunctuation() {
        XCTAssertEqual(statusTidyHint("梦枢天罗,落渊南丘"), "梦枢天罗、落渊南丘")
        XCTAssertEqual(statusTidyHint("剿灭 本周已打满"), "剿灭本周已打满")
        XCTAssertEqual(statusTidyHint("周一、四 跑"), "周一、四跑")
        XCTAssertEqual(statusTidyHint("理智 YW-4 (固定)"), "理智 YW-4（固定）")
        XCTAssertEqual(statusTidyHint("刷 1-7"), "刷 1-7")
        XCTAssertEqual(statusTidyHint("a, b (c)"), "a, b (c)")
    }

    func testReceiptTimeToday() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9)))
        XCTAssertEqual(receiptShortAt("10-14 12:57", now: now), "12:57")
        XCTAssertEqual(receiptShortAt("10-13 20:23", now: now), "昨天 20:23")
        XCTAssertEqual(receiptShortAt("10-11 08:00", now: now), "10-11 08:00")
    }

    func testReceiptDayAcrossMonth() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        XCTAssertEqual(receiptDayWord("11-01", now: now), "")
        XCTAssertEqual(receiptDayWord("10-31", now: now), "昨天")
        XCTAssertNil(receiptDayWord("10-30", now: now))
    }
}
