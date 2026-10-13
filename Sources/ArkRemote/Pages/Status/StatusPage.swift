import SwiftUI

/// The 状态 tab: same blocks, rows and wording as the web page (maa-automation/web/view.js render(), 状态 part), in order:
/// device card, notices (现在在跑 / 刷声骸), action tiles, stamina, 停止一切 note, shift segmented control, 这一趟,
/// 刷 4C 声骸, 机器 switches, 明日安排, 机器最近的回执. Standard controls only; Skip maps them to Android ones.
struct StatusPage: View {
    var data: StatusData
    var actions = StatusActions()
    /// The page's data as of now, for the 「查看全部」 page: skip-ui keeps the first navigationDestination closure a stack
    /// collects (Navigation.swift:869-872, NavigationDestination.equals is always true), so one capturing `data` showed
    /// the receipts of the App's first draw, even pushed afresh (test pass 1, 问题 9). nil: `data` (previews).
    var live: (() -> StatusData)? = nil

    @State var bossIndex = 1
    @State var echoUntil = "08:30"
    @State var echoNewUntil = ""
    /// The question of the command button just pressed, shown as a confirmationDialog drawn from that button (`StatusAsking`;
    /// reference P10 / N9: Calendar's discard confirmation; HIG Action sheets "Use an action sheet — not an alert — to
    /// offer choices related to an intentional action").
    @State var confirm: StatusAsk? = nil
    /// Android only: bumped every 30 s so 「X 分钟前」 and the 月卡 day count follow the clock (iOS: TimelineView in body).
    @State var tick = 0
    /// Sizes that follow Dynamic Type (HIG Typography; ScaledMetric): the resource icon of a stamina tile, and the
    /// Android-only machine dot (no computer symbol in skip-ui's Material table, Components/Image.swift).
    @ScaledMetric(relativeTo: .title2) var resIcon: CGFloat = 30
    @ScaledMetric(relativeTo: .body) var dotSide: CGFloat = 10
    /// A reselect of the 状态 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.status }

