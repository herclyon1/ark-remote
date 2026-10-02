import SwiftUI

/// The 状态 tab: StatusPage fed from Relay / Live / StaminaStore / Pending; buttons send what the web page's
/// buttons send (maa-automation/web/view.js wire(): #runnow, #refresh, #estop, #echofarm, #echofarmuntil,
/// #echofarmstop); [data-relay] switch flips wait in 「待保存」 like the web page's edits. The mapping and the confirm /
/// send code live in Pages/Status/.
struct StatusTab: View {
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""
    @AppStorage("ark-remote-estop") var estopAt = 0
    @State var ask: StatusAsk? = nil
    /// Switch flips not yet sent (view.js `edits`); 保存 in the toolbar sends them after one review.
    @State var edits: [String: EWEdit] = [:]

    var body: some View {
        let relay = Relay.shared
        var data = StatusData.from(relay: relay, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                                   currentQueue: storedQueue, estopAt: estopAt)
        let _ = StatusCommands.applyEdits(edits, to: &data)
        StatusPage(data: data, actions: StatusCommands.actions(data, ask: $ask, storedQueue: $storedQueue, edits: $edits))
            .refreshable { await Live.shared.ping() }
            .task {
                // first open: newest state from the mailbox, and the stamina numbers
                if let s = try? await relay.latestState() {
                    relay.adopt(s)
                    Pending.shared.reconcile()
                }
                _ = await StaminaStore.shared.refresh()
            }
            .alert(ask?.title ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
                if let a = ask {
                    Button(a.ok, role: a.destructive ? .destructive : nil) {
                        if a.isEstop { estopAt = nowSec() }
                        Task { await StatusCommands.send(a) }
                    }
                    Button("取消", role: .cancel) {}
                }
            } message: {
                Text(ask?.message ?? "")
            }
            .modifier(EWSaveBar(edits: $edits))   // 「保存（N）」 / 「放弃」 and the toast, shared with the 终末地 / 鸣潮 tabs
    }
}
