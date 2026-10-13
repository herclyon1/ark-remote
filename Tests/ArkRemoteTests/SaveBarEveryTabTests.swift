import XCTest

/// Regression 0108 #4: 10-02 18:57 「现在方舟顶栏是什么东西？」. 方舟 had a top bar of its own while the other tabs shared
/// one; bb1fdc2 put every tab on the one edit bar over the one pool of unsaved changes. The check: every tab's root page
/// carries EWSaveBar with its own name, the bar's title while editing is 「待保存 N 项」 counted over the shared pool, and
/// no other code draws a 「待保存」 title. The replay step ark.edit4 (scripts/replay/steps.py) sees 「待保存 4 项」 on 方舟.
final class SaveBarEveryTabTests: XCTestCase {
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

    func testEveryTabRootHasTheSharedBar() throws {
        for (file, title) in Self.roots {
            XCTAssertTrue(Self.carriesBar(try RepoFiles.lines(file), title: title), "\(file) has no EWSaveBar(title: \"\(title)\")")
        }
    }

    func testTheBarCountsTheOnePool() throws {
        let bar = try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/SaveBar.swift").map(RepoFiles.code).joined(separator: "\n")
        XCTAssertTrue(bar.contains("EWEdits.shared.items"), "the bar no longer reads the shared pool")
        XCTAssertTrue(bar.contains("navigationTitle(edits.isEmpty ? title : \"待保存 \\(edits.count) 项\")"),
                      "the editing title is not 「待保存 N 项」")
    }

    func testNoOtherEditTitle() throws {
        for (path, lines) in try RepoFiles.swiftSources() where !path.hasSuffix("Pages/Shell/SaveBar.swift") {
            // a row's own 「待保存」 tag (EWRowView, StatusCommands) is fine; a title of its own is not
            for (i, line) in lines.enumerated() where RepoFiles.code(line).contains("navigationTitle(")
                && RepoFiles.code(line).contains("待保存") {
                XCTFail("\(path):\(i + 1) draws a 「待保存」 title of its own")
            }
        }
    }

    func testTheScanSeesAMissingBar() {
        XCTAssertFalse(Self.carriesBar(["    // .modifier(EWSaveBar(title: \"明日方舟\"))"], title: "明日方舟"))
        XCTAssertTrue(Self.carriesBar(["    .modifier(EWSaveBar(title: \"明日方舟\"))"], title: "明日方舟"))
    }
}
