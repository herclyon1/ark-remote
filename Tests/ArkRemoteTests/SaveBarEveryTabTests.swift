import XCTest
@testable import ArkRemote

/// Regression 0108 #4. Defect guarded: one tab gets its own edit bar or its own pool of unsaved changes (方舟 once had a
/// top bar of its own; bb1fdc2 put every tab on the one bar). Edits made there would then not show, or not be saved,
/// confirmed and mailed, with the rest, and that is the App's core flow. The check: every tab's root page carries
/// EWSaveBar with its own name, the bar reads the shared pool, its title says how many changes wait, and no other code
/// titles a page from the pool. The replay step ark.edit4 (scripts/replay/steps.py) sees the count on 方舟.
@MainActor final class SaveBarEveryTabTests: XCTestCase {
    static let roots = [
        ("Sources/ArkRemote/Pages/Shell/StatusTab.swift", "状态"),
        ("Sources/ArkRemote/Pages/Shell/ArknightsTab.swift", "明日方舟"),
        ("Sources/ArkRemote/Pages/Shell/EndfieldTab.swift", "终末地"),
        ("Sources/ArkRemote/Pages/Shell/WuwaTab.swift", "鸣潮"),
        ("Sources/ArkRemote/ContentView.swift", "手机"),
    ]

    static func carriesBar(_ lines: [String], title: String) -> Bool {
        lines.map(RepoFiles.code).contains { $0.contains(".modifier(EWSaveBar(title: \"\(title)\"))") }
    }

    /// "line code" of every navigationTitle outside SaveBar.swift that titles a page from the pool of changes.
    static func ownEditTitles(_ lines: [String]) -> [String] {
        lines.enumerated().compactMap { i, line in
            let c = RepoFiles.code(line)
            return c.contains("navigationTitle(") && (c.contains("EWEdits") || c.contains("edits.count"))
                ? "\(i + 1) \(c.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    func testEveryTabRootHasTheSharedBar() throws {
        for (file, title) in Self.roots {
            XCTAssertTrue(Self.carriesBar(try RepoFiles.lines(file), title: title), "\(file) has no EWSaveBar(title: \"\(title)\")")
        }
    }

    func testTheBarCountsTheOnePool() throws {
        let bar = try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/SaveBar.swift").map(RepoFiles.code).joined(separator: "\n")
        XCTAssertTrue(bar.contains("EWEdits.shared.items"), "the bar no longer reads the shared pool")
    }

    /// The title is the tab's name while nothing waits, and names the count while changes wait.
    func testTheTitleSaysHowManyWait() {
        for tab in ["状态", "明日方舟", "手机"] {
            XCTAssertEqual(EWSaveBar.title(tab: tab, count: 0), tab)
            for n in [1, 4, 12] {
                let t = EWSaveBar.title(tab: tab, count: n)
                XCTAssertNotEqual(t, tab, "\(n) changes wait but the title is still the tab's name")
                XCTAssertTrue(t.contains("\(n)"), "\(t) does not say \(n)")
            }
        }
    }

    func testNoOtherEditTitle() throws {
        for (path, lines) in try RepoFiles.swiftSources() where !path.hasSuffix("Pages/Shell/SaveBar.swift") {
            for hit in Self.ownEditTitles(lines) { XCTFail("\(path):\(hit) titles a page from the pool of its own") }
        }
    }

    func testTheScanSeesAMissingBar() {
        XCTAssertFalse(Self.carriesBar(["    // .modifier(EWSaveBar(title: \"明日方舟\"))"], title: "明日方舟"))
        XCTAssertTrue(Self.carriesBar(["    .modifier(EWSaveBar(title: \"明日方舟\"))"], title: "明日方舟"))
        XCTAssertEqual(Self.ownEditTitles(["        .navigationTitle(edits.count > 0 ? \"改了 \\(edits.count) 处\" : \"方舟\")",
                                           "        .navigationTitle(EWEdits.shared.items.isEmpty ? \"方舟\" : \"编辑中\")",
                                           "        .navigationTitle(\"确认这次修改\")",
                                           "        // .navigationTitle(edits.count)"]).count, 2)
    }
}
