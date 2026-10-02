import SwiftUI

/// The 方舟 tab: ArknightsPage filled from the relay snapshot (Relay.shared.snap).
/// Changes stay on the page as edits until 保存 sends them, one command each, like the web's
/// save bar (view.js:2402-2459); an edit that could not be sent stays on the page.
struct ArknightsTab: View {
    /// What the page shows: the machine's values, sent changes on top, unsaved edits on top of that.
    @State var shown = ArknightsPageData()
    /// The same without the unsaved edits; the difference is what 保存 sends.
    @State var base = ArknightsPageData()
    @State var saving = false
    /// The 「确认这次修改」 box is up (view.js doSave, view.js:1328-1336).
    @State var reviewing = false
    /// The shift picked on the 状态 tab (view.js curQueue, localStorage "ark-remote-cfg-queue").
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""

    private var bridge: ArknightsBridge {
        ArknightsBridge(snap: Relay.shared.snap, queue: storedQueue, lastGoodMaster: ArknightsBridge.lastGoodMaster(),
                        lastGoodConfig: ArknightsBridge.lastGoodConfig())
    }
    private var edits: [ArknightsEdit] { bridge.edits(from: base, to: shown) }

    var body: some View {
        ArknightsPage(data: $shown, onResend: { key in
            Task {
                await Pending.shared.resend(key)
                refresh()
            }
        }, edited: Set(edits.map { $0.field.path }))
            .toolbar {
                if !edits.isEmpty {
                    Button("放弃") { shown = base }
                        .disabled(saving)
                    Button("保存（\(edits.count)）") { reviewing = true }
                        .disabled(saving)
                }
            }
            // index.html:849-857, view.js:1331-1335: each change as 「名字 旧值 → 新值」 before anything is sent.
            .alert("确认这次修改", isPresented: $reviewing) {
                Button("再想想", role: .cancel) {}
                Button("确认修改") { Task { await save() } }
            } message: {
                Text(verbatim: edits.map {
                    "\($0.label)\n\(Pending.shared.valueLabel($0.pending, $0.from)) → \(Pending.shared.valueLabel($0.pending, $0.to))"
                }.joined(separator: "\n\n"))
            }
            .task { await reload() }
            // Pull to refresh, as the other tabs have: one read of the latest state.
            .refreshable { await reload() }
            .onChange(of: Relay.shared.snapAt) {
                refresh()
            }
            // view.js:945-949: a new shift re-renders and keeps the unsaved edits.
            .onChange(of: storedQueue) {
                refresh()
            }
    }

    private func reload() async {
        refresh()
        if let s = try? await Relay.shared.latestState() {
            Relay.shared.adopt(s)
        }
        refresh()
    }

    /// Re-reads the snapshot and keeps the unsaved edits on top (view.js: `const keep = { ...edits }; render(); edits = keep`).
    private func refresh() {
        let kept = edits
        // view.js:423-426: keep the last readable master copy for the next time it can't be read.
        EWLastGood.save(snap: Relay.shared.snap, game: "MAA")
        // view.js:312-314: and the last readable AUTO-MAS config.
        ArknightsBridge.saveConfig(snap: Relay.shared.snap)
        let b = bridge
        // The web's render fills liveVals for every field on the page, then reconciles the sent changes.
        Pending.shared.liveVals.merge(b.liveVals) { _, new in new }
        Pending.shared.reconcile()
        let next = b.pageData(withPending: true, editing: Set(kept.map { $0.ref.id }))
        var page = next
        for e in kept {
            e.field.apply(e.to, to: &page)
        }
        base = next
        shown = page
    }

    /// view.js:2402-2459: send each edit in turn; stop at the first failure and keep the rest.
    private func save() async {
        guard !saving else { return }
        saving = true
        var sent = 0
        var failed: Error?
        for e in edits {
            do {
                try await Relay.shared.send(e.body)
                Pending.shared.add(e.ref.id, e.pending)
                sent += 1
            } catch {
                failed = error
                break
            }
        }
        refresh()
        if let failed {
            let left = edits.count
            Relay.shared.showToast(sent > 0
                ? "发出去 \(sent) 项，剩下 \(left) 项没发出去（\(errorMessage(failed))）。没发出去的还在页面上，可以再按一次保存。"
                : "一项都没发出去（\(errorMessage(failed))）。改动还在页面上，可以再按一次保存。", ms: 7000)
        } else if sent > 0 {
            Relay.shared.showToast("\(sent) 项已寄出。机器开着几秒内生效；关着就等开机——每一项下面都标着「已寄出」，生效了才会消失。", ms: 7000)
        }
        // view.js:2455-2457: ask the machine once, 2 s later, for a state reported after the send. One request, no loop.
        if sent > 0 {
            let after = nowSec()   // view.js:2456: taken after the sends, only a state reported after this counts
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await Live.shared.ping(minAt: after)
            }
        }
        saving = false
    }
}
