// The 鸣潮 (OK-WW) tab. Same cards and rows as the web page's 鸣潮 tab (view.js:754 TABS /^鸣潮/):
// the 「鸣潮」 card (schema.js:220-239) with the relay's 无音区结算截图 switch at its end (RELAY_SWITCHES, view.js:514),
// then 「鸣潮 · 周常」 (view.js:524-535). 刷 4C 声骸 is not here: its header matches no tab, so the web page puts it on 状态.
// The page draws and reports changes; WuwaTab (Pages/Shell) feeds it and sends each change as it is made.

import SwiftUI

/// The 鸣潮 card, copied from schema.js:220-239 (labels and hints verbatim).
enum WuwaSchema {
    /// 无音区: OK-WW stores only the index into the game's F2 list; each index drops two echo sets (schema.js:54).
    /// 3.7 list (2026-09-30), row for row as relay/ark_relay/wuwa_tacet.py TACET and schema.js:60-68.
    static let tacet: [(names: [String], value: Int)] = [
        (["衔梦照世之心", "茜染怀想之花"], 1),
        (["衔梦照世之心", "镜影流电之瞬"], 2),
        (["羽落空尘之歌", "冥途夜行之灯"], 3),
        (["羽落空尘之歌", "清邪荡煞之心"], 4),
        (["雪落无声之愿", "剪心辑梦之影"], 5),
        (["听唤语义之愿", "长路启航之星"], 6),
        (["长路启航之星", "斑驳粉饰之沫"], 7),
    ]

    /// Echo set icons in Module.xcassets, exported verbatim from schema.js SET_ICONS (76×76 PNGs from the Kuro wiki, oldest first).
    /// Asset names stay ASCII because they become Android resources.
    static let setIcons: [String: String] = [
        "长路启航之星": "echo-set-1",
        "斑驳粉饰之沫": "echo-set-2",
        "听唤语义之愿": "echo-set-3",
        "雪落无声之愿": "echo-set-4",
        "剪心辑梦之影": "echo-set-5",
        "羽落空尘之歌": "echo-set-6",
        "清邪荡煞之心": "echo-set-7",
        "冥途夜行之灯": "echo-set-8",
        "衔梦照世之心": "echo-set-9",
        "镜影流电之瞬": "echo-set-10",
        "茜染怀想之花": "echo-set-11",
    ]

    /// 凝素领域: all 15 of relay wuwa_forgery.py FORGERY (27-43), three regions in the order 迅刀 / 音感仪 / 长刃 / 臂铠 / 佩枪
    /// (schema.js:75 had the 梦州 five only; a machine set to 6–15 showed no choice, 审查 B12).
    static let forge: [EWChoice] = [
        EWChoice("1 · 迅刀（陨翼云渊）", "1"),
        EWChoice("2 · 音感仪（静灭云渊）", "2"),
        EWChoice("3 · 长刃（裂斩云渊）", "3"),
        EWChoice("4 · 臂铠（碎蚀云渊）", "4"),
        EWChoice("5 · 佩枪（沉熄云渊）", "5"),
        EWChoice("6 · 迅刀（荒蓁旧殿）", "6"),
        EWChoice("7 · 音感仪（残照终课）", "7"),
        EWChoice("8 · 长刃（灾逆旧殿）", "8"),
        EWChoice("9 · 臂铠（虚诞终课）", "9"),
        EWChoice("10 · 佩枪（余烬终课）", "10"),
        EWChoice("11 · 迅刀（赦罪庭园）", "11"),
        EWChoice("12 · 音感仪（浸礼海渊）", "12"),
        EWChoice("13 · 长刃（赞颂庭园）", "13"),
        EWChoice("14 · 臂铠（祝祭海渊）", "14"),
        EWChoice("15 · 佩枪（告解海渊）", "15"),
    ]

