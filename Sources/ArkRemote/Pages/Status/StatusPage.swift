import SwiftUI

/// The 状态 tab as a grouped list (HIG Lists and tables: "Prefer displaying text in a list or table."), in order: the
/// machine, what runs now and the running 刷声骸, the 月卡 reminder, the two commands, 理智, the 停止一切 note, the shift
/// picker, 这一趟, 刷 4C 声骸, 机器 switches, 月卡, 明日安排, 机器最近的回执. Switches and pickers apply when changed
/// (StatusCommands.apply); what is on its way shows in its own row (StatusOutbox).
struct StatusPage: View {
    var data: StatusData
    var actions = StatusActions()
    var outbox = StatusOutbox()
    /// The page's data as of now, for the 「查看全部」 page: skip-ui keeps the first navigationDestination closure a stack
    /// collects (Navigation.swift:869-872, NavigationDestination.equals is always true), so one capturing `data` showed
    /// the receipts of the App's first draw, even pushed afresh (test pass 1, 问题 9). nil: `data` (previews).
    var live: (() -> StatusData)? = nil

    @State var bossIndex = 1
    @State var echoUntil = "08:30"
    /// The running farm's end time as last picked, while the machine has not reported it yet ("" = the machine's).
    @State var echoNewUntil = ""
    #if os(Android)
    /// MonthCardStore.today(), renewed at each Beijing midnight so 还剩 X 天 recounts (edge audit 22); iOS: TimelineView.
    @State var today = MonthCardStore.today()
    @ScaledMetric private var dotSide: CGFloat = 10
    @ScaledMetric private var stopSide: CGFloat = 14
    #endif
    /// The game's own resource icon beside its 理智 row, scaled with Dynamic Type (HIG Typography).
    @ScaledMetric private var resIcon: CGFloat = 30
    /// A reselect of the 状态 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.status }

