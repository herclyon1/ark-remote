import XCTest

/// Regression 0108 #23: 10-07 17:33 「安卓那边缺组件？安卓这么烂？…」「安卓和苹果都是顶级公司，安卓咋会缺东西呢」. An Android
/// branch had drawn its own shapes where a system component exists. The rule (the 10-08 list: "安卓分支自画形状无 Skip
/// 源码出处就报"): a shape drawn under `#if os(Android)` must say, in a comment on its line or the three lines above,
/// which Skip / Android source shows the system component is missing (skip-ui / skip-fuse file, or an Android or
/// Material page). The native lint (remote-ref/tools/ark-native-lint.py) has no Android rules and is outside this repo,
/// so the rule lives here and runs with every `swift test`.
final class AndroidDrawnShapeTests: XCTestCase {
    static let shape = try! NSRegularExpression(
        pattern: #"\b(?:Circle|Rectangle|RoundedRectangle|UnevenRoundedRectangle|Capsule|Ellipse|Path|Canvas)\s*[({]|\.(?:clipShape|stroke|cornerRadius)\("#)
    static let sources = ["skip-ui", "skip-fuse", "skipui", "SkipUI", "Components/", "developer.android.com", "material.io"]

    /// "line code" of every Android-only shape without a source in reach.
    static func unsourced(_ lines: [String]) -> [String] {
        var android: [Bool] = []
        var out: [String] = []
        for (i, raw) in lines.enumerated() {
            let c = RepoFiles.code(raw).trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("#if ") { android.append(c == "#if os(Android)"); continue }
            if c.hasPrefix("#else") || c.hasPrefix("#elseif") { if !android.isEmpty { android[android.count - 1] = false }; continue }
            if c.hasPrefix("#endif") { _ = android.popLast(); continue }
            guard android.contains(true),
                  shape.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) != nil else { continue }
            let reach = lines[max(0, i - 3)...i].joined(separator: "\n")
            if !sources.contains(where: { reach.contains($0) }) { out.append("\(i + 1) \(c)") }
        }
        return out
    }

    func testAndroidShapesNameTheirSource() throws {
        var hits: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() { hits += Self.unsourced(lines).map { "\(path):\($0)" } }
        XCTAssertEqual(hits, [], "an Android branch draws a shape with no Skip / Android source for the missing component")
    }

    func testTheScanSeesAnUnsourcedShape() {
        let drawn = ["#if os(Android)", "Circle().fill(Color.green).frame(width: 10, height: 10)", "#else",
                     "Image(systemName: \"desktopcomputer\")", "#endif"]
        XCTAssertEqual(Self.unsourced(drawn), ["2 Circle().fill(Color.green).frame(width: 10, height: 10)"])
        let sourced = ["#if os(Android)", "// not in skip-ui's Material table (Components/Image.swift)", "Circle().fill(.green)", "#endif"]
        XCTAssertEqual(Self.unsourced(sourced), [])
        XCTAssertEqual(Self.unsourced(["#if !os(Android)", "Circle()", "#endif", "@State var p = NavigationPath()"]), [])
    }
}
