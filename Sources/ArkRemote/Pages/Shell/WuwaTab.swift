import SwiftUI

/// The 鸣潮 tab: WuwaPage fed from snap.master["OK-WW"] and snap.relay (无音区截图, 周常); config edits go out as
/// set_master, the 无音区结算截图 switch as its RELAY_SWITCHES body, 周本打第几个 as weekly_boss (view.js #go, 2402-2440).
struct WuwaTab: View {
    static let game = "OK-WW"
    static let tacetKey = "relay|tacet_shots"
    static let bossKey = "wb|OK-WW|第几个周本"

    /// The unsaved changes of every tab (Logic/Edits.swift); this tab reads and writes its own keys.
    private var edits: [String: EWEdit] { EWEdits.shared.items }

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
        let master = EWMaster.from(snap: relay.snap, game: Self.game)
        let lastGood = EWLastGood.load(Self.game)
        let bits = RelayBits(relay.snap)
        // the switch shows unsaved → sent → reported, like the config rows; the sent value stays on the switch also when the
        // machine answered differently (pending.js applyPending writes p.to back whatever mismatchAt says; ArknightsBridge shownValue)
        let sentTacet = Pending.shared.shownValue(for: Self.tacetKey)?.bool
        // 「拨回原样就撤销」 compares with what the control showed before this change: the sent-but-unconfirmed value while it is
        // on its way, else the machine's (view.js:1286 base(), used at :1254 for the switch and :1336 / :1347 for 周本 and config rows)
        let tacetBase = sentTacet ?? bits.tacetShots
        let bossBase = Pending.shared.items[Self.bossKey]?.to.number.map { Int($0) } ?? bits.bossIndex
        let data = WuwaPageData(master: ewShown(master, game: Self.game, edits: edits),
                                lastGoodMaster: lastGood.map { ewShown($0, game: Self.game, edits: edits) },
                                tacetShots: edits[Self.tacetKey]?.to.bool ?? sentTacet ?? bits.tacetShots,
                                parkDone: bits.parkDone, weeklyBossDone: bits.bossDone,
                                weeklyBossIndex: Int(edits[Self.bossKey]?.to.number ?? Double(bossBase)),
                                tags: tags(master))
        WuwaPage(data: data, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel([WuwaSchema.group], machine ?? master, path)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v,
                                           machine: Self.base(path: path, machine: machine?.values[path]))
            ewPutEdit(k, e)   // a row changed again keeps its place in the review order
        }, onRelaySwitch: { id, on in
            // RELAY_SWITCHES tacet_shots (schema.js:260-262); a flip back to what it showed before drops the edit (view.js:1251-1258)
            guard id == Self.tacetKey else { return }
            ewPutEdit(id, on == tacetBase ? nil
                : EWEdit(label: "无音区结算截图", src: "relay", from: .bool(tacetBase), to: .bool(on),
                         body: .object(["action": .string("tacet_shots"), "on": .bool(on)])))
        }, onWeeklyBossIndex: { n in
            ewPutEdit(Self.bossKey, n == bossBase ? nil
                : EWEdit(label: "周本 · 打第几个", src: "wb", from: .int(bossBase), to: .int(n)))   // view.js:1336-1339
        }, onResend: { k in Task { await Pending.shared.resend(k) } })
        .modifier(EWSaveBar(title: "游戏机遥控"))   // view.js:1283 one title for every page
        // a pull asks the machine to report again and waits for it, up to 11 s (view.js:1150 pullRefresh → live.js ping, the
        // 状态 tab's Live.ping); the state it adopts comes back through onChange(of: snapAt) below
        .refreshable {
            await Live.shared.ping()
            sync()
        }
        .task { await load() }
        .onChange(of: relay.snapAt) { _, _ in sync() }
    }

    /// Config rows, the 无音区截图 switch, and 周本: a sent 周本 change is kept in Pending like the switches (view.js:2992-2997)
    /// and checked against the machine's 第几个周本 (view.js:576), so its row gets the same receipt lines.
    private func tags(_ master: EWMaster) -> [String: EWRowTag] {
        var out = ewTags(game: Self.game, master: master, edits: edits)
        out[Self.tacetKey] = ewTag(Self.tacetKey, edits: edits)
        out[Self.bossKey] = ewTag(Self.bossKey, edits: edits)
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
        if let n = (r?["周常"]?["周本"] ?? r?["周本"])?["第几个周本"]?.number { extra[Self.bossKey] = .int(Int(n)) }
        ewSyncLive(game: Self.game, master: EWMaster.from(snap: relay.snap, game: Self.game), extra: extra)
    }
}
