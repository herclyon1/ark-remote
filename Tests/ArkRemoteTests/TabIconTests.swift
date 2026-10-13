import XCTest

/// Regression 0108 #1: the tab bar's icons. 10-02 16:23 「这个比之前是个退步。不应该」 when the game tabs lost their
/// coloured project icons; b3f23be put them back and dec49e0 (10-07) swapped all five for system symbols again
/// (方舟 `shield` / Icons.Outlined.Star …). Owner decision G7: 状态 and 手机 are Apple's SF Symbols (gauge, iphone) drawn
/// live; the three game tabs keep their projects' coloured icons (his 09-14 21:08, 10-02 16:23).
final class TabIconTests: XCTestCase {
    static let expected = [
        "状态": "tabSymbol(\"gauge.with.dots.needle.67percent\"",
        "手机": "tabSymbol(\"iphone\"",
        "方舟": "tabIcon(\"tab-arknights\")",
        "终末地": "tabIcon(\"tab-endfield\")",
        "鸣潮": "tabIcon(\"tab-wuwa\")",
    ]

    /// Tab name → the code of its icon closure, from `Label { Text("<name>") } icon: { <icon> }` lines.
    static func tabIcons(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines.map(RepoFiles.code) {
            guard let t = line.range(of: "Label { Text(\""), let i = line.range(of: "} icon: {", range: t.upperBound..<line.endIndex)
            else { continue }
            let name = String(line[t.upperBound...].prefix { $0 != "\"" })
            out[name] = String(line[i.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// The icons in ContentView are the decided ones, and the game ones are images drawn in their own colours.
    func testTabIcons() throws {
        let icons = Self.tabIcons(try RepoFiles.lines("Sources/ArkRemote/ContentView.swift"))
        XCTAssertEqual(Set(icons.keys), Set(Self.expected.keys), "the five tabs' labels")
        for (tab, want) in Self.expected {
            XCTAssertTrue(icons[tab]?.hasPrefix(want) == true, "\(tab): \(icons[tab] ?? "none"), want \(want)…")
        }
        for game in ["tab-arknights", "tab-endfield", "tab-wuwa"] {
            let contents = try RepoFiles.text("Sources/ArkRemote/Resources/Module.xcassets/\(game).imageset/Contents.json")
            XCTAssertTrue(contents.contains("\"template-rendering-intent\": \"original\""),
                          "\(game) is not drawn in its own colours")
        }
        // tabSymbol is the live SF Symbol on iOS (the exported image only on Android, which has no such Material icon)
        let content = try RepoFiles.lines("Sources/ArkRemote/ContentView.swift")
        let body = try XCTUnwrap(RepoFiles.body(after: "private func tabSymbol(", in: content)).joined(separator: "\n")
        XCTAssertTrue(body.contains("#else\n    Image(systemName: symbol)"), "tabSymbol does not draw the SF Symbol on iOS")
    }

    /// The scan reads dec49e0's labels (Tab { } label: { Label … }) and would have refused them.
    func testTheScanCatchesDec49e0() {
        let dec49e0 = """
                Label { Text("状态") } icon: { symbol("gauge.with.dots.needle.67percent", android: "Icons.Outlined.Info") }
                Label { Text("方舟") } icon: { symbol("shield", android: "Icons.Outlined.Star") }
            """.components(separatedBy: "\n")
        let icons = Self.tabIcons(dec49e0)
        XCTAssertEqual(icons["方舟"], "symbol(\"shield\", android: \"Icons.Outlined.Star\") }")
        XCTAssertFalse(icons["方舟"]!.hasPrefix(Self.expected["方舟"]!))
        XCTAssertFalse(icons["状态"]!.hasPrefix(Self.expected["状态"]!))
    }
}
