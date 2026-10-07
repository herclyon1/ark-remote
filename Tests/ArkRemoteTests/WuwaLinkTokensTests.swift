import XCTest
@testable import ArkRemote

/// 鸣潮波片 disappeared. A 免输入链接 with `&t=` replaces the stored game tokens (StaminaStore.fromLink); PhoneLink.open
/// then takes the machine's 森空岛 session back from the state already here (fromSnapshot), so neither game is lost.
/// A copied link is taken on the next open even when the phone is already set up (PhoneLink.takeClipboardLink).
@MainActor final class WuwaLinkTokensTests: XCTestCase {
    static let kPart = PhoneLink.enc(#"{"t":"t","p":"1"}"#)
    static let tPart = PhoneLink.enc(#"{"kuro":{"token":"x","did":"y"}}"#)
    /// Built the way PhoneLink.make() builds it.
    static let fullLink = PhoneLink.pageURL + "#k=" + kPart + "&t=" + tPart
    static let snap: JSONValue = .object([
        "at": .int(nowSec()),
        "密钥": .object(["sk": .object(["cred": .string("CRED-MACHINE"), "dId": .string("d1")])]),
    ])

    /// Set up as the phone is once it has a mailbox and the machine's state: same topic / PIN as the link.
    @discardableResult
    private func prepare() -> CallCount {
        let calls = SharedStateGuard.stubStaminaOffline()
        Relay.shared.config = RelayConfig(topic: "t", pin: "1")
        Relay.shared.snap = Self.snap
        StaminaStore.shared.saveTokens(.object(["sk": .object(["cred": .string("CRED-OLD")])]))
        UserDefaults.standard.removeObject(forKey: PhoneLink.takenKey)
        return calls
    }

    func testOpenedLinkKeepsBothGames() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let calls = prepare()

        let took = PhoneLink.open(try XCTUnwrap(URL(string: Self.fullLink)))
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertTrue(took)
        let t = StaminaStore.shared.tokens
        XCTAssertEqual(t?["kuro"]?["token"]?.string, "x")
        XCTAssertEqual(t?["sk"]?["cred"]?.string, "CRED-MACHINE")
        XCTAssertEqual(StaminaStore.shared.status(), "森空岛、库街区")
        XCTAssertEqual(Relay.shared.config, RelayConfig(topic: "t", pin: "1"))
        // the read open() starts ran, against the stub, and was over before the state is put back
        XCTAssertGreaterThan(calls.value, 0)
    }

    /// Already set up, the link copied: the next open takes it (keys updated), and the same link only once.
    func testCopiedLinkUpdatesKeysWhenAlreadySetUp() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        prepare()
        PhoneLink.readClipboard = { Self.fullLink }

        PhoneLink.takeClipboardLink()
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(StaminaStore.shared.tokens?["kuro"]?["token"]?.string, "x")
        XCTAssertEqual(StaminaStore.shared.tokens?["sk"]?["cred"]?.string, "CRED-MACHINE")

        // the same link on the clipboard at the next open is not taken again
        let sentinel: JSONValue = .object(["kuro": .object(["token": .string("later")])])
        StaminaStore.shared.saveTokens(sentinel)
        PhoneLink.takeClipboardLink()
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(StaminaStore.shared.tokens, sentinel)
    }

    /// The cause: a link sent without the 库街区 key (`#k=` only) carries no tokens, so nothing changes.
    func testLinkWithoutTokensChangesNoKeys() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        prepare()
        let before = StaminaStore.shared.tokens
        let url = try XCTUnwrap(URL(string: PhoneLink.pageURL + "#k=" + Self.kPart))

        XCTAssertFalse(StaminaStore.shared.fromLink(url))
        PhoneLink.open(url)
        try await SharedStateGuard.settleStaminaRefresh()
        XCTAssertEqual(StaminaStore.shared.tokens, before)
        XCTAssertNil(StaminaStore.shared.tokens?["kuro"])
    }
}
