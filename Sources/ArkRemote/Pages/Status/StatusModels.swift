import Foundation

// Placeholder data for the 状态 tab. Field names follow the web page (maa-automation/web/view.js render(),
// planRows(), numTiles()) and schema.js; the real snapshot is wired in by the logic layer later.

/// One shift (班次) from snapshot.queues: 名 / 定时 / 脚本.
struct StatusQueue: Hashable, Identifiable {
    var name: String          // 名
    var scheduled: Bool       // 定时 (false → 「未启用定时」)
    var scripts: [String]     // 脚本: MAA / MaaEnd / OK-WW
    var id: String { name }
}

/// A game line under a plan time row: ▸ name, followed by its hint lines.
struct StatusPlanGame: Hashable, Identifiable {
    var name: String
    var hints: [String]
    var id: String { name }
}

/// One 🕘 block of snapshot.plan. When it maps to a shift, the row carries the 今天跳过 switch.
struct StatusPlanBlock: Hashable, Identifiable {
    var time: String          // e.g. "04:00"
    var tokyo: String         // 东京 time, may be empty
    var queueName: String?    // the shift this block belongs to, nil when none matches
    var runsToday: Bool       // switch on = 今天照常, off = 今天跳过
    var games: [StatusPlanGame]
    /// The block's 「⏻ 跑完自动关机」 line (plan.py:674-675), without the mark; "" when the shift does not shut down.
    var after: String = ""
    var id: String { (queueName ?? "") + time }
    /// The time a row leads with: the plan's 东京 time when it gives one (the page's times are the phone's clock, 审查 B4;
    /// the tile's 「下一趟」 uses the same), else the machine's.
    var shownTime: String { tokyo.isEmpty ? time : tokyo }
    /// 「机器 09:00」 under it when the lead is the 东京 time, else "".
    var machineNote: String { tokyo.isEmpty || time.isEmpty ? "" : "机器 \(time)" }
}

/// One stamina tile (明日方舟 理智 / 终末地 理智 / 鸣潮 波片).
struct StatusStamina: Hashable, Identifiable {
    var label: String         // 「明日方舟 理智」
    var value: Int?           // 理智 / 波片
    var cap: Int?             // 上限
    var sub: String           // 「今天 19:24 回满」, 「已满」, 鸣潮: 回满 · 备用 · 周本
    var error: String?        // 错误
    var id: String { label }
}

/// One machine receipt from relay.最近指令.
struct StatusReceipt: Hashable, Identifiable {
    var ok: Bool
    var text: String
    var at: String            // "MM-DD HH:MM", when the machine acted on it
    var sent: String = ""     // "MM-DD HH:MM", the envelope's own time (modes.add_receipt sent=); older receipts have none
    var action: String = ""   // the command's action (skip_today / unskip_today / estop …)
    /// D207: the relay holds the order until the running script ends (modes.py add_receipt `queued`); the final receipt
    /// follows with the same action and `sent`. Not yet an answer to what the order did.
    var queued = false
    /// `at` / `sent` on the phone's clock, for display only (Logic/MachineTime.swift, 审查 B4); "" = not converted, show raw.
    /// The raw Beijing strings stay for the skip notes, the estop match and the Beijing day.
    var atLocal: String = ""
    var sentLocal: String = ""
    /// view.js rcNote: a skip receipt that no longer holds, drawn grey with this under it
    /// (「已被 HH:MM 的「跳过早班」取代」 / 「机器现在：早班今天照常」).
    var note: String? = nil
    /// how many earlier rows (newest first) carry the same at + text: receipts stamp only the minute (modes.py:584 %m-%d %H:%M),
    /// so one command run twice in a minute gives two equal rows, and skip-ui keys a List's rows by ForEach id, so two equal
    /// ids crash its LazyColumn ("Key … was already used"; StatusPage planRows has the same trap). Set in StatusData.from.
    var dup = 0
    var id: String { dup == 0 ? at + text : at + text + "#\(dup)" }

