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

    private var bridge: ArknightsBridge { ArknightsBridge(snap: Relay.shared.snap) }
    private var edits: [ArknightsEdit] { bridge.edits(from: base, to: shown) }

    var body: some View {
        ArknightsPage(data: $shown)
            .toolbar {
                if !edits.isEmpty {
                    Button("放弃") { shown = base }
                        .disabled(saving)
                    Button("保存（\(edits.count)）") { Task { await save() } }
                        .disabled(saving)
                }
            }
            .task {
                refresh()
                if let s = try? await Relay.shared.latestState() {
                    Relay.shared.adopt(s)
                }
                refresh()
            }
            .onChange(of: Relay.shared.snapAt) {
                refresh()
            }
    }

    /// Re-reads the snapshot and keeps the unsaved edits on top (view.js: `const keep = { ...edits }; render(); edits = keep`).
    private func refresh() {
        let kept = edits
        let b = bridge
        // The web's render fills liveVals for every field on the page, then reconciles the sent changes.
        Pending.shared.liveVals.merge(b.liveVals) { _, new in new }
        Pending.shared.reconcile()
        let next = b.pageData(withPending: true)
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
            // TODO: the per-row 「已寄出 HH:MM」 tag (Pending.shared.tag(for:)) is not drawn yet, so the web's
            // second sentence about it is left out.
            Relay.shared.showToast("\(sent) 项已寄出。机器开着几秒内生效；关着就等开机。", ms: 7000)
            // TODO: the web asks the machine for a fresh state 2 s after sending (view.js:2455-2457 ping(after));
            // that belongs to the live-state logic, not this page.
        }
        saving = false
    }
}
