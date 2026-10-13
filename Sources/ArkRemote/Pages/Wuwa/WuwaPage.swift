// The 鸣潮 (OK-WW) tab. Same cards and rows as the web page's 鸣潮 tab (view.js:754 TABS /^鸣潮/):
// the 「鸣潮」 card (schema.js:220-239) with the relay's 无音区结算截图 switch at its end (RELAY_SWITCHES, view.js:514),
// then the weekly card (view.js:524-535, 「鸣潮 · 周常」 there; 「每天」 / 「每周」 here). 刷 4C 声骸 is not here: its header matches no tab, so the web page puts it on 状态.
// Data, saving and the tab bar are wired by 验收 once the logic layer lands; this page only draws and reports edits.
// Apple counterpart by purpose (BOARD/app-page-references.txt P2): Shortcuts › Automation › an automation's editor, which
// sets what a job that runs by itself on a schedule does (menu values, switches, label + value rows in a grouped list);
// not Settings, which changes this phone at once. The 无音区 pick sheet follows P4 (Shortcuts › Weekly days, one row per
// choice with a checkmark). Changes still wait for 保存 → 确认 → 寄出 (EWSaveBar).

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

    /// Each hint says what the row does, shortened in place (design rule 8; BOARD/App-待他定项-从记录定-1014.md W4): no
    /// 「只在上面选…时才有用」, since those rows are hidden for the other choices (`hidden(_:)`). The hints are only read in
    /// the card's footer, with no 「行名：」 in front (A2/W4), so each names its subject; a row whose name already says
    /// everything has none (体力刷什么, 刷哪种材料: it is shown only once 模拟领域 is picked).
    static let group = EWGroupSpec(title: "鸣潮", fields: [
        EWFieldSpec(path: "DailyTask.json/Which to Farm", type: .text, label: "体力刷什么",
                    hint: nil),
        EWFieldSpec(path: "DailyTask.json/Material Selection", type: .text, label: "刷哪种材料",
                    hint: nil),
        EWFieldSpec(path: "DailyTask.json/Which Forgery Challenge to Farm", type: .select, label: "凝素领域打哪个",
                    hint: "凝素领域按想要的武器材料挑。", choices: forge),
        // our own name: OK-WW's 「刷第几个无音区 (F2列表)」 wrapped the name and the value onto two lines each (review 鸣潮 2)
        EWFieldSpec(path: "DailyTask.json/Which Tacet Suppression to Farm", type: .icons, name: "无音区打哪个",
                    hint: "无音区按想要的声骸套装挑。",
                    choices: tacet.map { EWChoice($0.names.joined(separator: " ＋ "), String($0.value)) }),
        // the first two settlements (his 10-12 11:17 「我要的就是要刷前两个残像聚落，第2个就是落渊南丘」; the relay's
        // mastercfg_okww.py ONLY_NESTS 梦枢天罗、落渊南丘); the old 「只刷落渊南丘」 was out of date
        EWFieldSpec(path: "NightmareNestTask.json/Only Farm These Nests", type: .text, label: "残象聚落点位",
                    hint: "残象聚落只刷列表里的前两个，这是定好的，要换在电脑上改。", readOnly: true),
    ])
}

/// Placeholder input for the page: snap.master["OK-WW"], the relay's own switch and the weekly block (relay["周常"]).
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
    /// path (or "relay|tacet_shots", "wb|OK-WW|第几个周本") -> the small lines under that row.
    var tags: [String: EWRowTag] = [:]

    static let sample = WuwaPageData(master: .wuwaSample)
}

struct WuwaPage: View {
    var data: WuwaPageData
    var onChange: (String, EWValue) -> Void
    /// (switch id as the web page names it, new state): "relay|tacet_shots"
    var onRelaySwitch: (String, Bool) -> Void
    var onWeeklyBossIndex: (Int) -> Void
    var onResend: (String) -> Void