    /// view.js rcWhen(r, at): 「HH:MM 发出 · <at> 执行」 when the phone's send time differs from the run's; the send's date
    /// shows only when it is another day. `at` is the time as the row shows it (full on the 状态 page, HH:MM in 回执).
    /// Both on the phone's clock (atLocal / sentLocal), as the `at` passed in.
    func when(_ at: String) -> String {
        if sent.isEmpty || sent == self.at { return at }
        let a = atLocal.isEmpty ? self.at : atLocal, sl = sentLocal.isEmpty ? sent : sentLocal
        let s = String(sl.prefix(5)) == String(a.prefix(5)) ? String(sl.dropFirst(6)) : sl
        return "\(s) 发出 · \(at) 执行"
    }
    /// atLocal, else the raw `at`.
    var shownAt: String { atLocal.isEmpty ? at : atLocal }
}

/// 刷声骸 state from relay.刷声骸.
struct StatusEchoFarm: Hashable {
    var name: String          // 名字
    var from: String          // 从 (HH:MM), may be empty
    var until: String         // 到 (HH:MM), machine time: the 改收工 field starts from it and sends machine time
    /// 从 / 到 on the phone's clock (「明天 08:30」 when not today), for the notice (审查 B4).
    var fromLocal: String = ""
    var untilLocal: String = ""
}

/// A 4C boss: 序号 = position in the game's 讨伐强敌 list.
struct StatusBoss: Hashable, Identifiable {
    var index: Int
    var name: String
    var id: Int { index }
}

/// The small line under a row (pending.js applyPending; index.html:769-773): grey, or red with 「再发一次」.
enum StatusTag: Hashable {
    case sent(String, again: Bool)       // 已寄出 … / 没回执 · 已寄出 HH:MM (+ 再发一次 past 10 h)
    case bad(String)                     // 没生效 · … + 再发一次, red
    case applied(String)                 // 已应用 HH:MM
    /// pending.js:63 `row.classList.add("posted")`: the row gets the light green ground (index.html:768).
    var posted: Bool { switch self { case .sent, .bad: return true; default: return false } }
}

/// 「已停止 · 下一趟 HH:MM 照常」 with the machine's receipt as the footnote.
struct StatusEstopNote: Hashable {
    var title: String
    var receipt: String
}

struct StatusData {
    // Device card: 「游戏机 · 开机中」 / 「实时 · 配置 1 分钟前」.
    var deviceName = "游戏机"
    var deviceHead = ""
    var deviceStatus = "正在读取…"
    var online = false                        // heartbeat verdict (Live.alive): gates 现在在跑 (view.js:356-357)
    var dotOn = false                         // the card's dot: setStatus state "on" (index.html .devcard .dot.on green, else tertiary)
    /// The 「关机 · …」 verdict (Live.updateLive / pingInner set state "off" with that text): the machine is known to be off.
    /// Not `!online`: that is also true while 「正在确认是否在线…」 and when the phone has no network.
    var machineOff = false
    // Notices.
    var busy: [String] = []                   // run.在跑的 (only shown while online)
    var echoFarm: StatusEchoFarm?             // relay.刷声骸 when 到 is set
    var configUnreadable = false              // config._错误 → 读不到 AUTO-MAS 的配置
    var configIsStale = false                 // falling back to lastGoodConfig
    // Action tiles.
    var nextAt = ""                           // next 🕘 time in plan
    var refreshing = false                    // Live.busy: the 刷新 tile spins while a ping runs
    // Stamina tiles; nil = phone not configured, [] = configured but still reading.
    var stamina: [StatusStamina]? = nil
    var staminaSource = ""                    // 取自
    // 停止一切 note within 6 h.
    var estopNote: StatusEstopNote? = nil
    // Shifts.
    var queues: [StatusQueue] = []
    var currentQueue = ""
    var plan: [StatusPlanBlock] = []
    // 刷 4C 声骸.
    var bosses: [StatusBoss] = []             // schema.js BOSSES
    // 机器 switches (schema.js RELAY_SWITCHES, tab 状态).
    var skipShutdown = false                  // 下次别关机
    var debugModeUntil: String? = nil         // 调试模式, value = until HH:MM when on ("" = on, time unknown)
    // The line under a switch while a sent change waits (Pending tag), keyed by StatusSwitchID.
    var switchTags: [String: StatusTag] = [:]
    // Plan lines before the first 🕘 (view.js planRows foot), shown in 明日安排's footnote.
    var planFoot: [String] = []
    // Receipts (newest first) and the group-header note.
    var receipts: [StatusReceipt] = []
    var todayLast = ""                        // 今天.最近
    var todayFailed = 0                       // 今天.失败
    /// view.js nowRow 「今天实际」: 「早班 照常 · 晚班 跳过」 while a skip is in play today, else nil.
    var todayActual: String? = nil
    var receiptsToday = ""                    // today "MM-DD" on the phone's clock: the 回执 page puts 今天实际 in that day's group

