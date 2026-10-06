import SwiftUI

/// The 鸣潮 tab: WuwaPage fed from snap.master["OK-WW"] and snap.relay (无音区截图, 周常). A change applies when it is made,
/// as a switch in Settings does (验收 10-07): it goes out at once as a one-item send through EWSave.send — a config row as
/// set_master, the 无音区结算截图 switch as its RELAY_SWITCHES body, 周本打第几个 as weekly_boss (view.js #go, 2402-2440) —
/// and Pending then shows it sent and checks the receipt. No 「待保存」 pool, no review sheet.
struct WuwaTab: View {
    static let game = "OK-WW"
    static let tacetKey = WuwaPage.tacetKey
    static let bossKey = WuwaPage.bossKey

    /// Changes being sent (EWSave.send running), by Pending key: drawn over the machine's values until Pending holds them,
    /// and their row is disabled meanwhile, so one row never has two sends out.
    @State var sending: [String: EWEdit] = [:]

    /// snap.relay, the weekly block and the switch as the web page reads them (view.js:303, 514-517; schema.js:254).
    private struct RelayBits {
        var tacetShots = false
        var parkDone = false
        var bossDone = false
        var bossIndex = 1

        init(_ snap: JSONValue?) {
            let relay = snap?["relay"] ?? .object([:])
            let weekly = relay["周常"] ?? .object([:])
            let wb = weekly["周本"] ?? relay["周本"] ?? .object([:])
            tacetShots = relay["无音区截图"]?.truthy ?? false
            parkDone = weekly["周常乐园"]?["本周已完成"]?.truthy ?? false
            bossDone = wb["本周已打"]?.truthy ?? false
            let n = Int(wb["第几个周本"]?.number ?? 1)
            bossIndex = n == 0 ? 1 : n
        }
    }

    var body: some View {
        let relay = Relay.shared
        // decoded once per snapshot, not per body (EWMaster.live, EWLastGood): every switch to this tab runs the body afresh
        let master = EWMaster.live(Self.game)
        let lastGood = EWLastGood.load(Self.game)
        let bits = RelayBits(relay.snap)
        // the switch shows sent → reported, like the config rows; the sent value stays on the switch also when the machine
        // answered differently (pending.js applyPending writes p.to back whatever mismatchAt says; ArknightsBridge shownValue)
        let tacetBase = Pending.shared.shownValue(for: Self.tacetKey)?.bool ?? bits.tacetShots
        let bossBase = safeInt(Pending.shared.items[Self.bossKey]?.to.number) ?? bits.bossIndex
        let data = WuwaPageData(master: ewShown(master, game: Self.game, edits: sending),
                                lastGoodMaster: lastGood.map { ewShown($0, game: Self.game, edits: sending) },
                                tacetShots: sending[Self.tacetKey]?.to.bool ?? tacetBase,
                                parkDone: bits.parkDone, weeklyBossDone: bits.bossDone,
                                weeklyBossIndex: safeInt(sending[Self.bossKey]?.to.number) ?? bossBase,
                                status: status(master), busy: Set(sending.keys.map(Self.rowKey)))
        WuwaPage(data: data, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel([WuwaSchema.group], machine ?? master, path)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v,
                                           machine: Self.base(path: path, machine: machine?.values[path]))
            if let e { send(k, e) }   // nil: back to what the row showed before, nothing to send (view.js:1251-1258)
        }, onRelaySwitch: { id, on in
            // RELAY_SWITCHES tacet_shots (schema.js:260-262)
            guard id == Self.tacetKey, on != tacetBase else { return }
            send(id, EWEdit(label: "无音区结算截图", src: "relay", from: .bool(tacetBase), to: .bool(on),
                            body: .object(["action": .string("tacet_shots"), "on": .bool(on)])))
        }, onWeeklyBossIndex: { n in
            guard n != bossBase else { return }
            send(Self.bossKey, EWEdit(label: "周本 · 打第几个", src: "wb", from: .int(bossBase), to: .int(n)))   // view.js:1336-1339
        }, onResend: { k in Task { await Pending.shared.resend(k) } })
        .navigationTitle("鸣潮")
        // a pull asks the machine to report again and waits for it, up to 11 s (view.js:1150 pullRefresh → live.js ping, the
        // 状态 tab's Live.ping); the state it adopts comes back through onChange(of: snapAt) below
        .refreshable {
            await Live.shared.ping()
            sync()
        }
        .task { await load() }
        .onChange(of: relay.snapAt) { _, _ in sync() }
    }

    /// A Pending key as the page keys its rows: a config row by its path, the switch and 周本 by their own keys.
    private static func rowKey(_ key: String) -> String {
        let prefix = "master|\(game)|"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
    }

    /// One change, sent alone. A value the relay would refuse is not sent (EWSave.problem); a failure puts the row back to
    /// its value before and says why (an alert, as Pending.resend does for 「发不出去」).
    private func send(_ key: String, _ e: EWEdit) {
        if let why = EWSave.problem(e) {
            Relay.shared.showAlert("没发出去", "「\(e.label)」\(why)")
            return
        }
        sending[key] = e
        Task {
            let r = await EWSave.send([key: e])
            sending[key] = nil
            if let failure = r.failure {
                Relay.shared.showAlert("没发出去", gameSendFailure(e.label, failure))
            }
        }
    }

    /// The line under each row: 「正在寄出」 while sending, else the receipt (pending.js:47-67). A sent 周本 change is kept
    /// in Pending like the switches (view.js:2992-2997) and checked against the machine's 第几个周本 (view.js:576).
    private func status(_ master: EWMaster) -> [String: GameRowStatus] {
        var out: [String: GameRowStatus] = [:]
        func put(_ row: String, _ t: EWRowTag?) {
            guard let t, let text = t.text else { return }
            out[row] = GameRowStatus(text: text, bad: t.bad, resendKey: t.resendKey)
        }
        for (path, t) in ewTags(game: Self.game, master: master, edits: [:]) { put(path, t) }
        put(Self.tacetKey, ewTag(Self.tacetKey, edits: [:]))
        put(Self.bossKey, ewTag(Self.bossKey, edits: [:]))
        for k in sending.keys { out[Self.rowKey(k)] = .sendingNow }
        return out
    }

    /// view.js:1286 base(): a config row's value before this change is the sent-but-unconfirmed one while it is on its way,
    /// else the machine's. A sent partial dict (boxes) goes on top of the machine's, as ewShown draws it.
    @MainActor private static func base(path: String, machine: EWValue?) -> EWValue? {
        guard let sent = Pending.shared.items["master|\(Self.game)|\(path)"]?.to.ewValue else { return machine }
        if case .boxes(let part) = sent {
            return .boxes((machine?.boxValues ?? [:]).merging(part) { _, b in b })
        }
        return sent
    }

    private func load() async {
        if let s = try? await Relay.shared.latestState() { _ = Relay.shared.adopt(s) }
        sync()
    }

    private func sync() {
        let relay = Relay.shared
        EWLastGood.save(snap: relay.snap, game: Self.game)
        var extra: [String: JSONValue] = [Self.tacetKey: .bool(RelayBits(relay.snap).tacetShots)]
        // view.js:576: the machine's 第几个周本, for the receipt check of a sent 周本 change (only when the relay reports it)
        let r = relay.snap?["relay"]
        if let n = safeInt((r?["周常"]?["周本"] ?? r?["周本"])?["第几个周本"]?.number) { extra[Self.bossKey] = .int(n) }
        ewSyncLive(game: Self.game, master: EWMaster.live(Self.game), extra: extra)
    }
}
