import SwiftUI

/// The 终末地 tab: EndfieldPage fed from snap.master["MaaEnd"]. A change applies as it is made, as Settings does: a
/// switch or a choice goes out at once, a number or text when it is submitted, each as its own set_master (EWSave.apply).
/// The 库存 row is a NavigationLink inside EndfieldPage.
struct EndfieldTab: View {
    static let game = "MaaEnd"

    var body: some View {
        EndfieldPage(data: Self.pageData(), live: Self.pageData, onChange: { path, v in
            // read at the change, not captured from this body: the 更多设置 page's rows get this closure through a
            // navigationDestination, which skip-ui keeps from its first registration (Navigation.swift:869-872), so a
            // captured machine value was the App's first one there. Decoded once per snapshot (EWMaster.live, EWLastGood).
            let master = EWMaster.live(Self.game)
            let machine = ewEffectiveMaster(master, lastGood: EWLastGood.load(Self.game)).0
            let label = ewLabel(EndfieldSchema.groups, machine ?? master, path)
            let key = "master|\(Self.game)|\(path)"
            // view.js:1254 base(): the value the row showed before this change. While this row's order is out, that is the
            // value being sent: a change back to the machine's value then is a change of its own and goes after it.
            let sending = EWSave.isSending(key) ? EWEdits.shared.items[key]?.to.ewValue : nil
            let base = sending ?? ewBase(game: Self.game, path: path, machine: machine?.values[path])
            let (k, e) = EWSave.masterEdit(game: Self.game, path: path, label: label, to: v, machine: base)
            // the same value as the order out now: nothing new to send, and that order stays
            if e == nil && sending != nil { return }
            EWSave.apply(k, e)
        }, onResend: { k in EWSave.resend(k) })
        .navigationTitle("终末地")
        // a pull asks the machine to report again and waits for it (view.js:1151 pullRefresh → live.js ping), as the 状态
        // tab does (StatusTab.swift:23); the state it adopts is then checked against what was sent
        .refreshable {
            await Live.shared.ping()
            sync()
        }
        .task { await load() }
        .onChange(of: Relay.shared.snapAt) { _, _ in sync() }
    }

    /// The page's data from the live snap and the changes still going out. Also read by the 「更多设置」 pages as they draw:
    /// on Android a pushed page keeps the data it was pushed with, so its 「正在寄出」 / 「已寄出」 lines would not appear.
    static func pageData() -> EndfieldPageData {
        let master = EWMaster.live(game)
        let edits = EWEdits.shared.items   // the changes of every tab not yet sent (Logic/Edits.swift); this tab's own keys
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
