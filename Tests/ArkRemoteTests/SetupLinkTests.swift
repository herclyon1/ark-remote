import XCTest
@testable import ArkRemote

/// The user could not get in: he always used the 免输入链接, and the setup screen did not take it. SetupScreen.takeLink
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
        PhoneLink.readClipboard = { PhoneLink.pageURL + "#k=" + PhoneLink.enc(#"{"t":"box1","p":"4321"}"#) }

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
}
