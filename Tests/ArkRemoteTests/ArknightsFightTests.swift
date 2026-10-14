import XCTest
@testable import ArkRemote

/// 方舟 › 作战. Defects guarded: 活动关序号 can be changed while 活动关优先 is off, when the machine does not use it
/// (Calendar hides End Repeat while Repeat is Never); the switch is named after its group (「作战」) instead of what turning
/// it off stops; the stage footer loses the 关卡 / 理智药 facts when the switches move to their own card.
final class ArknightsFightTests: XCTestCase {
    func testActivityIndexOnlyWhileActivityFirstIsOn() {
        var d = ArknightsPageData.sample
        d.ifFight = true
        d.activityStageIndex = "1"
        d.ifActivityFirst = false
        XCTAssertEqual(ArknightsPage.fightRows(d), ["Task.IfFight", "Task.IfActivityFirst"])
        d.ifActivityFirst = true
        XCTAssertEqual(ArknightsPage.fightRows(d), ["Task.IfFight", "Task.IfActivityFirst", "Task.ActivityStageIndex"])
    }

    func testSwitchSaysWhatItStops() throws {
        let code = try RepoFiles.lines("Sources/ArkRemote/Pages/Arknights/ArknightsPage.swift").map(RepoFiles.code)
        XCTAssertTrue(code.contains { $0.contains(#"label("Task.IfFight", "刷关卡")"#) }, "the 作战 switch is not 「刷关卡」")
        // the switches' card footer says when 活动关序号 is used no more: the row is hidden otherwise
        XCTAssertFalse(ArknightsPage.footerText(["Task.ActivityStageIndex"]).contains("开着时才用"))
        let stage = ArknightsPage.footerText(["Info.Stage", "Info.MedicineNumb"])
        XCTAssertTrue(stage.contains("1-7") && stage.contains("999"), stage)
    }
}
