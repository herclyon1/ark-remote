import XCTest

/// Regression 0108 #10: 10-02 21:08 「app切换页面的时候那个淡入淡出动画未结束就滑动的时候就会滑动失败」. skip-ui's TabView
/// cross-fades tabs for 700 ms on Android and a swipe during the fade is lost; 4e62ea6 turns the fade off
/// (skip-ui README "tabViewTransitions": NavDisplayTransitionOptions(.none)), as Apple's tab bar switches at once.
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
