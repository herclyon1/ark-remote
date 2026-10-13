import XCTest

/// Regression 0108 #16: 10-05 05:10 「这个为什么不补？」 (D39, tapping the selected tab again goes back to its root page).
/// The pop and the scroll to the top are replay steps (receipts.tabpop, mc.tabpop, ef.stock.tabpop, ef.more.tabpop,
/// d39.*.top in scripts/replay/steps.py); the part with no step was 8bd50e0's: on Android the large title opens again on
/// a reselect after the page was scrolled to the bottom (skip-ui does not do it; SkipFixes.swift ExpandTopBarOnReselect).
/// The check: each of the five tabs' NavigationStack carries `.expandsTopBarOnReselect(.<tab>)`, the modifier still
/// installs ExpandTopBarOnReselect on Android, and ContentView.reselect still clears every tab's path.
final class TabReselectTitleTests: XCTestCase {
    static let tabs = ["status", "arknights", "endfield", "wuwa", "phone"]

    static func expanded(_ lines: [String]) -> Set<String> {
        var out = Set<String>()
        for line in lines.map(RepoFiles.code) {
            for t in tabs where line.contains(".expandsTopBarOnReselect(.\(t))") { out.insert(t) }
        }
        return out
    }

    func testEveryTabOpensItsTitleOnReselect() throws {
        let content = try RepoFiles.lines("Sources/ArkRemote/ContentView.swift")
        XCTAssertEqual(Self.expanded(content), Set(Self.tabs))
        let reselect = try XCTUnwrap(RepoFiles.body(after: "private func reselect(", in: content)).joined(separator: "\n")
        for t in Self.tabs { XCTAssertTrue(reselect.contains("\(t)Path = NavigationPath()"), "a reselect of \(t) keeps its pushed page") }
        let fixes = try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/SkipFixes.swift")
        let modifier = try XCTUnwrap(RepoFiles.body(after: "func expandsTopBarOnReselect(", in: fixes)).joined(separator: "\n")
        XCTAssertTrue(modifier.contains("#if os(Android)\n        composeModifier { ExpandTopBarOnReselect(tab: tab.reselectIndex) }"),
                      "expandsTopBarOnReselect no longer opens the title on Android")
    }

    func testTheScanSeesAMissingTab() {
        XCTAssertEqual(Self.expanded(["  .expandsTopBarOnReselect(.status)", "  // .expandsTopBarOnReselect(.phone)"]), ["status"])
    }
}