    var body: some View {
        #if os(Android)
        page(today: today)
            .task {
                // skip-fuse-ui has no TimelineView (none in Sources/SkipSwiftUI): sleep to the next Beijing midnight
                while !Task.isCancelled {
                    let wait = max(1, statusNextBeijingMidnight().timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    today = MonthCardStore.today()
                }
            }
        #else
        // MonthCardStore.today() is the Beijing day: redrawn at each Beijing midnight, so 还剩 X 天 recounts (edge audit 22)
        TimelineView(.periodic(from: statusNextBeijingMidnight(), by: 86_400)) { _ in
            page(today: MonthCardStore.today())
        }
        #endif
    }

    private func page(today: String) -> some View {
        List {
            deviceSection
            notices
            // view.js:362: the 月卡 0–5 days reminder, after the notices
            MonthCardReminder(today: today)
            commands
            staminaSection
            // top-level conditional sections go through listSection (Pages/Shell/SkipFixes.swift): a bare `if` leaves
            // an empty grey section on Android
            listSection("status-estop", ifLet: data.estopNote) { note in
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).foregroundStyle(.red)
                        Text(note.receipt).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            shiftPicker
            thisShift
            echoFarmStart
            machineSection
            // view.js:404: the 月卡 rows, after the 机器 section and before 明日安排
            MonthCardRows(today: today)
            tomorrow
            receiptsSection
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. skip-ui's ScrollViewProxy reaches rows only (LazySupport.swift:250-288; a section header is a
        // count, :283), and the List's top inset and the first section's top are lazy items of their own before the
        // first row (List.swift:537-541, :438-470), so scrollTo(the first row) left them above the screen (0.4.4 final
        // pass, replay step 40). .id resets the remembered list state through key() (AdditionalViewModifiers.swift:
        // 1730-1750). No animation.
        .id(reselect)
        // 「查看全部」 and the 月卡 rows push by value (StatusRoute), so ContentView's path can pop them on a reselect (D39).
        // On the List, not a Section or row: skip-ui's List finds its sections by type (MonthCardRows.swift), and SwiftUI
        // wants navigationDestination outside lazy containers.
        .navigationDestination(for: StatusRoute.self) { route in
            switch route {
            case .receipts:
                StatusReceiptsPage(data: live ?? { [data] in data })
            case .monthCard(let g):
                MonthCardPage(game: g)
            }
        }
        // the machine reported the farm's end time: the picker follows it again
        .onChange(of: data.echoFarm?.until) { _, _ in echoNewUntil = "" }
    }

    // MARK: rows shared by the sections

    /// A row's title with a secondary line under it (the subtitle of a list row).
    private func titled(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// The state of a switch's order (pending.js:50-73), as secondary text in its row; red when it did not take.
    @ViewBuilder private func tagLine(_ id: String) -> some View {
        if outbox.sending[id] != nil {
            Text("正在寄出…").font(.footnote).foregroundStyle(.secondary)
        } else if let why = outbox.failed[id] {
            Text(why).font(.footnote).foregroundStyle(.red)   // EWSave.send's sentence: 「没发出去（…）。」
        } else {
            switch data.switchTags[id] {
            case .applied(let t)?, .sent(let t, _)?:
                Text(t).font(.footnote).foregroundStyle(.secondary)
            case .bad(let t)?:
                Text(t).font(.footnote).foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    /// 「再发一次」 is offered past 10 h without a receipt or after a receipt that did not match (pending.js:58-59; only by
    /// the user's own act, never automatically).
    private func canResend(_ id: String) -> Bool {
        guard outbox.sending[id] == nil else { return false }
        switch data.switchTags[id] {
        case .sent(_, let again)?: return again
        case .bad?: return true
        default: return false
        }
    }

    /// A switch row: disabled while its order is on its way; 「再发一次」 as the row's swipe action and context menu.
    @ViewBuilder private func switchRow<Row: View>(_ id: String, _ row: Row) -> some View {
        if canResend(id) {
            row
                .disabled(outbox.sending[id] != nil)
                .swipeActions { Button("再发一次") { actions.resend(id) } }
                .contextMenu { Button("再发一次") { actions.resend(id) } }
        } else {
            row.disabled(outbox.sending[id] != nil)
        }
    }

    // MARK: the machine

    private var deviceSection: some View {
        Section {
            Label {
                titled(data.deviceHead.isEmpty ? data.deviceName : "\(data.deviceName) · \(data.deviceHead)", data.deviceStatus)
            } icon: {
                // a ping is running (pull to refresh, or the page's own): the progress in place of the dot
                if data.refreshing { ProgressView() } else { deviceDot }
            }
        }
    }

    /// Green while the machine is on (setStatus state "on"), else grey; the text beside it says the state.
    @ViewBuilder private var deviceDot: some View {
        #if os(Android)
        // circle.fill is not in skip-ui's symbol table (Image.swift composeSymbolName; it would draw a warning triangle)
        Circle().fill(data.dotOn ? Color.green : Color.gray.opacity(0.5)).frame(width: dotSide, height: dotSide)
            .accessibilityHidden(true)
        #else
        Image(systemName: "circle.fill").imageScale(.small)
            .foregroundStyle(data.dotOn ? Color.green : Color.secondary)
            .accessibilityHidden(true)
        #endif
    }

    // MARK: notices

    @ViewBuilder private var notices: some View {
        listSection("status-busy", if: !data.busy.isEmpty && data.online) {
            Section {
                Text(data.busy.joined(separator: "、"))
            } header: {
                Text("现在在跑")
            } footer: {
                Text("这时改的设置要等跑完才生效。")
            }
        }
        listSection("status-echofarm", ifLet: data.echoFarm) { ef in
            Section {
                LabeledContent("正在刷", value: ef.name)
                // echofarm.py retime (363-384) resolves the time like a start: one already past is tomorrow's (审查 A2).
                // Applied when picked (StatusActions.changeEchoFarmUntil), no confirm.
                DatePicker("刷到（机器时间）",
                           selection: hhmmBinding(echoNewUntil.isEmpty ? ef.until : echoNewUntil, fallback: ef.until) { v in
                               echoNewUntil = v
                               actions.changeEchoFarmUntil(v)
                           },
                           displayedComponents: .hourAndMinute)
                Button("提前收工", role: .destructive) { actions.stopEchoFarm() }
            } header: {
                Text("刷声骸")
            } footer: {
                // the phone's clock, with the machine's 到 the picker uses (审查 B4)
                Text("按手机时间 \(ef.untilLocal) 收工" + (ef.fromLocal.isEmpty ? "" : "，\(ef.fromLocal) 开始") + "。已经过了的时刻算明天。")
            }
        }
    }

    // MARK: commands

    private var commands: some View {
        Section {
            Button { actions.runNow() } label: {
                Label {
                    titled("现在跑一趟", !data.busy.isEmpty ? "正在跑 \(data.busy.joined(separator: "、"))，跑完再派"
                           : data.currentQueue.isEmpty ? "" : data.nextAt.isEmpty ? data.currentQueue
                           : "\(data.currentQueue) · 下一趟 \(data.nextAt)")
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            // HIG Alerts: "Avoid using an alert merely to provide information." The reason is the row's subtitle.
            .disabled(!data.busy.isEmpty)
            Button(role: .destructive) { actions.stopAll() } label: {
                Label {
                    titled("停止一切", data.machineOff ? "机器关着，没有在跑的" : "脚本和游戏")
                } icon: {
                    stopIcon
                }
            }
            .disabled(data.machineOff)
        }
    }

    @ViewBuilder private var stopIcon: some View {
        #if os(Android)
        // no Material stop icon in skip-ui's symbol table: the filled square drawn
        RoundedRectangle(cornerRadius: 2).fill(data.machineOff ? Color.gray : Color.red).frame(width: stopSide, height: stopSide)
        #else
        Image(systemName: "stop.fill")
        #endif
    }

    // MARK: stamina

    /// One row per game: the resource's own icon (view.js:266 RES → Module.xcassets res-ak / res-ef / res-ww), the value
    /// with its cap, and when it is full under the name. Before the first reading the rows show redacted placeholders
    /// (HIG Loading: "consider showing placeholder text, graphics, or animations as content loads").
    @ViewBuilder private var staminaSection: some View {
        listSection("status-stamina", ifLet: data.stamina) { tiles in
            let loading = tiles.isEmpty
            Section {
                ForEach(loading ? Self.staminaPlaceholders : tiles) { t in staminaRow(t, loading: loading) }
            } footer: {
                if loading { Text("正在读取…") }
                else if !data.staminaSource.isEmpty { Text("\(data.staminaSource) 读取") }
            }
        }
    }

    private static let staminaPlaceholders = ["明日方舟 理智", "终末地 理智", "鸣潮 波片"].map {
        StatusStamina(label: $0, value: 100, cap: 100, sub: "今天 00:00 回满")
    }
    private static let staminaIcon = ["明日方舟 理智": "res-ak", "终末地 理智": "res-ef", "鸣潮 波片": "res-ww"]
    private static let staminaColour: [String: Color] = ["明日方舟 理智": .blue, "终末地 理智": .orange, "鸣潮 波片": .teal]

    private func staminaRow(_ t: StatusStamina, loading: Bool) -> some View {
        LabeledContent {
            if t.error == nil {
                Text(t.value.map { v in t.cap.map { "\(v)/\($0)" } ?? "\(v)" } ?? "–")
                    .digitsMonospaced()
                    .foregroundStyle(Self.staminaColour[t.label] ?? Color.blue)
                    .redacted(reason: loading ? .placeholder : [])
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label)
                    if let err = t.error {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    } else if !t.sub.isEmpty {
                        Text(t.sub).font(.footnote).foregroundStyle(.secondary)
                            .redacted(reason: loading ? .placeholder : [])
                    }
                }
            } icon: {
                decorativeImage(Self.staminaIcon[t.label] ?? "res-ak").resizable().scaledToFit()
                    .frame(width: resIcon, height: resIcon)   // t.label names it
            }
        }
    }

    // MARK: shift

    @ViewBuilder private var shiftPicker: some View {
        listSection("status-shift", if: !data.queues.isEmpty) {
            let unscheduled = data.queues.filter { !$0.scheduled }.map { $0.name }
            Section {
                // HIG Segmented controls: "Use nouns or noun phrases for segment labels."
                Picker("班次", selection: Binding(get: { data.currentQueue }, set: { actions.selectQueue($0) })) {
                    ForEach(data.queues) { q in Text(q.name).tag(q.name) }
                }
                .pickerStyle(.segmented)
            } footer: {
                if !unscheduled.isEmpty { Text("\(unscheduled.joined(separator: "、"))未启用定时。") }
            }
        }
    }

    // MARK: plan (这一趟 / 明日安排)

    @ViewBuilder private func planRows(_ blocks: [StatusPlanBlock]) -> some View {
        ForEach(blocks) { b in
            if let q = b.queueName {
                switchRow(StatusSwitchID.queue(q),
                          Toggle(isOn: Binding(get: { b.runsToday }, set: { actions.setRunsToday(q, $0) })) {
                              VStack(alignment: .leading, spacing: 2) {
                                  // a skipped shift's row has no time (StatusMapping, 审查 B2); the lead time is 东京 (B4)
                                  Text(b.shownTime.isEmpty ? q : "\(q) · \(b.shownTime)")
                                  let sub = [b.machineNote, b.after].filter { !$0.isEmpty }.joined(separator: " · ")
                                  if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
                                  tagLine(StatusSwitchID.queue(q))
                              }
                          })
            } else {
                titled(b.shownTime, [b.machineNote, b.after].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            // ids carry the block: the same game sits in several blocks (这一趟 and 明日安排), and skip-ui keys a List's
            // rows by ForEach id, so two equal ids crash its LazyColumn ("Key … was already used")
            ForEach(b.games.map { StatusPlanGameRow(block: b.id, game: $0) }) { r in
                titled(r.game.name, r.game.hints.joined(separator: "，"))
            }
        }
    }

    /// HIG Writing: "Describe what it does when turned on, and people can infer the opposite."
    private static let switchFoot = "开着的时刻今天照常跑；改动只管今天。"

    @ViewBuilder private var thisShift: some View {
        let mine = data.plan.filter { $0.queueName != nil && $0.queueName == data.currentQueue }
        Section {
            if mine.isEmpty {
                let scripts = data.queues.first(where: { $0.name == data.currentQueue })?.scripts ?? []
                titled(data.currentQueue.isEmpty ? "班次" : data.currentQueue,
                       scripts.isEmpty ? "机器还没上报排班" : scripts.map { StatusData.ownerName[$0] ?? $0 }.joined(separator: " → "))
            } else {
                planRows(mine)
            }
        } header: {
            Text("这一趟")
        } footer: {
            if !mine.isEmpty { Text(Self.switchFoot) }
        }
    }

    @ViewBuilder private var tomorrow: some View {
        let rest = data.plan.filter { $0.queueName == nil || $0.queueName != data.currentQueue }
        listSection("status-tomorrow", if: !rest.isEmpty) {
            Section {
                planRows(rest)
            } header: {
                Text("明日安排")
            } footer: {
                Text((data.planFoot + [Self.switchFoot]).joined(separator: "\n"))   // view.js:259 foot lines + the switch note
            }
        }
    }

    // MARK: 刷 4C 声骸 (start; the running farm is in the notices)

    @ViewBuilder private var echoFarmStart: some View {
        listSection("status-echo-start", if: data.echoFarm == nil) {
            Section {
                Picker("打哪个", selection: $bossIndex) {
                    ForEach(data.bosses) { b in Text("\(b.index). \(b.name)").tag(b.index) }
                }
                .pickerStyle(.menu)
                DatePicker("刷到（机器时间）", selection: hhmmBinding(echoUntil, fallback: "08:30") { echoUntil = $0 },
                           displayedComponents: .hourAndMinute)
                // started while the machine is off it would run at the next boot with the time resolved then (审查 A3)
                Button("开始刷") { actions.startEchoFarm(bossIndex, echoUntil) }
                    .disabled(data.machineOff)
            } header: {
                Text("刷 4C 声骸")
            } footer: {
                Text((data.machineOff ? "机器关着，开机后才能开始。" : "")
                     + "序号＝「讨伐强敌」列表从上往下数；刷的期间不花波片、不领周本奖励。到点自动收工、配置还原，已经过了的时刻算明天。")
            }
        }
    }

    /// A machine time 「HH:MM」 (sent as is, statusTimeHHMM) as the Date a time picker shows, and back. The same calendar
    /// both ways, on today's date in the phone's zone, so the picker shows exactly the stored 「HH:MM」 (the field is the
    /// machine's clock, but only its digits matter here: no zone conversion). `set` gets each new 「HH:MM」.
    private func hhmmBinding(_ value: String, fallback: String, set: @escaping (String) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let hm = (statusTimeHHMM(value) ?? statusTimeHHMM(fallback) ?? "08:30").split(separator: ":")
                let cal = Calendar.current
                return cal.date(bySettingHour: Int(hm[0]) ?? 8, minute: Int(hm[1]) ?? 30, second: 0,
                                of: cal.startOfDay(for: Date())) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let v = "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
                if v != statusTimeHHMM(value) { set(v) }
            }
        )
    }

    // MARK: 机器 (schema.js RELAY_SWITCHES, tab 状态)

    private var machineSection: some View {
        Section {
            switchRow(StatusSwitchID.skipShutdown,
                      Toggle(isOn: Binding(get: { data.skipShutdown }, set: { actions.setSkipShutdown($0) })) {
                          VStack(alignment: .leading, spacing: 2) {
                              Text("下次跑完不关机")
                              Text("只跳过下一次关机，再下一趟照常关").font(.footnote).foregroundStyle(.secondary)
                              tagLine(StatusSwitchID.skipShutdown)
                          }
                      })
            switchRow(StatusSwitchID.debugMode,
                      Toggle(isOn: Binding(get: { data.debugModeUntil != nil }, set: { actions.setDebugMode($0) })) {
                          VStack(alignment: .leading, spacing: 2) {
                              Text("调试模式")
                              Text(data.debugModeUntil.flatMap { $0.isEmpty ? nil : "到 \($0) 为止，跑完不关机" } ?? debugModeRule)
                                  .font(.footnote).foregroundStyle(.secondary)
                              tagLine(StatusSwitchID.debugMode)
                          }
                      })
        } header: {
            Text("机器")
        } footer: {
            // view.js:322-325 cfgNote: AUTO-MAS unreadable, and whether a last good config stands in
            if data.configUnreadable {
                // set_config fails at once when AUTO-MAS does not answer (commands.py:338-341), it is not held (审查 B16)
                warningLabel(data.configIsStale ? "读不到 AUTO-MAS 的配置（它没在运行？）——下面显示的是上次读到的；它没在运行时改的会失败，看回执"
                                                : "读不到 AUTO-MAS 的配置（它没在运行？）")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: receipts

    /// The last one-shot order until a newer receipt answers it; a failed one stays until the next order.
    private var shownShot: StatusShot? {
        guard let s = outbox.shot else { return nil }
        return s.failure != nil || data.receipts.first?.id == s.head ? s : nil
    }

    @ViewBuilder private var receiptsSection: some View {
        let shot = shownShot
        listSection("status-receipts", if: !data.receipts.isEmpty || shot != nil) {
            let note = [data.todayLast.isEmpty ? "" : "最近一趟 \(data.todayLast)",
                        data.todayFailed > 0 ? "失败 \(data.todayFailed) 趟" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            Section {
                if let shot { shotRow(shot) }
                // view.js:458 nowRow sits above the newest three
                if let actual = data.todayActual { todayActualRow(actual) }
                ForEach(data.receipts.prefix(3)) { r in receiptRow(r, at: r.shownAt) }
                if data.receipts.count > 3 {
                    // by value (StatusRoute.receipts; the page is built in body's navigationDestination), so a reselect can pop it
                    NavigationLink(value: StatusRoute.receipts) {
                        LabeledContent("查看全部", value: "\(data.receipts.count) 条")
                    }
                }
            } header: {
                Text("机器最近的回执")
            } footer: {
                if !note.isEmpty { Text(note) }
            }
        }
    }

    /// The order just sent (or not), in the place its receipt will appear (HIG Feedback: "Consider integrating status
    /// feedback into your interface.").
    private func shotRow(_ s: StatusShot) -> some View {
        LabeledContent {
            Text(s.at).foregroundStyle(.secondary)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.what)
                    Text(s.failure.map { "没寄出：\($0)" } ?? "已寄出，等机器回执")
                        .font(.footnote).foregroundStyle(s.failure == nil ? Color.secondary : Color.red)
                }
            } icon: {
                Image(systemName: s.failure == nil ? "paperplane" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.failure == nil ? Color.secondary : Color.red)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The next midnight of the Beijing day MonthCardStore.today() counts (UTC+8, no daylight saving).
func statusNextBeijingMidnight() -> Date {
    let day = 86_400.0, shift = 8 * 3600.0
    let now = Date().timeIntervalSince1970
    return Date(timeIntervalSince1970: ((now + shift) / day).rounded(.down) * day + day - shift)
}

/// A game row of one plan block (planRows); see the ForEach there for why the id includes the block.
private struct StatusPlanGameRow: Identifiable {
    var block: String
    var game: StatusPlanGame
    var id: String { block + "/" + game.id }
}

/// A receipt shows its whole text, wrapping onto as many lines as it needs (user, 10-02 20:49: a cut-off receipt, with
/// or without an ellipsis, hides the information). The icon and the time keep their width (time never wraps); only the
/// text gives way. The time is 「HH:MM 发出 · <at> 执行」 when the send time differs (view.js rcWhen); a skip receipt that
/// no longer holds is grey with the reason under it (view.js:451-452).
func receiptRow(_ r: StatusReceipt, at: String) -> some View {
    // a long time (「18:04 发出 · 10-05 18:05 执行」) goes under the text: kept on the right beside a two-line text it
    // overran the text and the card on Android (test pass 4, receipt-row-overlap.png)
    let when = r.when(at)
    let below = when.contains(" 发出 · ")   // StatusModels.swift:78, the two-time form
    return HStack {
        ReceiptIcon(r: r).fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 2) {
            Text(r.text).foregroundStyle(r.note == nil ? Color.primary : Color.secondary)
            if let note = r.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if below { Text(when).font(.footnote).foregroundStyle(.secondary) }
        }
        Spacer()
        if !below {
            Text(when).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// view.js nowRow: 「今天实际」 with each shift's 跳过 / 照常 today as the row's value.
func todayActualRow(_ actual: String) -> some View {
    LabeledContent("今天实际", value: actual)
}

/// A receipt's ✓ / ✕: the receipt text does not say whether it went through, so the icon carries it and is named
/// (accessibilityLabel docs: "a view that doesn't display text, like an icon").
struct ReceiptIcon: View {
    var r: StatusReceipt
    #if os(Android)
    /// sized to the Material CheckCircle beside it: a 13 pt disc in a 16 pt box (measured on the emulator)
    @ScaledMetric private var disc: CGFloat = 13
    @ScaledMetric private var box: CGFloat = 16
    @ScaledMetric private var glyph: CGFloat = 8
    #endif

    var body: some View {
        if r.note != nil {
            // a stale skip receipt: the icon goes grey with its row; only successful receipts get a note
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.secondary).accessibilityLabel("成功")
        } else if r.ok {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).accessibilityLabel("成功")
        } else {
            #if os(Android)
            // no Material cancel icon in skip-ui's symbol table: a red disc with the mapped xmark
            ZStack {
                Circle().fill(Color.red).frame(width: disc, height: disc)
                // sized as an image, not a font: skip-ui draws a resizable symbol through a painter that fills its frame
                // (Components/Image.swift RenderScaledImageVector, .stretch), and @ScaledMetric keeps it growing with
                // Dynamic Type
                Image(systemName: "xmark").resizable().scaledToFit().frame(width: glyph, height: glyph)
                    .foregroundStyle(Color.white)
                    .accessibilityHidden(true)
            }
            .frame(width: box, height: box)
            .accessibilityLabel("失败")
            #else
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red).accessibilityLabel("失败")
            #endif
        }
    }
}

/// The pages the 状态 tab pushes, as values on the tab's NavigationPath (ContentView), so a reselect of the tab can pop
/// them (D39). On Android an enum with a payload is a sealed class: the destination lookup keyed by StatusRoute.self finds
/// a case's subclass through its superclasses (skip-ui Navigation.swift:1163-1175).
enum StatusRoute: Hashable {
    /// 「查看全部」 → StatusReceiptsPage.
    case receipts
    /// A 月卡 row → MonthCardPage(game:).
    case monthCard(String)
}

/// 「查看全部」: reads the data in its own body (StatusPage.live), so it follows the machine's newest state on Android too.
struct StatusReceiptsPage: View {
    var data: () -> StatusData

    var body: some View {
        let d = data()
        StatusReceiptsList(receipts: d.receipts, todayActual: d.todayActual, today: d.receiptsToday)
    }
}

/// Every receipt grouped by day (receipts carry only 月-日).
struct StatusReceiptsList: View {
    var receipts: [StatusReceipt]
    /// view.js:463 the 今天实际 row heads today's group (`g.d === today ? nowRow : ""`).
    var todayActual: String? = nil
    var today = ""

    /// The App's own language for the day headers (「9月17日」), as every other string on the page.
    private static let zh = Locale(identifier: "zh_CN")

    private var days: [String] {
        var seen: [String] = []
        for r in receipts { let d = String(r.shownAt.prefix(5)); if !seen.contains(d) { seen.append(d) } }
        return seen
    }

    /// "MM-DD" as a date header, through the system date format. The year is this one, or last year's for a day still
    /// ahead (a December receipt read in January).
    private func dayName(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 2, let m = Int(p[0]), let day = Int(p[1]) else { return d }
        let cal = Calendar.current
        let now = Date()
        var c = DateComponents()
        c.year = cal.component(.year, from: now)
        c.month = m
        c.day = day
        guard var date = cal.date(from: c) else { return d }
        if date > now.addingTimeInterval(86_400), let prev = cal.date(byAdding: .year, value: -1, to: date) { date = prev }
        return date.formatted(.dateTime.month().day().locale(Self.zh))
    }

    var body: some View {
        List {
            ForEach(days, id: \.self) { d in
                Section(dayName(d)) {
                    if d == today, let actual = todayActual { todayActualRow(actual) }
                    ForEach(receipts.filter { $0.shownAt.hasPrefix(d) }) { r in receiptRow(r, at: String(r.shownAt.dropFirst(6))) }
                }
            }
        }
        .navigationTitle("回执")   // view.js:1162 openPage("回执", …)
        .refreshable { await Live.shared.ping() }
    }
}
