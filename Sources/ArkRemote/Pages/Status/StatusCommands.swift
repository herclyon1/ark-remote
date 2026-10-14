import SwiftUI

/// A command waiting for the user's yes (view.js ask() before oneShot / the save flow): a confirmationDialog anchored to
/// the button that asked (StatusPage `StatusAsking`, keyed by `anchor`), or, for `single`, the one-button alert of StatusTab.
struct StatusAsk: Equatable {
    var title: String
    var message: String
    var ok: String
    var destructive = false
    var body: JSONValue
    var okText: String
    /// Set for a switch: the change goes into Pending under this key once it is sent.
    var pendingKey: String? = nil
    var pendingEdit: PendingEdit? = nil
    var isEstop = false
    /// view.js ask(…, { single: true }): one 「好」 button, nothing is sent.
    var single = false
    /// The button the confirmation belongs to (the request's action): its dialog is drawn from that button.
    var anchor = ""

    /// A one-button notice in the same alert (view.js ask(title, text, "好", false, { single: true })).
    static func notice(_ title: String, _ message: String) -> StatusAsk {
        StatusAsk(title: title, message: message, ok: "好", body: .null, okText: "", single: true)
    }
}

/// The 状态 tab's buttons, with the request bodies of maa-automation/web/view.js wire() (959–1020).
@MainActor
enum StatusCommands {
    /// view.js oneShot(body, okText), plus Pending.add for switches (the save flow's `pending[id] = {...}`).
    /// Success goes to the status line under the title (Feedback.status, HIG Feedback "Consider integrating status
    /// feedback into your interface"); a failure comes back as the reason, which the caller shows in the
    /// 「发不出去」 one-button alert (view.js:1570 `ask("发不出去", e.message, "好", false, { single: true })`).
    static func send(_ a: StatusAsk) async -> String? {
        let relay = Relay.shared
        do {
            try await relay.send(a.body)
            if let k = a.pendingKey, var e = a.pendingEdit {
                e.sentAt = nowSec()
                Pending.shared.add(k, e)
            }
            Feedback.status(a.okText)
            return nil
        } catch {
            return Live.why(error)
        }
    }

