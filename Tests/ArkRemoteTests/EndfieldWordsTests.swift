import XCTest
@testable import ArkRemote

/// 终末地 rows a first-time reader could not read. Defects guarded: a weekday list shows a count to work out
/// (「已选 7/7」) instead of the days (Clock's Repeat: 「Every Day」 / 「Weekdays」); the three task cards do not show their
/// days in the same place; the mode menu reads like the 「基质刷取设置」 link under it (「刷取设置」); MaaEnd's
/// 「循环执行」 / 「使用几天内」 / 「随机模式 · 领取方式」 stay unexplained; the 基质刷取设置 page is one long card.
@MainActor final class EndfieldWordsTests: XCTestCase {
    static let week = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].enumerated().map {
        EWChoice($0.element, "AutoEssenceSchedule" + ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][$0.offset])
    }

    func testWeekdaysAreSaidAsDays() {
        let v = Self.week.map(\.value)
        XCTAssertEqual(ewPillsValue(Self.week, v), "每天")
        XCTAssertEqual(ewPillsValue(Self.week, Array(v.prefix(5))), "工作日")
        XCTAssertEqual(ewPillsValue(Self.week, Array(v.suffix(2))), "周末")
        XCTAssertEqual(ewPillsValue(Self.week, [v[0], v[2], v[4]]), "周一、三、五")
        XCTAssertEqual(ewPillsValue(Self.week, Array(v.prefix(6))), "周一、二、三、四、五、六")
        // a list that is not the week keeps its count
        let areas = [EWChoice("枢纽区", "VFTheHub"), EWChoice("清波寨", "WLQingboStockade")]
        XCTAssertEqual(ewPillsValue(areas, ["VFTheHub"]), "已选 1/2")
    }

    func testCardsShowDaysAndNamesSayWhatTheySet() {
        let data = EndfieldPageData.sample
        let m = data.master
        for (g, days) in [(EndfieldSchema.essence, "AutoEssence/AutoEssenceSchedule"),
                          (EndfieldSchema.protocolSpace, "ProtocolSpace/ProtocolSpaceSchedule"),
                          (EndfieldSchema.otherTasks, "AutoCollect/AutoCollectSchedule")] {
            let rows = ewRows(g, m, values: m.values)
            let first = rows.filter { EndfieldSchema.firstLevel.contains($0.path) }
            XCTAssertEqual(first.first { $0.path == days }?.label, "哪几天跑", "\(g.title): days not on the page")
        }
        let rows = ewRows(EndfieldSchema.essence, m, values: m.values)
        let label = { (p: String) in rows.first { $0.path == "AutoEssence/" + p }?.label }
        XCTAssertEqual(label("AutoEssenceMenu"), "刷取方式")
        XCTAssertEqual(label("AutoEssenceRepeatCount"), "每趟最多几轮")
        XCTAssertEqual(label("AutoEssenceObtainMode"), "领取方式")
        XCTAssertEqual(label("AutoEssenceSpMedicationExpireWithinDays"), "只吃几天内过期的")
        XCTAssertFalse(EndfieldSchema.otherTasks.title.contains("另一个任务"))
    }

    func testEssenceSettingsAreSplitIntoCards() {
        let m = EndfieldPageData.sample.master
        let rest = ewRows(EndfieldSchema.essence, m, values: m.values).filter { !EndfieldSchema.firstLevel.contains($0.path) }
        let cards = EndfieldSchema.moreCards(EndfieldSchema.essence.title, rest)
        XCTAssertEqual(cards.compactMap(\.header).prefix(4), ["刷哪里、刷几轮", "领奖", "战后筛选", "理智"])
        XCTAssertEqual(cards.map(\.rows.count).reduce(0, +), rest.count, "every row placed once")
        // ★ rows stay with their parent (decision E2: inline under 武器稀有度)
        let filter = cards.first { $0.header == "战后筛选" }?.rows.map(\.path) ?? []
        XCTAssertTrue(filter.contains("AutoEssence/EssenceFilterAfterBattleRarity6Weapon"))
        XCTAssertEqual(EndfieldSchema.moreCards(EndfieldSchema.protocolSpace.title, rest).count, 1)
    }
}