    static let group = EWGroupSpec(title: "鸣潮", fields: [
        EWFieldSpec(path: "DailyTask.json/Which to Farm", type: .text, label: "体力刷什么",
                    hint: "每天的体力花在哪"),
        EWFieldSpec(path: "DailyTask.json/Material Selection", type: .text, label: "刷哪种材料",
                    hint: "只在上面选「模拟领域」时才有用"),
        EWFieldSpec(path: "DailyTask.json/Which Forgery Challenge to Farm", type: .select, label: "凝素领域打哪个",
                    hint: "按想要的武器材料挑。只在上面选「凝素领域」时才有用", choices: forge),
        EWFieldSpec(path: "DailyTask.json/Which Tacet Suppression to Farm", type: .icons, label: "无音区打哪个",
                    hint: "按想要的声骸套装挑。只在上面选「无音区」时才有用",
                    choices: tacet.map { EWChoice($0.names.joined(separator: " ＋ "), String($0.value)) }),
        EWFieldSpec(path: "NightmareNestTask.json/Only Farm These Nests", type: .text, label: "残象聚落点位",
                    hint: "只刷落渊南丘，这是定好的。要换点位在电脑上改", readOnly: true),
    ])
}

/// Input for the page: snap.master["OK-WW"], the relay's own switch and the weekly block (relay["周常"]).
struct WuwaPageData {
    var master: EWMaster
    var lastGoodMaster: EWMaster? = nil
    /// relay["无音区截图"]
    var tacetShots = false
    /// relay["周常"]["周常乐园"]["本周已完成"]
    var parkDone = false
    /// relay["周常"]["周本"]["本周已打"]
    var weeklyBossDone = false
    /// relay["周常"]["周本"]["第几个周本"]
    var weeklyBossIndex = 1
    /// Row key (a config path, WuwaPage.tacetKey, WuwaPage.bossKey) -> the line under that row.
    var status: [String: GameRowStatus] = [:]
    /// Row keys whose change is on its way: the control is disabled until it has gone.
    var busy: Set<String> = []

    static let sample = WuwaPageData(master: .wuwaSample)
}

/// The 鸣潮 tab as a Settings page: the 「鸣潮」 section with the relay's 无音区结算截图 switch at its end, then 「鸣潮 · 周常」.
/// Each row's explanation sits under its name (brief 1007); a change applies when it is made — a switch, a menu or a pick
/// at once, a text field (a config row the machine gives no choices for) when it is submitted (验收 10-07). WuwaTab sends it.
struct WuwaPage: View {
    static let tacetKey = "relay|tacet_shots"
    static let bossKey = "wb|OK-WW|第几个周本"

    var data: WuwaPageData
    /// A config row's new value (path, value), to send now.
    var onChange: (String, EWValue) -> Void
    /// (switch id as the web page names it, new state): "relay|tacet_shots"
    var onRelaySwitch: (String, Bool) -> Void
    var onWeeklyBossIndex: (Int) -> Void
    var onResend: (String) -> Void

    /// The rows' working copy (EWRowView writes into it as the control changes).
    @State var values: [String: EWValue]
    /// Text rows typed in and not yet submitted, by path.
    @State var typed: [String: EWValue] = [:]
    /// A reselect of the 鸣潮 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.wuwa }