    static func actions(_ data: StatusData, ask: Binding<StatusAsk?>, storedQueue: Binding<String>,
                        edits: Binding<[String: EWEdit]>) -> StatusActions {
        let queue = data.currentQueue.isEmpty ? "早班" : data.currentQueue   // view.js theQueue(): curQueue || "早班"
        var a = StatusActions()
        a.runNow = {
            // sending while a run is on makes AUTO-MAS and the manual run fight (view.js:1209: a one-button alert)
            if !data.busy.isEmpty {
                ask.wrappedValue = StatusAsk.notice("正在跑别的", "现在正在跑 \(data.busy.joined(separator: "、"))，跑完再派。")
                return nil
            }
            // each confirmation says one sentence (HIG Action sheets: "Provide a message only if necessary"; reference P10,
            // Calendar's discard confirmation) that keeps what the press really does: it spends sanity; the mailbox holds
            // the order 12 hours, which matters only while the machine is off, so only then is it said
            return StatusAsk(
                title: "现在跑一趟？",
                message: "\(queue)现在多跑一趟，会花掉理智和波片。" + (data.machineOff ? "机器 12 小时内没开机就作废。" : ""),
                ok: "跑一趟",
                body: .object(["action": .string("run_now"), "confirmed": .bool(true), "queue": .string(queue)]),
                // the mailbox keeps a message 12 hours (ntfy.sh's cache; Pending.swift isStale) and nothing tracks a one-shot
                // order: 「下次开机跑」 promised a run that a machine off longer never got (edge audit 23)
                okText: "已派：现在跑一趟", anchor: "run_now")   // view.js:1215
        }
        a.refresh = { Task { await Live.shared.ping() } }
        a.stopAll = {
            // the relay drops an estop read from the boot backlog (boot_stages.py:534-546 LIVE_ONLY_ACTIONS): sent while the
            // machine is off it never runs, and the page waited 6 h for its receipt (审查 B8)
            if data.machineOff {
                ask.wrappedValue = StatusAsk.notice("机器关着", "关机时按的「停止一切」开机后不会执行，所以这次没有发。")
                return nil
            }
            return StatusAsk(
                title: "停止一切？", message: "停掉在跑的队列、脚本和游戏，排班和设置都不动，下一趟照常。",
                ok: "停止", destructive: true,
                body: .object(["action": .string("estop"), "confirmed": .bool(true)]),
                okText: "已下令停止一切", isEstop: true, anchor: "estop")   // view.js:1263
        }
        a.selectQueue = { storedQueue.wrappedValue = $0 }
        a.setRunsToday = { name, on in
            // the time as the row shows it (StatusPlanBlock.shownTime), so the review's 「今天不跑：早班（10:00）」 matches the row
            let label = data.plan.first(where: { $0.queueName == name && !$0.time.isEmpty }).map { "\(name) · \($0.shownTime)" } ?? name
            let body: JSONValue = on
                ? .object(["action": .string("unskip_today"), "queue": .string(name)])
                : .object(["action": .string("skip_today"), "queue": .string(name), "day": .string(statusBeijingToday())])
            note(edits, StatusSwitchID.queue(name), label: label, on: on, body: body)
        }
        a.startEchoFarm = { boss, until in
            // 开始刷 stays disabled until both are valid, with the reason under the section (echoFarmProblem); this guard
            // only keeps a stray call from sending (view.js:1228 / :1239 said it in a toast)
            // `until` is the phone's clock (the page's one clock); the relay reads the machine's (echofarm.py resolve_until)
            guard echoFarmProblem(boss: boss, until: until) == nil, let t = statusTimeHHMM(until),
                  let m = machineHHMM(fromPhone: t) else { return nil }
            let nm = statusBosses.first(where: { $0.index == boss })?.name ?? "第 \(boss) 个"
            // sent while the machine is off it ran at the next boot, with the time resolved at that moment: 08:30 asked at
            // 23:00 became the next day's 08:30, a farm of ~24 h over the morning shift (审查 A3; boot_stages.py:692-694,
            // echofarm.py:329 → 114-124). The relay is to refuse a stale one; the App does not send it at all.
            if data.machineOff {
                ask.wrappedValue = StatusAsk.notice("机器关着", "刷声骸要机器开着才能开始，所以这次没有发。")
                return nil
            }
            return StatusAsk(
                // the relay holds no queue back for a farm (审查 B14: echofarm is read only by commands / engine tick / shutdown /
                // phone, relay grep): a shift that comes due runs as usual
                title: "开始刷？", message: "刷「\(nm)」到 \(t)，期间到点的班次可能和它抢游戏。", ok: "开始刷",
                body: .object(["action": .string("echo_farm"), "confirmed": .bool(true), "boss": .int(boss),
                               "until": .string(m), "name": .string(nm)]),
                okText: "已派：刷到 \(t)", anchor: "echo_farm")   // view.js:1230
        }
        a.changeEchoFarmUntil = { until in
            // 改收工时刻 is disabled while the time is not a valid one (the reason is under the 刷声骸 section)
            guard let v = statusTimeHHMM(until), let m = machineHHMM(fromPhone: v) else { return nil }
            // echofarm.py retime → resolve_until (114-124): a time not after the machine's clock now is tomorrow's (审查 A2).
            // machineHHMM(fromPhone:) takes the phone time's next coming moment, which resolve_until reads the same way, so
            // 「already past」 is judged on the phone's clock the user picked on
            let past = v <= phoneHHMM(Date())
            return StatusAsk(
                title: "改收工时刻？",
                message: past ? "已过 \(v)，会到明天 \(v) 才收工。"
                    : "收工改到 \(v)。",
                ok: "改",
                body: .object(["action": .string("echo_farm_until"), "until": .string(m)]), okText: "收工时刻已改",
                anchor: "echo_farm_until")
        }
        a.stopEchoFarm = {
            StatusAsk(
                title: "现在收工？", message: "关掉脚本和游戏，配置还原。", ok: "收工", destructive: true,
                body: .object(["action": .string("echo_farm_stop")]), okText: "已收工", anchor: "echo_farm_stop")   // view.js:1246
        }
        a.confirm = { q in
            let pressed = nowSec()
            Task {
                if let why = await send(q) {
                    // view.js oneShot: the 「发不出去」 alert with the reason, StatusTab's one-button alert (125)
                    ask.wrappedValue = StatusAsk.notice("发不出去", why)
                } else if q.isEstop {
                    // only an order that went out waits for its receipt: written before the send, a failed one still read
                    // 「已下令停止 · 等机器回执」 for 6 hours (edge audit 4, 审查 B8). StatusTab reads it through @AppStorage
                    // (iOS observes UserDefaults; skip-ui registers a SharedPreferences listener, AppStorage.swift:84)
                    UserDefaults.standard.set(pressed, forKey: "ark-remote-estop")
                }
            }
        }
        a.setSkipShutdown = { on in relaySwitch(edits, StatusSwitchID.skipShutdown, on: on) }
        a.setDebugMode = { on in relaySwitch(edits, StatusSwitchID.debugMode, on: on) }
        a.resend = { id in Task { await Pending.shared.resend(id) } }   // pending.js [data-again] → resend(key)
        return a
    }