    var body: some View {
        #if os(Android)
        // skip-ui's TimelineView is commented out (Animation/Timeline.swift:3) and skip-fuse-ui has none
        page.task {
            let wait = 30.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                tick &+= 1
            }
        }
        #else
        // 「X 分钟前」 and the 月卡 day count are redrawn every 30 s by the system's schedule, not a timer of ours
        TimelineView(.periodic(from: .now, by: 30)) { _ in page }
        #endif
    }

    private var page: some View {
        let _ = tick
        return List {
            deviceCard
            notices
            // view.js:362: the 月卡 0–5 days reminder card, after the notices and before the tiles (Pages/Status/MonthCard*.swift)
            MonthCardReminder(today: MonthCardStore.today())
            actionTiles
            staminaSection
            // top-level conditional sections go through listSection (Pages/Shell/SkipFixes.swift): a bare `if` leaves
            // an empty grey section on Android
            listSection("status-estop", ifLet: data.estopNote) { note in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).foregroundStyle(.red)   // index.html:766 .estopnote .row label{color:var(--bad)}
                        Text(note.receipt).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            listSection("status-shift", if: !data.queues.isEmpty) {
                Section {
                    Picker("班次", selection: Binding(get: { data.currentQueue }, set: { actions.selectQueue($0) })) {
                        ForEach(data.queues) { q in
                            Text(q.scheduled ? q.name : "\(q.name)（未启用定时）").tag(q.name)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            thisShift
            echoFarmSection
            machineSection
            // view.js:404: the 月卡 rows, after the 机器 section (and its config note) and before 明日安排
            MonthCardRows(today: MonthCardStore.today())
            tomorrow
            receiptsSection
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. skip-ui's ScrollViewProxy reaches rows only (LazySupport.swift:250-288; a section header is a
        // count, :283), and the List's top inset and the first section's top (its rounded corners) are lazy items of
        // their own before the first row (List.swift:537-541, :438-470), so scrollTo(the device card) left them above
        // the screen: the card's top edge cut under 「游戏机遥控」 (0.4.4 final pass, replay step 40). skip-ui's own
        // scroll to item 0 (List.swift:233-237) runs only from a tap on the top bar (Navigation.swift:411-413).
        // .id resets the remembered list state through key() (AdditionalViewModifiers.swift:1730-1750). No animation.
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
        // Android: a tap outside the time fields or back with the keyboard up checks them, as the web input's blur
        // (view.js:1235); without this the check waited for a tab switch
        .clearsFocusOnOutsideTap()
        // the title (「游戏机遥控」, or 「待保存 N 项」 while changes wait, view.js:1554) is set by StatusTab's EWSaveBar
    }

    /// The small line under a switch row (pending.js:50-73; index.html:769-773): grey, red for 没生效, 「再发一次」 in link colour.
    @ViewBuilder private func tagLine(_ id: String) -> some View {
        switch data.switchTags[id] {
        case .unsaved(let t)?, .applied(let t)?:
            Text(t).font(.footnote).foregroundStyle(.secondary)
        case .sent(let t, let again)?:
            HStack(spacing: 6) {
                Text(t).font(.footnote).foregroundStyle(.secondary)
                if again { Button("再发一次") { actions.resend(id) }.font(.footnote).buttonStyle(.borderless) }
            }
        case .bad(let t)?:
            HStack(spacing: 6) {
                Text(t).font(.footnote).foregroundStyle(.red)
                Button("再发一次") { actions.resend(id) }.font(.footnote).buttonStyle(.borderless)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: device card

    /// The machine, as Find My's device card (reference P7 / N7: 原生-P7-查找-卡片-原尺寸.png): the device's symbol, its
    /// name in bold with the state, the last report under it in grey. The symbol is lit while the machine is on, as
    /// Home lights an accessory tile that is on (reference 首页机器行: 原生-苹果iOS27手册-家庭-Home标签.png).
    private var deviceCard: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.deviceHead.isEmpty ? data.deviceName : "\(data.deviceName) · \(data.deviceHead)").font(.headline)
                    Text(data.deviceStatus).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                deviceIcon
            }
        }
    }

    @ViewBuilder private var deviceIcon: some View {
        #if os(Android)
        // desktopcomputer is not in skip-ui's Material table (Components/Image.swift composeSymbolName)
        Circle().fill(data.dotOn ? Color.green : Color.secondary).frame(width: dotSide, height: dotSide)
            .accessibilityHidden(true)
        #else
        Image(systemName: "desktopcomputer").foregroundStyle(data.dotOn ? Color.green : Color.secondary)
            .accessibilityHidden(true)   // the text beside says 开机中 / 关机
        #endif
    }

    // MARK: notices

    @ViewBuilder private var notices: some View {
        listSection("status-busy", if: !data.busy.isEmpty && data.online) {
            Section("现在在跑") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.busy.joined(separator: "、"))
                    Text("这时改设置会被推迟到跑完再生效").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        listSection("status-echofarm", ifLet: data.echoFarm) { ef in
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷「\(ef.name)」")
                    // the phone's clock, with the machine's 到 the 改收工 field below uses (审查 B4)
                    Text("刷到 \(ef.untilLocal) 为止（机器时间 \(ef.until)）" + (ef.fromLocal.isEmpty ? "" : "，\(ef.fromLocal) 开始"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("改收工时刻") { confirm = actions.changeEchoFarmUntil(newUntil(ef)) }
                    .disabled(statusTimeHHMM(newUntil(ef)) == nil)
                    .modifier(StatusAsking(ask: $confirm, anchor: "echo_farm_until", confirm: actions.confirm))
                Button("提前收工", role: .destructive) { confirm = actions.stopEchoFarm() }
                    .modifier(StatusAsking(ask: $confirm, anchor: "echo_farm_stop", confirm: actions.confirm))
            } header: {
                Text("刷声骸")
            } footer: {
                // HIG Entering data: the button is grey until the entry is valid, and this line says why
                if statusTimeHHMM(newUntil(ef)) == nil { Text("时刻填成 08:30 这种") }
            }
        }
    }

    /// The 收工 time 改收工时刻 sends: the one picked below, else the machine's current 到.
    private func newUntil(_ ef: StatusEchoFarm) -> String { echoNewUntil.isEmpty ? ef.until : echoNewUntil }

    // MARK: action tiles

    private var actionTiles: some View {
        Section {
            Button { confirm = actions.runNow() } label: {
                tileLabel("现在跑一趟", data.currentQueue.isEmpty ? "" :
                          (data.nextAt.isEmpty ? data.currentQueue : "\(data.currentQueue) · 下一趟 \(data.nextAt)"),
                          tint: .blue) { Image(systemName: "play.fill") }
            }
            .modifier(StatusAsking(ask: $confirm, anchor: "run_now", confirm: actions.confirm))
            Button { actions.refresh() } label: {
                tileLabel("刷新", data.snapAt.map { ago($0) } ?? data.lastUpdate, tint: .gray, spinning: data.refreshing) {
                    symbol("arrow.clockwise", android: "Icons.Outlined.Refresh")
                }
            }
            Button(role: .destructive) { confirm = actions.stopAll() } label: {
                tileLabel("停止一切", "脚本和游戏", tint: .red) {
                    // no Material stop icon in skip-ui's table (Components/Image.swift): its close glyph
                    symbol("stop.fill", android: "Icons.Filled.Close")
                }
            }
            .modifier(StatusAsking(ask: $confirm, anchor: "estop", confirm: actions.confirm))
        }
    }

    private func tileLabel<Icon: View>(_ title: String, _ sub: String, tint: Color, spinning: Bool = false,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            // the title beside names the action: the icon is decorative (HIG VoiceOver: "Exclude purely decorative images")
            if spinning { ProgressView() } else { icon().foregroundStyle(tint).accessibilityHidden(true) }
            // a list row that acts is drawn in the tint (red for the destructive role), its detail in grey, as Find My's
            // device actions (reference P7) and Settings' 「Sign Out」
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Color.secondary) }
            }
        }
    }

    // MARK: stamina

    /// view.js numTiles(): three tiles 2 + 1 (the last one spans the row), each with the resource's own icon (view.js:266
    /// RES → Module.xcassets res-ak / res-ef / res-ww). Each tile is a system GroupBox read as Health's Summary card
    /// (reference P1 / N1: ios27-健康Summary-满数据-1.png): the name in its category colour, the value large and bold in
    /// the primary colour, the cap and the time it fills small and grey. Before the first reading the tiles show
    /// redacted placeholders (HIG Loading: "consider showing placeholder text, graphics, or animations as content
    /// loads") and 「正在读取…」 under them (view.js:293-297).
    @ViewBuilder private var staminaSection: some View {
        listSection("status-stamina", ifLet: data.stamina) { tiles in
            // placeholder values of a typical length, drawn redacted
            let shown = tiles.isEmpty
                ? [StatusStamina(label: "明日方舟 理智", value: 100, cap: 135, sub: "今天 00:00 回满"),
                   StatusStamina(label: "终末地 理智", value: 100, cap: 240, sub: "今天 00:00 回满"),
                   StatusStamina(label: "鸣潮 波片", value: 100, cap: 240, sub: "今天 00:00 回满")]
                : tiles
            Section {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        staminaTile(shown[0], placeholder: tiles.isEmpty)
                        if shown.count > 1 { staminaTile(shown[1], placeholder: tiles.isEmpty) }
                    }
                    if shown.count > 2 { staminaTile(shown[2], placeholder: tiles.isEmpty) }
                }
                #if !os(Android)
                // Health's Summary: each card on the grouped page ground, not inside a row (a GroupBox in a row has the
                // row's own colour in dark mode); skip-ui: listRowInsets unavailable, its GroupBox draws its own ground
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                #endif
            } footer: {
                if tiles.isEmpty { Text("正在读取…") }
                else if !data.staminaSource.isEmpty { Text("\(data.staminaSource) 读取，下拉刷新会重新读") }
            }
        }
    }

    private static let staminaIcon = ["明日方舟 理智": "res-ak", "终末地 理智": "res-ef", "鸣潮 波片": "res-ww"]
    /// The web's three colours are the system blue, orange and teal (index.html #30b0c7 = systemTeal): named, so they
    /// follow light / dark (HIG Color: "Avoid hard-coding system color values in your app").
    private static let staminaColour: [String: Color] = [
        "明日方舟 理智": .blue, "终末地 理智": .orange, "鸣潮 波片": .teal,
    ]

    private func staminaTile(_ t: StatusStamina, placeholder: Bool) -> some View {
        let icon = Self.staminaIcon[t.label] ?? "res-ak"
        let colour = Self.staminaColour[t.label] ?? Color.blue
        return GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    decorativeImage(icon).resizable().scaledToFit().frame(width: resIcon, height: resIcon)   // t.label names it
                    Spacer()
                    if t.error == nil {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(t.value.map(String.init) ?? "–").font(.title2).bold().monospacedDigit()
                            if let cap = t.cap { Text("/\(cap)").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .redacted(reason: placeholder ? .placeholder : [])
                    }
                }
                Text(t.label).font(.subheadline).bold().foregroundStyle(colour)
                if let err = t.error {
                    Text(err).font(.footnote).foregroundStyle(.red)
                } else if !t.sub.isEmpty {
                    Text(t.sub).font(.footnote).foregroundStyle(.secondary)
                        .redacted(reason: placeholder ? .placeholder : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // the colour of a grouped list's cards, so a tile reads as one of Health's Summary cards in light and dark
        .backgroundStyle(Color(uiColor: .secondarySystemGroupedBackground))
        #endif
    }

    // MARK: plan (这一趟 / 明日安排)

    @ViewBuilder private func planRows(_ blocks: [StatusPlanBlock]) -> some View {
        ForEach(blocks) { b in
            if let q = b.queueName {
                // Clock's alarm row (reference P6 / N11: mac27-时钟-闹钟-有数据.png, P6-快捷指令-自动化列表.png): the time
                // large, the name and what happens today small under it, the switch on the right
                Toggle(isOn: Binding(get: { b.runsToday }, set: { actions.setRunsToday(q, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        // a skipped shift's row has no time (StatusMapping, 审查 B2); the lead time is 东京, as the tile (B4)
                        if b.shownTime.isEmpty {
                            Text(q)
                        } else {
                            Text(b.shownTime).font(.title2).bold().monospacedDigit()
                        }
                        Text([b.shownTime.isEmpty ? "" : q, b.machineNote, b.runsToday ? "今天照常" : "今天跳过，明天照常", b.after]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        tagLine(StatusSwitchID.queue(q))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.shownTime).font(.title2).bold().monospacedDigit()
                    let sub = [b.machineNote, b.after].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            // ids carry the block: the same game sits in several blocks (这一趟 and 明日安排), and skip-ui keys a List's
            // rows by ForEach id, so two equal ids crash its LazyColumn ("Key … was already used")
            ForEach(b.games.map { StatusPlanGameRow(block: b.id, game: $0) }) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.game.name)
                    if !r.game.hints.isEmpty { Text(r.game.hints.joined(separator: "，")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private static let switchFoot = "时刻行的开关：关掉 = 这趟今天不跑，明天照常；再打开就恢复"

    @ViewBuilder private var thisShift: some View {
        let mine = data.plan.filter { $0.queueName != nil && $0.queueName == data.currentQueue }
        Section {
            if mine.isEmpty {
                let scripts = data.queues.first(where: { $0.name == data.currentQueue })?.scripts ?? []
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.currentQueue.isEmpty ? "班次" : data.currentQueue)
                    Text(scripts.isEmpty ? "机器还没上报排班" : scripts.map { StatusData.ownerName[$0] ?? $0 }.joined(separator: " → "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
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

    // MARK: 刷 4C 声骸

    private var echoFarmSection: some View {
        Section {
            if let ef = data.echoFarm {
                // echofarm.py retime (363-384) resolves the time like a start: one already past is tomorrow's (审查 A2: the
                // old 「已经过了的时刻＝立刻收工」 sent a farm on for another day); stopping now is 「提前收工」. view.js:398 #efnew
                // starts at the current 到; picked with the system time picker, not typed (user 20:12, via 验收)
                // the picker beside the title, labels hidden: as its label, the two-line hint pushed iOS's time capsule
                // under it, at the left (test pass 7)
                HStack(spacing: 12) {
                    rowTitle("改成刷到几点（机器时间）", "提前或延后都行。已经过了的时刻算明天；要马上停按「提前收工」")
                    DatePicker("改成刷到几点", selection: hhmmBinding($echoNewUntil, else: ef.until), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            } else {
                Picker(selection: $bossIndex) {
                    ForEach(data.bosses) { b in Text("\(b.index). \(b.name)").tag(b.index) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("刷 4C 声骸 · 打哪个")
                        Text("序号＝「讨伐强敌」列表从上往下数。刷的期间不花波片、不领周本奖励").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.menu)
                // view.js:174-176 echoFarmBlock: title + explanation left, the time right of them; picked, not typed
                HStack(spacing: 12) {
                    rowTitle("刷到几点（机器时间）", "已过就算明天。到点自动收工、配置还原")
                    DatePicker("刷到几点", selection: hhmmBinding($echoUntil, else: "08:30"), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                Button("开始刷") { confirm = actions.startEchoFarm(bossIndex, echoUntil) }
                    .disabled(StatusCommands.echoFarmProblem(boss: bossIndex, until: echoUntil) != nil)
                    .modifier(StatusAsking(ask: $confirm, anchor: "echo_farm", confirm: actions.confirm))
            }
        } header: {
            Text("刷 4C 声骸")
        } footer: {
            // HIG Entering data: 开始刷 is grey until a boss and a time are there, and this line says why
            if data.echoFarm == nil, let why = StatusCommands.echoFarmProblem(boss: bossIndex, until: echoUntil) { Text(why) }
        }
    }

    /// A row's title with its grey explanation under it (web `<label>title<span class="hint">…</span></label>`), taking
    /// the room left of the row's control.
    private func rowTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A machine time 「HH:MM」 (sent as is, statusTimeHHMM) as the Date a time picker shows, and back. The same calendar
    /// both ways, on today's date in the phone's zone, so the picker shows exactly the stored 「HH:MM」 (the field is the
    /// machine's clock, but only its digits matter here: no zone conversion).
    private func hhmmBinding(_ text: Binding<String>, else fallback: String) -> Binding<Date> {
        Binding(
            get: {
                let hm = (statusTimeHHMM(text.wrappedValue) ?? statusTimeHHMM(fallback) ?? "08:30").split(separator: ":")
                let cal = Calendar.current
                return cal.date(bySettingHour: Int(hm[0]) ?? 8, minute: Int(hm[1]) ?? 30, second: 0,
                                of: cal.startOfDay(for: Date())) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                text.wrappedValue = "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
            }
        )
    }

    // MARK: 机器 (schema.js RELAY_SWITCHES, tab 状态)

    private var machineSection: some View {
        Section {
            Toggle(isOn: Binding(get: { data.skipShutdown }, set: { actions.setSkipShutdown($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下次跑完不关机")
                    Text(skipShutdownRule).font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.skipShutdown)
                }
            }
            Toggle(isOn: Binding(get: { data.debugModeUntil != nil }, set: { actions.setDebugMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("调试模式")
                    Text(data.debugModeUntil.flatMap { $0.isEmpty ? nil : "开着，到 \($0)——这期间跑完不关机" } ?? debugModeRule)
                        .font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.debugMode)
                }
            }
        } header: {
            Text("机器")
        } footer: {
            // view.js:322-325 cfgNote, placed right after the 机器 section (view.js:402): a bare footnote line in --warn
            // (systemOrange, index.html:102/477), no card; AUTO-MAS unreadable, and whether a last good config stands in
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

    @ViewBuilder private var receiptsSection: some View {
        listSection("status-receipts", if: !data.receipts.isEmpty) {
            let note = [data.todayLast.isEmpty ? "" : "最近一趟 \(data.todayLast)",
                        data.todayFailed > 0 ? "失败 \(data.todayFailed) 趟" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            Section {
                // view.js:458 nowRow sits above the newest three
                if let actual = data.todayActual { todayActualRow(actual) }
                ForEach(data.receipts.prefix(3)) { r in receiptRow(r, at: r.shownAt) }
                if data.receipts.count > 3 {
                    // by value (StatusRoute.receipts; the page is built in body's navigationDestination), so a reselect can pop it
                    NavigationLink(value: StatusRoute.receipts) {
                        HStack {
                            Text("查看全部")
                            Spacer()
                            Text("\(data.receipts.count) 条").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                // view.js:449 `<h2>机器最近的回执 <small>…</small></h2>`; index.html:232 h2 small = footnote size, weight 400, dim
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("机器最近的回执")
                    if !note.isEmpty {
                        Text(note).font(.footnote).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // Android centred the bare HStack in the header slot
            }
        }
    }
}

/// A game row of one plan block (planRows); see the ForEach there for why the id includes the block.
private struct StatusPlanGameRow: Identifiable {
    var block: String
    var game: StatusPlanGame
    var id: String { block + "/" + game.id }
}

/// The confirmation of one command button, drawn from that button: SwiftUI's confirmationDialog attached to the button
/// that asks, as its documentation's example does ("In regular size classes in iOS, the system renders confirmation
/// dialogs as a popover"); reference P10 / N9 (P10-日历-放弃确认.png). One `confirm` state per page, keyed by the
/// request's action (StatusAsk.anchor), so only the pressed button's dialog shows (7b6a3f1).
struct StatusAsking: ViewModifier {
    @Binding var ask: StatusAsk?
    var anchor: String
    var confirm: (StatusAsk) -> Void

    /// The last question shown, so the title stays while the dialog animates away after `ask` went nil.
    @State var last: StatusAsk? = nil

    func body(content: Content) -> some View {
        let mine = ask?.anchor == anchor ? ask : nil
        content
            .onChange(of: mine) { _, v in if let v { last = v } }
            .confirmationDialog((mine ?? last)?.title ?? "",
                                isPresented: Binding(get: { ask?.anchor == anchor },
                                                     set: { if !$0, ask?.anchor == anchor { ask = nil } }),
                                titleVisibility: .visible, presenting: mine ?? last) { a in
                Button(a.ok, role: a.destructive ? .destructive : nil) { confirm(a) }
                Button("取消", role: .cancel) {}
            } message: { a in
                Text(a.message)
            }
    }
}

/// A receipt shows its whole text, wrapping onto as many lines as it needs (user, 10-02 20:49: a cut-off receipt, with
/// or without an ellipsis, hides the information). The web row is one line with an ellipsis (view.js:449-451,
/// index.html:392); the App does not follow it here. The icon and the time keep their width (time never wraps, as
/// :379 `.ro.short` nowrap); only the text gives way. The time is 「HH:MM 发出 · <at> 执行」 when the send time differs
/// (view.js rcWhen); a skip receipt that no longer holds is grey with the reason under it (view.js:451-452, index.html:377
/// `.row.stale > label{color:var(--dim)}`, `.sf.stale` dim icon).
func receiptRow(_ r: StatusReceipt, at: String) -> some View {
    // a long time (「18:04 发出 · 10-05 18:05 执行」) goes under the text: kept on the right beside a two-line text it
    // overran the text and the card on Android (test pass 4, receipt-row-overlap.png)
    let when = r.when(at)
    let below = when.contains(" 发出 · ")   // StatusModels.swift:78, the two-time form
    return HStack {
        receiptIcon(r).fixedSize(horizontal: true, vertical: false)
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

/// view.js nowRow: 「今天实际」 with each shift's 跳过 / 照常 today as the row's grey value (`.ro.short`).
func todayActualRow(_ actual: String) -> some View {
    HStack {
        Text("今天实际")
        Spacer()
        Text(actual).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

@ViewBuilder private func receiptIcon(_ r: StatusReceipt) -> some View {
    if r.note != nil {
        // a stale skip receipt: the icon goes dim with its row (index.html:377 .sf.stale{background:var(--dim)});
        // only successful receipts get a note, so it is always the check
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.gray).accessibilityLabel("成功")
    } else if r.ok {
        // the receipt text does not say whether it went through: the icon carries it, so it is named (accessibilityLabel docs:
        // "a view that doesn't display text, like an icon")
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).accessibilityLabel("成功")
    } else {
        // no Material cancel icon in skip-ui's table (Components/Image.swift): its close glyph, in red
        symbol("xmark.circle.fill", android: "Icons.Filled.Close").foregroundStyle(Color.red).accessibilityLabel("失败")
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

/// Every receipt grouped by day (回执只带 月-日, so the header is 「9月17日」).
struct StatusReceiptsList: View {
    var receipts: [StatusReceipt]
    /// view.js:463 the 今天实际 row heads today's group (`g.d === today ? nowRow : ""`).
    var todayActual: String? = nil
    var today = ""

    private var days: [String] {
        var seen: [String] = []
        for r in receipts { let d = String(r.shownAt.prefix(5)); if !seen.contains(d) { seen.append(d) } }
        return seen
    }

    private func dayName(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 2, let m = Int(p[0]), let day = Int(p[1]) else { return d }
        return "\(m)月\(day)日"
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
