import SwiftUI

/// The 终末地 tab: EndfieldPage fed from snap.master["MaaEnd"]; edits wait in 「待保存」 and go out as set_master
/// after one review (view.js #go, 2402-2440). The 库存 row opens the stockpile page.
struct EndfieldTab: View {
    static let game = "MaaEnd"

    /// The unsaved changes of every tab (Logic/Edits.swift); this tab reads and writes its own keys.
    private var edits: [String: EWEdit] { EWEdits.shared.items }
    @State var showStockpile = false

    var body: some View {
        let relay = Relay.shared
        let master = EWMaster.from(snap: relay.snap, game: Self.game)
        let lastGood = EWLastGood.load(Self.game)
        let data = EndfieldPageData(master: ewShown(master, game: Self.game, edits: edits),
                                    lastGoodMaster: lastGood.map { ewShown($0, game: Self.game, edits: edits) },
                                    tags: ewTags(game: Self.game, master: master, edits: edits))
        EndfieldPage(data: data, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel(EndfieldSchema.groups, machine ?? master, path)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v, machine: machine?.values[path])
            EWEdits.shared.items[k] = e
        }, onOpenStockpile: { showStockpile = true },
           onResend: { k in Task { await Pending.shared.resend(k) } })
        .navigationDestination(isPresented: $showStockpile) { EndfieldStockpilePage() }
        .modifier(EWSaveBar(title: "游戏机遥控"))   // view.js:1283 one title for every page
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
        ewSyncLive(game: Self.game, master: EWMaster.from(snap: relay.snap, game: Self.game))
    }
}
