import XCTest
@testable import ArkRemote

/// The 方舟 and 鸣潮 card footers (decision A2/W4, BOARD/App-待他定项-从记录定-1014.md): no 「行名：」 list repeating
/// the row names drawn right above, while the facts he cannot infer stay (the 关卡 format example, 理智药 0 / 999).
@MainActor final class FooterTextTests: XCTestCase {
    private let arknightsStage = ["Info.Stage", "Info.MedicineNumb", "Task.IfFight", "Task.IfActivityFirst",
                                  "Task.ActivityStageIndex"]
    private let arknightsAward = ["Award/Mail", "Award/Orundum", "Award/Mining", "Award/SpecialAccess"]

    /// No line starts with a row name and 「：」.
    private func assertNoNameList(_ text: String, _ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        for l in text.split(separator: "\n") {
            for n in names {
                XCTAssertFalse(l.hasPrefix(n + "："), "「\(l)」 starts with 「\(n)：」", file: file, line: line)
            }
        }
    }

    func testArknightsStageFooterHasNoRowNamesButKeepsTheFacts() {
        let foot = ArknightsPage.footerText(arknightsStage)
        assertNoNameList(foot, ["关卡", "理智药", "作战开关", "活动关优先", "活动关序号"])
        XCTAssertFalse(foot.contains("："), foot)
        XCTAssertTrue(foot.contains("1-7、CE-6、AT-4"), foot)
        XCTAssertTrue(foot.contains("填 0 不用"), foot)
        XCTAssertTrue(foot.contains("填 999 不限"), foot)
        XCTAssertEqual(foot.split(separator: "\n").count, arknightsStage.count)
    }

    func testArknightsAwardFooterHasNoRowNames() {
        let foot = ArknightsPage.footerText(arknightsAward)
        assertNoNameList(foot, ["邮件", "幸运墙合成玉", "开采许可合成玉", "周年月卡"])
        XCTAssertFalse(foot.contains("："), foot)
    }

    func testWuwaDailyFooterHasNoRowNames() {
        let rows = ewRows(WuwaSchema.group, .wuwaSample, values: [:])
        XCTAssertFalse(rows.isEmpty)
        let foot = WuwaPage.dailyFoot(rows)
        assertNoNameList(foot, rows.map(\.label) + ["无音区结算截图"])
        XCTAssertFalse(foot.contains("："), foot)
        // the switch's sentence is still there, and the 残象聚落 line names no single settlement (W2)
        XCTAssertTrue(foot.contains(tacetShotsHint), foot)
        XCTAssertTrue(foot.contains("前两个"), foot)
        XCTAssertFalse(foot.contains("落渊南丘"), foot)
    }

    func testWuwaWeeklyFooterHasNoRowNames() {
        let foot = WuwaPage.weeklyFoot
        assertNoNameList(foot, ["周常乐园", "周本", "周本打第几个"])
        XCTAssertFalse(foot.contains("："), foot)
        XCTAssertTrue(foot.contains("第一个是 1"), foot)
    }

    /// 终末地 cards and their 「…设置」 pages: no 「行名：」 in front either (HIG review 1014: the three game tabs used two
    /// footer styles), and a sentence shared by several rows (routes, reward groups) is said once.
    func testEndfieldFootersHaveNoRowNamesAndNoRepeats() {
        let data = EndfieldPageData.sample
        for g in EndfieldSchema.groups {
            guard let c = ewCard(g, data, values: data.master.values) else { return XCTFail("no card for \(g.title)") }
            for part in [c.rows.filter { EndfieldSchema.firstLevel.contains($0.path) },
                         c.rows.filter { !EndfieldSchema.firstLevel.contains($0.path) }] {
                let foot = ewFoot(part, card: c.rows)
                assertNoNameList(foot, c.rows.map(\.label))
                let lines = foot.split(separator: "\n")
                XCTAssertEqual(lines.count, Set(lines).count, foot)
            }
        }
        XCTAssertEqual(ewFoot([EWFootItem(label: "A", hint: "x。"), EWFootItem(label: "B", hint: "y。")], rows: 2), "x。\ny。")
    }
}
