import XCTest
@testable import ArkRemote

/// app-opt-round7-1108 (Gemini's dispatch, paired with the relay's relay-opt-round6-1108 R6-04).
///
/// R7-01: the send time is taken before the POST at every send, as Net.send stamps the envelope's ts, and a state of
/// the send's own second answers it (Pending.reconcile `<`): taken after the reply, a fast machine's state of second T
/// read as older than a sentAt of T + 1 and was skipped.
/// R7-02: a receipt is this change's when its "target" (modes.py add_receipt, phone_channel.receipt_target) is this
/// change's setting, and its "ts" (to the second) is not before the send; an older relay's receipt without them counts
/// by action and minute, as before.
/// R7-03: 森空岛's session is saved again when the machine hands over another role under the same cred; 库街区's
/// waveplates are timed on ntfy's clock (Relay.serverNowMs), as every other age in the app.
@MainActor final class ReceiptMatchTests: XCTestCase {
    private var saved: SharedStateGuard!
    private var skew: Double = 0
    private var stored: [(String, Any?)] = []

    override func setUp() async throws {
        saved = SharedStateGuard()
        skew = Relay.shared.clockSkewMs
        stored = [Pending.pendingKey, Pending.ackedKey].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        Relay.shared.clockSkewMs = 0
    }

