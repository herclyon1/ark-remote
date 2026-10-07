import SwiftUI

/// The 鸣潮 tab: WuwaPage fed from snap.master["OK-WW"] and snap.relay (无音区截图, 周常). A change applies when it is made,
/// as a switch in Settings does (验收 10-07): it goes out at once through EWSave.apply, the one way out every tab's
/// changes take (one order at a time) — a config row as set_master, the 无音区结算截图 switch as its RELAY_SWITCHES body,
/// 周本打第几个 as weekly_boss (view.js #go, 2402-2440) — and Pending then shows it sent and checks the receipt. A change
/// that did not go out stays on its row with the reason under it (再发一次 / 不改了). No review sheet.
struct WuwaTab: View {
    static let game = "OK-WW"
    static let tacetKey = WuwaPage.tacetKey
    static let bossKey = WuwaPage.bossKey

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
        // the changes on their way or that did not go out (EWEdits; ewShown takes this game's keys from it): drawn over the
        // machine's and the sent values
        let pool = EWEdits.shared.items
        let data = WuwaPageData(master: ewShown(master, game: Self.game, edits: pool),
                                lastGoodMaster: lastGood.map { ewShown($0, game: Self.game, edits: pool) },
                                tacetShots: pool[Self.tacetKey]?.to.bool ?? tacetBase,
                                parkDone: bits.parkDone, weeklyBossDone: bits.bossDone,
                                weeklyBossIndex: safeInt(pool[Self.bossKey]?.to.number) ?? bossBase,
                                status: status(master, pool: pool), busy: Self.busy(pool))
        WuwaPage(data: data, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel([WuwaSchema.group], machine ?? master, path)
            // view.js:1254 base(): what the row showed before this change; nil edit = back to it (view.js:1251-1258)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v,
                                           machine: Self.base(path: path, machine: machine?.values[path]))
            Self.apply(k, e)
        }, onRelaySwitch: { id, on in
            // RELAY_SWITCHES tacet_shots (schema.js:260-262)
            guard id == Self.tacetKey else { return }
            Self.apply(id, on == tacetBase ? nil
                       : EWEdit(label: "无音区结算截图", src: "relay", from: .bool(tacetBase), to: .bool(on),
                                body: .object(["action": .string("tacet_shots"), "on": .bool(on)])))
        }, onWeeklyBossIndex: { n in
            Self.apply(Self.bossKey, n == bossBase ? nil
                       : EWEdit(label: "周本 · 打第几个", src: "wb", from: .int(bossBase), to: .int(n)))   // view.js:1336-1339
        }, onResend: { k in EWSave.resend(k) })
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

    /// One change, applied now (EWSave.apply: queued behind any order out, sent alone). nil drops a queued or failed
    /// change of the row (back to what it showed). A value the relay would refuse (EWSave.problem) is not sent: the drain
    /// leaves it on the row with the reason. While this row's own order is out it is disabled (busy), and a nil then would
    /// drop the change being sent from the pool: not done.
    @MainActor private static func apply(_ key: String, _ e: EWEdit?) {
        if e == nil && (EWSave.isSending(key) || EWEdits.shared.items[key] == nil) { return }
        EWSave.apply(key, e)
    }

    /// Rows whose change is queued or out (not one that failed): disabled until it is through, so one row never has two
    /// orders out.
    @MainActor private static func busy(_ pool: [String: EWEdit]) -> Set<String> {
        let q = EWSendQueue.shared
        var out = Set<String>()
        for (k, e) in pool where e.failure == nil && q.queued.contains(k) && isOurs(k) { out.insert(rowKey(k)) }
        for k in q.resending where isOurs(k) { out.insert(rowKey(k)) }
        return out
    }

    /// A pool / Pending key of this tab.
    private static func isOurs(_ key: String) -> Bool {
        key.hasPrefix("master|\(game)|") || key == tacetKey || key == bossKey
    }

    /// The line under each row: 「正在寄出」 while sending, a change that did not go out with the reason, else the receipt
    /// (pending.js:47-67). A sent 周本 change is kept in Pending like the switches (view.js:2992-2997) and checked against
    /// the machine's 第几个周本 (view.js:576).
    private func status(_ master: EWMaster, pool: [String: EWEdit]) -> [String: GameRowStatus] {
        var out: [String: GameRowStatus] = [:]
        let prefix = "master|\(Self.game)|"
        for (path, t) in ewTags(game: Self.game, master: master, edits: pool) {
            if let s = GameRowStatus.from(t, key: prefix + path) { out[path] = s }
        }
        for k in [Self.tacetKey, Self.bossKey] {
            if let s = GameRowStatus.from(ewTag(k, edits: pool), key: k) { out[k] = s }
        }
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
