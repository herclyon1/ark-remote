import XCTest
@testable import ArkRemote

/// Regression 0108 #30. Defect guarded: the machine's on / off state is not visible on 状态's device card, or 「on」
/// disagrees with the state line. The state is carried by the card's text (data.deviceStatus under the name; the icon
/// is accessibilityHidden), as HIG Color asks: "Avoid relying solely on color to differentiate between objects,
/// indicate interactivity, or communicate essential information." The icon is a second cue and must still differ
/// between on and off on each platform; which colours it uses is a design choice, so the check names none.
@MainActor final class MachineColourTests: XCTestCase {
    /// The platforms on which deviceIcon's body does not depend on data.dotOn (drawn the same whether on or off).
    static func iconIgnoresState(_ lines: [String]) -> [RepoFiles.Platform] {
        guard let icon = RepoFiles.body(after: "private var deviceIcon: some View", in: lines) else { return [.android, .apple] }
        let ps = RepoFiles.platforms(icon)
        return [RepoFiles.Platform.android, .apple].filter { p in
            !zip(icon, ps).contains { line, q in (q == p || q == .either) && line.contains("data.dotOn") }
        }
    }

    /// Whether deviceCard's label draws data.deviceStatus as text.
    static func cardSaysState(_ lines: [String]) -> Bool {
        guard let card = RepoFiles.body(after: "private var deviceCard: some View", in: lines) else { return false }
        return card.contains { $0.contains("Text(") && $0.contains("data.deviceStatus") }
    }

    func testTheCardShowsTheState() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        XCTAssertEqual(Self.iconIgnoresState(lines), [], "the device icon looks the same whether the machine is on or off")
        XCTAssertTrue(Self.cardSaysState(lines), "the device card no longer says the machine's state in words")
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

    func testTheScanSeesAnIconThatIgnoresTheState() {
        let head = ["    @ViewBuilder private var deviceIcon: some View {"]
        let grey = head + ["        Image(systemName: \"desktopcomputer\")", "            .foregroundStyle(Color.secondary)", "    }"]
        XCTAssertEqual(Self.iconIgnoresState(grey), [.android, .apple])
        let lit = head + ["        Image(systemName: \"desktopcomputer\").foregroundStyle(data.dotOn ? .orange : .gray)", "    }"]
        XCTAssertEqual(Self.iconIgnoresState(lit), [])
        let iosOnly = head + ["        #if os(Android)", "        Circle().fill(Color.secondary)", "        #else",
                              "        Image(systemName: \"desktopcomputer\").symbolVariant(data.dotOn ? .fill : .none)", "        #endif", "    }"]
        XCTAssertEqual(Self.iconIgnoresState(iosOnly), [.android])
        XCTAssertFalse(Self.cardSaysState(["    private var deviceCard: some View {", "        Label { Text(data.deviceName) } icon: { }", "    }"]))
    }
}