    override func tearDown() async throws {
        saved.restore()
        Relay.shared.clockSkewMs = skew
        for (k, v) in stored {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private func receipt(_ action: String, ts: Int?, target: String?, queued: Bool = false,
                         sent: String = "") -> JSONValue {
        var o: [String: JSONValue] = ["action": .string(action), "ok": .bool(true), "text": .string("好"),
                                      "at": .string(sent)]
        if !sent.isEmpty { o["sent"] = .string(sent) }
        if let ts { o["ts"] = .int(ts) }
        if let target { o["target"] = .string(target) }
        if queued { o["queued"] = .bool(true) }
        return .object(o)
    }

    private func state(at: Int, receipts: [JSONValue]) -> JSONValue {
        .object(["at": .int(at), "relay": .object(["最近指令": .array(receipts)])])
    }

    private func master(_ path: String, sentAt: Int) -> PendingEdit {
        PendingEdit(label: path, src: "master", owner: "终末地", path: path, from: .string("a"), to: .string("b"),
                    sentAt: sentAt)
    }

    // MARK: R7-01

    /// Every `relay.send(` takes its time before the call: no `nowSec()` in the lines that follow it.
    func testSendTimeTakenBeforeThePost() throws {
        for (path, lines) in try RepoFiles.swiftSources() {
            for (i, line) in lines.enumerated() where line.contains("try await relay.send(") {
                let after = lines[(i + 1)..<min(lines.count, i + 9)].prefix { !$0.contains("} catch") }
                XCTAssertFalse(after.contains { $0.contains("nowSec()") }, "\(path):\(i + 1): the send time is read after the POST")
                let before = lines[max(0, i - 3)..<i]
                if path.hasSuffix("Edits.swift") || path.hasSuffix("StatusCommands.swift") || path.hasSuffix("Pending.swift") {
                    XCTAssertTrue(before.contains { $0.contains("nowSec()") }, "\(path):\(i + 1): no send time taken before the POST")
                }
            }
        }
    }

    /// The machine answered within the send's own second: that state clears the change.
    func testStateOfTheSendSecondCounts() {
        let now = nowSec()
        let p = Pending(relay: .shared)
        p.items = ["k": master("AutoEssence/AutoEssenceMenu", sentAt: now)]
        p.liveVals = ["k": .string("b")]
        Relay.shared.snap = state(at: now, receipts: [])
        p.reconcile()
        XCTAssertNil(p.items["k"], "a state stamped in the send's own second is the answer")
        p.items = ["k": master("AutoEssence/AutoEssenceMenu", sentAt: now)]
        Relay.shared.snap = state(at: now - 1, receipts: [])
        p.reconcile()
        XCTAssertNotNil(p.items["k"], "a state from before the send is not")
    }

    // MARK: R7-02

    /// Two settings of one action saved in one second: each receipt answers only its own setting.
    func testReceiptMatchesItsOwnTarget() {
        let now = nowSec()
        let p = Pending(relay: .shared)
        Relay.shared.snap = state(at: now + 1, receipts: [
            receipt("set_master", ts: now, target: "终末地:AutoEssence/AutoEssenceMenu"),
        ])
        XCTAssertTrue(p.machineActed(on: master("AutoEssence/AutoEssenceMenu", sentAt: now)))
        XCTAssertFalse(p.machineActed(on: master("AutoEssence/AutoEssenceObtainMode", sentAt: now)),
                       "another setting's receipt is not this one's")
        // An older relay's receipt (no target, no ts): by action and minute, as before.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = machineZone
        f.dateFormat = "MM-dd HH:mm"
        let minute = f.string(from: Date(timeIntervalSince1970: Double(now)))
        Relay.shared.snap = state(at: now + 1, receipts: [receipt("set_master", ts: nil, target: nil, sent: minute)])
        XCTAssertTrue(p.machineActed(on: master("AutoEssence/AutoEssenceObtainMode", sentAt: now)))
    }

    /// A receipt with "ts" counts to the second: one from before the send (an earlier press of the same setting, the
    /// same minute) does not.
    func testReceiptTsCountsToTheSecond() {
        let now = nowSec()
        let p = Pending(relay: .shared)
        let edit = master("AutoEssence/AutoEssenceMenu", sentAt: now)
        Relay.shared.snap = state(at: now, receipts: [receipt("set_master", ts: now - 30,
                                                              target: "终末地:AutoEssence/AutoEssenceMenu")])
        XCTAssertFalse(p.machineActed(on: edit), "30 s before the send is an earlier press")
        Relay.shared.snap = state(at: now, receipts: [receipt("set_master", ts: now - 1,
                                                              target: "终末地:AutoEssence/AutoEssenceMenu")])
        XCTAssertTrue(p.machineActed(on: edit), "within the 2 s the whole seconds may differ by")
    }

    /// 排队中 ends with the final receipt of the same send (ts and target), not with another setting's.
    func testQueuedEndsWithItsOwnFinalReceipt() {
        let now = nowSec()
        let p = Pending(relay: .shared)
        let edit = master("AutoEssence/AutoEssenceMenu", sentAt: now)
        let q = receipt("set_master", ts: now, target: "终末地:AutoEssence/AutoEssenceMenu", queued: true)
        Relay.shared.snap = state(at: now, receipts: [q, receipt("set_master", ts: now, target: "终末地:Other/Path")])
        XCTAssertTrue(p.isQueued(edit), "another setting's final receipt does not end this one's queue")
        Relay.shared.snap = state(at: now, receipts: [q, receipt("set_master", ts: now,
                                                                 target: "终末地:AutoEssence/AutoEssenceMenu")])
        XCTAssertFalse(p.isQueued(edit))
    }

    func testTargetOfEachKind() {
        XCTAssertEqual(Pending.target(of: master("A/B", sentAt: 0)), "终末地:A/B")
        XCTAssertEqual(Pending.target(of: PendingEdit(label: "方舟", src: "mas", owner: "MAA", path: "Stage.Stage",
                                                      to: .string("1-7"), sentAt: 0)), "MAA:Stage.Stage")
        XCTAssertEqual(Pending.target(of: PendingEdit(label: "晚班", src: "relay", to: .bool(false), sentAt: 0,
                                                      body: .object(["action": .string("skip_today"),
                                                                     "queue": .string("晚班")]))), "晚班")
        XCTAssertEqual(Pending.target(of: PendingEdit(label: "周本", src: "wb", to: .int(1), sentAt: 0)), "")
    }

    // MARK: R7-03

    /// The same cred with another role: saved; with the same role, or none handed over: not.
    func testSessionSavedWhenTheRoleChanges() {
        let s = StaminaStore.shared
        s.saveTokens(.object(["sk": .object(["cred": .string("C"), "uid": .string("1"), "efRole": .string("R1"),
                                             "efServer": .string("1")])]))
        func snap(_ sk: [String: JSONValue]) -> JSONValue { .object(["密钥": .object(["sk": .object(sk)])]) }
        XCTAssertFalse(s.fromSnapshot(snap(["cred": .string("C"), "uid": .string("1"), "efRole": .string("R1")])))
        XCTAssertFalse(s.fromSnapshot(snap(["cred": .string("C")])), "nothing new handed over")
        XCTAssertTrue(s.fromSnapshot(snap(["cred": .string("C"), "uid": .string("1"), "efRole": .string("R2"),
                                           "efServer": .string("1")])), "another 终末地 role")
        XCTAssertEqual(s.tokens?["sk"]?["efRole"]?.string, "R2")
        XCTAssertTrue(s.fromSnapshot(snap(["cred": .string("C"), "uid": .string("2"), "efRole": .string("R2"),
                                           "efServer": .string("1")])), "another account")
    }

    /// 库街区's full-time stamp is read against ntfy's clock: a phone an hour slow does not show waveplates an hour short.
    func testWaveplatesOnNtfysClock() async throws {
        let s = StaminaStore.shared
        Relay.shared.clockSkewMs = 3_600_000                       // the phone is an hour behind ntfy
        let server = Relay.shared.serverNowMs() / 1000
        let widget: JSONValue = .object([
            "success": .bool(true), "code": .int(200),
            "data": .object([
                "serverTime": .double(server - 60),
                "energyData": .object(["cur": .int(200), "total": .int(240),
                                       "refreshTimeStamp": .double(server + 3600)]),   // full in an hour: 10 short
            ]),
        ])
        s.fetch = { _, _, _, _, _ in (widget.encoded(), 200) }
        let w = await s.kuro(.object(["token": .string("t"), "did": .string("d"), "roleId": .string("1"),
                                      "serverId": .string("s")]))
        XCTAssertEqual(w.waveplates, 230, "240 less the 10 an hour from full; on the phone's clock it read 220")
    }
}
