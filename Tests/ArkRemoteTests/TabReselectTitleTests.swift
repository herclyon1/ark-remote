import XCTest

/// Regression 0108 #16 (D39). Defect guarded: tapping the selected tab again does not go back to its root page, or on
/// Android leaves the large title collapsed after the page was scrolled. Going back to the root on a reselect is the
/// system tab bar's behaviour on iOS, which the Android build must match; skip-ui does not reopen the title by itself
/// (SkipFixes.swift ExpandTopBarOnReselect, 8bd50e0). The pop and the scroll to the top are replay steps
/// (receipts.tabpop, mc.tabpop, ef.stock.tabpop, ef.more.tabpop, d39.*.top in scripts/replay/steps.py).
/// The check: each of the five tabs' NavigationStack carries `.expandsTopBarOnReselect(.<tab>)`, the modifier installs
/// ExpandTopBarOnReselect in its Android branch, and ContentView.reselect clears every tab's path.
final class TabReselectTitleTests: XCTestCase {
    static let tabs = ["status", "arknights", "endfield", "wuwa", "phone"]

    static func expanded(_ lines: [String]) -> Set<String> {
        var out = Set<String>()
        for line in lines.map(RepoFiles.code) {
            for t in tabs where line.contains(".expandsTopBarOnReselect(.\(t))") { out.insert(t) }
        }
        return out
    }

    /// Whether expandsTopBarOnReselect's body installs ExpandTopBarOnReselect while an Android branch is open.
    static func opensOnAndroid(_ lines: [String]) -> Bool {
        guard let body = RepoFiles.body(after: "func expandsTopBarOnReselect(", in: lines) else { return false }
        return RepoFiles.contains("ExpandTopBarOnReselect", on: .android, in: body)
    }

    func testEveryTabOpensItsTitleOnReselect() throws {
        let content = try RepoFiles.lines("Sources/ArkRemote/ContentView.swift")
        XCTAssertEqual(Self.expanded(content), Set(Self.tabs))
        let reselect = try XCTUnwrap(RepoFiles.body(after: "private func reselect(", in: content)).joined(separator: "\n")
        for t in Self.tabs { XCTAssertTrue(reselect.contains("\(t)Path = NavigationPath()"), "a reselect of \(t) keeps its pushed page") }
        XCTAssertTrue(Self.opensOnAndroid(try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/SkipFixes.swift")),
                      "expandsTopBarOnReselect no longer opens the title on Android")
    }

    func testTheScanSeesAMissingTab() {
        XCTAssertEqual(Self.expanded(["  .expandsTopBarOnReselect(.status)", "  // .expandsTopBarOnReselect(.phone)"]), ["status"])
    }

    func testTheScanSeesTheModifierBranch() {
        let fn = ["    func expandsTopBarOnReselect(_ tab: ContentTab) -> some View {", "        #if os(Android)"]
        XCTAssertTrue(Self.opensOnAndroid(fn + ["          composeModifier { ExpandTopBarOnReselect(tab: tab.reselectIndex) }",
                                                "        #else", "        self", "        #endif", "    }"]))
        XCTAssertFalse(Self.opensOnAndroid(fn + ["        self", "        #else",
                                                 "        composeModifier { ExpandTopBarOnReselect(tab: tab.reselectIndex) }",
                                                 "        #endif", "    }"]))
        XCTAssertFalse(Self.opensOnAndroid(fn + ["        // composeModifier { ExpandTopBarOnReselect(tab: 0) }", "        self",
                                                 "        #else", "        self", "        #endif", "    }"]))
    }
}
