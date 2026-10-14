import XCTest
@testable import ArkRemote

/// 手机 page words a first-time reader could not act on. Defects guarded: the record sheet says 「送不到时…」 before
/// anything was sent; the mark button is named 「就是这里」 / 「旗子」 in one place and shows another icon on each platform;
/// the PIN-mismatch line sends the user to 「粘贴密钥串」 for a link; the self check counts a machine off at night or an
/// unset optional key as failures.
@MainActor final class PhoneWordsTests: XCTestCase {
    func testRecordSheetSaysOnlyWhatHoldsNow() {
        func rec(_ state: String?) -> JSONValue {
            var o: [String: JSONValue] = ["events": .array(Array(repeating: .null, count: 13))]
            if let state { o["upload"] = .object(["state": .string(state)]) }
            return .object(o)
        }
        XCTAssertEqual(DiagUI.sheetMessage(rec("local")).text, "记了 13 条。还没发出，只在这台手机里。可以复制或分享给别人。")
        XCTAssertEqual(DiagUI.sheetMessage(rec("sent")).text, "记了 13 条，已发去排查。")
        XCTAssertTrue(DiagUI.sheetMessage(rec("kept")).text.hasPrefix("记了 13 条，没发出去（"))
        for s in ["local", "sent", "kept"] {
            XCTAssertFalse(DiagUI.sheetMessage(rec(s)).text.contains("就是这里"))
        }
    }

    func testTheMarkButtonHasOneName() throws {
        XCTAssertEqual(DiagMarkMenu.name, "标出问题")
        XCTAssertTrue(DiagUI.startLine.contains("「标出问题」"))
        XCTAssertFalse(DiagAccessory.detail(DiagUI.startLine).contains("旗子"))
        for file in ["Sources/ArkRemote/Pages/Shell/DiagAccessory.swift", "Sources/ArkRemote/Pages/Phone/PhoneDiag.swift",
                     "Sources/ArkRemote/Pages/Phone/PhoneDiagRows.swift"] {
            let code = try RepoFiles.lines(file).map(RepoFiles.code).joined(separator: "\n")
            XCTAssertFalse(code.contains("\"就是这里\"") || code.contains("就是这里」"), "\(file) still says 就是这里")
        }
    }

    func testPinMismatchPointsAtTheLinkRow() throws {
        let code = try RepoFiles.lines("Sources/ArkRemote/Logic/Net.swift").map(RepoFiles.code).joined(separator: "\n")
        XCTAssertTrue(code.contains("「粘贴免输入链接」重设"))
        let page = try RepoFiles.lines("Sources/ArkRemote/Pages/Phone/PhonePage.swift").map(RepoFiles.code).joined(separator: "\n")
        XCTAssertTrue(page.contains("Button(\"粘贴免输入链接\")"), "the 手机 page has no 粘贴免输入链接 row")
    }

    func testNormalStatesAreNotFailures() {
        let off = SelfCheckItem(name: "机器", ok: false, detail: "关着（开机后会自动连上）", neutral: true)
        let bad = SelfCheckItem(name: "手机网络", ok: false, detail: "没网", fix: "看看手机的网络设置")
        let saved = UserDefaults.standard.string(forKey: LastSelfCheck.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: LastSelfCheck.key) }
            else { UserDefaults.standard.removeObject(forKey: LastSelfCheck.key) }
        }
        LastSelfCheck.save([off, bad])
        XCTAssertEqual(LastSelfCheck.stored()?["fails"]?.number, 1, "the machine off at night is not a failure")
        XCTAssertEqual(LastSelfCheck.summary()["failRows"]?.array?.count, 1)
    }
}
