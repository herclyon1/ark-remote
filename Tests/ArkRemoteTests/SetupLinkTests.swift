import XCTest
@testable import ArkRemote

/// Defect guarded: the setup screen ignores the 免输入链接 on the clipboard, so a phone with no settings cannot get in
/// without typing the mailbox and PIN; or its footnote sends him to the retired web page or a bookmark. SetupScreen.takeLink
/// (f5d9e59) takes a `#k=` link from the clipboard through PhoneLink.open, which fills the mailbox and PIN.
/// The .onAppear / .onOpenURL wiring that calls it is view code and is not covered here.
@MainActor final class SetupLinkTests: XCTestCase {
    private func notSetUp() {
        SharedStateGuard.stubStaminaOffline()
        Relay.shared.config = nil
        UserDefaults.standard.removeObject(forKey: Relay.cfgKey)
        StaminaStore.shared.tokens = nil
        UserDefaults.standard.removeObject(forKey: StaminaStore.tokensKey)
        UserDefaults.standard.removeObject(forKey: PhoneLink.takenKey)
    }

    func testClipboardLinkFillsMailboxAndPin() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        notSetUp()
        PhoneLink.readClipboard = { PhoneLink.oldPageURL + "#k=" + PhoneLink.enc(#"{"t":"box1","p":"4321"}"#) }

        let took = SetupScreen.takeLink()
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertTrue(took)
        XCTAssertEqual(Relay.shared.config?.topic, "box1")
        XCTAssertEqual(Relay.shared.config?.pin, "4321")
    }

    func testOtherClipboardTextIsLeftAlone() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        notSetUp()
        PhoneLink.readClipboard = { "hello" }

        XCTAssertFalse(SetupScreen.takeLink())
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertNil(Relay.shared.config)
    }

    /// The App's own link (复制免输入链接 on 手机, arkremote://link#k=…) is taken as well as an old web-page one.
    func testClipboardAppLinkFillsMailboxAndPin() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        notSetUp()
        PhoneLink.readClipboard = { PhoneLink.linkBase + "#k=" + PhoneLink.enc(#"{"t":"box2","p":"8765"}"#) }

        let took = SetupScreen.takeLink()
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertTrue(took)
        XCTAssertEqual(Relay.shared.config?.topic, "box2")
        XCTAssertEqual(Relay.shared.config?.pin, "8765")
    }

    /// Shot 26: the footer under 粘贴免输入链接 pointed at the retired web page (「在网页「手机」页或书签里…」). It must send
    /// him to where the link is made now: the 手机 tab, where 复制免输入链接 is; not to the web page or a bookmark.
    func testLinkFooterNamesTheAppNotTheWebPage() {
        let foot = SetupScreen.linkFootNote
        XCTAssertFalse(foot.contains("网页"), foot)
        XCTAssertFalse(foot.contains("书签"), foot)
        XCTAssertTrue(foot.contains("手机"), foot)
    }
}
