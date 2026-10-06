import SwiftUI

/// The 方舟 tab: ArknightsPage filled from the relay snapshot (Relay.shared.snap). A change applies when it is made, as a
/// switch in Settings does (验收 10-07): it goes out at once as a one-item send through EWSave.send (set_config for the
/// 「明日方舟」 rows, set_master for 基建 and 奖励, view.js #go 2964-2966), and Pending then shows it sent and checks the
/// receipt. No 「待保存」 pool, no review sheet.
struct ArknightsTab: View {
    /// The shift picked on the 状态 tab (view.js curQueue, localStorage "ark-remote-cfg-queue").
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""
    /// The selected tab (ContentView): 「换班次」 switches to 状态.
    @AppStorage("tab") var tab = ContentTab.status

    private var bridge: ArknightsBridge {
        ArknightsBridge(snap: Relay.shared.snap, queue: storedQueue, lastGoodMaster: ArknightsBridge.lastGoodMaster(),
                        lastGoodConfig: ArknightsBridge.lastGoodConfig())
    }

    /// The machine's values with the sent-but-unconfirmed ones on top (view.js render; pending.js applyPending).
    private func base(_ b: ArknightsBridge) -> ArknightsPageData {
        b.pageData(withPending: true)
    }

    /// What the page shows: `base` with the changes on their way and the refused ones on top. The page writes a change
    /// into it; `apply` sends it.
    @State var shown = ArknightsPageData()
    /// Changes being sent (EWSave.send running), by field id: drawn over `base` until Pending holds them, and their row
    /// is disabled meanwhile, so one row never has two sends out.
    @State var sending: [String: ArknightsEdit] = [:]
    /// Typed values the relay would refuse (EWSave.problem: a stage code off its pattern, 理智药 outside 0–999, an empty
    /// number), by field id: kept in the row with the reason under it, not sent.
    @State var refused: [String: ArknightsRefused] = [:]

    var body: some View {
        ArknightsPage(data: $shown, status: status, busy: Set(sending.values.map { $0.field.path }), onResend: { key in
            Task {
                await Pending.shared.resend(key)
                refresh()
            }
        }, onShowStatus: { tab = .status })
            .navigationTitle("方舟")
            .task { await reload() }
            // Pull to refresh asks the machine to report again (view.js:1150 → live.js:21 ping: {action:"refresh"}, up to 11 s),
            // as the 状态 tab does (StatusTab.swift:23); the state it adopts redraws through onChange(of: snapAt).
            .refreshable {
                await Live.shared.ping()
                refresh()
            }
            .onChange(of: shown) { old, new in
                apply(from: old, to: new)
            }
            .onChange(of: Relay.shared.snapAt) {
                refresh()
            }
            // the sent changes changed — one went out, a receipt came, or 「不再等待」 (PendingBarView): redraw now
            .onChange(of: Pending.shared.items) {
                redraw()
            }
            // view.js:945-949: a new shift re-renders.
            .onChange(of: storedQueue) {
                refresh()
            }
    }

    /// The line under each row: the receipt (pending.js:47-67), else 「正在寄出」 or why a value was not sent.
    private var status: [String: GameRowStatus] {
        var out: [String: GameRowStatus] = [:]
        for (path, t) in shown.tags { out[path] = GameRowStatus(text: t.text, bad: t.bad, resendKey: t.resendKey) }
        for e in sending.values { out[e.field.path] = .sendingNow }
        for r in refused.values { out[r.edit.field.path] = GameRowStatus(text: r.why, bad: true) }
        return out
    }

    /// A step of `shown`: the fields that moved in it and now differ from `base` are changes made on the page (a redraw
    /// moves fields to `base` plus what is already sending or refused, which is no new change). Each goes out on its own.
    private func apply(from old: ArknightsPageData, to new: ArknightsPageData) {
        let b = bridge
        let moved = Set(b.edits(from: old, to: new).map { $0.ref.id })
        guard !moved.isEmpty else { return }
        let wanted = b.edits(from: base(b), to: new)
        for id in moved where sending[id] == nil {
            // back to what the row showed before (view.js note(): no change)
            guard let e = wanted.first(where: { $0.ref.id == id }) else { refused[id] = nil; continue }
            if refused[id]?.edit == e { continue }
            if let why = EWSave.problem(e.poolEdit) {
                refused[id] = ArknightsRefused(edit: e, why: why)
                continue
            }
            refused[id] = nil
            send(e)
        }
    }

    /// One change, sent alone. A failure puts the row back to its value before and says why (an alert, as Pending.resend
    /// does for 「发不出去」).
    private func send(_ e: ArknightsEdit) {
        let id = e.ref.id
        sending[id] = e
        Task {
            let r = await EWSave.send([id: e.poolEdit])
            sending[id] = nil
            if let failure = r.failure {
                Relay.shared.showAlert("没发出去", gameSendFailure(e.label, failure))
            }
            redraw()
        }
    }

    /// `base` with the changes on their way and the refused ones on top.
    private func redraw() {
        var page = base(bridge)
        for e in sending.values { e.field.apply(e.to, to: &page) }
        for r in refused.values { r.edit.field.apply(r.edit.to, to: &page) }
        shown = page
    }

    private func reload() async {
        refresh()
        if let s = try? await Relay.shared.latestState() {
            Relay.shared.adopt(s)
        }
        refresh()
    }

    /// The web's render: keep the last readable copies, feed Pending's receipt check, draw.
    private func refresh() {
        // view.js:423-426: keep the last readable master copy for the next time it can't be read.
        EWLastGood.save(snap: Relay.shared.snap, game: "MAA")
        // view.js:323-328: and the last readable AUTO-MAS config.
        ArknightsBridge.saveConfig(snap: Relay.shared.snap)
        // The web's render fills liveVals for every field on the page, then reconciles the sent changes.
        let b = bridge
        Pending.shared.liveVals.merge(b.liveVals) { _, new in new }
        for id in b.staleIDs { Pending.shared.liveVals[id] = nil }   // a copy, not a read: no receipt check against it
        Pending.shared.reconcile()
        redraw()
    }
}

/// A typed value that is not sent, and why (EWSave.problem).
struct ArknightsRefused: Equatable {
    var edit: ArknightsEdit
    var why: String
}
