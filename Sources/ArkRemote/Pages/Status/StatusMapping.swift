import Foundation

// Maps the machine's snapshot (Relay.shared.snap), the heartbeat verdict (Live), the stamina reading
// (StaminaStore) and the sent-but-unconfirmed changes (Pending) into StatusData, the way
// maa-automation/web/view.js render() builds the 状态 part (planRows(), numTiles(), relayRow()).

/// view.js OWNER_OF: game name in the plan text → script name in a shift's 脚本.
let statusOwnerOf = ["明日方舟": "MAA", "终末地": "MaaEnd", "鸣潮": "OK-WW"]

/// view.js timeHHMM(s): "8:30" / "08:30" → "08:30", anything else nil.
func statusTimeHHMM(_ s: String) -> String? {
    let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard p.count == 2, (1...2).contains(p[0].count), p[1].count == 2,
          let h = Int(p[0]), let m = Int(p[1]), h <= 23, m <= 59 else { return nil }
    return "\(pad2(h)):\(p[1])"
}

/// view.js beijingToday(): yyyy-MM-dd in Asia/Shanghai.
func statusBeijingToday() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

/// view.js whenFull(stamp): "MM-DD HH:MM" → 「今天 19:24 回满」 / 「明天 01:38 回满」 / 「MM-DD HH:MM 回满」.
func statusWhenFull(_ stamp: String?) -> String {
    guard let stamp, !stamp.isEmpty else { return "" }
    let parts = stamp.split(separator: " ")
    guard parts.count == 2, parts[0].count == 5, parts[1].count == 5 else { return "回满 \(stamp)" }
    let cal = Calendar.current
    func md(_ d: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(pad2(c.month ?? 0))-\(pad2(c.day ?? 0))"
    }
    let day = String(parts[0])
    let today = md(Date()), tomorrow = md(Date().addingTimeInterval(86400))
    let name = day == today ? "今天" : day == tomorrow ? "明天" : day
    return "\(name) \(parts[1]) 回满"
}

/// The switch ids, as in view.js / schema.js.
enum StatusSwitchID {
    static let skipShutdown = "relay|skip_shutdown"
    static let debugMode = "relay|debug_mode"
    static func queue(_ name: String) -> String { "relay|queue:\(name)" }
}

