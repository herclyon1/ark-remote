import SwiftUI

/// A command waiting for the user's yes in the page's alert (view.js ask() before oneShot / the save flow).
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

    /// A one-button notice in the same alert (view.js ask(title, text, "好", false, { single: true })).
    static func notice(_ title: String, _ message: String) -> StatusAsk {
        StatusAsk(title: title, message: message, ok: "好", body: .null, okText: "", single: true)
    }
}

/// The 状态 tab's buttons, with the request bodies of maa-automation/web/view.js wire() (959–1020).
@MainActor
enum StatusCommands {
    /// view.js oneShot(body, okText), plus Pending.add for switches (the save flow's `pending[id] = {...}`).
    /// Success is the web's short toast as is; a failure comes back as the reason, which the caller shows in the
    /// 「发不出去」 one-button alert (view.js:1570 `ask("发不出去", e.message, "好", false, { single: true })`).
    static func send(_ a: StatusAsk) async -> String? {
        let relay = Relay.shared
        do {
            try await relay.send(a.body)
            if let k = a.pendingKey, var e = a.pendingEdit {
                e.sentAt = nowSec()
                Pending.shared.add(k, e)
            }
            relay.showToast(a.okText)
            return nil
        } catch {
            return Live.why(error)
        }
    }

    static func actions(_ data: StatusData, ask: Binding<StatusAsk?>, storedQueue: Binding<String>,
                        edits: Binding<[String: EWEdit]>) -> StatusActions {
        let relay = Relay.shared
        let queue = data.currentQueue.isEmpty ? "早班" : data.currentQueue   // view.js theQueue(): curQueue || "早班"
        var a = StatusActions()
        a.runNow = {
            // sending while a run is on makes AUTO-MAS and the manual run fight (view.js:1209: a one-button alert)
            if !data.busy.isEmpty {
                ask.wrappedValue = StatusAsk.notice("正在跑别的", "现在正在跑 \(data.busy.joined(separator: "、"))，跑完再派。硬要派会和它打架。")
                return
            }
            ask.wrappedValue = StatusAsk(
                title: "现在跑一趟？", message: "让「\(queue)」现在多跑一趟。会真的花掉理智／波片；机器关着就变成下次开机跑。",
                ok: "跑一趟",
                body: .object(["action": .string("run_now"), "confirmed": .bool(true), "queue": .string(queue)]),
                okText: "已派：现在跑一趟")   // view.js:1215: one line, the confirm before it already says what happens when off
        }
        a.refresh = { Task { await Live.shared.ping() } }
        a.stopAll = {
            // the relay drops an estop read from the boot backlog (boot_stages.py:534-546 LIVE_ONLY_ACTIONS): sent while the
            // machine is off it never runs, and the page waited 6 h for its receipt (审查 B8)
            if data.machineOff {
                ask.wrappedValue = StatusAsk.notice("机器关着", "现在没有在跑的东西。关机时按的「停止一切」开机后也不会执行，所以这次没有发。")
                return
            }
            ask.wrappedValue = StatusAsk(
                title: "停止一切？", message: "停掉现在在跑的：队列、脚本和游戏。不动排班、不动任何设置，下一趟照常。回执会告诉你停干净没有。",
                ok: "停止", destructive: true,
                body: .object(["action": .string("estop"), "confirmed": .bool(true)]),
                okText: "已下令停止一切", isEstop: true)   // view.js:1263
        }
        a.selectQueue = { storedQueue.wrappedValue = $0 }
        a.setRunsToday = { name, on in
            let label = data.plan.first(where: { $0.queueName == name && !$0.time.isEmpty }).map { "\(name) · \($0.time)" } ?? name
            let body: JSONValue = on
                ? .object(["action": .string("unskip_today"), "queue": .string(name)])
                : .object(["action": .string("skip_today"), "queue": .string(name), "day": .string(statusBeijingToday())])
            note(edits, StatusSwitchID.queue(name), label: label, on: on, body: body)
        }
        a.startEchoFarm = { boss, until in
            guard let t = statusTimeHHMM(until), boss > 0 else {
                relay.showToast("先选 boss 再填时刻")   // view.js:1228
                return
            }
            let nm = statusBosses.first(where: { $0.index == boss })?.name ?? "第 \(boss) 个"
            // sent while the machine is off it ran at the next boot, with the time resolved at that moment: 08:30 asked at
            // 23:00 became the next day's 08:30, a farm of ~24 h over the morning shift (审查 A3; boot_stages.py:692-694,
            // echofarm.py:329 → 114-124). The relay is to refuse a stale one; the App does not send it at all.
            if data.machineOff {
                ask.wrappedValue = StatusAsk.notice("机器关着", "刷声骸要机器开着才能开始。关机时发出的要等下次开机才执行，那时收工时刻按开机那一刻重新算，可能一刷就是一整天。开机后再按。")
                return
            }
            ask.wrappedValue = StatusAsk(
                title: "开始刷？", message: "刷「\(nm)」到机器时间 \(t) 为止？期间脚本会一直在打，别的任务不跑。", ok: "开始刷",
                body: .object(["action": .string("echo_farm"), "confirmed": .bool(true), "boss": .int(boss),
                               "until": .string(t), "name": .string(nm)]),
                okText: "已派：刷到 \(t)")   // view.js:1230
        }
        a.changeEchoFarmUntil = { until in
            guard let v = statusTimeHHMM(until) else {
                relay.showToast("时刻填成 08:30 这种")   // view.js:1239
                return
            }
            // echofarm.py retime → resolve_until (114-124): a time not after the machine's clock now is tomorrow's (审查 A2)
            let past = v <= machineNowHHMM()
            ask.wrappedValue = StatusAsk(
                title: "改收工时刻？",
                message: past ? "机器时间现在已过 \(v)，会算成明天 \(v) 才收工。要马上停，按「提前收工」。"
                    : "把收工时刻改成 \(v)（机器时间）？",
                ok: "改",
                body: .object(["action": .string("echo_farm_until"), "until": .string(v)]), okText: "收工时刻已改")
        }
        a.stopEchoFarm = {
            ask.wrappedValue = StatusAsk(
                title: "现在收工？", message: "会关掉脚本和游戏，配置还原成你原来那份。", ok: "收工", destructive: true,
                body: .object(["action": .string("echo_farm_stop")]), okText: "已收工")   // view.js:1246
        }
        a.setSkipShutdown = { on in relaySwitch(edits, StatusSwitchID.skipShutdown, on: on) }
        a.setDebugMode = { on in relaySwitch(edits, StatusSwitchID.debugMode, on: on) }
        a.resend = { id in Task { await Pending.shared.resend(id) } }   // pending.js [data-again] → resend(key)
        return a
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
            d.switchTags[id] = .unsaved("待保存")
        }
    }
}
