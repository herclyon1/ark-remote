import XCTest

/// Regression 0108 #10. Defect guarded: on Android, skip-ui's TabView cross-fades between tabs (TabView.swift falls back
/// to NavDisplayTransitionOptions.tabViewDefaults, the NavDisplay default transition), and a swipe made during the fade
/// is lost: lost input. 4e62ea6 turns the fade off (skip-ui README "tabViewTransitions": NavDisplayTransitionOptions(.none)).
/// The check: ContentView's TabView keeps `.tabViewTransitions { _ in .init(.none) }` inside its `#if os(Android)`.
final class TabSwitchAtOnceTests: XCTestCase {
    static let line = ".tabViewTransitions { _ in .init(.none) }"

    /// Whether `line` is in the code under an `#if os(Android)` that is still open there.
    static func fadeOff(_ lines: [String]) -> Bool {
        var androidOpen: [Bool] = []
        for raw in lines {
            let c = RepoFiles.code(raw).trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("#if ") { androidOpen.append(c == "#if os(Android)") }
            else if c.hasPrefix("#else") || c.hasPrefix("#elseif") { if !androidOpen.isEmpty { androidOpen[androidOpen.count - 1] = false } }
            else if c.hasPrefix("#endif") { _ = androidOpen.popLast() }
            else if c.contains(line) { return androidOpen.last == true }
        }
        return false
    }

    func testTabsSwitchWithoutTheFade() throws {
        XCTAssertTrue(Self.fadeOff(try RepoFiles.lines("Sources/ArkRemote/ContentView.swift")),
                      "ContentView's TabView fades between tabs on Android again")
    }

    func testTheScanSeesTheFadeOn() {
        XCTAssertTrue(Self.fadeOff(["#if os(Android)", "        .tabViewTransitions { _ in .init(.none) }   // x", "#endif"]))
        XCTAssertFalse(Self.fadeOff(["#if os(Android)", "#endif", "        .onChange(of: shiftTabs) { }"]))
        XCTAssertFalse(Self.fadeOff(["        // .tabViewTransitions { _ in .init(.none) }"]))
        XCTAssertFalse(Self.fadeOff(["#if os(Android)", "#else", "        .tabViewTransitions { _ in .init(.none) }", "#endif"]))
    }
}
