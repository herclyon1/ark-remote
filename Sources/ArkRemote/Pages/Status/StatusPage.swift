import SwiftUI

/// The 状态 tab: same blocks, rows and wording as the web page (maa-automation/web/view.js render(), 状态 part), in order:
/// device card, notices (现在在跑 / 刷声骸), action tiles, stamina, 停止一切 note, shift segmented control, 这一趟,
/// 刷 4C 声骸, 机器 switches, 明日安排, 机器最近的回执. Standard controls only; Skip maps them to Android ones.
struct StatusPage: View {
    var data: StatusData
    var actions = StatusActions()

    @State var bossIndex = 1
    @State var echoUntil = "08:30"
    @State var echoNewUntil = ""

    var body: some View {
        List {
            deviceCard
            notices
            actionTiles
            staminaSection
            if let note = data.estopNote {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                        Text(note.receipt).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !data.queues.isEmpty {
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
            tomorrow
            receiptsSection
        }
        .navigationTitle("状态")
    }

    /// The Pending tag under a switch row (「已寄出 HH:MM · …」).
    @ViewBuilder private func tagLine(_ id: String) -> some View {
        if let t = data.switchTags[id] { Text(t).font(.footnote).foregroundStyle(.blue) }
    }

    // MARK: device card

    private var deviceCard: some View {
        Section {
            HStack(spacing: 12) {
                Circle().fill(data.online ? Color.green : Color.gray).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.deviceHead.isEmpty ? data.deviceName : "\(data.deviceName) · \(data.deviceHead)")
                    Text(data.deviceStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: notices

    @ViewBuilder private var notices: some View {
        if data.configUnreadable {
            Section {
                Label(data.configIsStale ? "读不到 AUTO-MAS 的配置（它没在运行？）——下面显示的是上次读到的，改了也要等它开着才生效"
                                         : "读不到 AUTO-MAS 的配置（它没在运行？）",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        if !data.busy.isEmpty && data.online {
            Section("现在在跑") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.busy.joined(separator: "、"))
                    Text("这时改设置会被推迟到跑完再生效").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if let ef = data.echoFarm {
            Section("刷声骸") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷「\(ef.name)」")
                    Text(ef.from.isEmpty ? "刷到 \(ef.until) 为止" : "刷到 \(ef.until) 为止，\(ef.from) 开始")
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
                          icon: "play.fill", tint: .blue)
            }
            Button { actions.refresh() } label: {
                tileLabel("刷新", data.lastUpdate, icon: "arrow.clockwise", tint: .gray)
            }
            Button { actions.stopAll() } label: {
                tileLabel("停止一切", "脚本和游戏", icon: "stop.fill", tint: .red)
            }
        }
    }

    private func tileLabel(_ title: String, _ sub: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(title == "停止一切" ? Color.red : Color.primary)
                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: stamina

    @ViewBuilder private var staminaSection: some View {
        if let tiles = data.stamina {
            Section {
                if tiles.isEmpty {
                    Text("正在读取…").foregroundStyle(.secondary)
                } else {
                    ForEach(tiles) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.label).font(.footnote).foregroundStyle(.secondary)
                            if let err = t.error {
                                Text(err).foregroundStyle(.red)
                            } else {
                                Text(t.cap.map { "\(t.value.map(String.init) ?? "–")/\($0)" } ?? (t.value.map(String.init) ?? "–"))
                                    .font(.title2)
                                if !t.sub.isEmpty { Text(t.sub).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            } footer: {
                if !data.staminaSource.isEmpty { Text("\(data.staminaSource) 读取，下拉刷新会重新读") }
            }
        }
    }

    // MARK: plan (这一趟 / 明日安排)

    @ViewBuilder private func planRows(_ blocks: [StatusPlanBlock]) -> some View {
        ForEach(blocks) { b in
            if let q = b.queueName {
                Toggle(isOn: Binding(get: { b.runsToday }, set: { actions.setRunsToday(q, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(q) · \(b.time)")
                        Text([b.tokyo.isEmpty ? "" : "东京 \(b.tokyo)", b.runsToday ? "今天照常" : "今天跳过，明天照常"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        tagLine(StatusSwitchID.queue(q))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.time)
                    if !b.tokyo.isEmpty { Text("东京 \(b.tokyo)").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            ForEach(b.games) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name)
                    if !g.hints.isEmpty { Text(g.hints.joined(separator: "，")).font(.footnote).foregroundStyle(.secondary) }
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
        if !rest.isEmpty {
            Section {
                planRows(rest)
            } header: {
                Text("明日安排")
            } footer: {
                Text(Self.switchFoot)
            }
        }
    }

    // MARK: 刷 4C 声骸

    private var echoFarmSection: some View {
        Section("刷 4C 声骸") {
            if let ef = data.echoFarm {
                VStack(alignment: .leading, spacing: 4) {
                    Text("改成刷到几点")
                    Text("提前或延后都行，填 21:00 这种。已经过了的时刻＝立刻收工").font(.footnote).foregroundStyle(.secondary)
                    TextField(ef.until, text: $echoNewUntil)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("刷到几点（机器时间）")
                    Text("填 08:30 这种，已过就算明天。到点自动收工、配置还原").font(.footnote).foregroundStyle(.secondary)
                    TextField("08:30", text: $echoUntil)
                }
                Button("开始刷") { actions.startEchoFarm(bossIndex, echoUntil) }
            }
        }
    }

    // MARK: 机器 (schema.js RELAY_SWITCHES, tab 状态)

    private var machineSection: some View {
        Section("机器") {
            Toggle(isOn: Binding(get: { data.skipShutdown }, set: { actions.setSkipShutdown($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下次跑完不关机")
                    Text("只跳过下一次关机，再下一趟照常关").font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.skipShutdown)
                }
            }
            Toggle(isOn: Binding(get: { data.debugModeUntil != nil }, set: { actions.setDebugMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("调试模式")
                    Text(data.debugModeUntil.flatMap { $0.isEmpty ? nil : "开着，到 \($0)——这期间跑完不关机" } ?? "开着的 90 分钟里跑完不关机，到点自动关掉")
                        .font(.footnote).foregroundStyle(.secondary)
                    tagLine(StatusSwitchID.debugMode)
                }
            }
        }
    }

    // MARK: receipts

    @ViewBuilder private var receiptsSection: some View {
        if !data.receipts.isEmpty {
            let note = [data.todayLast.isEmpty ? "" : "最近一趟 \(data.todayLast)",
                        data.todayFailed > 0 ? "失败 \(data.todayFailed) 趟" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            Section {
                ForEach(data.receipts.prefix(3)) { r in receiptRow(r, at: r.at) }
                if data.receipts.count > 3 {
                    NavigationLink {
                        StatusReceiptsPage(receipts: data.receipts)
                    } label: {
                        HStack {
                            Text("查看全部")
                            Spacer()
                            Text("\(data.receipts.count) 条").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(note.isEmpty ? "机器最近的回执" : "机器最近的回执  \(note)")
            }
        }
    }
}

func receiptRow(_ r: StatusReceipt, at: String) -> some View {
    HStack {
        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.ok ? Color.green : Color.red)
        Text(r.text)
        Spacer()
        Text(at).foregroundStyle(.secondary)
    }
}

/// 「查看全部」: every receipt grouped by day (回执只带 月-日, so the header is 「9月17日」).
struct StatusReceiptsPage: View {
    var receipts: [StatusReceipt]

    private var days: [String] {
        var seen: [String] = []
        for r in receipts { let d = String(r.at.prefix(5)); if !seen.contains(d) { seen.append(d) } }
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
                    ForEach(receipts.filter { $0.at.hasPrefix(d) }) { r in receiptRow(r, at: String(r.at.dropFirst(6))) }
                }
            }
        }
        .navigationTitle("机器最近的回执")
    }
}
