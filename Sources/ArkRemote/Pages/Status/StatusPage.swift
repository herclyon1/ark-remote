import SwiftUI

/// The 状态 tab: same blocks, rows and wording as the web page (maa-automation/web/view.js render(), 状态 part), in order:
/// device card, notices (现在在跑 / 刷声骸), action tiles, stamina, 停止一切 note, shift segmented control, 班次,
/// 刷声骸, 机器 switches, 月卡, 机器最近的回执. Standard controls only; Skip maps them to Android ones.
struct StatusPage: View {
    var data: StatusData
    var actions = StatusActions()
    /// The page's data as of now, for the 「查看全部」 page: skip-ui keeps the first navigationDestination closure a stack
    /// collects (Navigation.swift:869-872, NavigationDestination.equals is always true), so one capturing `data` showed
    /// the receipts of the App's first draw, even pushed afresh (test pass 1, 问题 9). nil: `data` (previews).
    var live: (() -> StatusData)? = nil

    @State var bossIndex = 1
    /// The 刷声骸 end on the phone's clock (the page uses one clock, the phone's); sent converted to the machine's. Starts at
    /// the moment the old machine-clock default 08:30 named.
    @State var echoUntil = phoneHHMM(fromMachine: "08:30")
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
                    #if !os(Android)
                    .listRowInsets(EdgeInsets())   // skip-ui: listRowInsets unavailable (skip-fuse-ui List.swift:381)
                    #endif
                    // on the page ground, not in a card, as Health's D / W / M control (ios27-健康Steps详情), on both
                    // platforms (skip-fuse-ui List.swift:336 has listRowBackground)
                    .listRowBackground(Color.clear)
                } footer: {
                    // the control has no title and, since the 班次 list below shows every shift, nothing on this page
                    // changes when it is flipped: it picks the shift the game tabs edit and 现在跑一趟 runs (decision G1
                    // keeps the control). HIG Segmented controls: "affect an object, state, or view"; say which.
                    Text("选哪一班，方舟、终末地、鸣潮页改的就是这一班的设置，「现在跑一趟」也跑这一班。")
                }
            }
            // every shift in one list right after the actions, as Clock's alarms (HIG Layout: "Group related items"): the
            // shifts were split into 这一趟 and 明日安排 with 刷声骸, 机器 and 月卡 between them
            shifts
            echoFarmSection
            machineSection
            MonthCardRows(today: MonthCardStore.today())
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
        // the title (the tab's name) is set by StatusTab's EWSaveBar
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
                // the name alone on the first line, the state and how fresh it is on the grey line under it, as Find My's
                // card puts 「This Mac」 and the time under the name (P7; HIG Writing: "Choose simple, plain language")
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.deviceName).font(.headline)
                    Text(data.deviceHead.isEmpty ? data.deviceStatus : "\(data.deviceHead) · \(data.deviceStatus)")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    // the phone's clock only, as every time on the page (审查 B4)
                    Text("刷到 \(ef.untilLocal) 为止" + (ef.fromLocal.isEmpty ? "" : "，\(ef.fromLocal) 开始"))
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

    /// The 收工 time 改收工时刻 sends, on the phone's clock: the one picked below, else the machine's current 到 on that clock.
    private func newUntil(_ ef: StatusEchoFarm) -> String { echoNewUntil.isEmpty ? phoneHHMM(fromMachine: ef.until) : echoNewUntil }

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
                // the icon stays put while a refresh runs: the pull to refresh shows the one progress indicator (HIG
                // Progress indicators: "Display a progress indicator in a consistent location."); in the tint of the
                // row's text, as the other two rows
                // no second line: how fresh the state is is said once, on the device card above (「17 秒前更新」)
                tileLabel("刷新", "", tint: .blue) {
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

    /// The row's icon and words as the system's Label, so the three icons share one column and the words and the
    /// separators line up (HIG Layout: "Align elements to make them easier to scan."; the icons were 12, 20 and 13 pt
    /// wide in an HStack, the words starting at 67, 72 and 69.5 pt).
    private func tileLabel<Icon: View>(_ title: String, _ sub: String, tint: Color,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        Label {
            // a list row that acts is drawn in the tint (red for the destructive role), its detail in grey, as Find My's
            // device actions (reference P7) and Settings' 「Sign Out」
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(Color.secondary) }
            }
        } icon: {
            // the title beside names the action: the icon is decorative (HIG VoiceOver: "Exclude purely decorative images")
            icon().foregroundStyle(tint).accessibilityHidden(true)
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
                            Text(t.value.map(String.init) ?? "–").font(.title2).bold().tabularDigits()
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

    // MARK: 班次

    @ViewBuilder private func planRows(_ blocks: [StatusPlanBlock]) -> some View {
        ForEach(blocks) { b in
            if let q = b.queueName {
                // 快捷指令's automation row (reference P6-快捷指令-自动化列表.png): the time in bold, under it the shift and what
                // the switch does (HIG Toggles: "Clearly identify the setting the toggle affects"), the switch on the right
                Toggle(isOn: Binding(get: { b.runsToday }, set: { actions.setRunsToday(q, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        // a skipped shift's row has its time from the shift's 时刻; only an older relay leaves it out
                        if b.shownTime.isEmpty {
                            Text(q)
                        } else {
                            // the size of 快捷指令 › 自动化's 「At 7:00, daily」 (P6), the iOS reference of the row
                            Text(b.shownTime).font(.headline).tabularDigits()
                        }
                        Text([b.shownTime.isEmpty ? "" : q, b.switchLine].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        let more = [b.machineNote, b.after].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !more.isEmpty { Text(more).font(.footnote).foregroundStyle(.secondary) }
                        tagLine(StatusSwitchID.queue(q))
                    }
                }
                // today's run is over: skip_today is for today only (the relay refuses another day), so the switch could
                // change nothing; Clock's switch always acts on the ring its row names
                .disabled(b.passedToday)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.shownTime).font(.headline).tabularDigits()
                    let sub = [b.machineNote, b.after].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            // ids carry the block: the same game sits in several blocks, and skip-ui keys a List's rows by ForEach id, so
            // two equal ids crash its LazyColumn ("Key … was already used")
            ForEach(b.games.map { StatusPlanGameRow(block: b.id, game: $0) }) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.game.name)
                    // every game row says what it runs, as its siblings do; a game the machine gave no line for says so
                    Text(r.game.hints.isEmpty ? "没读到这一项明天跑什么" : r.game.hints.joined(separator: "，"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !r.game.warning.isEmpty {
                        // beside the game it is about, in the page's one warning style (机器 section's warningLabel)
                        warningLabel(r.game.warning).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder private var shifts: some View {
        Section {
            if data.plan.isEmpty {
                let scripts = data.queues.first(where: { $0.name == data.currentQueue })?.scripts ?? []
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.currentQueue.isEmpty ? "班次" : data.currentQueue)
                    Text(scripts.isEmpty ? "机器还没上报排班" : scripts.map { StatusData.ownerName[$0] ?? $0 }.joined(separator: " → "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                planRows(data.plan)
            }
        } header: {
            Text("班次")
        } footer: {
            // the game lines are the plan for tomorrow (plan.py next_plan) while the switches act on today: said once
            let lines = (data.plan.contains { !$0.games.isEmpty } ? ["各班下面列的是明天要跑的内容。"] : []) + data.planFoot
            if !lines.isEmpty { Text(lines.joined(separator: "\n")) }
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
                    rowTitle("改成刷到几点", "已过算明天；马上停按「提前收工」")
                    DatePicker("改成刷到几点", selection: hhmmBinding($echoNewUntil, else: phoneHHMM(fromMachine: ef.until)),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            } else {
                // the name left and the value right on one line, as Calendar's 「Repeat」 row (P10): the value is the option's
                // name alone, as Calendar's menu shows 「Never」; the list keeps the game's order (footer)
                // 讨伐强敌, then the weekly bosses, with a separator between the two groups (HIG Menus: "To help people
                // visually distinguish such groups, use a separator."). Not a Section: skip-ui's Picker keeps only tagged
                // children (Picker.swift processPickerContent), so a Section's rows would vanish on Android, while the
                // untagged Divider is skipped there; the 「周本」 in each weekly name tells the groups apart on Android.
                Picker(selection: $bossIndex) {
                    ForEach(data.bosses.filter { !$0.weekly }) { b in Text(b.name).tag(b.id) }
                    Divider()
                    ForEach(data.bosses.filter { $0.weekly }) { b in Text(b.name).tag(b.id) }
                } label: {
                    Text("打哪个")
                }
                .pickerStyle(.menu)
                .menuValueGrey()
                // view.js:174-176 echoFarmBlock: title + explanation left, the time right of them; picked, not typed. The
                // hint is the one fact the name does not give, in one short clause (HIG Lists and tables: "Keep item text
                // succinct"; 到点收工 is the row name itself)
                HStack(spacing: 12) {
                    rowTitle("刷到几点", "已过算明天")
                    DatePicker("刷到几点", selection: hhmmBinding($echoUntil, else: phoneHHMM(fromMachine: "08:30")),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                Button("开始刷") { confirm = actions.startEchoFarm(bossIndex, echoUntil) }
                    .disabled(StatusCommands.echoFarmProblem(boss: bossIndex, until: echoUntil) != nil)
                    .modifier(StatusAsking(ask: $confirm, anchor: "echo_farm", confirm: actions.confirm))
            }
        } header: {
            // 4C is the players' word for a 4-cost echo: said in plain words
            Text("刷声骸（4 费）")
        } footer: {
            // 打哪个's explanation; HIG Entering data: 开始刷 is grey until a boss and a time are there, and a line says why
            if data.echoFarm == nil {
                let why = StatusCommands.echoFarmProblem(boss: bossIndex, until: echoUntil)
                Text((["先列「讨伐强敌」，再列周本，都按游戏里列表的顺序排。刷的期间不花波片、不领周本奖励。"]
                        + (why.map { [$0] } ?? []))
                        .joined(separator: "\n"))
            }
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

    /// A phone time 「HH:MM」 as the Date a time picker shows, and back. The same calendar both ways, on today's date in the
    /// phone's zone, so the picker shows exactly the stored 「HH:MM」; StatusCommands converts it to the machine's clock.
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
            Section {
                // view.js:458 nowRow sits above the newest three
                if let actual = data.todayActual { todayActualRow(actual) }
                ForEach(data.receipts.prefix(3)) { r in receiptRow(r, at: receiptShortAt(r.shownAt)) }
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
                // the header alone, one text as Health's 「Steps」. No 「最近一趟 X」 / 「失败 N 趟」 (view.js:449): how the
                // machine's runs went is the daily report's, not the App's (his 10-07 17:56, design rule 7, regression #26)
                Text("机器最近的回执")
                    .frame(maxWidth: .infinity, alignment: .leading)   // Android centred a bare header in the slot
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
    // the icon and the time on the first text line (HIG Lists; Health's day list keeps the time level with the words):
    // centred against a text of 2-4 lines they floated beside its middle
    return HStack(alignment: .firstTextBaseline) {
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

/// Only a command the machine did not carry out is marked (the red ✗; his 10-10 16:58: the phone must say plainly when a
/// change failed). A receipt that went through has no icon, as Health's day list marks nothing on a normal row (P8;
/// design rule 5: stress only what went wrong).
/// The slot is kept on every row (the symbol hidden), as Mail keeps its unread-dot column, so every row's text starts at
/// the same left edge.
@ViewBuilder private func receiptIcon(_ r: StatusReceipt) -> some View {
    if r.ok || r.note != nil {
        symbol("xmark.circle.fill", android: "Icons.Filled.Close").hidden().accessibilityHidden(true)
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

    /// 「今天」 / 「昨天」 for the last two days, else 「9月17日」.
    private func dayName(_ d: String) -> String {
        switch receiptDayWord(d) {
        case ""?: return "今天"
        case let w?: return w
        case nil: break
        }
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
        #if os(iOS)
        // small and centred, as Health's pushed day list (P8); iOS only (MonthCardPage says why)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await Live.shared.ping() }
    }
}

/// A receipt day 「MM-DD」 on the phone's clock: "" for today, 「昨天」 for yesterday, nil for an earlier day.
func receiptDayWord(_ md: String, now: Date = Date()) -> String? {
    let cal = Calendar.current
    func mmdd(_ d: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(pad2(c.month ?? 0))-\(pad2(c.day ?? 0))"
    }
    if md == mmdd(now) { return "" }
    if let y = cal.date(byAdding: .day, value: -1, to: now), md == mmdd(y) { return "昨天" }
    return nil
}

/// A receipt's 「MM-DD HH:MM」 as the 状态 page shows it: 「12:57」 today, 「昨天 20:23」 yesterday, else as it is. The
/// short form leaves the text more of the row (Health's day list: one line of words, the time beside it).
func receiptShortAt(_ at: String, now: Date = Date()) -> String {
    guard at.count > 6 else { return at }
    let time = String(at.dropFirst(6))
    switch receiptDayWord(String(at.prefix(5)), now: now) {
    case ""?: return time
    case let w?: return "\(w) \(time)"
    case nil: return at
    }
}

extension Text {   // also the 用药 rows (Pages/Phone/MedicationRows.swift)
    /// Digits of equal width, so a changing number or time does not shift (the Health Summary value and the Clock alarm
    /// time). Android: skip-fuse-ui marks Text.monospacedDigit() unavailable (Text/Text.swift:347-350); Roboto's
    /// digits are tabular by default, so the Text is used as it is.
    func tabularDigits() -> Text {
        #if os(Android)
        self
        #else
        monospacedDigit()
        #endif
    }
}