    init(data: WuwaPageData,
         onChange: @escaping (String, EWValue) -> Void = { _, _ in },
         onRelaySwitch: @escaping (String, Bool) -> Void = { _, _ in },
         onWeeklyBossIndex: @escaping (Int) -> Void = { _ in },
         onResend: @escaping (String) -> Void = { _ in }) {
        self.data = data
        self.onChange = onChange
        self.onRelaySwitch = onRelaySwitch
        self.onWeeklyBossIndex = onWeeklyBossIndex
        self.onResend = onResend
        _values = State(initialValue: ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:])
    }

    var body: some View {
        List {
            gameCard
            weeklyCard
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. Not scrollTo(the first row): the top inset and the first section's top stay above the screen, the
        // first card's top edge cut under the title (StatusPage.swift explains, at its own .id(reselect)).
        .id(reselect)
        .keyboardDone()
        // a text row goes out when it is submitted (onSubmit reaches every text field in the List)
        .onSubmit {
            let out = typed
            typed = [:]
            for (path, v) in out { onChange(path, v) }
        }
        .onChange(of: data.master.values) { _, _ in
            values = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:]
            typed = [:]
        }
    }

    /// OK-WW declares which sub-items belong to which 「体力刷什么」 choice (sub_configs); the others are hidden (view.js:436-443).
    private func hidden(_ m: EWMaster) -> Set<String> {
        let picked = values["DailyTask.json/Which to Farm"]?.key
        var out = Set<String>()
        for (k, paths) in m.subs where k != picked { out.formUnion(paths) }
        return out
    }

    @ViewBuilder
    private var gameCard: some View {
        let (m, notes) = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster)
        let rows = gameRows(m, notes)
        Section {
            if let m {
                ForEach(rows) { row in
                    EWRowView(row: row, values: $values, readonly: m.readonly,
                              onChange: { path, v in changed(row, path, v) }, onResend: onResend, showHint: true)
                        .disabled(data.busy.contains(row.path))
                        .gameRowStatus(row.kind == .warning ? nil : data.status[row.path], onResend: onResend)
                }
                // The relay's own switch for OK-WW (schema.js RELAY_SWITCHES tab "OK-WW"); not part of any config file.
                Toggle(isOn: Binding(get: { data.tacetShots }, set: { onRelaySwitch(Self.tacetKey, $0) })) {
                    EWRowTitle(label: "无音区结算截图", hint: "日报后面带上无音区打完的两张结算图")
                }
                .disabled(data.busy.contains(Self.tacetKey))
                .gameRowStatus(data.status[Self.tacetKey], onResend: onResend)
            } else {
                // view.js:478-480: no 母本 and no earlier copy → the card is only this line; the switch is not drawn either
                warningLabel("这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(WuwaSchema.group.title)
        }
    }

    /// A switch, menu or pick goes out at once; a text row waits for its submit.
    private func changed(_ row: EWRow, _ path: String, _ v: EWValue) {
        switch row.kind {
        case .text, .number, .box: typed[path] = v
        default: onChange(path, v)
        }
    }

    /// The 母本's rows: the notes about an earlier copy first, then the fields the 体力 choice opens.
    private func gameRows(_ master: EWMaster?, _ notes: [String]) -> [EWRow] {
        guard let m = master else { return [] }
        return notes.enumerated().map { EWRow(id: "warn-\(WuwaSchema.group.title)-\($0.offset)", kind: .warning, path: "", label: $0.element) }
            + ewRows(WuwaSchema.group, m, values: values, hidden: hidden(m))
    }

    /// 周本打第几个: weeklyboss.py:219 takes 1–20; a value the machine reports outside that is listed too, as it is.
    private var bossChoices: [Int] {
        let n = data.weeklyBossIndex
        return Array(1...20) + ((1...20).contains(n) ? [] : [n])
    }

    /// Weekly items: done this week stops them, Monday 04:00 brings them back (view.js:510-535).
    private var weeklyCard: some View {
        Section {
            LabeledContent {
                Text(data.parkDone ? "本周已完成" : "本周还没做")
            } label: {
                EWRowTitle(label: "周常乐园", hint: "不花体力。做完就停到下周一")
            }
            LabeledContent {
                Text(data.weeklyBossDone ? "本周已领满" : "本周还没领满")
            } label: {
                EWRowTitle(label: "周本 战歌重奏", hint: "花体力。一周领 3 次奖励、每次 60 结晶波片、固定打 90 级，领满就停到下周一")
            }
            // a small range: a menu Picker, not a text field (brief 1007 "Numbers: … Picker for small ranges")
            // menuPicker (SkipFixes.swift): inside the row's VStack (its status line) a bare Picker loses its title on Android
            menuPicker(selection: Binding(get: { data.weeklyBossIndex }, set: { onWeeklyBossIndex($0) })) {
                ForEach(bossChoices, id: \.self) { n in
                    Text(verbatim: "\(n)").tag(n)
                }
            } title: {
                EWRowTitle(label: "周本打第几个",
                           hint: "游戏里按 F2 打开周本列表，从上往下数，第一个是 1。新 Boss 上线顺序会变，换本时记得来改")
            }
            .disabled(data.busy.contains(Self.bossKey))
            .gameRowStatus(data.status[Self.bossKey], onResend: onResend)
        } header: {
            Text("鸣潮 · 周常")
        }
    }
}
