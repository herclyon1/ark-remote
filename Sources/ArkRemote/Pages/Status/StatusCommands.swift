import SwiftUI

/// A command waiting for the user's yes in the tab's confirmation dialog (StatusTab). HIG Action sheets: "Use an action
/// sheet — not an alert — to offer choices related to an intentional action."
struct StatusAsk: Equatable {
    var title: String
    var message: String
    /// The dialog's verb (「跑一趟」 / 「停止」 / 「开始刷」 / 「收工」).
    var ok: String
    /// A stop that cannot be undone (HIG Action sheets: "Use the destructive style for buttons that perform destructive
    /// actions").
    var destructive = false
    var body: JSONValue
    /// What the outbox row in the 回执 section names while the order is on its way (「现在跑一趟」).
    var what: String
    var isEstop = false

    /// The order's action (「run_now」 / 「estop」 / 「echo_farm」 / 「echo_farm_stop」): which button's dialog shows it.
    var action: String { body["action"]?.string ?? "" }
}

/// What the page sent and has no answer for yet, shown where it was sent from (HIG Feedback: "Consider integrating status
/// feedback into your interface."). In memory only; the machine's receipt is the lasting record.
struct StatusOutbox: Equatable {
    /// switch id → the value on its way (queued or out through EWSave.apply): the switch shows it, disabled, until the
    /// send returns. Filled from the pool by `withSwitches`.
    var sending: [String: Bool] = [:]
    /// switch id → why the last send of that switch did not go out (the switch shows its old value). From the pool.
    var failed: [String: String] = [:]
    /// the last one-shot command (现在跑一趟 / 刷声骸 / 收工时刻 / 提前收工, or a failed 停止一切)
    var shot: StatusShot? = nil
}

/// One one-shot command in the 回执 section until the machine's next receipt answers it.
struct StatusShot: Equatable {
    var what: String
    /// 「HH:MM」 on the phone's clock, as the receipt rows' times
    var at: String
    /// why it did not go out; nil = sent
    var failure: String? = nil
    /// the newest receipt's id when it went out: once a newer receipt is in, that receipt is the answer and the row goes
    var head: String? = nil
}

/// The 状态 tab's commands, with the request bodies of the web page's view.js wire() (959–1020).
@MainActor
enum StatusCommands {
    /// view.js oneShot(body): one order to the mailbox. nil when it went out, else the reason in words.
    static func send(_ a: StatusAsk) async -> String? {
        do {
            try await Relay.shared.send(a.body)
            return nil
        } catch {
            return Live.why(error)
        }
    }

    /// Sends a one-shot order and records it in the outbox row. Returns true when it went out. A sent 停止一切 has its own
    /// row (StatusData.estopNote, from StatusTab's estopAt), so only its failure is recorded here.
    static func shoot(_ a: StatusAsk, head: String?, outbox: Binding<StatusOutbox>) async -> Bool {
        let why = await send(a)
        if why == nil && a.isEstop { return true }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        outbox.wrappedValue.shot = StatusShot(what: a.what, at: "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))", failure: why,
                                              head: head)
        return why == nil
    }

