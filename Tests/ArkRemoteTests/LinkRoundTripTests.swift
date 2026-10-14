import XCTest
@testable import ArkRemote

/// 复制免输入链接 copied a link to the old web page (https://herclyon1.github.io/maa/#k=…, 0.4.4 PhoneTab.swift:34).
/// It now copies the App's own form (PhoneLink.linkBase, the scheme Darwin/Info.plist and the Android manifest
/// register), and what it copies comes back as the same mailbox, PIN and game keys through every way in: an opened
/// link (.onOpenURL → PhoneLink.open) and the clipboard (SetupScreen.takeLink on 「第一次使用」). A link copied before
/// (the web page form) still works.
@MainActor final class LinkRoundTripTests: XCTestCase {
    private func setUpPhone(topic: String, pin: String) {
        SharedStateGuard.stubStaminaOffline()
        Relay.shared.saveConfig(topic: topic, pin: pin)
        StaminaStore.shared.tokens = nil
        UserDefaults.standard.removeObject(forKey: StaminaStore.tokensKey)
        UserDefaults.standard.removeObject(forKey: PhoneLink.takenKey)
    }

    /// The phone the link is taken on: nothing stored yet.
    private func freshPhone() {
        Relay.shared.config = nil
        UserDefaults.standard.removeObject(forKey: Relay.cfgKey)
        StaminaStore.shared.tokens = nil
        UserDefaults.standard.removeObject(forKey: StaminaStore.tokensKey)
        UserDefaults.standard.removeObject(forKey: PhoneLink.takenKey)
    }

    func testCopiedLinkIsTheAppsOwnForm() throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        setUpPhone(topic: "box-rt", pin: "8642")

        let link = try XCTUnwrap(PhoneLink.make())
        XCTAssertTrue(link.hasPrefix("arkremote://link#k="), link)
        XCTAssertFalse(link.contains("github.io"), link)
        XCTAssertEqual(URL(string: link)?.scheme, "arkremote")
    }

    func testOpenedLinkGivesBackTheSameMailboxPinAndKeys() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        setUpPhone(topic: "box-rt", pin: "8642")
        StaminaStore.shared.saveTokens(.object(["kuro": .object(["token": .string("TK"), "did": .string("DID")])]))
        let link = try XCTUnwrap(PhoneLink.make())
        XCTAssertTrue(link.contains("&t="), link)

        freshPhone()
        XCTAssertTrue(PhoneLink.open(try XCTUnwrap(URL(string: link))))
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(Relay.shared.config?.topic, "box-rt")
        XCTAssertEqual(Relay.shared.config?.pin, "8642")
        XCTAssertEqual(StaminaStore.shared.tokens?["kuro"]?["token"]?.string, "TK")
        XCTAssertEqual(StaminaStore.shared.tokens?["kuro"]?["did"]?.string, "DID")
    }

    func testPastedLinkGivesBackTheSameMailboxAndPin() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        setUpPhone(topic: "box-paste", pin: "0007")
        let link = try XCTUnwrap(PhoneLink.make())

        freshPhone()
        PhoneLink.readClipboard = { link }
        XCTAssertTrue(SetupScreen.takeLink())
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(Relay.shared.config?.topic, "box-paste")
        XCTAssertEqual(Relay.shared.config?.pin, "0007")
    }

    func testOldWebPageLinkStillWorks() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        freshPhone()
        SharedStateGuard.stubStaminaOffline()
        let old = PhoneLink.oldPageURL + "#k=" + PhoneLink.enc(#"{"t":"box-old","p":"1357"}"#)

        PhoneLink.readClipboard = { old }
        XCTAssertTrue(SetupScreen.takeLink())
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(Relay.shared.config?.topic, "box-old")
        XCTAssertEqual(Relay.shared.config?.pin, "1357")

        freshPhone()
        XCTAssertTrue(PhoneLink.open(try XCTUnwrap(URL(string: old))))
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(Relay.shared.config?.topic, "box-old")
        XCTAssertEqual(Relay.shared.config?.pin, "1357")
    }
}