    @State var values: [String: EWValue]
    @State var tacetShots: Bool
    @State var bossIndex: Int
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
        _tacetShots = State(initialValue: data.tacetShots)
        _bossIndex = State(initialValue: data.weeklyBossIndex)
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
        .onChange(of: data.master.values) { _, _ in
            values = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:]
        }
        .onChange(of: data.tacetShots) { _, v in tacetShots = v }
        .onChange(of: data.weeklyBossIndex) { _, v in bossIndex = v }
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
        // view.js:976-995: the hints sit under the card; the 无音区结算截图 switch is one of its rows.
        // Only when the 母本 is readable: otherwise the card is the one warning line.
        let foot = m == nil ? "" : Self.dailyFoot(rows)
        Section {
            if let m {
                ForEach(rows) { row in
                    EWRowView(row: row, values: $values, readonly: m.readonly, onChange: onChange,
                              tag: data.tags[row.path], onResend: onResend, showHint: false)
                }
                // The relay's own switch for OK-WW (schema.js RELAY_SWITCHES tab "OK-WW"); not part of any config file.
                tagged("relay|tacet_shots") {
                    Toggle(isOn: Binding(get: { tacetShots }, set: { tacetShots = $0; onRelaySwitch("relay|tacet_shots", $0) })) {
                        EWRowTitle(label: "无音区结算截图", hint: nil)
                    }
                }
            } else {
                // view.js:478-480: no 母本 and no earlier copy → the card is only this line; the switch is not drawn either
                warningLabel("这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改")
                    .foregroundStyle(.orange)
            }
        } header: {
            // the page is 鸣潮 already: the header names the group (review 鸣潮 3; Shortcuts' 「Personal」, P6)
            Text("每天")
        } footer: {
            if !foot.isEmpty { Text(verbatim: foot) }
        }
    }

    /// The 母本's rows: the notes about an earlier copy first, then the fields the 体力 choice opens.
    private func gameRows(_ master: EWMaster?, _ notes: [String]) -> [EWRow] {
        guard let m = master else { return [] }
        return notes.enumerated().map { EWRow(id: "warn-\(WuwaSchema.group.title)-\($0.offset)", kind: .warning, path: "", label: $0.element) }
            + ewRows(WuwaSchema.group, m, values: values, hidden: hidden(m))
    }

    /// The relay's range for 周本打第几个 (weeklyboss.py:219; the same check before sending, Logic/Edits.swift problem()).
    static let bossRange = 1...20

    /// The 每天 card's footer: the drawn rows' hints, then the 无音区结算截图 switch's, one sentence a line. No 「行名：」 list in
    /// front: it repeated every row name right above it (decision A2/W4, BOARD/App-待他定项-从记录定-1014.md).
    static func dailyFoot(_ rows: [EWRow]) -> String {
        (rows.filter { $0.kind != .warning }.map(\.hint) + [tacetShotsHint])
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The 每周 card's footer (view.js:976-995), no 「行名：」 list (A2/W4): each sentence names what it is about.
    static let weeklyFoot = "周常乐园不花体力，做完就停到下周一。\n"
        + "周本花体力，一周领 3 次奖励，领满就停到下周一。\n"
        + "周本的序号在游戏里按 F2 打开周本列表从上往下数，第一个是 1。新 Boss 上线顺序会变，换本时记得来改。"

    /// Weekly items: done this week stops them, Monday 04:00 brings them back (view.js:510-535).
    /// Read-only lines are the system label + value row (LabeledContent: the name leading, the value trailing in the
    /// secondary colour), as Shortcuts' automation editor shows 「Event  Time of Day」 (reference P2).
    private var weeklyCard: some View {
        Section {
            LabeledContent("周常乐园") {
                Text(data.parkDone ? "本周已完成" : "本周还没做").foregroundStyle(.secondary)   // Android: LabeledContent does not grey its value
            }
            // the name, and the boss under it in grey (the system's subtitle in a LabeledContent label)
            LabeledContent {
                Text(data.weeklyBossDone ? "本周已领满" : "本周还没领满").foregroundStyle(.secondary)
            } label: {
                Text("周本")
                Text("战歌重奏")
            }
            // A small whole number in a fixed range is a stepper with its value beside it (HIG Steppers: "Make the value
            // that a stepper affects obvious."; the App's own 充值了 N 次, MonthCardRows.swift). − is off at 1, + at 20,
            // so a value the relay refuses can no longer be entered (it was typed, then refused at 寄出 with 「要填 1–20」).
            tagged("wb|OK-WW|第几个周本") {
                Stepper(value: Binding(get: { bossIndex }, set: { n in
                    bossIndex = n
                    onWeeklyBossIndex(n)
                }), in: Self.bossRange) {
                    LabeledContent("周本打第几个") {
                        Text(verbatim: String(bossIndex)).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("每周")
        } footer: {
            Text(verbatim: Self.weeklyFoot)
        }
    }

    /// A row with its small lines under it, same as the config rows (EWRowView): one shape with or without them.
    private func tagged<Row: View>(_ key: String, @ViewBuilder _ row: () -> Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row()
            if let tag = data.tags[key] {
                EWTagLine(tag: tag, onResend: onResend)
            }
        }
        .listRowBackground(rowBackground(nil))   // no state tint (EWRowView); never nil on Android (SkipFixes.swift)
    }
}
