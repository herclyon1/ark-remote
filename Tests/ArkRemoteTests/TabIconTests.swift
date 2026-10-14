import XCTest

/// Regression 0108 #1: the tab bar's icons. Defect guarded: the three game tabs lose their coloured character icons,
/// either because the call no longer names a tab-* imageset (dec49e0, 10-07, swapped them for system symbols such as
/// `shield` / Icons.Outlined.Star) or because the imageset becomes a one-colour template; or a tab goes missing from
/// the five. 状态 and 手机 use SF Symbols (HIG Tab bars: "Consider using SF Symbols to provide familiar, scalable tab
/// bar icons"); which symbol is a free choice, so the check names none.
final class TabIconTests: XCTestCase {
    static let expected = [
        "状态": "tabSymbol(",
        "手机": "tabSymbol(",
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

    /// Whether tabSymbol's body draws the SF Symbol in its non-Android branch.
    static func symbolOnApple(_ lines: [String]) -> Bool {
        guard let body = RepoFiles.body(after: "private func tabSymbol(", in: lines) else { return false }
        return RepoFiles.contains("Image(systemName:", on: .apple, in: body)
    }

    func testTabIcons() throws {
        let content = try RepoFiles.lines("Sources/ArkRemote/ContentView.swift")
        let icons = Self.tabIcons(content)
        XCTAssertEqual(Set(icons.keys), Set(Self.expected.keys), "the five tabs' labels")
        for (tab, want) in Self.expected {
            XCTAssertTrue(icons[tab]?.hasPrefix(want) == true, "\(tab): \(icons[tab] ?? "none"), want \(want)…")
        }
        // These imagesets are full-colour character art; drawn as a template they become a one-colour silhouette with
        // nothing readable in it. Colour versus monochrome tab icons is owner decision G7 (the HIG prefers monochrome
        // tab bars when the content is colourful). If the artwork is replaced by monochrome glyphs, remove this
        // assertion with it.
        for game in ["tab-arknights", "tab-endfield", "tab-wuwa"] {
            let contents = try RepoFiles.text("Sources/ArkRemote/Resources/Module.xcassets/\(game).imageset/Contents.json")
            XCTAssertTrue(contents.contains("\"template-rendering-intent\": \"original\""),
                          "\(game) is not drawn in its own colours")
        }
        // tabSymbol is the live SF Symbol on iOS (the exported image only on Android, which has no such Material icon)
        XCTAssertTrue(Self.symbolOnApple(content), "tabSymbol does not draw the SF Symbol on iOS")
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

    /// The symbol must sit in the non-Android branch: in the Android one, or commented out, it does not count.
    func testTheScanSeesTheSymbolBranch() {
        let fn = ["private func tabSymbol(_ symbol: String, else asset: String) -> some View {", "    #if os(Android)"]
        XCTAssertTrue(Self.symbolOnApple(fn + ["    tabIcon(asset)", "    #else", "      Image(systemName: symbol)", "    #endif", "}"]))
        XCTAssertFalse(Self.symbolOnApple(fn + ["    Image(systemName: symbol)", "    #else", "    tabIcon(asset)", "    #endif", "}"]))
        XCTAssertFalse(Self.symbolOnApple(fn + ["    tabIcon(asset)", "    #else", "    // Image(systemName: symbol)", "    tabIcon(asset)",
                                                "    #endif", "}"]))
    }
}
