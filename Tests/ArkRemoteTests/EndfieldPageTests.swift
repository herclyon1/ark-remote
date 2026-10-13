import XCTest
@testable import ArkRemote

/// The 终末地 tab's choice page and 库存 page, without their views.
/// - 勾选页 ✓ (App-全部显示项 191, shell-api 「至少要留一个」): nothing ticked on a multi-choice page is refused; the page
///   disables ✓ and says so in its footer instead of the old toast. The write-back order and the edge audit 33 rule
///   (same set in another order = no change) stay as view.js:1146-1149.
/// - 库存 (app-page-references P5): a row short of one build is marked, so the page draws its 「差 N」 orange.
final class EndfieldPageTests: XCTestCase {
    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    func testNothingTickedIsBlocked() {
        XCTAssertEqual(ewChoiceResult(draft: [], initial: days, listed: days, multi: true), .blocked)
    }

    func testSameSetInAnotherOrderIsNoChange() {
        XCTAssertEqual(ewChoiceResult(draft: days.reversed(), initial: days, listed: days, multi: true), .unchanged)
    }

    func testWrittenBackInTableOrderKeepingUnlistedValues() {
        XCTAssertEqual(ewChoiceResult(draft: ["Sunday", "old", "Monday"], initial: days, listed: days, multi: true),
                       .commit(["Monday", "Sunday", "old"]))
    }

    func testSingleChoiceCommits() {
        XCTAssertEqual(ewChoiceResult(draft: ["3"], initial: ["1"], listed: ["1", "2", "3"], multi: false), .commit(["3"]))
    }

    @MainActor func testShortRowIsMarked() throws {
        let g = try JSONValue.parse(Data("""
        {"rows": [
          {"id": "a", "name": "short", "group": "养成", "have": 3, "need": 10, "servings": 0.3},
          {"id": "b", "name": "enough", "group": "养成", "have": 30, "need": 10, "servings": 3},
          {"id": "c", "name": "no need", "group": "养成", "have": 5}
        ]}
        """.utf8))
        guard case .list(let sections, _) = Stockpile.list(g, .object([:]), err: "") else { return XCTFail("not a list") }
        let rows = Dictionary(uniqueKeysWithValues: sections.flatMap { $0.rows }.map { ($0.name, $0) })
        XCTAssertEqual(rows["short"]?.value, "差 7")
        XCTAssertEqual(rows["short"]?.short, true)
        XCTAssertEqual(rows["enough"]?.value, "3.0 人份")
        XCTAssertEqual(rows["enough"]?.short, false)
        XCTAssertNil(rows["no need"]?.value)
        XCTAssertEqual(rows["no need"]?.short, false)
    }
}