extension StatusData {
    /// Builds the page data. `currentQueue` is the stored choice (view.js curQueue); `estopAt` the time of the
    /// last 停止一切 in seconds (localStorage ark-remote-estop). Also writes Pending.liveVals for the switches,
    /// as view.js render() fills liveVals.
    @MainActor
    static func from(relay: Relay, live: Live, stamina: StaminaStore, pending: Pending,
                     currentQueue: String, estopAt: Int) -> StatusData {
        var d = StatusData()
        let snap = relay.snap
        let relayObj = snap?["relay"]

        // config: AUTO-MAS not running → only _错误 in it
        let cfg = snap?["config"]?.object ?? [:]
        d.configUnreadable = snap != nil && (cfg["_错误"] != nil || cfg.isEmpty)

        // device card: setStatus text split at the first 「 · 」
        let st = relay.statusText.isEmpty ? "正在读取…" : relay.statusText
        if let r = st.range(of: " · ") {
            d.deviceHead = String(st[..<r.lowerBound])
            d.deviceStatus = String(st[r.upperBound...])
        } else {
            d.deviceStatus = st
        }
        d.online = live.alive

        // notices
        d.busy = (snap?["run"]?["在跑的"]?.array ?? []).compactMap { $0.string }
        if let ef = relayObj?["刷声骸"], let until = ef["到"]?.string, !until.isEmpty {
            d.echoFarm = StatusEchoFarm(name: ef["名字"]?.string ?? "?",
                                        from: String((ef["从"]?.string ?? "").dropFirst(11)),
                                        until: String(until.dropFirst(11)))
        }

        // shifts
        d.queues = (snap?["queues"]?.array ?? []).compactMap { q in
            guard let name = q["名"]?.string else { return nil }
            return StatusQueue(name: name, scheduled: q["定时"]?.bool != false,
                               scripts: (q["脚本"]?.array ?? []).compactMap { $0.string })
        }
        d.currentQueue = d.queues.contains(where: { $0.name == currentQueue }) ? currentQueue : (d.queues.first?.name ?? currentQueue)

        // plan text: 🕘 time rows, ▸ game rows with hint lines under them
        let planText = snap?["plan"]?.string ?? ""
        let skipped = relayObj?["今天跳过"]?.jsString ?? ""
        var blocks: [StatusPlanBlock] = []
        for raw in planText.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("📅") { continue }
            if l.hasPrefix("🕘") {
                let rest = l.replacingOccurrences(of: "🕘", with: "").trimmingCharacters(in: .whitespaces)
                let pair = rest.components(separatedBy: " 东京 ")
                blocks.append(StatusPlanBlock(time: pair[0].trimmingCharacters(in: .whitespaces),
                                              tokyo: pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespaces) : "",
                                              queueName: nil, runsToday: true, games: []))
                continue
            }
            if l.hasPrefix("▸") {
                guard !blocks.isEmpty else { continue }
                blocks[blocks.count - 1].games.append(
                    StatusPlanGame(name: l.replacingOccurrences(of: "▸", with: "").trimmingCharacters(in: .whitespaces), hints: []))
                continue
            }
            if let b = blocks.indices.last, let g = blocks[b].games.indices.last { blocks[b].games[g].hints.append(l) }
        }
        if d.nextAt.isEmpty, let first = blocks.first { d.nextAt = first.time }
        for i in blocks.indices {
            let owners = blocks[i].games.compactMap { statusOwnerOf[$0.name] }.sorted().joined(separator: "|")
            if let q = d.queues.first(where: { $0.scripts.sorted().joined(separator: "|") == owners }) {
                let id = StatusSwitchID.queue(q.name)
                let on = skipped != q.name
                pending.liveVals[id] = .bool(on)
                blocks[i].queueName = q.name
                blocks[i].runsToday = pending.shownValue(for: id)?.truthy ?? on
                if let t = tagText(pending.tag(for: id)) { d.switchTags[id] = t }
            }
        }
        d.plan = blocks

        // action tiles
        if let at = relay.snapAt { d.lastUpdate = ago(at) }

        // stamina (numTiles): nil = phone not configured; [] = configured, no reading yet
        if let r = stamina.data {
            let ak = r.arknights, ef = r.endfield, ww = r.wuwa
            func full(_ g: GameStamina) -> String {
                let w = statusWhenFull(g.fullAt)
                if !w.isEmpty { return w }
                if let c = g.current, let m = g.max, c >= m { return "已满" }
                return ""
            }
            let wwSub = ww.error != nil ? "" : [statusWhenFull(ww.fullAt),
                                                "备用 \(ww.reserve.map(String.init) ?? "–")",
                                                "周本 \(ww.weekly.map(String.init) ?? "–")/\(ww.weeklyMax.map(String.init) ?? "–")"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            d.stamina = [
                StatusStamina(label: "明日方舟 理智", value: ak.current, cap: ak.max, sub: full(ak), error: ak.error),
                StatusStamina(label: "终末地 理智", value: ef.current, cap: ef.max, sub: full(ef), error: ef.error),
                StatusStamina(label: "鸣潮 波片", value: ww.waveplates, cap: ww.max, sub: wwSub, error: ww.error),
            ]
            d.staminaSource = r.takenAt
        } else if stamina.tokens != nil || stamina.loadTokens() != nil {
            d.stamina = []
        }

        // receipts, newest first
        let rcs = relayObj?["最近指令"]?.array ?? []
        d.receipts = rcs.reversed().map { r in
            StatusReceipt(ok: r["ok"]?.truthy ?? false, text: r["text"]?.jsString ?? "", at: r["at"]?.jsString ?? "")
        }

        // 停止一切 note for 6 hours
        if estopAt > 0, nowSec() - estopAt < 6 * 3600 {
            let since = Pending.hhmm(estopAt)
            let rc = rcs.reversed().first { r in
                let t = r["text"]?.jsString ?? ""
                return t.contains("停") || t.lowercased().contains("estop") || (r["at"]?.jsString ?? "") >= since
            }
            d.estopNote = StatusEstopNote(title: "已停止 · 下一趟\(d.nextAt.isEmpty ? "" : " " + d.nextAt) 照常",
                                          receipt: rc.map { "回执 \($0["at"]?.jsString ?? "")：\($0["text"]?.jsString ?? "")" }
                                              ?? "等机器回执：停干净没有以回执为准")
        }

        // 机器 switches (relayRow): value = relay[key]; shown value = the sent one while it waits
        let skipLive = relayObj?["下次别关机"]?.truthy ?? false
        pending.liveVals[StatusSwitchID.skipShutdown] = .bool(skipLive)
        d.skipShutdown = pending.shownValue(for: StatusSwitchID.skipShutdown)?.truthy ?? skipLive
        let dbg = relayObj?["调试模式"]
        let dbgLive = dbg?.truthy ?? false
        pending.liveVals[StatusSwitchID.debugMode] = .bool(dbgLive)
        let dbgShown = pending.shownValue(for: StatusSwitchID.debugMode)?.truthy ?? dbgLive
        d.debugModeUntil = dbgShown ? (dbgLive ? (dbg?.jsString ?? "") : "") : nil   // "" = on, until not reported yet
        for id in [StatusSwitchID.skipShutdown, StatusSwitchID.debugMode] {
            if let t = tagText(pending.tag(for: id)) { d.switchTags[id] = t }
        }

        // 刷 4C 声骸 boss list
        d.bosses = statusBosses

        // receipts group-header note
        let today = snap?["今天"]
        d.todayLast = today?["最近"]?.jsString ?? ""
        d.todayFailed = Int(today?["失败"]?.number ?? 0)
        return d
    }

    private static func tagText(_ tag: PendingTag?) -> String? {
        switch tag {
        case .sent(let text): return text
        case .mismatch(let text, _): return text
        case .applied(let text): return text
        case nil: return nil
        }
    }
}

/// schema.js BOSSES, from Logic/Schema.swift `bosses`.
let statusBosses: [StatusBoss] = bosses.map { StatusBoss(index: $0.index, name: $0.name) }
