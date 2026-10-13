import XCTest
@testable import ArkRemote

/// Regression 0108 #30: 10-07 23:47–23:55 on the home ring sample (b33d784, never merged): 「去掉圆环。是谁说的？谁的
/// 主意？」, 「正常开机不该上色，只有不正常才上色。这是苹果说的吗？这谁说的？」, 「黑环抢眼。苹果自己的配色方案是什么？」.
/// This base (0.4.4, design rule 1) draws no ring; the stamina tiles are Health-style cards. What carries over is the
/// colour of the machine's state, which he did not want taken away for a machine that is on: the 状态 device card's
/// icon is the system green while the machine is on and grey otherwise (Batteries-widget green, never black), on both
/// platforms, and «on» is the state line's own verdict.
@MainActor final class MachineColourTests: XCTestCase {
    static let colour = "data.dotOn ? Color.green : Color.secondary"

    /// How many of the device icon's branches colour it green-when-on / grey-otherwise.
    static func colouredBranches(_ lines: [String]) -> Int {
        guard let icon = RepoFiles.body(after: "private var deviceIcon: some View", in: lines) else { return 0 }
        return icon.filter { $0.contains(colour) }.count
    }

    func testDeviceIconIsGreenWhileOn() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        XCTAssertEqual(Self.colouredBranches(lines), 2, "the Android dot and the iOS symbol: green while on, grey otherwise")
    }

    func testOnIsTheStateLinesVerdict() {
        let guardState = SharedStateGuard()
        defer { guardState.restore() }
        let r = Relay.shared
        for (text, state, on) in [("实时 · 开机中", "on", true), ("关机 · 20 分钟前", "off", false), ("正在确认是否在线…", "", false)] {
            (r.statusText, r.statusState) = (text, state)
            let d = StatusData.from(relay: r, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                                    currentQueue: "", estopAt: 0)
            XCTAssertEqual(d.dotOn, on, text)
        }
    }

    func testTheScanSeesAnUncolouredIcon() {
        let grey = ["    @ViewBuilder private var deviceIcon: some View {", "        Image(systemName: \"desktopcomputer\")",
                    "            .foregroundStyle(Color.secondary)", "    }"]
        XCTAssertEqual(Self.colouredBranches(grey), 0)
    }
}
