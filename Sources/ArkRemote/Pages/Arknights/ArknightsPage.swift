import SwiftUI

/// The 方舟 tab: the four sections the web remote shows for 明日方舟 (maa-automation/web/view.js:753 puts every section
/// titled 明日方舟… on this tab); the web page is the feature list only. Built as a Settings page: a Form of label-left
/// rows, each row's explanation under its name (brief 1007 "a row's explanation goes under that row's label"), and a change
/// applies when it is made — a switch or a menu at once, a text or number field when it is submitted or left (验收 10-07);
/// ArknightsTab sends it.
struct ArknightsPage: View {
    @Binding var data: ArknightsPageData
    /// The line under each row, by field path: sending, the receipt, or why a typed value was not sent (GameRowStatus).
    var status: [String: GameRowStatus] = [:]
    /// Rows whose change is on its way: their control is disabled until it has gone (brief 1007 "disabled instead of
    /// hidden or after-the-fact error").
    var busy: Set<String> = []
    /// 再发一次 on a 「没生效」 / 「没回执」 row (pending.js:85 resend).
    var onResend: (String) -> Void = { _ in }
    /// Switches to the 状态 tab, where the shift is picked (HIG Writing: "provide a direct link or button, rather than
    /// trying to describe its location").
    var onShowStatus: () -> Void = {}
    /// A reselect of the 方舟 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.arknights }

