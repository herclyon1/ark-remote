import XCTest

/// Regression 0108 #14. The owner, 10-02 16:41 「为什么有大约 50 处这么多不一样的地方？」, 20:07 「十条缺陷和五十多处不一致都
/// 修好了吗？」, 21:07 「还有没有不一致的地方和缺陷了？检查的到不到位？」: the App, ported from the web page, differed from it in
/// ~50 places. The list (BOARD/归档-1010/核对-缺陷与差异-2010.md: 12 defects + 58 differences) left 8 rows open on 10-02.
/// Since D212 (10-07) the web page is the App's feature list only, not its look (the web is no longer maintained), so a
/// text-by-text comparison of each page would flag the native redesign itself. What is checked instead:
///  1. every command the web page can send is one the App sends (the feature list): a feature missing from the port was
///     what 月卡 (#15) turned out to be;
///  2. the 8 rows left open on 10-02 stay closed: the no-input link opens the App (A5), 「链接已复制」 (手机5), a send
///     with changes left unsent says so in an alert (终末地17), no bare `if` at the top of a List (方舟10, an empty grey
///     section on Android). 状态15 (time fields checked on leaving) is #17's TimePickerTests: the fields are system time
///     pickers now. 手机6 (fixed link address) and 手机9 (版本 is the App's version) were closed as by design on 10-02.
final class WebDifferencesTests: XCTestCase {
    /// Every `action` the web page sends (maa-automation web/*.js on origin/main, read 2026-10-16; the web is frozen).
    static let webActions = ["debug_mode", "echo_farm", "echo_farm_stop", "echo_farm_until", "estop", "monthcard", "refresh",
                             "run_now", "set_config", "set_master", "skip_shutdown", "skip_today", "tacet_shots",
                             "unskip_today", "watch", "weekly_boss"]

    func testEveryWebCommandIsSentByTheApp() throws {
        let code = try RepoFiles.swiftSources().flatMap { $0.lines.map(RepoFiles.code) }.joined(separator: "\n")
        let missing = Self.webActions.filter { !code.contains("\"\($0)\"") }
        XCTAssertEqual(missing, [], "commands the web page sends and the App does not")
    }

    func testTheOpenRowsStayClosed() throws {
        // A5: the copied link is the App's own scheme, and both platforms open the App for it
        let tab = try RepoFiles.text("Sources/ArkRemote/Pages/Phone/PhoneTab.swift")
        XCTAssertTrue(tab.contains("static let linkBase = \"arkremote://link\""), "A5: the copied link is not arkremote://link")
        let manifest = try RepoFiles.text("Android/app/src/main/AndroidManifest.xml")
        XCTAssertTrue(manifest.contains("android:scheme=\"arkremote\"") && manifest.contains("android:host=\"link\""),
                      "A5: Android does not open arkremote://link")
        let plist = try RepoFiles.text("Darwin/Info.plist")
        XCTAssertTrue(plist.contains("<string>arkremote</string>"), "A5: iOS does not open arkremote://")
        // 手机5: the web's words after a copy (view.js:1327)
        XCTAssertTrue(try RepoFiles.text("Sources/ArkRemote/Pages/Phone/PhonePage.swift").contains("\"链接已复制\""), "手机5")
        // 终末地17: a send that left changes unsent says so (view.js:3005-3009 ask 「有改动没发出去」)
        XCTAssertTrue(try RepoFiles.text("Sources/ArkRemote/Pages/Shell/SaveBar.swift").contains(".alert(\"有改动没发出去\""), "终末地17")
        // 方舟10: no bare `if` at the top of any List
        var bare: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() { bare += Self.bareIfs(lines).map { "\(path):\($0)" } }
        XCTAssertEqual(bare.filter { b in !Self.bareIfAllowed.contains { b.hasPrefix($0.file) && b.hasSuffix($0.code) } }, [],
                       "方舟10: use listSection")
    }

    /// EndfieldStockNotesPage is pushed only from the 库存 list (its 「关于这些数字」 row), and Stockpile keeps the last good
    /// list (Stockpile.swift: back to .loading only while there is none), so its `if case .list` holds while it is shown.
    static let bareIfAllowed = [(file: "Sources/ArkRemote/Pages/Endfield/EWLive.swift:",
                                 code: "if case .list(_, let footnote) = Stockpile.shared.content {")]

    /// Lines (1-based, with their code) of an `if` directly inside a `List {` body.
    static func bareIfs(_ lines: [String]) -> [String] {
        var out: [String] = []
        for (i, line) in lines.enumerated() where RepoFiles.code(line).range(of: #"\bList\s*(\([^)]*\))?\s*\{\s*$"#,
                                                                              options: .regularExpression) != nil {
            var depth = 0
            for j in i..<lines.count {
                let c = RepoFiles.code(lines[j])
                if j > i, depth == 1, c.range(of: #"^\s*if\b"#, options: .regularExpression) != nil {
                    out.append("\(j + 1) \(c.trimmingCharacters(in: .whitespaces))")
                }
                depth += c.filter { $0 == "{" }.count - c.filter { $0 == "}" }.count
                if j > i, depth <= 0 { break }
            }
        }
        return out
    }

    /// The 10-02 方舟 page shape is caught; a listSection and an `if` inside a Section are not.
    func testTheScanSeesABareIf() {
        let page = ["        List {", "            if data.notInShift {", "                Section { Text(\"x\") }", "            }",
                    "            listSection(\"a\", if: ok) {", "                Section {", "                    if data.stage != nil {",
                    "                        Text(\"y\")", "                    }", "                }", "            }", "        }"]
        XCTAssertEqual(Self.bareIfs(page), ["2 if data.notInShift {"])
    }
}
