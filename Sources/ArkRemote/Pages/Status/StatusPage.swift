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
    /// Which time field has the keyboard: leaving it checks the entry (view.js:1235 data-time onchange fires on blur).
    @FocusState var timeFocus: Bool
    @FocusState var newTimeFocus: Bool
    /// Bumped every 30 s by a local timer so 「X 分钟前」 follows the clock (no network: view.js ago() redrawn on render).
    @State var tick = 0
    /// A reselect of the 状态 tab at its root (ContentView.reselect, D39): scroll to the top.
    @Environment(\.tabReselect) var reselect

    /// The first row of the page, always drawn and in a section without a header. skip-ui's ScrollViewProxy finds ids of
    /// rows only (LazySupport.swift:250-288; a section header is a count, :283), so this is the top it can reach: the
    /// device card flush under the top bar, with the list's top inset and empty header item above it scrolled off.
    static let topID = "status-top"

    var body: some View {
        let _ = tick
        ScrollViewReader { proxy in
        List {
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
        // skip-ui animates scrollTo only inside withAnimation (List.swift:242) and ignores the anchor (ScrollView.swift:163)
        .onChange(of: reselect) { withAnimation { proxy.scrollTo(Self.topID, anchor: .top) } }
        // Android: a tap outside the time fields or back with the keyboard up checks them, as the web input's blur
        // (view.js:1235); without this the check waited for a tab switch
        .clearsFocusOnOutsideTap()
        // the title (「游戏机遥控」, or 「待保存 N 项」 while changes wait, view.js:1554) is set by StatusTab's EWSaveBar
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                tick &+= 1
            }
        }
        }
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

    /// pending.js:63 `.posted`: a sent row sits on a light green ground (index.html:768, --ok at 8 %).
    private func rowGround(_ id: String) -> Color? {
        (data.switchTags[id]?.posted ?? false) ? Color.green.opacity(0.08) : nil
    }

    // MARK: device card

    private var deviceCard: some View {
        Section {
            HStack(spacing: 12) {
                Circle().fill(data.dotOn ? Color.green : Color.gray.opacity(0.5)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.deviceHead.isEmpty ? data.deviceName : "\(data.deviceName) · \(data.deviceHead)")
                    Text(data.deviceStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .id(Self.topID)   // the reselect's scroll target (topID)
        }
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
            Section("刷声骸") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷「\(ef.name)」")
                    // the phone's clock, with the machine's 到 the 改收工 field below uses (审查 B4)
                    Text("刷到 \(ef.untilLocal) 为止（机器时间 \(ef.until)）" + (ef.fromLocal.isEmpty ? "" : "，\(ef.fromLocal) 开始"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("改收工时刻") { actions.changeEchoFarmUntil(echoNewUntil.isEmpty ? ef.until : echoNewUntil) }
                Button("提前收工", role: .destructive) { actions.stopEchoFarm() }
            }
        }
    }

    // MARK: action tiles

    private var actionTiles: some View {
        Section {
            Button { actions.runNow() } label: {
                tileLabel("现在跑一趟", data.currentQueue.isEmpty ? "" :
                          (data.nextAt.isEmpty ? data.currentQueue : "\(data.currentQueue) · 下一趟 \(data.nextAt)"),
                          tint: .blue) { Image(systemName: "play.fill") }
            }
            Button { actions.refresh() } label: {
                tileLabel("刷新", data.snapAt.map { ago($0) } ?? data.lastUpdate, tint: .gray, spinning: data.refreshing) {
                    symbol("arrow.clockwise", android: "Icons.Outlined.Refresh")
                }
            }
            Button { actions.stopAll() } label: {
                tileLabel("停止一切", "脚本和游戏", tint: .red) {
                    // no Material stop icon in skip-ui's table: the filled square drawn on Android
                    #if os(Android)
                    RoundedRectangle(cornerRadius: 2).fill(Color.red).frame(width: 14, height: 14)
                    #else
                    Image(systemName: "stop.fill")
                    #endif
                }
            }
        }
    }

    private func tileLabel<Icon: View>(_ title: String, _ sub: String, tint: Color, spinning: Bool = false,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            // the title beside names the action: the icon is decorative (HIG VoiceOver: "Exclude purely decorative images")
            if spinning { ProgressView() } else { icon().foregroundStyle(tint).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(title == "停止一切" ? Color.red : Color.primary)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: stamina

    /// view.js numTiles(): three tiles 2 + 1 (the last one spans the row, Reminders' odd smart-list tile), each with the
    /// resource's own icon (view.js:266 RES → Module.xcassets res-ak / res-ef / res-ww) and its colour; before the first
    /// reading the tiles show with placeholders and 「正在读取…」 under them (view.js:293-297).
    @ViewBuilder private var staminaSection: some View {
        listSection("status-stamina", ifLet: data.stamina) { tiles in
            let shown = tiles.isEmpty
                ? [StatusStamina(label: "明日方舟 理智", value: nil, cap: nil, sub: ""),
                   StatusStamina(label: "终末地 理智", value: nil, cap: nil, sub: ""),
                   StatusStamina(label: "鸣潮 波片", value: nil, cap: nil, sub: "")]
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
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))   // skip-ui: unavailable on Android
                #endif
            } footer: {
                if tiles.isEmpty { Text("正在读取…") }
                else if !data.staminaSource.isEmpty { Text("\(data.staminaSource) 读取，下拉刷新会重新读") }
            }
        }
    }

    private static let staminaIcon = ["明日方舟 理智": "res-ak", "终末地 理智": "res-ef", "鸣潮 波片": "res-ww"]
    private static let staminaColour: [String: Color] = [
        "明日方舟 理智": .blue, "终末地 理智": .orange,
        "鸣潮 波片": Color(red: 0x30 / 255.0, green: 0xb0 / 255.0, blue: 0xc7 / 255.0),
    ]

    private func staminaTile(_ t: StatusStamina, placeholder: Bool) -> some View {
        let icon = Self.staminaIcon[t.label] ?? "res-ak"
        let colour = Self.staminaColour[t.label] ?? Color.blue
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                decorativeImage(icon).resizable().scaledToFit().frame(width: 30, height: 30)   // t.label names it
                Spacer()
                if placeholder {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2)).frame(width: 56, height: 22)
                } else if t.error == nil {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(t.value.map(String.init) ?? "–").font(.title2).bold().foregroundStyle(colour)
                        if let cap = t.cap { Text("/\(cap)").font(.footnote).foregroundStyle(colour) }
                    }
                }
            }
            Text(t.label).font(.subheadline).bold().foregroundStyle(.secondary)
            if placeholder {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2)).frame(width: 90, height: 11)
            } else if let err = t.error {
                Text(err).font(.footnote).foregroundStyle(.red)
            } else if !t.sub.isEmpty {
                Text(t.sub).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: plan (这一趟 / 明日安排)

    @ViewBuilder private func planRows(_ blocks: [StatusPlanBlock]) -> some View {
        ForEach(blocks) { b in
            if let q = b.queueName {
                Toggle(isOn: Binding(get: { b.runsToday }, set: { actions.setRunsToday(q, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        // a skipped shift's row has no time (StatusMapping, 审查 B2); the lead time is 东京, as the tile (B4)
                        Text(b.shownTime.isEmpty ? q : "\(q) · \(b.shownTime)")
                        Text([b.machineNote, b.runsToday ? "今天照常" : "今天跳过，明天照常", b.after]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        tagLine(StatusSwitchID.queue(q))
                    }
                }
                .listRowBackground(rowGround(StatusSwitchID.queue(q)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.shownTime)
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
        Section("刷 4C 声骸") {
            if let ef = data.echoFarm {
                // view.js:396-398: the field sits beside its title, the explanation under the title (web .row: label + .hint left,
                // input.short right, index.html:488 72–120 px wide)
                HStack(spacing: 12) {
                    // echofarm.py retime (363-384) resolves the time like a start: one already past is tomorrow's (审查 A2: the
                    // old 「已经过了的时刻＝立刻收工」 sent a farm on for another day); stopping now is 「提前收工」
                    rowTitle("改成刷到几点（机器时间）", "提前或延后都行，填 21:00 这种。已经过了的时刻算明天；要马上停按「提前收工」")
                    // view.js:398 #efnew value = the current 到; :1235 data-time: a bad entry rolls back with a toast when it is left
                    TextField(ef.until, text: $echoNewUntil)
                        .onAppear { if echoNewUntil.isEmpty { echoNewUntil = ef.until } }
                        .onSubmit { echoNewUntil = Self.checkedTime(echoNewUntil, else: ef.until) }
                        .focused($newTimeFocus)
                        .onChange(of: newTimeFocus) { _, on in
                            if !on { echoNewUntil = Self.checkedTime(echoNewUntil, else: ef.until) }
                        }
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.timeFieldWidth)
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
                // view.js:174-176 echoFarmBlock: title + explanation left, the time field right of them
                HStack(spacing: 12) {
                    rowTitle("刷到几点（机器时间）", "填 08:30 这种，已过就算明天。到点自动收工、配置还原")
                    TextField("08:30", text: $echoUntil)
                        .onSubmit { echoUntil = Self.checkedTime(echoUntil, else: "08:30") }
                        .focused($timeFocus)
                        .onChange(of: timeFocus) { _, on in
                            if !on { echoUntil = Self.checkedTime(echoUntil, else: "08:30") }
                        }
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.timeFieldWidth)
                }
                Button("开始刷") { actions.startEchoFarm(bossIndex, echoUntil) }
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

    /// index.html:488 input.short: 72–120 px; a fixed width in that range holds 「08:30」 with the platform field's padding.
    private static let timeFieldWidth: CGFloat = 104

    /// view.js:1235 input[data-time] onchange: 「8:30」 → 「08:30」; anything else rolls back with 「时刻填成 08:30 这种」.
    @MainActor static func checkedTime(_ v: String, else last: String) -> String {
        if let t = statusTimeHHMM(v) { return t }
        Relay.shared.showToast("时刻填成 08:30 这种")
        return last
    }

    // MARK: 机器 (schema.js RELAY_SWITCHES, tab 状态)

    private var machineSection: some View {
        Section {
            Toggle(isOn: Binding(get: { data.skipShutdown }, set: { actions.setSkipShutdown($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下次跑完不关机")
                    Text("只跳过下一次关机，再下一趟照常关").font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.skipShutdown)
                }
            }
            .listRowBackground(rowGround(StatusSwitchID.skipShutdown))
            Toggle(isOn: Binding(get: { data.debugModeUntil != nil }, set: { actions.setDebugMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("调试模式")
                    Text(data.debugModeUntil.flatMap { $0.isEmpty ? nil : "开着，到 \($0)——这期间跑完不关机" } ?? debugModeRule)
                        .font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.debugMode)
                }
            }
            .listRowBackground(rowGround(StatusSwitchID.debugMode))
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

/// A receipt shows its whole text, wrapping onto as many lines as it needs (user, 10-02 20:49: a cut-off receipt, with
/// or without an ellipsis, hides the information). The web row is one line with an ellipsis (view.js:449-451,
/// index.html:392); the App does not follow it here. The icon and the time keep their width (time never wraps, as
/// :379 `.ro.short` nowrap); only the text gives way. The time is 「HH:MM 发出 · <at> 执行」 when the send time differs
/// (view.js rcWhen); a skip receipt that no longer holds is grey with the reason under it (view.js:451-452, index.html:377
/// `.row.stale > label{color:var(--dim)}`, `.sf.stale` dim icon).
func receiptRow(_ r: StatusReceipt, at: String) -> some View {
    HStack {
        receiptIcon(r).fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 2) {
            Text(r.text).foregroundStyle(r.note == nil ? Color.primary : Color.secondary)
            if let note = r.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        Spacer()
        Text(r.when(at)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
        // no Material cancel icon in skip-ui's table: a red disc with the mapped xmark on Android
        #if os(Android)
        // sized to the Material CheckCircle beside it: a 13 pt disc in a 16 pt box (measured on the emulator)
        ZStack {
            Circle().fill(Color.red).frame(width: 13, height: 13)
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white)
                .accessibilityHidden(true)
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel("失败")
        #else
        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red).accessibilityLabel("失败")
        #endif
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