    static func actions(_ data: StatusData, ask: Binding<StatusAsk?>, storedQueue: Binding<String>,
                        outbox: Binding<StatusOutbox>) -> StatusActions {
        let queue = data.currentQueue.isEmpty ? "早班" : data.currentQueue   // view.js theQueue(): curQueue || "早班"
        let head = data.receipts.first?.id
        var a = StatusActions()
        // sending while a run is on makes AUTO-MAS and the manual run fight (view.js:1209): the row is disabled then, with
        // the reason under its title (StatusPage.commands)
        a.runNow = {
            ask.wrappedValue = StatusAsk(
                title: "现在跑一趟？", message: "让「\(queue)」现在多跑一趟。会真的花掉理智／波片；机器关着的话，12 小时内开机才会跑，再晚就作废。",
                ok: "跑一趟",
                body: .object(["action": .string("run_now"), "confirmed": .bool(true), "queue": .string(queue)]),
                // the mailbox keeps a message 12 hours (ntfy.sh's cache; Pending.swift isStale) and nothing tracks a one-shot
                // order: 「下次开机跑」 promised a run that a machine off longer never got (edge audit 23)
                what: "现在跑一趟")
        }
        // the relay drops an estop read from the boot backlog (boot_stages.py:534-546 LIVE_ONLY_ACTIONS): sent while the
        // machine is off it never runs (审查 B8), so the row is disabled while the machine is off
        a.stopAll = {
            ask.wrappedValue = StatusAsk(
                title: "停止一切？", message: "停掉现在在跑的：队列、脚本和游戏。不动排班、不动任何设置，下一趟照常。回执会告诉你停干净没有。",
                ok: "停止", destructive: true,
                body: .object(["action": .string("estop"), "confirmed": .bool(true)]),
                what: "停止一切", isEstop: true)   // view.js:1263
        }
        a.selectQueue = { storedQueue.wrappedValue = $0 }
        a.setRunsToday = { name, on in
            // the time as the row shows it (StatusPlanBlock.shownTime), so Pending's label matches the row
            let label = data.plan.first(where: { $0.queueName == name && !$0.time.isEmpty }).map { "\(name) · \($0.shownTime)" } ?? name
            let body: JSONValue = on
                ? .object(["action": .string("unskip_today"), "queue": .string(name)])
                : .object(["action": .string("skip_today"), "queue": .string(name), "day": .string(statusBeijingToday())])
            apply(StatusSwitchID.queue(name), label: label, on: on, body: body)
        }
        // the boss Picker and the time DatePicker always hold a valid value (bossIndex starts at 1; hhmmBinding writes HH:MM)
        a.startEchoFarm = { boss, until in
            let t = statusTimeHHMM(until) ?? until
            let nm = statusBosses.first(where: { $0.index == boss })?.name ?? "第 \(boss) 个"
            // sent while the machine is off it ran at the next boot, with the time resolved at that moment (审查 A3;
            // boot_stages.py:692-694, echofarm.py:329 → 114-124): the 开始刷 row is disabled while the machine is off
            ask.wrappedValue = StatusAsk(
                // the relay holds no queue back for a farm (审查 B14): a shift that comes due runs as usual
                title: "开始刷？", message: "刷「\(nm)」到机器时间 \(t) 为止？期间脚本会一直在打；到点的班次照常跑，可能和它抢游戏。", ok: "开始刷",
                body: .object(["action": .string("echo_farm"), "confirmed": .bool(true), "boss": .int(boss),
                               "until": .string(t), "name": .string(nm)]),
                what: "刷「\(nm)」到 \(t)")   // view.js:1230
        }
        // a setting of the running farm: applied when the time picker changes, no confirm (HIG Alerts: "Avoid displaying
        // alerts for common, undoable actions"). echofarm.py retime → resolve_until (114-124): a time not after the
        // machine's clock now is tomorrow's (审查 A2); the section's footer says so.
        a.changeEchoFarmUntil = { until in
            let v = statusTimeHHMM(until) ?? until
            let order = StatusAsk(title: "", message: "", ok: "",
                                  body: .object(["action": .string("echo_farm_until"), "until": .string(v)]),
                                  what: "收工时刻改到 \(v)")
            Task { _ = await shoot(order, head: head, outbox: outbox) }
        }
        a.stopEchoFarm = {
            ask.wrappedValue = StatusAsk(
                title: "现在收工？", message: "会关掉脚本和游戏，配置还原成你原来那份。", ok: "收工", destructive: true,
                body: .object(["action": .string("echo_farm_stop")]), what: "提前收工")   // view.js:1246
        }
        a.setSkipShutdown = { on in relaySwitch(StatusSwitchID.skipShutdown, on: on) }
        a.setDebugMode = { on in relaySwitch(StatusSwitchID.debugMode, on: on) }
        a.resend = { id in EWSave.resend(id) }   // pending.js [data-again] → resend(key)
        return a
    }

    /// A schema.js RELAY_SWITCHES row flipped: sent now (sw.on / sw.off).
    static func relaySwitch(_ id: String, on: Bool) {
        guard let sw = relaySwitches.first(where: { $0.id == id }) else { return }
        apply(id, label: sw.label, on: on, body: on ? sw.on : sw.off)
    }

    /// A switch flipped (decision by 验收 10-07: native settings apply when changed): the change goes to EWSave.apply, the
    /// one way out every tab's changes take — its relay branch stamps a skip's Beijing day as it goes (Pending.skipDayNow,
    /// edge audit 17), Pending.add keeps the body for 「再发一次」, and one ask follows for a state reported after the send
    /// (Live.ping(afterSeconds:), view.js:2455-2457). The base is the sent-but-unreceipted value, else the machine's
    /// (view.js:1254 / 1286 base()): a flip back to it drops a change that has not gone out. The switch is disabled while
    /// its own order is out (StatusPage.switchRow), and a drop then would take the change being sent out of the pool.
    static func apply(_ id: String, label: String, on: Bool, body raw: JSONValue) {
        guard !EWSave.isSending(id) else { return }
        let from = (Pending.shared.items[id]?.to ?? Pending.shared.liveVals[id])?.truthy ?? false
        if on == from {
            if EWEdits.shared.items[id] != nil { EWSave.apply(id, nil) }
            return
        }
        EWSave.apply(id, EWEdit(label: label, src: "relay", from: .bool(from), to: .bool(on), body: raw))
    }

    /// The outbox with the switches' orders from the pool (EWEdits / EWSendQueue): on their way, or did not go out.
    static func withSwitches(_ outbox: StatusOutbox) -> StatusOutbox {
        var box = outbox
        let q = EWSendQueue.shared
        for (id, e) in EWEdits.shared.items where id.hasPrefix("relay|") {
            if let f = e.failure {
                box.failed[id] = f
            } else if q.queued.contains(id) {
                box.sending[id] = e.to.truthy
            }
        }
        for id in q.resending where id.hasPrefix("relay|") { box.sending[id] = (Pending.shared.items[id]?.to.truthy) ?? false }
        return box
    }

    /// The switches show a value on its way on top of the machine's / sent values.
    static func applyOutbox(_ outbox: StatusOutbox, to d: inout StatusData) {
        for (id, on) in outbox.sending {
            if id == StatusSwitchID.skipShutdown {
                d.skipShutdown = on
            } else if id == StatusSwitchID.debugMode {
                d.debugModeUntil = on ? (d.debugModeUntil ?? "") : nil
            } else if let i = d.plan.firstIndex(where: { $0.queueName.map(StatusSwitchID.queue) == id }) {
                d.plan[i].runsToday = on
            }
        }
    }
}