    /// Why 开始刷 cannot be pressed yet, or nil (view.js:1228 / :1239 said these in a toast; HIG Entering data: "make the
    /// button available only after people enter the data you require").
    static func echoFarmProblem(boss: Int, until: String) -> String? {
        if boss <= 0 { return "先选 boss 再填时刻" }
        if statusTimeHHMM(until) == nil { return "时刻填成 08:30 这种" }
        return nil
    }

    /// A schema.js RELAY_SWITCHES row flipped: the change waits in 「待保存」 (sw.on / sw.off is what 保存 sends).
    static func relaySwitch(_ edits: Binding<[String: EWEdit]>, _ id: String, on: Bool) {
        guard let sw = relaySwitches.first(where: { $0.id == id }) else { return }
        note(edits, id, label: sw.label, on: on, body: on ? sw.on : sw.off)
    }

    /// view.js [data-relay] onchange: a flip back to the value the switch showed before drops the edit, otherwise it
    /// waits in 「待保存」 until the tab's 保存 sends all of them after one review (EWSaveBar, as on the 终末地 / 鸣潮 tabs).
    /// The base is the sent-but-unreceipted value while it is on its way, else the machine's (view.js:1254 / 1286 base()):
    /// with the machine's alone a flip back after a save looked like no change and the sent value still landed.
    static func note(_ edits: Binding<[String: EWEdit]>, _ id: String, label: String, on: Bool, body: JSONValue) {
        let from = (Pending.shared.items[id]?.to ?? Pending.shared.liveVals[id])?.truthy ?? false
        if on == from {
            edits.wrappedValue[id] = nil
        } else {
            var e = EWEdit(label: label, src: "relay", from: .bool(from), to: .bool(on), body: body)
            // a row changed again keeps its place in the review order, as a JS object key does (EWLive.swift ewPutEdit)
            if let old = edits.wrappedValue[id] { e.at = old.at }
            edits.wrappedValue[id] = e
        }
    }

    /// The switches show the unsaved edits on top of the machine's / sent values.
    static func applyEdits(_ edits: [String: EWEdit], to d: inout StatusData) {
        // the pool holds every tab's changes (Logic/Edits.swift); only this tab's switches are drawn here
        for (id, e) in edits where id == StatusSwitchID.skipShutdown || id == StatusSwitchID.debugMode
            || id.hasPrefix(StatusSwitchID.queue("")) {
            let on = e.to.truthy
            if id == StatusSwitchID.skipShutdown {
                d.skipShutdown = on
            } else if id == StatusSwitchID.debugMode {
                d.debugModeUntil = on ? (d.debugModeUntil ?? "") : nil
            } else if let i = d.plan.firstIndex(where: { $0.queueName.map(StatusSwitchID.queue) == id }) {
                d.plan[i].runsToday = on
            }
            d.switchTags[id] = .unsaved("未寄出")
        }
    }
}