    var body: some View {
        Form {
            // listSection, not a bare `if`: a false `if` at the top of a List draws an empty grey section on Android (SkipFixes.swift)
            listSection("ark-notinshift", if: data.notInShift) {
                Section {
                    Text(verbatim: "\(data.shiftName.isEmpty ? "这个班次" : data.shiftName)不跑明日方舟。")
                        .foregroundStyle(.secondary)
                    Button("换班次") { onShowStatus() }
                }
            }
            stageSection
            infrastSection
            awardSection
            weeklySection
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new Form, whose new scroll state starts at
        // the real top. Not scrollTo(the first row): the top inset and the first section's top stay above the screen, the
        // first card's top edge cut under the title (StatusPage.swift explains, at its own .id(reselect)). Form is
        // skip-ui's List (Form.swift:9-14).
        .id(reselect)
        .keyboardDone()
    }

    // MARK: 明日方舟 (schema.js:116-127)

    /// Each row's explanation, as schema.js:124-133 writes it.
    private static let hints: [String: String] = [
        "Info.Stage": "游戏内的关卡号，例如 1-7（常规）、CE-6（龙门币）、AT-4（活动关）",
        "Info.MedicineNumb": "一趟最多使用几瓶理智药。0＝不使用；999＝不限量",
        "Task.IfFight": "关掉后不刷关卡，只做基建、公招等日常",
        "Task.IfActivityFirst": "有活动就刷活动关，活动结束后自动回到上面那个固定关",
        "Task.ActivityStageIndex": "活动关卡列表从上往下数，第一关是 1。只在「活动关优先」开着时才有用",
        "Infrast/UsesOfDrones": "贸易站＝加速龙门币或合成玉订单，制造站＝加速对应产物",
        "Award/Mail": "每趟顺手把邮箱里的奖励全收了。关着邮件会一直躺着，到期作废",
        "Award/Orundum": "每天去幸运墙领那份合成玉",
        "Award/Mining": "有限时开采许可时每天领它的合成玉",
        "Award/SpecialAccess": "周年送的月卡每天的那份也领",
    ]

    private var hasStageRows: Bool {
        data.stage != nil || data.medicineNumb != nil || data.ifFight != nil || data.ifActivityFirst != nil
            || data.activityStageIndex != nil
    }

    /// view.js:798-801: a section with no rows is not drawn.
    var stageSection: some View {
        listSection("ark-stage", if: data.configUnreadable || hasStageRows) {
        Section {
            // view.js:309-311: AUTO-MAS not running → the last config read, said so.
            if data.configUnreadable {
                // set_config fails at once when AUTO-MAS does not answer (commands.py:338-341), it is not held (审查 B16)
                warning(data.configStale
                    ? "读不到 AUTO-MAS 的配置（它没在运行？），下面是上次读到的；它没在运行时改的会失败"
                    : "读不到 AUTO-MAS 的配置（它没在运行？）")
            }
            if data.stage != nil {
                row("Info.Stage") {
                    ArknightsTextRow(label: label("Info.Stage", "关卡"), hint: Self.hints["Info.Stage"],
                                     text: binding(\.stage, default: ""))
                }
            }
            if data.medicineNumb != nil {
                row("Info.MedicineNumb") {
                    ArknightsNumberRow(label: label("Info.MedicineNumb", "理智药"), hint: Self.hints["Info.MedicineNumb"],
                                       text: binding(\.medicineNumb, default: ""))
                }
            }
            if data.ifFight != nil {
                row("Task.IfFight") {
                    ArknightsToggleRow(label: label("Task.IfFight", "作战开关"), hint: Self.hints["Task.IfFight"],
                                       isOn: binding(\.ifFight, default: false))
                }
            }
            if data.ifActivityFirst != nil {
                row("Task.IfActivityFirst") {
                    ArknightsToggleRow(label: label("Task.IfActivityFirst", "活动关优先"),
                                       hint: Self.hints["Task.IfActivityFirst"],
                                       isOn: binding(\.ifActivityFirst, default: false))
                }
            }
            if data.activityStageIndex != nil {
                row("Task.ActivityStageIndex") {
                    ArknightsNumberRow(label: label("Task.ActivityStageIndex", "活动关序号"),
                                       hint: Self.hints["Task.ActivityStageIndex"],
                                       text: binding(\.activityStageIndex, default: ""))
                }
            }
        } header: {
            Text("明日方舟")
        }
        }
    }

    // MARK: 明日方舟 · 基建 (schema.js:128-131)

    /// view.js:973 (layoutTabs): a master section is drawn when its card holds anything — a row or a warning.
    private var masterHasNotes: Bool { data.masterUnreadable || data.masterStale || !data.masterNotes.isEmpty }

    var infrastSection: some View {
        listSection("ark-infrast", if: masterHasNotes || data.usesOfDrones != nil) {
        Section {
            if data.masterUnreadable {
                warning(Self.masterUnreadableText)
            } else {
                masterWarnings
                if data.usesOfDrones != nil {
                    row("Infrast/UsesOfDrones") {
                        ArknightsPickerRow(label: label("Infrast/UsesOfDrones", "无人机用在哪"),
                                           hint: Self.hints["Infrast/UsesOfDrones"],
                                           options: data.usesOfDronesOptions,
                                           selection: binding(\.usesOfDrones, default: ""))
                    }
                }
            }
        } header: {
            Text("明日方舟 · 基建")
        }
        }
    }

    // MARK: 明日方舟 · 领取奖励 (schema.js:132-141)

    private var hasAwardRows: Bool {
        data.awardMail != nil || data.awardOrundum != nil || data.awardMining != nil || data.awardSpecialAccess != nil
    }

    var awardSection: some View {
        listSection("ark-award", if: masterHasNotes || hasAwardRows) {
        Section {
            if data.masterUnreadable {
                warning(Self.masterUnreadableText)
            } else {
                masterWarnings
                if data.awardMail != nil {
                    row("Award/Mail") {
                        ArknightsToggleRow(label: label("Award/Mail", "领取所有邮件奖励"), hint: Self.hints["Award/Mail"],
                                           isOn: binding(\.awardMail, default: false))
                    }
                }
                if data.awardOrundum != nil {
                    row("Award/Orundum") {
                        ArknightsToggleRow(label: label("Award/Orundum", "领取幸运墙的每日合成玉"),
                                           hint: Self.hints["Award/Orundum"],
                                           isOn: binding(\.awardOrundum, default: false))
                    }
                }
                if data.awardMining != nil {
                    row("Award/Mining") {
                        ArknightsToggleRow(label: label("Award/Mining", "领取限时开采许可的合成玉"),
                                           hint: Self.hints["Award/Mining"],
                                           isOn: binding(\.awardMining, default: false))
                    }
                }
                if data.awardSpecialAccess != nil {
                    row("Award/SpecialAccess") {
                        ArknightsToggleRow(label: label("Award/SpecialAccess", "领取周年赠送月卡"),
                                           hint: Self.hints["Award/SpecialAccess"],
                                           isOn: binding(\.awardSpecialAccess, default: false))
                    }
                }
            }
        } header: {
            Text("明日方舟 · 领取奖励")
        }
        }
    }

    // MARK: 明日方舟 · 周常 (view.js:519-523; shown only when MAA is in this shift)

    var weeklySection: some View {
        listSection("ark-weekly", ifLet: data.annihilationDoneThisWeek) { done in
            Section {
                // annihilation.py:56-65 counts the week from Monday 04:00 Beijing = 05:00 Tokyo (审查 B4)
                LabeledContent {
                    Text(done ? "本周已打满" : "本周还没打满")
                } label: {
                    EWRowTitle(label: "剿灭", hint: "打满本周剿灭后自动停掉，下周一 05:00（东京时间）自动恢复")
                }
            } header: {
                Text("明日方舟 · 周常")
            }
        }
    }

    private static let masterUnreadableText = "这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改"

    /// The notes at the top of a master section (view.js:482-493): the master copy is the last one read (said once inside
    /// each master section), then 「名字没翻译出来」 and 「定义文件里没有这些任务」.
    @ViewBuilder private var masterWarnings: some View {
        if data.masterStale {
            warning("配置文件这次读不到，下面是上次读到的；改了要等它能读到才生效")
        }
        ForEach(data.masterNotes, id: \.self) { note in
            warning(note)
        }
    }

    /// The shared warning row (Pages/Shell/A11y.swift warningLabel), in orange as on the 状态 / 终末地 / 鸣潮 tabs.
    private func warning(_ text: String) -> some View {
        warningLabel(text)
            .foregroundStyle(.orange)
    }

    /// The machine's name for the row (view.js labelOf), else ours.
    private func label(_ path: String, _ fallback: String) -> String {
        data.labels[path] ?? fallback
    }

    /// A row with its status line under it (GameRowStatus); disabled while its change is on its way.
    private func row<Row: View>(_ path: String, @ViewBuilder _ content: () -> Row) -> some View {
        content()
            .disabled(busy.contains(path))
            .gameRowStatus(status[path], onResend: onResend)
            .id("ark-row-" + path)   // constant per row, so the shape stays one
    }

    /// A binding to an optional field that the row only draws when the field is non-nil.
    private func binding<T>(_ keyPath: WritableKeyPath<ArknightsPageData, T?>, default fallback: T) -> Binding<T> {
        Binding(
            get: { data[keyPath: keyPath] ?? fallback },
            set: { data[keyPath: keyPath] = $0 }
        )
    }
}

struct ArknightsToggleRow: View {
    let label: String
    var hint: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            EWRowTitle(label: label, hint: hint)
        }
    }
}

