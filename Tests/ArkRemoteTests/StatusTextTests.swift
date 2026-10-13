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

    /// The machine's decorative emoji go from every name shown (owner decision E5); ★ and plain text stay.
    func testMachineNamesWithoutEmoji() {
        XCTAssertEqual(ewDisplayLabel("🎱基质刷取"), "基质刷取")
        XCTAssertEqual(ewDisplayLabel("⚔️协议空间"), "协议空间")
        XCTAssertEqual(ewDisplayLabel("🧺自动采集"), "自动采集")
        // HIG review 1014: the machine's half-width brackets beside the App's full-width punctuation
        XCTAssertEqual(ewDisplayLabel("执行周期(游戏时间)"), "执行周期（游戏时间）")
        XCTAssertEqual(ewDisplayLabel("刷第几个无音区 (F2列表)"), "刷第几个无音区（F2列表）")
        XCTAssertEqual(ewDisplayLabel("Level (1-5)"), "Level (1-5)")
        XCTAssertEqual(ewDisplayLabel("🟨无瑕基质"), "无瑕基质")
        XCTAssertEqual(ewDisplayLabel("🟪高纯基质"), "高纯基质")
        XCTAssertEqual(ewDisplayLabel("★6 黯色火炬"), "★6 黯色火炬")
        XCTAssertEqual(ewDisplayLabel("干员养成（作战记录、协议圆盘）"), "干员养成（作战记录、协议圆盘）")
        XCTAssertEqual(ewDisplayLabel("早班 → 晚班 · 1-7"), "早班 → 晚班 · 1-7")
        XCTAssertEqual(statusTidyHint("🎱基质刷取 · 随机模式"), "基质刷取 · 随机模式")
    }

    /// A machine master's names are shown without emoji, while the values that are sent stay as the machine has them.
    func testMasterDecodeStripsNamesNotValues() throws {
        let json = """
        {"values": {"AutoEssence/@enabled": true, "AutoEssence/Mode": "🎱x"},
         "labels": {"AutoEssence/@enabled": "🎱基质刷取"},
         "options": {"AutoEssence/Mode": [["🟨无瑕基质", "🎱x"]]}}
        """
        let m = try XCTUnwrap(EWMaster(jsonString: json))
        XCTAssertEqual(m.labels["AutoEssence/@enabled"], "基质刷取")
        XCTAssertEqual(m.options["AutoEssence/Mode"]?.first?.label, "无瑕基质")
        XCTAssertEqual(m.options["AutoEssence/Mode"]?.first?.value, "🎱x")
        XCTAssertEqual(m.values["AutoEssence/Mode"]?.key, "🎱x")
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