    static let ownerName = ["MAA": "明日方舟", "MaaEnd": "终末地", "OK-WW": "鸣潮"]
}

/// What the page asks the logic layer to do. Every closure is optional so the page builds on its own.
struct StatusActions {
    var runNow: () -> Void = {}
    var stopAll: () -> Void = {}
    var selectQueue: (String) -> Void = { _ in }
    var setRunsToday: (String, Bool) -> Void = { _, _ in }        // queue name, on
    var startEchoFarm: (Int, String) -> Void = { _, _ in }        // boss index, until HH:MM
    var changeEchoFarmUntil: (String) -> Void = { _ in }
    var stopEchoFarm: () -> Void = {}
    var setSkipShutdown: (Bool) -> Void = { _ in }
    var setDebugMode: (Bool) -> Void = { _ in }
    var resend: (String) -> Void = { _ in }                       // 「再发一次」 under a row, switch id
    var resendShot: (StatusAsk) -> Void = { _ in }                // 「再发一次」 of a one-shot the machine never read
}

extension StatusData {
    /// Demo content so the page shows something before the logic layer is wired.
    static var sample: StatusData {
        var d = StatusData()
        d.deviceHead = "开机中"
        d.deviceStatus = "实时 · 配置 1 分钟前"
        d.online = true
        d.nextAt = "04:00"
        d.stamina = [
            StatusStamina(label: "明日方舟 理智", value: 120, cap: 135, sub: "今天 19:24 回满"),
            StatusStamina(label: "终末地 理智", value: 240, cap: 240, sub: "已满"),
            StatusStamina(label: "鸣潮 波片", value: 141, cap: 240, sub: "明天 01:38 回满 · 备用 12 · 周本 3/3"),
        ]
        d.staminaSource = "05:58"
        d.queues = [StatusQueue(name: "早班", scheduled: true, scripts: ["MAA", "MaaEnd", "OK-WW"]),
                    StatusQueue(name: "晚班", scheduled: true, scripts: ["MAA"])]
        d.currentQueue = "早班"
        d.plan = [
            StatusPlanBlock(time: "04:00", tokyo: "05:00", queueName: "早班", runsToday: true,
                            games: [StatusPlanGame(name: "明日方舟", hints: ["刷 1-7", "领取奖励"]),
                                    StatusPlanGame(name: "终末地", hints: ["基质刷取"]),
                                    StatusPlanGame(name: "鸣潮", hints: ["无音区"])]),
            StatusPlanBlock(time: "20:00", tokyo: "21:00", queueName: "晚班", runsToday: true,
                            games: [StatusPlanGame(name: "明日方舟", hints: ["刷 1-7"])]),
        ]
        d.bosses = [StatusBoss(index: 1, name: "天傀劫煞"), StatusBoss(index: 2, name: "万囿牢·朽躯"),
                    StatusBoss(index: 3, name: "梦魇亚当·重锤"), StatusBoss(index: 4, name: "无铭探索者")]
        d.receipts = [StatusReceipt(ok: true, text: "下次跑完不关机", at: "10-02 05:40"),
                      StatusReceipt(ok: true, text: "现在跑一趟", at: "10-02 05:31"),
                      StatusReceipt(ok: false, text: "刷声骸：游戏没开", at: "10-01 22:10"),
                      StatusReceipt(ok: true, text: "调试模式 90 分钟", at: "10-01 21:00")]
        d.todayLast = "早班"
        return d
    }
}
