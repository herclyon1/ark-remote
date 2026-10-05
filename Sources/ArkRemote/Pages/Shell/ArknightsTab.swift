import SwiftUI

/// The 方舟 tab: ArknightsPage filled from the relay snapshot (Relay.shared.snap).
/// A change waits in the page's one pool of unsaved changes (Logic/Edits.swift, view.js `edits`) with the other tabs'
/// ones; the shared edit bar (EWSaveBar: ✕ / 「待保存 N 项」 / ✓, view.js:1551-1555) reviews them in 「确认这次修改」 and
/// sends them all in one go (view.js doSave 1609, #go 2954), set_config / set_master each; one that could not be sent stays.
struct ArknightsTab: View {
    /// The shift picked on the 状态 tab (view.js curQueue, localStorage "ark-remote-cfg-queue").
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""

    private var bridge: ArknightsBridge {
        ArknightsBridge(snap: Relay.shared.snap, queue: storedQueue, lastGoodMaster: ArknightsBridge.lastGoodMaster(),
                        lastGoodConfig: ArknightsBridge.lastGoodConfig())
    }

    /// This tab's entries in the pool, by the web's id (`${src}|MAA|${path}`).
    private var mine: [String: EWEdit] {
        var out: [String: EWEdit] = [:]
        for f in ArknightsField.allCases {
            if let id = f.ref?.id, let e = EWEdits.shared.items[id] { out[id] = e }
        }
        return out
    }

    /// The machine's values with the sent-but-unconfirmed ones on top (view.js render; pending.js applyPending).
    private func base(_ b: ArknightsBridge) -> ArknightsPageData {
        b.pageData(withPending: true, editing: Set(mine.keys))
    }

    /// What the page shows: `base` with the unsaved changes on top (view.js applyEdits after every render). Kept as the
    /// page typed it (a number box holds 「012」 until the next render, like the web's <input>); its difference from
    /// `base` is written into the pool on every change.
    @State var shown = ArknightsPageData()

    /// The difference between `base` and what the page shows, as pool entries (view.js note(): back to the old value = no entry).
    private func changes(_ page: ArknightsPageData) -> [String: EWEdit] {
        let b = bridge
        var out: [String: EWEdit] = [:]
        for e in b.edits(from: base(b), to: page) { out[e.ref.id] = e.poolEdit }
        return out
    }

    var body: some View {
        let edited = Set(ArknightsField.allCases.compactMap { f -> String? in
            guard let id = f.ref?.id, mine[id] != nil else { return nil }
            return f.path
        })
        ArknightsPage(data: $shown, onResend: { key in
            Task {
                await Pending.shared.resend(key)
                refresh()
            }
        }, edited: edited)
            .modifier(EWSaveBar(title: "游戏机遥控"))   // view.js:1554: one title for every page, 「待保存 N 项」 while editing
            .task { await reload() }
            // Pull to refresh asks the machine to report again (view.js:1150 → live.js:21 ping: {action:"refresh"}, up to 11 s),
            // as the 状态 tab does (StatusTab.swift:23); the state it adopts redraws through onChange(of: snapAt).
            .refreshable {
                await Live.shared.ping()
                refresh()
            }
            // a change on the page goes into the pool (view.js note → edits[id])
            .onChange(of: shown) {
                let next = changes(shown)
                for f in ArknightsField.allCases {
                    guard let id = f.ref?.id else { continue }
                    if EWEdits.shared.items[id] != next[id] { ewPutEdit(id, next[id]) }   // a row changed again keeps its place
                }
            }
            // the pool changed from elsewhere — ✕ on any tab, or ✓ sent them (view.js:2950 / 3003 then render()): redraw
            .onChange(of: mine) {
                if changes(shown) != mine { redraw() }
            }
            .onChange(of: Relay.shared.snapAt) {
                refresh()
            }
            // the sent changes changed outside this tab — 「不等了，清掉」 on the bar (pending.js:85 `pending = {}; savePending();
            // render();`): redraw now, so the rows' 「已寄出」 line, green ground and sent value go at once, not with the next state
            .onChange(of: Pending.shared.items) {
                redraw()
            }
            // view.js:945-949: a new shift re-renders; the unsaved changes stay in the pool.
            .onChange(of: storedQueue) {
                refresh()
            }
    }

    /// `base` with the pool's changes on top (view.js: `const keep = { ...edits }; render(); edits = keep`).
    private func redraw() {
        var page = base(bridge)
        let pool = mine
        for f in ArknightsField.allCases {
            if let id = f.ref?.id, let e = pool[id] { f.apply(e.to, to: &page) }
        }
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
        Pending.shared.liveVals.merge(bridge.liveVals) { _, new in new }
        Pending.shared.reconcile()
        redraw()
    }
}
