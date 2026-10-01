import SwiftUI

/// The 鸣潮 tab: WuwaPage fed from snap.master["OK-WW"] and snap.relay (无音区截图, 周常); config edits go out as
/// set_master, the 无音区结算截图 switch as its RELAY_SWITCHES body, 周本打第几个 as weekly_boss (view.js #go, 2402-2440).
struct WuwaTab: View {
    static let game = "OK-WW"
    static let tacetKey = "relay|tacet_shots"
    static let bossKey = "wb|OK-WW|第几个周本"

    @State var edits: [String: EWEdit] = [:]

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
        // the switch shows unsaved → sent → reported, like the config rows
        let sentTacet = Pending.shared.items[Self.tacetKey].flatMap { $0.mismatchAt == nil ? $0.to.bool : nil }
        let data = WuwaPageData(master: ewShown(master, game: Self.game, edits: edits),
                                lastGoodMaster: lastGood.map { ewShown($0, game: Self.game, edits: edits) },
                                tacetShots: edits[Self.tacetKey]?.to.bool ?? sentTacet ?? bits.tacetShots,
                                parkDone: bits.parkDone, weeklyBossDone: bits.bossDone,
                                weeklyBossIndex: Int(edits[Self.bossKey]?.to.number ?? Double(bits.bossIndex)))
        WuwaPage(data: data, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel([WuwaSchema.group], machine ?? master, path)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v, machine: machine?.values[path])
            edits[k] = e
        }, onRelaySwitch: { id, on in
            // RELAY_SWITCHES tacet_shots (schema.js:254-256); a flip back to the machine's state drops the edit (view.js:1009)
            guard id == Self.tacetKey else { return }
            edits[id] = on == bits.tacetShots ? nil
                : EWEdit(label: "无音区结算截图", src: "relay", from: .bool(bits.tacetShots), to: .bool(on),
                         body: .object(["action": .string("tacet_shots"), "on": .bool(on)]))
        }, onWeeklyBossIndex: { n in
            edits[Self.bossKey] = n == bits.bossIndex ? nil
                : EWEdit(label: "周本打第几个", src: "wb", from: .int(bits.bossIndex), to: .int(n))
        })
        .navigationTitle("鸣潮")
        .modifier(EWSaveBar(edits: $edits))
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: relay.snapAt) { _, _ in sync() }
    }

    private func load() async {
        if let s = try? await Relay.shared.latestState() { _ = Relay.shared.adopt(s) }
        sync()
    }

    private func sync() {
        let relay = Relay.shared
        EWLastGood.save(snap: relay.snap, game: Self.game)
        ewSyncLive(game: Self.game, master: EWMaster.from(snap: relay.snap, game: Self.game),
                   extra: [Self.tacetKey: .bool(RelayBits(relay.snap).tacetShots)])
    }
}
