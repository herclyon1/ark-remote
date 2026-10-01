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
}

/// The 状态 tab's buttons, with the request bodies of maa-automation/web/view.js wire() (959–1020).
@MainActor
enum StatusCommands {
    /// view.js oneShot(body, okText), plus Pending.add for switches (the save flow's `pending[id] = {...}`).
    static func send(_ a: StatusAsk) async {
        let relay = Relay.shared
        do {
            try await relay.send(a.body)
            if let k = a.pendingKey, var e = a.pendingEdit {
                e.sentAt = nowSec()
                Pending.shared.add(k, e)
            }
            relay.showToast(a.okText + "（机器开着就是马上，关着就是下次开机）")
        } catch {
            relay.showToast("发不出去：" + Live.why(error), ms: 6000)
        }
    }

    static func actions(_ data: StatusData, ask: Binding<StatusAsk?>, storedQueue: Binding<String>) -> StatusActions {
        let relay = Relay.shared
        let queue = data.currentQueue
        var a = StatusActions()
        a.runNow = {
            // sending while a run is on makes AUTO-MAS and the manual run fight (view.js #runnow)
            if !data.busy.isEmpty {
                relay.showToast("现在正在跑 \(data.busy.joined(separator: "、"))，跑完再派。硬要派会和它打架。", ms: 5000)
                return
            }
            ask.wrappedValue = StatusAsk(
                title: "现在跑一趟？", message: "让「\(queue)」现在多跑一趟。会真的花掉理智／波片；机器关着就变成下次开机跑。",
                ok: "跑一趟",
                body: .object(["action": .string("run_now"), "confirmed": .bool(true), "queue": .string(queue)]),
                okText: "已让「\(queue)」现在开跑。机器关着时这条会等到下次开机才执行，那时候它本来也要跑，所以等于没多跑一趟")
        }
        a.refresh = { Task { await Live.shared.ping() } }
        a.stopAll = {
            ask.wrappedValue = StatusAsk(
                title: "停止一切？", message: "停掉现在在跑的：队列、脚本和游戏。不动排班、不动任何设置，下一趟照常。回执会告诉你停干净没有。",
                ok: "停止", destructive: true,
                body: .object(["action": .string("estop"), "confirmed": .bool(true)]),
                okText: "已下令停止一切，机器上几秒内生效", isEstop: true)
        }
        a.selectQueue = { storedQueue.wrappedValue = $0 }
        a.setRunsToday = { name, on in
            let label = data.plan.first(where: { $0.queueName == name }).map { "\(name) · \($0.time)" } ?? name
            let body: JSONValue = on
                ? .object(["action": .string("unskip_today"), "queue": .string(name)])
                : .object(["action": .string("skip_today"), "queue": .string(name), "day": .string(statusBeijingToday())])
            // TODO: the web page collects switch flips in its 保存修改 bar (view.js edits / updateBar) and sends them
            // together after one review; that bar is not ported yet, so each flip asks on its own here.
            ask.wrappedValue = StatusAsk(
                title: "保存修改？", message: "\(label)：\(on ? "开 → 今天照常" : "关 → 今天跳过，明天照常")", ok: "寄出",
                body: body, okText: "已寄出「\(label)」", pendingKey: StatusSwitchID.queue(name),
                pendingEdit: PendingEdit(label: label, src: "relay", from: .bool(!on), to: .bool(on), sentAt: 0, body: body))
        }
        a.startEchoFarm = { boss, until in
            guard let t = statusTimeHHMM(until), boss > 0 else {
                relay.showToast("先选 boss，再填结束时刻（08:30 这种）", ms: 4000)
                return
            }
            let nm = statusBosses.first(where: { $0.index == boss })?.name ?? "第 \(boss) 个"
            ask.wrappedValue = StatusAsk(
                title: "开始刷？", message: "刷「\(nm)」到机器时间 \(t) 为止？期间脚本会一直在打，别的任务不跑。", ok: "开始刷",
                body: .object(["action": .string("echo_farm"), "confirmed": .bool(true), "boss": .int(boss),
                               "until": .string(t), "name": .string(nm)]),
                okText: "已让它刷「\(nm)」到 \(t)。到点中继会自己收工并把配置还原")
        }
        a.changeEchoFarmUntil = { until in
            guard let v = statusTimeHHMM(until) else {
                relay.showToast("时刻要填 08:30 这种（时:分）", ms: 3000)
                return
            }
            ask.wrappedValue = StatusAsk(
                title: "改收工时刻？", message: "把收工时刻改成 \(v)（机器时间）？", ok: "改",
                body: .object(["action": .string("echo_farm_until"), "until": .string(v)]), okText: "收工时刻已改")
        }
        a.stopEchoFarm = {
            ask.wrappedValue = StatusAsk(
                title: "现在收工？", message: "会关掉脚本和游戏，配置还原成你原来那份。", ok: "收工", destructive: true,
                body: .object(["action": .string("echo_farm_stop")]), okText: "已收工，脚本和游戏都关了，配置还原")
        }
        a.setSkipShutdown = { on in ask.wrappedValue = relaySwitch(StatusSwitchID.skipShutdown, on: on) }
        a.setDebugMode = { on in ask.wrappedValue = relaySwitch(StatusSwitchID.debugMode, on: on) }
        return a
    }

    /// A schema.js RELAY_SWITCHES row flipped: confirm, then send sw.on / sw.off and track it in Pending.
    static func relaySwitch(_ id: String, on: Bool) -> StatusAsk? {
        guard let sw = relaySwitches.first(where: { $0.id == id }) else { return nil }
        let body = on ? sw.on : sw.off
        // TODO: same as setRunsToday — the web 保存修改 bar (one review for several flips) is not ported yet.
        return StatusAsk(title: "保存修改？", message: "\(sw.label)：\(on ? "关 → 开" : "开 → 关")", ok: "寄出",
                         body: body, okText: "已寄出「\(sw.label)」", pendingKey: id,
                         pendingEdit: PendingEdit(label: sw.label, src: "relay", from: .bool(!on), to: .bool(on), sentAt: 0, body: body))
    }
}
