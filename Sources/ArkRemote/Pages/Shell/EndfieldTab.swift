import SwiftUI

/// The 终末地 tab: EndfieldPage fed from snap.master["MaaEnd"]; edits wait in 「待保存」 and go out as set_master
/// after one review (view.js #go, 2402-2440). The 库存 row is a NavigationLink inside EndfieldPage.
struct EndfieldTab: View {
    static let game = "MaaEnd"

    var body: some View {
        let relay = Relay.shared
        EndfieldPage(data: Self.pageData(), live: Self.pageData, onChange: { path, v in
            // read at the change, not captured from this body: the 更多设置 page's rows get this closure through a
            // navigationDestination, which skip-ui keeps from its first registration (Navigation.swift:869-872), so a
            // captured machine value was the App's first one there. Decoded once per snapshot (EWMaster.live, EWLastGood).
            let master = EWMaster.live(Self.game)
            let machine = ewEffectiveMaster(master, lastGood: EWLastGood.load(Self.game)).0
            let label = ewLabel(EndfieldSchema.groups, machine ?? master, path)
            // view.js:1254 base(): a change back to the sent-but-unconfirmed value drops the edit, not only one back to the machine's
            let base = ewBase(game: Self.game, path: path, machine: machine?.values[path])
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v, machine: base)
            ewPutEdit(k, e)   // a row changed again keeps its place in the review order
        }, onResend: { k in Task { await Pending.shared.resend(k) } })
        .modifier(EWSaveBar(title: "游戏机遥控"))   // view.js:1283 one title for every page
        // a pull asks the machine to report again and waits for it (view.js:1151 pullRefresh → live.js ping), as the 状态
        // tab does (StatusTab.swift:23); the state it adopts is then checked against what was sent
        .refreshable {
            await Live.shared.ping()
            sync()
        }
        .task { await load() }
        .onChange(of: relay.snapAt) { _, _ in sync() }
    }

    /// The page's data from the live snap and the unsaved changes. Also read by the 「更多设置」 pages as they draw: on
    /// Android a pushed page keeps the data it was pushed with, so its 「待保存」 / 「已寄出」 lines would not appear.
    static func pageData() -> EndfieldPageData {
        let master = EWMaster.live(game)
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
        ewSyncLive(game: Self.game, master: EWMaster.live(Self.game))
    }
}
