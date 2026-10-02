import SwiftUI

/// The 终末地 tab: EndfieldPage fed from snap.master["MaaEnd"]; edits wait in 「待保存」 and go out as set_master
/// after one review (view.js #go, 2402-2440). The 库存 row is a NavigationLink inside EndfieldPage.
struct EndfieldTab: View {
    static let game = "MaaEnd"

    var body: some View {
        let relay = Relay.shared
        let master = EWMaster.from(snap: relay.snap, game: Self.game)
        let lastGood = EWLastGood.load(Self.game)
        EndfieldPage(data: Self.pageData(), live: Self.pageData, onChange: { path, v in
            let machine = ewEffectiveMaster(master, lastGood: lastGood).0
            let label = ewLabel(EndfieldSchema.groups, machine ?? master, path)
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v, machine: machine?.values[path])
            EWEdits.shared.items[k] = e
        }, onResend: { k in Task { await Pending.shared.resend(k) } })
        .modifier(EWSaveBar(title: "游戏机遥控"))   // view.js:1283 one title for every page
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: relay.snapAt) { _, _ in sync() }
    }

    /// The page's data from the live snap and the unsaved changes. Also read by the 「更多设置」 pages as they draw: on
    /// Android a pushed page keeps the data it was pushed with, so its 「待保存」 / 「已寄出」 lines would not appear.
    static func pageData() -> EndfieldPageData {
        let master = EWMaster.from(snap: Relay.shared.snap, game: game)
        let edits = EWEdits.shared.items   // the unsaved changes of every tab (Logic/Edits.swift); this tab's own keys
        return EndfieldPageData(master: ewShown(master, game: game, edits: edits),
                                lastGoodMaster: EWLastGood.load(game).map { ewShown($0, game: game, edits: edits) },
                                tags: ewTags(game: game, master: master, edits: edits))
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
