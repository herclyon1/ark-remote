import SwiftUI

/// The 方舟 tab: ArknightsPage filled from the relay snapshot (Relay.shared.snap). A change applies when it is made, as a
/// switch in Settings does (验收 10-07): it goes out at once through EWSave.apply, the one way out every tab's changes take
/// (one order at a time; set_config for the 「明日方舟」 rows, set_master for 基建 and 奖励, view.js #go 2964-2966), and
/// Pending then shows it sent and checks the receipt. A change that did not go out — the network, or a value the relay
/// would refuse (EWSave.problem) — stays on its row with the reason under it (再发一次 / 不改了). No review sheet.
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

    /// What the page shows: `base` with this tab's changes in the pool (EWEdits: on their way, or not gone out) on top.
    /// The page writes a change into it; `apply` hands it to EWSave.apply.
    @State var shown = ArknightsPageData()

    var body: some View {
        ArknightsPage(data: $shown, status: status, busy: busy, onResend: { key in EWSave.resend(key) },
                      onShowStatus: { tab = .status })
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
            // a change went out, failed, or was dropped (EWSave.apply's drain, EWSave.drop): redraw now
            .onChange(of: EWEdits.shared.items) {
                redraw()
            }
            // view.js:945-949: a new shift re-renders.
            .onChange(of: storedQueue) {
                refresh()
            }
    }

    /// The field of a pool / Pending key of this tab (ArknightsFieldRef.id, view.js:455), nil for another tab's key.
    private static func field(_ key: String) -> ArknightsField? {
        ArknightsField.allCases.first { $0.ref?.id == key }
    }

    /// This tab's changes in the pool, by field.
    private var pooled: [(key: String, field: ArknightsField, edit: EWEdit)] {
        EWEdits.shared.items.compactMap { k, e in Self.field(k).map { (k, $0, e) } }
    }

    /// The line under each row: 「正在寄出」 while its change is out, a change that did not go out with the reason, else
    /// the receipt (pending.js:47-67).
    private var status: [String: GameRowStatus] {
        var out: [String: GameRowStatus] = [:]
        for (path, t) in shown.tags { out[path] = GameRowStatus(text: t.text, bad: t.bad, resendKey: t.resendKey) }
        let q = EWSendQueue.shared
        for p in pooled {
            if let failure = p.edit.failure {
                out[p.field.path] = GameRowStatus(text: failure, bad: true, retryKey: p.key)
            } else if q.queued.contains(p.key) {
                out[p.field.path] = .sendingNow
            }
        }
        for k in q.resending { if let f = Self.field(k) { out[f.path] = .sendingNow } }
        return out
    }

    /// Rows whose change is queued or out (not one that failed), and rows whose 再发一次 is out: disabled until it is
    /// through, so one row never has two orders out.
    private var busy: Set<String> {
        let q = EWSendQueue.shared
        var out = Set(pooled.filter { $0.edit.failure == nil && q.queued.contains($0.key) }.map { $0.field.path })
        for k in q.resending { if let f = Self.field(k) { out.insert(f.path) } }
        return out
    }

    /// A step of `shown`: the fields that moved in it and now differ from `base` are changes made on the page (a redraw
    /// moves fields to `base` plus what the pool holds, which is no new change). Each goes to EWSave.apply on its own.
    private func apply(from old: ArknightsPageData, to new: ArknightsPageData) {
        let b = bridge
        let moved = Set(b.edits(from: old, to: new).map { $0.ref.id })
        guard !moved.isEmpty else { return }
        let wanted = b.edits(from: base(b), to: new)
        let pool = EWEdits.shared.items
        // a row whose order is out is disabled (busy); a nil for it would drop the change being sent from the pool
        for id in moved where !EWSave.isSending(id) {
            guard let e = wanted.first(where: { $0.ref.id == id }) else {
                // back to what the row showed before (view.js note(): no change): a queued or failed change of it goes
                if pool[id] != nil { EWSave.apply(id, nil) }
                continue
            }
            if let p = pool[id], p.to == e.to, p.failure == nil { continue }   // already on its way
            EWSave.apply(id, e.poolEdit)
        }
    }

    /// `base` with this tab's changes in the pool on top.
    private func redraw() {
        var page = base(bridge)
        for p in pooled { p.field.apply(p.edit.to, to: &page) }
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
