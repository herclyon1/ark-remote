import SwiftUI

/// The 状态 tab: StatusPage fed from Relay / Live / StaminaStore / Pending; buttons send what the web page's
/// buttons send (maa-automation/web/view.js wire(): #runnow, #refresh, #estop, #echofarm, #echofarmuntil,
/// #echofarmstop); [data-relay] switch flips wait in 「待保存」 like the web page's edits. The mapping and the confirm /
/// send code live in Pages/Status/.
struct StatusTab: View {
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""
    @AppStorage("ark-remote-estop") var estopAt = 0
    @State var ask: StatusAsk? = nil
    /// Switch flips not yet sent: the one pool of every tab (view.js `edits`, Logic/Edits.swift); ✓ in the toolbar sends them
    /// with the other tabs' changes after one review.
    private var edits: Binding<[String: EWEdit]> {
        Binding(get: { EWEdits.shared.items }, set: { EWEdits.shared.items = $0 })
    }

    /// The 状态 data from the singletons and the stored settings as they are now (StatusPage.live): read by a pushed page
    /// as it draws, never captured.
    static func liveData() -> StatusData {
        let d = UserDefaults.standard
        var data = StatusData.from(relay: Relay.shared, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                                   currentQueue: d.string(forKey: "ark-remote-cfg-queue") ?? "",
                                   estopAt: d.integer(forKey: "ark-remote-estop"))
        StatusCommands.applyEdits(EWEdits.shared.items, to: &data)
        return data
    }

    var body: some View {
        let relay = Relay.shared
        var data = StatusData.from(relay: relay, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                                   currentQueue: storedQueue, estopAt: estopAt)
        let _ = StatusCommands.applyEdits(edits.wrappedValue, to: &data)
        StatusPage(data: data, actions: StatusCommands.actions(data, ask: $ask, storedQueue: $storedQueue, edits: edits),
                   live: Self.liveData)
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
            .alert(ask?.title ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
                if let a = ask {
                    if a.single {
                        // view.js ask(…, { single: true }): 「正在跑别的」 / 「发不出去」, one button, nothing sent
                        Button(a.ok, role: .cancel) {}
                    } else {
                        Button(a.ok, role: a.destructive ? .destructive : nil) {
                            let pressed = nowSec()
                            Task {
                                // view.js oneShot: a send that fails is the 「发不出去」 alert with the reason, not a toast
                                let why = await StatusCommands.send(a)
                                if let why {
                                    // an instant failure (no mailbox set) must not land while this alert is still closing
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    ask = StatusAsk.notice("发不出去", why)
                                } else if a.isEstop {
                                    // only an order that went out waits for its receipt: written before the send, a
                                    // failed one still read 「已下令停止 · 等机器回执」 for 6 hours (edge audit 4, 审查 B8)
                                    estopAt = pressed
                                }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
            } message: {
                Text(ask?.message ?? "")
            }
            .modifier(EWSaveBar(title: "游戏机遥控"))   // ✕ / 「待保存 N 项」 / ✓ over every tab's changes (view.js:1551-1555)
    }
}
