import SwiftUI

/// The 状态 tab: StatusPage fed from Relay / Live / StaminaStore / Pending; commands send what the web page's buttons send
/// (view.js wire(): #runnow, #estop, #echofarm, #echofarmuntil, #echofarmstop). Switches and pickers apply when changed
/// (StatusCommands.apply); the commands that spend or stop a run ask first in a confirmation dialog. The mapping and the
/// send code live in Pages/Status/.
struct StatusTab: View {
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""
    @AppStorage("ark-remote-estop") var estopAt = 0
    @State var ask: StatusAsk? = nil
    /// Orders on their way and the last one-shot command (StatusOutbox).
    @State var outbox = StatusOutbox()

    /// The 状态 data from the singletons and the stored settings as they are now (StatusPage.live): read by a pushed page
    /// as it draws, never captured.
    static func liveData() -> StatusData {
        let d = UserDefaults.standard
        return StatusData.from(relay: Relay.shared, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                               currentQueue: d.string(forKey: "ark-remote-cfg-queue") ?? "",
                               estopAt: d.integer(forKey: "ark-remote-estop"))
    }

    var body: some View {
        let relay = Relay.shared
        var data = StatusData.from(relay: relay, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                                   currentQueue: storedQueue, estopAt: estopAt)
        // the switches' orders on their way or not gone out are in the shared pool (EWSave.apply), the one-shot in `outbox`
        let box = StatusCommands.withSwitches(outbox)
        let _ = StatusCommands.applyOutbox(box, to: &data)
        StatusPage(data: data, actions: StatusCommands.actions(data, ask: $ask, storedQueue: $storedQueue, outbox: $outbox),
                   outbox: box, live: Self.liveData)
            .navigationTitle("状态")
            // HIG Refresh content controls: "A refresh control lets people immediately reload content"
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
                    if relay.snap == nil, let note = relay.pinMismatchNote() {
                        relay.setStatus(note, "off")
                    }
                } catch {
                    // leaving the tab cancels this .task: that is no network failure (edge audit 8)
                    if Live.isCancel(error) { return }
                    let net = Live.isNetwork(error)
                    if net { Live.shared.netOk = false }
                    relay.setStatus("读不到信箱 · " + Live.why(error) + (net ? "，先看看你这边有没有网" : ""), "")
                }
                _ = await StaminaStore.shared.refresh()
            }
            // HIG Action sheets: "Use an action sheet — not an alert — to offer choices related to an intentional action."
            // A send that fails shows in the 回执 section's outbox row (StatusShot), not in a second alert.
            .confirmationDialog(ask?.title ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
                                titleVisibility: .visible) {
                if let a = ask {
                    Button(a.ok, role: a.destructive ? .destructive : nil) {
                        let pressed = nowSec()
                        let head = data.receipts.first?.id
                        Task {
                            // only an order that went out waits for its receipt: written before the send, a failed one
                            // still read 「已下令停止 · 等机器回执」 for 6 hours (edge audit 4, 审查 B8)
                            if await StatusCommands.shoot(a, head: head, outbox: $outbox), a.isEstop { estopAt = pressed }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            } message: {
                Text(ask?.message ?? "")
            }
    }
}