/// The stage code, label left and field right as a Settings text row. What is typed stays in the field and is written to
/// the page (and so sent) when it is submitted or the field is left; it is checked as it is typed against the relay's
/// stage pattern (EWSave.stageOK, commands.py _STAGE_RE), so a code it would refuse is said before anything goes out
/// (HIG Text fields: "Validate fields when it makes sense").
struct ArknightsTextRow: View {
    let label: String
    var hint: String? = nil
    @Binding var text: String
    /// What is typed, while editing; nil = the field shows `text`.
    @State var draft: String? = nil
    @FocusState var focused: Bool

    private var typedProblem: String? {
        guard let d = draft?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !d.isEmpty else { return nil }
        return EWSave.stageOK(d) ? nil : "要写成 1-7、CE-6 这种"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                // a stage code (1-7, CE-6): an auto-capital or an autocorrection made it a code the relay's pattern refuses or
                // another stage (edge audit 30); the same input traits as the setup screen's mailbox field
                TextField(label, text: Binding(get: { draft ?? text }, set: { draft = $0 }), prompt: Text("未设"))
                    .multilineTextAlignment(.trailing)
                    .setupPlainInput()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { commit() }
            } label: {
                EWRowTitle(label: label, hint: hint)
            }
            if let typedProblem {
                Text(verbatim: typedProblem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { _, now in
            if !now { commit() }
        }
    }

    private func commit() {
        guard let d = draft else { return }
        draft = nil
        if d != text { text = d }
    }
}

/// A number, label left and field right: iOS's number field (TextField(value:format:), HIG Text fields: "Use a number
/// formatter to help with numeric data"), so full-width digits from a Chinese keyboard (１２) read as 12 without a filter of
/// our own (IntegerFormatStyle parses them; checked with swift, 10-07). The page keeps the value as the box's text ("" =
/// null, view.js:503 / 1097). What is typed is written to the page when the field is left or submitted: SwiftUI on iOS
/// hands a formatted field's value over then, skip-fuse-ui on each keystroke (TextField.swift:26-40), so the row holds it
/// until focus goes in both cases. The 0 / 999 meaning is in the hint; 999 is a valid value, so no stepper.
struct ArknightsNumberRow: View {
    let label: String
    var hint: String? = nil
    @Binding var text: String
    /// The typed value while editing; .none = the field shows `text`, .some(nil) = emptied.
    @State var draft: Int?? = nil
    @FocusState var focused: Bool

