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
                // first open (view.js boot :2928-2946): say what the cached state is, then ask the mailbox; a failure is said
                // in words (no network ≠ machine off), and a mailbox full of states none of which match the PIN says so
                if relay.statusText.isEmpty {
                    relay.setStatus(relay.snapAt.map { "状态 \(ago($0))" } ?? "正在读取…", "")
                }
                do {
                    if let s = try await relay.latestState() {
                        relay.adopt(s)
                        Pending.shared.reconcile()
                    }
                    if relay.snap == nil && relay.pinScan.seen > 0 && relay.pinScan.matched == 0 {
                        relay.setStatus("信箱里有 \(relay.pinScan.seen) 条消息但 PIN 对不上——检查设置里的 PIN", "off")
                    }
                } catch {
                    Live.shared.netOk = false
                    relay.setStatus("读不到信箱 · " + Live.why(error) + "，先看看你这边有没有网", "")
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
