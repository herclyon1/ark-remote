import XCTest

/// Regression 0108 #23. Defect guarded: an Android branch draws its own shape where a system component exists, so the
/// Android build looks and behaves unlike the platform's own controls. A shape drawn only for Android (under
/// `#if os(Android)`, or in the `#else` of `#if !os(Android)…`) must be in the list below with the reason the system
/// component cannot be used (a skip-ui / skip-fuse source showing it is missing). Any other one fails until it is
/// added with its reason. The native lint (remote-ref/tools/ark-native-lint.py) has no Android rules and is outside
/// this repo, so the rule lives here and runs with every `swift test`.
final class AndroidDrawnShapeTests: XCTestCase {
    static let shape = try! NSRegularExpression(
        pattern: #"\b(?:Circle|Rectangle|RoundedRectangle|UnevenRoundedRectangle|Capsule|Ellipse|Path|Canvas)\s*[({]|\.(?:clipShape|stroke|cornerRadius)\("#)

    /// The Android-only shapes that are allowed: (file, trimmed line, why the system component cannot be used).
    static let allowed: [(file: String, line: String, reason: String)] = [
        ("Sources/ArkRemote/Pages/Status/StatusPage.swift",
         "Circle().fill(data.dotOn ? Color.green : Color.secondary).frame(width: dotSide, height: dotSide)",
         "desktopcomputer is missing from skip-ui's Material table (Components/Image.swift composeSymbolName)"),
    ]

    /// "line code" of every Android-only shape in `lines` (file `path`) that is not in `allowed`.
    static func unlisted(_ lines: [String], path: String) -> [String] {
        zip(lines.indices, RepoFiles.platforms(lines)).compactMap { i, p in
            let c = RepoFiles.code(lines[i]).trimmingCharacters(in: .whitespaces)
            guard p == .android, !c.hasPrefix("#"),
                  shape.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) != nil,
                  !allowed.contains(where: { $0.file == path && $0.line == c }) else { return nil }
            return "\(i + 1) \(c)"
        }
    }

    func testAndroidShapesAreListedWithAReason() throws {
        var hits: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() { hits += Self.unlisted(lines, path: path).map { "\(path):\($0)" } }
        XCTAssertEqual(hits, [], "an Android branch draws a shape that is not in AndroidDrawnShapeTests.allowed with its reason")
        XCTAssertTrue(Self.allowed.allSatisfy { !$0.reason.isEmpty })
    }

    func testTheScanSeesAnUnlistedShape() {
        let drawn = ["#if os(Android)", "Circle().fill(Color.green).frame(width: 10, height: 10)", "#else",
                     "Image(systemName: \"desktopcomputer\")", "#endif"]
        XCTAssertEqual(Self.unlisted(drawn, path: "x.swift"), ["2 Circle().fill(Color.green).frame(width: 10, height: 10)"])
        // a source comment next to it is not enough any more: only the list allows it
        let commented = ["#if os(Android)", "// not in skip-ui's Material table (Components/Image.swift)", "Circle().fill(.green)", "#endif"]
        XCTAssertEqual(Self.unlisted(commented, path: "x.swift"), ["3 Circle().fill(.green)"])
        // the listed line in its own file passes, the same line elsewhere does not
        let listed = ["    #if os(Android)", "    " + Self.allowed[0].line, "    #endif"]
        XCTAssertEqual(Self.unlisted(listed, path: Self.allowed[0].file), [])
        XCTAssertEqual(Self.unlisted(listed, path: "x.swift").count, 1)
        // Apple-only shapes are not this check's business
        XCTAssertEqual(Self.unlisted(["#if !os(Android)", "Circle()", "#endif", "@State var p = NavigationPath()"], path: "x.swift"), [])
    }

    /// The `#else` of `#if !os(Android)` (and of `#if !os(Android) && canImport(UIKit)`) is the Android branch.
    func testTheElseOfNotAndroidIsAndroid() {
        XCTAssertEqual(Self.unlisted(["#if !os(Android)", "Image(systemName: \"x\")", "#else", "Capsule().fill(.red)", "#endif"],
                                     path: "x.swift"), ["4 Capsule().fill(.red)"])
        XCTAssertEqual(Self.unlisted(["#if !os(Android) && canImport(UIKit)", "Text(\"x\")", "#else", "  RoundedRectangle(cornerRadius: 4)",
                                      "#endif"], path: "x.swift"), ["4 RoundedRectangle(cornerRadius: 4)"])
        XCTAssertEqual(RepoFiles.platforms(["#if os(Android)", "a", "#else", "b", "#endif", "c"]),
                       [.android, .android, .apple, .apple, .either, .either])
    }
}
