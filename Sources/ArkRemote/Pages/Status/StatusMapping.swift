import Foundation

// Maps the machine's snapshot (Relay.shared.snap), the heartbeat verdict (Live), the stamina reading
// (StaminaStore) and the sent-but-unconfirmed changes (Pending) into StatusData, the way
// maa-automation/web/view.js render() builds the 状态 part (planRows(), numTiles(), relayRow()).

/// view.js OWNER_OF: game name in the plan text → script name in a shift's 脚本.
let statusOwnerOf = ["明日方舟": "MAA", "终末地": "MaaEnd", "鸣潮": "OK-WW"]

/// relay config.py GAME_PROCS / SCRIPT_PROCS (401-413) without .exe → what the user knows them as.
let statusProcName = [
    "Endfield": "终末地", "Client-Win64-Shipping": "鸣潮", "Wuthering Waves": "鸣潮启动器",
    "dnplayer": "雷电模拟器（明日方舟）", "MAA": "MAA（明日方舟）", "MaaEnd": "MaaEnd（终末地）", "ok-ww": "OK-WW（鸣潮）",
]

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
    /// last 停止一切 in seconds (localStorage ark-remote-estop).
    ///
    /// `record`: also do what view.js render() does besides drawing — fill Pending.liveVals for the switches and keep
    /// the last readable AUTO-MAS config. Only AppGlue passes true, once per adopted state. StatusTab.body must not:
    /// a write to the @Observable Pending during the view update (even of an equal value) re-ran the body, which
    /// wrote again — the 状态 tab redrew nonstop while idle (验收 10-02 19:3x: +258 frames in 10 s, 115 % CPU).
    @MainActor
    static func from(relay: Relay, live: Live, stamina: StaminaStore, pending: Pending,
                     currentQueue: String, estopAt: Int, record: Bool = false) -> StatusData {
        var d = StatusData()
        let snap = relay.snap
        let relayObj = snap?["relay"]

        // config: AUTO-MAS not running → only _错误 in it
        let cfg = snap?["config"]?.object ?? [:]
        d.configUnreadable = snap != nil && (cfg["_错误"] != nil || cfg.isEmpty)
        // view.js:323-328: a good config is kept (LS + "-config"); unreadable → the page falls back to it and says so
        if d.configUnreadable {
            d.configIsStale = statusLastGoodConfig() != nil
        } else if record, let c = snap?["config"], let at = relay.snapAt, at != statusLastGoodAt {
            statusLastGoodAt = at
            UserDefaults.standard.set(c.encodedString(), forKey: statusLastGoodKey)
        }

        // device card: setStatus text split at the first 「 · 」
        let st = relay.statusText.isEmpty ? "正在读取…" : relay.statusText
        if let r = st.range(of: " · ") {
            d.deviceHead = String(st[..<r.lowerBound])
            d.deviceStatus = String(st[r.upperBound...])
        } else {
            d.deviceStatus = st
        }
        d.online = live.alive
        d.dotOn = relay.statusState == "on"   // view.js setStatus(text, state) → #dot2 class (live.js:65-66), not the heartbeat alone
        // "off" also marks the PIN-mismatch line (StatusTab); only the 「关机 · …」 lines are the machine being off
        d.machineOff = relay.statusState == "off" && st.hasPrefix("关机")
        d.refreshing = live.busy

        // notices
        // 审查 B7: run.在跑的 is the process table at the moment of the push (phone.py:1052-1053), so it holds only while the
        // machine is on and the state is fresh (Live.freshMs): a 2-hour-old list kept 「现在跑一趟」 refused as 「正在跑别的」
        // after the machine was off. Its names are exe names (config.py:401-413, .exe dropped by snapshot.py:181): shown as
        // the games and scripts they are.
        let fresh = relay.snapAt.map { relay.serverNowMs() - Double($0) * 1000 < Live.freshMs } ?? false   // ntfy's clock (edge audit 3)
        if live.alive && fresh {
            for n in (snap?["run"]?["在跑的"]?.array ?? []).compactMap({ $0.string }) {
                let name = statusProcName[n] ?? n
                if !d.busy.contains(name) { d.busy.append(name) }
            }
        }
        if let ef = relayObj?["刷声骸"], let until = ef["到"]?.string, !until.isEmpty {
            let from = ef["从"]?.string ?? ""
            d.echoFarm = StatusEchoFarm(name: ef["名字"]?.string ?? "?",
                                        from: String(from.dropFirst(11)),
                                        until: String(until.dropFirst(11)),
                                        fromLocal: from.isEmpty ? "" : localClock(fromMachineFull: from),
                                        untilLocal: localClock(fromMachineFull: until))
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
        // view.js:232-233: 「今天跳过队列」 is a list (中继 09-30); older snapshots carry one name in 「今天跳过」
        let skipList = relayObj?["今天跳过队列"]?.array
        let skipped = skipList.map { $0.map { $0.jsString } } ?? ((relayObj?["今天跳过"]?.jsString).map { $0.isEmpty ? [] : [$0] } ?? [])
        var blocks: [StatusPlanBlock] = []
        var foot: [String] = []
        for raw in planText.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("📅") { continue }
            if l.hasPrefix("🕘") {
                let rest = l.replacingOccurrences(of: "🕘", with: "").trimmingCharacters(in: .whitespaces)
                // view.js:225 split(/\s+东京\s+/): JS \s takes the ideographic space (U+3000) the plan text puts before 东京
                // ("09:00　东京 10:00"); splitting on " 东京 " alone left it all in the time
                var time = rest, tokyo = ""
                if let r = rest.range(of: "东京"), r.lowerBound > rest.startIndex,
                   rest[rest.index(before: r.lowerBound)].isWhitespace {
                    time = String(rest[..<r.lowerBound])
                    tokyo = String(rest[r.upperBound...])
                }
                blocks.append(StatusPlanBlock(time: time.trimmingCharacters(in: .whitespaces),
                                              tokyo: tokyo.trimmingCharacters(in: .whitespaces),
                                              queueName: nil, runsToday: true, games: []))
                continue
            }
            // plan.py:674-675 ends a shift's block with 「⏻ 跑完自动关机」: it belongs to the block, not to its last game's
            // hints, where it read as that game's setting (审查 C3)
            if l.hasPrefix("⏻") {
                if let b = blocks.indices.last {
                    blocks[b].after = l.replacingOccurrences(of: "⏻", with: "").trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if l.hasPrefix("▸") {
                guard !blocks.isEmpty else { continue }
                blocks[blocks.count - 1].games.append(
                    StatusPlanGame(name: l.replacingOccurrences(of: "▸", with: "").trimmingCharacters(in: .whitespaces), hints: []))
                continue
            }
            if let b = blocks.indices.last, let g = blocks[b].games.indices.last { blocks[b].games[g].hints.append(l) }
            else if blocks.isEmpty { foot.append(l) }   // view.js:229 `else if (!cur) foot.push(l)`
        }
        for i in blocks.indices {
            let owners = blocks[i].games.compactMap { statusOwnerOf[$0.name] }.sorted().joined(separator: "|")
            // the plan names no shift, only its games: two shifts running the same games both matched and the first won,
            // so the second time row's switch sent skip_today for the first shift (edge audit 29). A tie is broken by
            // 定时 (only scheduled shifts have time rows); one still tied gets no switch rather than the wrong one.
            var hits = d.queues.filter { $0.scripts.sorted().joined(separator: "|") == owners }
            if hits.count > 1 { hits = hits.filter { $0.scheduled } }
            if hits.count == 1, let q = hits.first {
                let id = StatusSwitchID.queue(q.name)
                let on = !skipped.contains(q.name)
                if record { pending.liveVals[id] = .bool(on) }
                blocks[i].queueName = q.name
                blocks[i].runsToday = pending.shownValue(for: id)?.truthy ?? on
                if let t = tag(pending, id) { d.switchTags[id] = t }
            }
        }
        // 审查 B2: a skip engaged turns the shift's timer off (modes.py:393-396, queues.py:59-60) and plan.next_plan lists
        // only timed shifts (plan.py:136), so the row went from the plan with its switch — the one way to undo the skip here
        // (unskip_today, modes.py:467-501). A shift skipped today with no row gets one, without a time (the plan no longer
        // gives it), so it can be switched back on.
        for q in d.queues where skipped.contains(q.name) && !blocks.contains(where: { $0.queueName == q.name }) {
            let id = StatusSwitchID.queue(q.name)
            if record { pending.liveVals[id] = .bool(false) }
            blocks.append(StatusPlanBlock(time: "", tokyo: "", queueName: q.name,
                                          runsToday: pending.shownValue(for: id)?.truthy ?? false, games: []))
            if let t = tag(pending, id) { d.switchTags[id] = t }
        }
        // 审查 B3: the tile reads 「<shift> · 下一趟 <time>」, so the time is that shift's own row (blocks.first was the plan's
        // first row whatever the shift: 「晚班 · 下一趟 09:00」), on the phone's clock (the 东京 time the plan gives, B4)
        if d.nextAt.isEmpty, let mine = blocks.first(where: { $0.queueName == d.currentQueue && !$0.time.isEmpty }) {
            d.nextAt = mine.shownTime
        }
        d.plan = blocks
        d.planFoot = foot

        // action tiles
        if let at = relay.snapAt { d.lastUpdate = ago(at); d.snapAt = at }

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
            // with the day when it is not today's (审查 C2)
            d.staminaSource = stamina.takenMs > 0 ? localClockWithDay(Date(timeIntervalSince1970: stamina.takenMs / 1000)) : r.takenAt
        } else if stamina.tokens != nil || stamina.loadTokens() != nil {
            d.stamina = []
        }

        // receipts, newest first
        let rcs = relayObj?["最近指令"]?.array ?? []
        d.receipts = rcs.reversed().map { r in
            StatusReceipt(ok: r["ok"]?.truthy ?? false, text: r["text"]?.jsString ?? "", at: r["at"]?.jsString ?? "",
                          sent: r["sent"]?.jsString ?? "", action: r["action"]?.jsString ?? "",
                          queued: r["queued"]?.truthy == true,
                          atLocal: phoneStamp(fromMachine: r["at"]?.jsString ?? ""),
                          sentLocal: (r["sent"]?.jsString).map { phoneStamp(fromMachine: $0) } ?? "")
        }
        var idSeen: [String: Int] = [:]   // StatusReceipt.dup: equal minute + text must not give equal ForEach ids
        for i in d.receipts.indices {
            let k = d.receipts[i].at + d.receipts[i].text
            let n = idSeen[k] ?? 0
            d.receipts[i].dup = n
            idSeen[k] = n + 1
        }
        // view.js:418-438: a skip receipt is the machine's answer at that moment, not what holds now. Per day and queue only
        // the last successful skip / unskip stays; earlier ones go grey with what replaced them, and a today's one that the
        // snapshot's 「今天跳过队列」 contradicts goes grey with what holds now. The queue is the first 「…」 in the text.
        let todayMD = String(statusBeijingToday().dropFirst(5))
        var lastOk: [String: StatusReceipt] = [:]
        var skipToday = false
        for i in d.receipts.indices {
            let r = d.receipts[i]
            guard r.action == "skip_today" || r.action == "unskip_today",
                  let q = statusFirstQuoted(r.text) else { continue }
            let day = String(r.at.prefix(5)), key = day + "|" + q
            if day == todayMD { skipToday = true }
            // a queued skip (D207) has not run: it neither replaces the one before nor answers for today yet
            if !r.ok || r.queued { continue }
            if let later = lastOk[key] {
                d.receipts[i].note = "已被 \(String(later.shownAt.dropFirst(6))) 的「\(later.action == "skip_today" ? "跳过" : "取消跳过")\(q)」取代"
                continue
            }
            lastOk[key] = r
            if day == todayMD && (r.action == "skip_today") != skipped.contains(q) {
                d.receipts[i].note = "机器现在：\(q)今天\(skipped.contains(q) ? "跳过" : "照常")"
            }
        }
        // view.js:439-440 nowRow: what each shift does today, while a skip is in play
        if (skipToday || !skipped.isEmpty) && !d.queues.isEmpty {
            d.todayActual = d.queues.map { "\($0.name) \(skipped.contains($0.name) ? "跳过" : "照常")" }.joined(separator: " · ")
        }
        // the 回执 page groups by the phone's day (shownAt), so today's group is the phone's today
        let md = Calendar.current.dateComponents([.month, .day], from: Date())
        d.receiptsToday = "\(pad2(md.month ?? 0))-\(pad2(md.day ?? 0))"

        // 停止一切 note for 6 hours
        if estopAt > 0, nowSec() - estopAt < 6 * 3600 {
            // view.js:379-383: this press's answer = an estop receipt stamped (Beijing "MM-DD HH:MM") at or after the press
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            f.dateFormat = "MM-dd HH:mm"
            // the press on ntfy's clock (Relay.clockSkewMs): a phone running fast stamped it after the machine's receipt
            let pressed = f.string(from: Date(timeIntervalSince1970: TimeInterval(estopAt) + relay.clockSkewMs / 1000))
            let rc = rcs.reversed().first { r in
                let at = r["at"]?.jsString ?? ""
                // "MM-dd" has no year: a receipt in January answers a press on 12-31 (the window is 6 hours)
                return r["action"]?.jsString == "estop" && (at >= pressed || (pressed.hasPrefix("12-") && at.hasPrefix("01-")))
            }
            // 「下一趟」 here is the next run whatever the shift: the first timed row still to come today on the machine's
            // clock, else tomorrow's first (审查 B3), on the phone's clock (B4)
            let timed = d.plan.filter { !$0.time.isEmpty && $0.runsToday }
            let now = machineNowHHMM()
            let next = (timed.first(where: { $0.time > now }) ?? timed.first).map { $0.shownTime } ?? ""
            let head = rc == nil ? "已下令停止 · 等机器回执"
                : (rc?["ok"]?.truthy ?? false) ? "已停止 · 下一趟\(next.isEmpty ? "" : " " + next) 照常" : "没停干净 · 见下方回执"
            d.estopNote = StatusEstopNote(title: head,
                                          receipt: rc.map { "回执 \(phoneStamp(fromMachine: $0["at"]?.jsString ?? ""))：\($0["text"]?.jsString ?? "")" }
                                              ?? "等机器回执：停干净没有以回执为准")
        }

        // 机器 switches (relayRow): value = relay[key]; shown value = the sent one while it waits
        let skipLive = relayObj?["下次别关机"]?.truthy ?? false
        if record { pending.liveVals[StatusSwitchID.skipShutdown] = .bool(skipLive) }
        d.skipShutdown = pending.shownValue(for: StatusSwitchID.skipShutdown)?.truthy ?? skipLive
        let dbg = relayObj?["调试模式"]
        let dbgLive = dbg?.truthy ?? false
        if record { pending.liveVals[StatusSwitchID.debugMode] = .bool(dbgLive) }
        let dbgShown = pending.shownValue(for: StatusSwitchID.debugMode)?.truthy ?? dbgLive
        // "" = on, until not reported yet. The relay's "YYYY-MM-DD HH:MM" is Beijing (modes.py:217): shown on the phone's
        // clock with the day (「明天 09:30」), as the page's other times (审查 A1 / B4)
        d.debugModeUntil = dbgShown ? (dbgLive ? localClock(fromMachineFull: dbg?.jsString ?? "") : "") : nil
        for id in [StatusSwitchID.skipShutdown, StatusSwitchID.debugMode] {
            if let t = tag(pending, id) { d.switchTags[id] = t }
        }

        // 刷 4C 声骸 boss list
        d.bosses = statusBosses

        // receipts group-header note
        let today = snap?["今天"]
        d.todayLast = today?["最近"]?.jsString ?? ""
        d.todayFailed = Int(today?["失败"]?.number ?? 0)
        return d
    }

    /// pending.js:50-73: the small line under a row. Past 10 h without a receipt the line is 「没回执 · 已寄出 HH:MM」 with
    /// 「再发一次」 (pending.js:58-59: resent only by a tap, never automatically).
    @MainActor private static func tag(_ pending: Pending, _ id: String) -> StatusTag? {
        switch pending.tag(for: id) {
        case .sent(let text): return .sent(text, again: pending.staleResendKey(for: id) != nil)
        case .mismatch(let text, _): return .bad(text)
        case .applied(let text): return .applied(text)
        case nil: return nil
        }
    }
}

/// view.js `/「([^」]+)」/.exec(text)[1]`: the first non-empty 「…」 in the text, nil when there is none.
func statusFirstQuoted(_ text: String) -> String? {
    var from = text.startIndex
    while let a = text.range(of: "「", range: from..<text.endIndex) {
        guard let b = text.range(of: "」", range: a.upperBound..<text.endIndex) else { return nil }
        if a.upperBound < b.lowerBound { return String(text[a.upperBound..<b.lowerBound]) }
        from = a.upperBound
    }
    return nil
}

/// view.js lastGoodConfig: the last readable AUTO-MAS config, localStorage LS + "-config".
let statusLastGoodKey = "ark-remote-cfg-config"
@MainActor var statusLastGoodAt: Int? = nil
func statusLastGoodConfig() -> JSONValue? {
    guard let raw = UserDefaults.standard.string(forKey: statusLastGoodKey), let v = try? JSONValue.parse(raw), !v.isNull else { return nil }
    return v
}

/// schema.js BOSSES, from Logic/Schema.swift `bosses`.
let statusBosses: [StatusBoss] = bosses.map { StatusBoss(index: $0.index, name: $0.name) }