    var body: some View {
        LabeledContent {
            TextField(label, value: Binding<Int?>(get: { draft ?? Int(text) }, set: { draft = .some($0) }),
                      format: .number.grouping(.never), prompt: Text("未设"))
                .multilineTextAlignment(.trailing)
                .setupNumberInput()
                .focused($focused)
                .onSubmit { commit() }
        } label: {
            EWRowTitle(label: label, hint: hint)
        }
        // iOS writes a formatted field's value as focus leaves, in either order with the focus change: whichever comes
        // second commits it
        .onChange(of: focused) { _, now in
            if !now { commit() }
        }
        .onChange(of: draft) { _, _ in
            if !focused { commit() }
        }
    }

    private func commit() {
        guard let d = draft else { return }
        draft = nil
        let s = d.map { String($0) } ?? ""
        if s != text { text = s }
    }
}

struct ArknightsPickerRow: View {
    let label: String
    var hint: String? = nil
    let options: [ArknightsOption]
    @Binding var selection: String

    /// view.js:559: a null value gets a hidden, disabled 「未设」 option, selected, so the select reads 「未设」 until another
    /// item is picked; it is listed here only while nothing is set. A value the list does not have is listed as
    /// 「未知：<value>」 and selected: as the web's <select> it read as the first item, a value the machine does not have
    /// (审查 B13; mastercfg.py:569-570 passes gui.new.json's value as is).
    private var shown: [ArknightsOption] {
        let unset = selection.isEmpty && !options.contains { $0.value.isEmpty }
        let unknown = !selection.isEmpty && !options.contains { $0.value == selection }
        return (unset ? [ArknightsOption(label: "未设", value: "")] : [])
            + (unknown ? [ArknightsOption(label: "未知：\(selection)", value: selection)] : []) + options
    }

    var body: some View {
        // menuPicker (SkipFixes.swift): inside the row's VStack (its status line) a bare Picker loses its title on Android
        menuPicker(selection: Binding(
            get: { shown.contains { $0.value == selection } ? selection : (options.first?.value ?? "") },
            set: { selection = $0 }
        )) {
            ForEach(shown) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        } title: {
            EWRowTitle(label: label, hint: hint)
        }
    }
}
