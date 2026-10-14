import XCTest
@testable import ArkRemote

/// The game cards' footers (decision A2/W4, BOARD/App-待他定项-从记录定-1014.md). Defect guarded: a footer repeats the
/// row names drawn right above it as a 「行名：」 list, or loses a fact the rows do not show: the stage-code format,
/// 理智药 0 = don't use and 999 = no limit, 周本 numbering from 1, and that only the first two settlements count. Without
/// those facts a wrong value gets mailed to the PC. The checks look for the facts, not for one wording of them.
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

    /// No line starts with a short label and 「：」, whatever the label says (a name list whose names differ from the rows').
    private func assertNoLabelPrefix(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for l in text.split(separator: "\n") {
            XCTAssertFalse(Self.has(String(l), #"^[^。，、\s]{1,8}："#), "「\(l)」 starts with a label", file: file, line: line)
        }
    }

    static func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// `n` as a number of its own (0 is not the 0 in 10).
    static func number(_ text: String, _ n: Int) -> Bool { has(text, #"(?<!\d)"# + "\(n)" + #"(?!\d)"#) }

    func testArknightsStageFooterHasNoRowNamesButKeepsTheFacts() {
        let foot = ArknightsPage.footerText(arknightsStage)
        assertNoNameList(foot, ["关卡", "理智药", "作战开关", "活动关优先", "活动关序号"])
        assertNoLabelPrefix(foot)
        XCTAssertTrue(Self.has(foot, #"[A-Z]*\d+-\d+"#), "no stage-code example: \(foot)")
        XCTAssertTrue(Self.number(foot, 0), "理智药 0 is not explained: \(foot)")
        XCTAssertTrue(Self.number(foot, 999), "理智药 999 is not explained: \(foot)")
    }

    func testArknightsAwardFooterHasNoRowNames() {
        let foot = ArknightsPage.footerText(arknightsAward)
        assertNoNameList(foot, ["邮件", "幸运墙合成玉", "开采许可合成玉", "周年月卡"])
        assertNoLabelPrefix(foot)
    }

    func testWuwaDailyFooterHasNoRowNames() {
        let rows = ewRows(WuwaSchema.group, .wuwaSample, values: [:])
        XCTAssertFalse(rows.isEmpty)
        let foot = WuwaPage.dailyFoot(rows)
        assertNoNameList(foot, rows.map(\.label) + ["无音区结算截图"])
        assertNoLabelPrefix(foot)
        // the switch's sentence is still there, and the 残象聚落 line names no single settlement (W2)
        XCTAssertTrue(foot.contains(tacetShotsHint), foot)
        XCTAssertTrue(Self.has(foot, #"前\s*(两|2)\s*个"#), "only the first two settlements count: \(foot)")
        XCTAssertFalse(foot.contains("落渊南丘"), foot)
    }

    func testWuwaWeeklyFooterHasNoRowNames() {
        let foot = WuwaPage.weeklyFoot
        assertNoNameList(foot, ["周常乐园", "周本", "周本打第几个"])
        assertNoLabelPrefix(foot)
        XCTAssertTrue(Self.number(foot, 1), "周本 numbering from 1 is not said: \(foot)")
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
