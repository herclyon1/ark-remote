import SwiftUI

/// The 方舟 tab: the four sections the web remote shows for 明日方舟
/// (maa-automation/web/view.js:753 puts every section titled 明日方舟… on this tab).
/// Labels and hints are copied from web/schema.js:116-141 and view.js:519-523; the hints sit in each section's footer
/// (view.js:978-995).
/// Plain SwiftUI controls only; Skip renders them as Android-native controls.
struct ArknightsPage: View {
    @Binding var data: ArknightsPageData
    /// 再发一次 under a 「没生效」 row (pending.js:85 resend).
    var onResend: (String) -> Void = { _ in }
    /// Paths with an unsaved edit: 「待保存」 under the row and a tinted row (view.js:1268-1275).
    var edited: Set<String> = []
    /// A reselect of the 方舟 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.arknights }

    var body: some View {
        Form {
            // listSection, not a bare `if`: a false `if` at the top of a List draws an empty grey section on Android (SkipFixes.swift)
            listSection("ark-notinshift", if: data.notInShift) {
                Section {
                    Text(verbatim: "\(data.shiftName.isEmpty ? "这个班次" : data.shiftName)不跑明日方舟。换班次在「状态」页。")
                        .foregroundStyle(.secondary)
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
        // the title (the tab's name, or 「待保存 N 项」 while changes wait, view.js:1554) is set by ArknightsTab's EWSaveBar
    }

    // MARK: 明日方舟 (schema.js:116-127)

    /// Each row's hint (schema.js:124-133), one sentence of what the row does, in words rather than 「0＝」 signs (HIG
    /// Lists: "Keep item text succinct so row content is comfortable to read."; design rule 8).
    private static let hints: [String: String] = [
        "Info.Stage": "游戏里的关卡号，如 1-7、CE-6、AT-4。",
        "Info.MedicineNumb": "一趟最多用几瓶，填 0 不用，填 999 不限。",
        "Task.IfFight": "关掉后只做基建、公招等日常，不刷关卡。",
        "Task.IfActivityFirst": "有活动先刷活动关，活动结束后回到上面的关卡。",
        "Task.ActivityStageIndex": "活动关卡列表从上往下数第几关，活动关优先开着时才用。",
        "Infrast/UsesOfDrones": "贸易站加速订单，制造站加速产物。",
        "Award/Mail": "每趟收下邮箱里的奖励，关着的话邮件到期作废。",
        "Award/Orundum": "每天去幸运墙领合成玉。",
        "Award/Mining": "有限时开采许可时每天领合成玉。",
        "Award/SpecialAccess": "周年送的月卡每天也领。",
    ]

    /// view.js:978-995 (layoutTabs): the hints leave the rows for a footer under the card, one line each, prefixed with
    /// 「行名：」 when the card has more than one row. `rows` = the rows drawn, in order.
    private func hintFooter(_ rows: [ArknightsHintRow]) -> some View {
        let lines = rows.compactMap { row -> String? in
            guard let hint = Self.hints[row.path] else { return nil }
            let title = label(row.path, row.name)
            return (rows.count > 1 && !title.isEmpty ? title + "：" : "") + hint
        }
        return Group {
            if !lines.isEmpty {
                Text(verbatim: lines.joined(separator: "\n"))
            }
        }
    }

    private var stageRows: [ArknightsHintRow] {
        var out: [ArknightsHintRow] = []
        if data.stage != nil { out.append(ArknightsHintRow(path: "Info.Stage", name: "关卡")) }
        if data.medicineNumb != nil { out.append(ArknightsHintRow(path: "Info.MedicineNumb", name: "理智药")) }
        if data.ifFight != nil { out.append(ArknightsHintRow(path: "Task.IfFight", name: "作战开关")) }
        if data.ifActivityFirst != nil { out.append(ArknightsHintRow(path: "Task.IfActivityFirst", name: "活动关优先")) }
        if data.activityStageIndex != nil { out.append(ArknightsHintRow(path: "Task.ActivityStageIndex", name: "活动关序号")) }
        return out
    }

    /// view.js:798-801: a section with no rows is not drawn.
    var stageSection: some View {
        listSection("ark-stage", if: data.configUnreadable || !stageRows.isEmpty) {
        Section {
            // view.js:309-311: AUTO-MAS not running → the last config read, said so in yellow.
            if data.configUnreadable {
                // set_config fails at once when AUTO-MAS does not answer (commands.py:338-341), it is not held (审查 B16)
                ArknightsWarningRow(text: data.configStale
                    ? "读不到 AUTO-MAS 的配置（它没在运行？）——下面显示的是上次读到的；它没在运行时改的会失败，看回执"
                    : "读不到 AUTO-MAS 的配置（它没在运行？）")
            }
            if data.stage != nil {
                tagged("Info.Stage") {
                    ArknightsTextRow(label: label("Info.Stage", "关卡"),
                                     text: binding(\.stage, default: ""))
                }
            }
            if data.medicineNumb != nil {
                tagged("Info.MedicineNumb") {
                    ArknightsNumberRow(label: label("Info.MedicineNumb", "理智药"),
                                       text: binding(\.medicineNumb, default: ""))
                }
            }
            if data.ifFight != nil {
                tagged("Task.IfFight") {
                    ArknightsToggleRow(label: label("Task.IfFight", "作战开关"),
                                       isOn: binding(\.ifFight, default: false))
                }
            }
            if data.ifActivityFirst != nil {
                tagged("Task.IfActivityFirst") {
                    ArknightsToggleRow(label: label("Task.IfActivityFirst", "活动关优先"),
                                       isOn: binding(\.ifActivityFirst, default: false))
                }
            }
            if data.activityStageIndex != nil {
                tagged("Task.ActivityStageIndex") {
                    ArknightsStepperRow(label: label("Task.ActivityStageIndex", "活动关序号"),
                                        text: binding(\.activityStageIndex, default: ""))
                }
            }
        } header: {
            // the page is 明日方舟 already: each header names its group only (HIG Writing: "Check each word to be sure
            // it needs to be there.")
            Text("作战")
        } footer: {
            hintFooter(stageRows)
        }
        }
    }

    // MARK: 明日方舟 · 基建 (schema.js:128-131)

    private var infrastRows: [ArknightsHintRow] {
        data.usesOfDrones != nil ? [ArknightsHintRow(path: "Infrast/UsesOfDrones", name: "无人机用途")] : []
    }

    /// view.js:973 (layoutTabs): a master section is drawn when its card holds anything — a row or a yellow note.
    private var masterHasNotes: Bool { data.masterUnreadable || data.masterStale || !data.masterNotes.isEmpty }

    var infrastSection: some View {
        listSection("ark-infrast", if: masterHasNotes || !infrastRows.isEmpty) {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow()
            } else {
                masterWarnings
                if data.usesOfDrones != nil {
                    tagged("Infrast/UsesOfDrones") {
                        ArknightsPickerRow(label: label("Infrast/UsesOfDrones", "无人机用途"),
                                           options: data.usesOfDronesOptions,
                                           selection: binding(\.usesOfDrones, default: ""))
                    }
                }
            }
        } header: {
            Text("基建")
        } footer: {
            hintFooter(data.masterUnreadable ? [] : infrastRows)
        }
        }
    }

    // MARK: 明日方舟 · 领取奖励 (schema.js:132-141)

    private var awardRows: [ArknightsHintRow] {
        var out: [ArknightsHintRow] = []
        if data.awardMail != nil { out.append(ArknightsHintRow(path: "Award/Mail", name: Self.awardName["Award/Mail"]!)) }
        if data.awardOrundum != nil { out.append(ArknightsHintRow(path: "Award/Orundum", name: Self.awardName["Award/Orundum"]!)) }
        if data.awardMining != nil { out.append(ArknightsHintRow(path: "Award/Mining", name: Self.awardName["Award/Mining"]!)) }
        if data.awardSpecialAccess != nil {
            out.append(ArknightsHintRow(path: "Award/SpecialAccess", name: Self.awardName["Award/SpecialAccess"]!))
        }
        return out
    }

    var awardSection: some View {
        listSection("ark-award", if: masterHasNotes || !awardRows.isEmpty) {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow()
            } else {
                masterWarnings
                if data.awardMail != nil {
                    tagged("Award/Mail") {
                        ArknightsToggleRow(label: label("Award/Mail", Self.awardName["Award/Mail"]!),
                                           isOn: binding(\.awardMail, default: false))
                    }
                }
                if data.awardOrundum != nil {
                    tagged("Award/Orundum") {
                        ArknightsToggleRow(label: label("Award/Orundum", Self.awardName["Award/Orundum"]!),
                                           isOn: binding(\.awardOrundum, default: false))
                    }
                }
                if data.awardMining != nil {
                    tagged("Award/Mining") {
                        ArknightsToggleRow(label: label("Award/Mining", Self.awardName["Award/Mining"]!),
                                           isOn: binding(\.awardMining, default: false))
                    }
                }
                if data.awardSpecialAccess != nil {
                    tagged("Award/SpecialAccess") {
                        ArknightsToggleRow(label: label("Award/SpecialAccess", Self.awardName["Award/SpecialAccess"]!),
                                           isOn: binding(\.awardSpecialAccess, default: false))
                    }
                }
            }
        } header: {
            Text("领取奖励")
        } footer: {
            hintFooter(data.masterUnreadable ? [] : awardRows)
        }
        }
    }

    // MARK: 明日方舟 · 周常 (view.js:519-523; shown only when MAA is in this shift)

    var weeklySection: some View {
        listSection("ark-weekly", ifLet: data.annihilationDoneThisWeek) { done in
            Section {
                // a read-only value: the system's name + value row (iOS reads the two as one element); the value
                // secondary on Android too, where skip-ui's LabeledContent draws it in the primary colour
                LabeledContent {
                    Text(done ? "本周已打满" : "本周还没打满")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("剿灭")
                }
            } header: {
                Text("周常")
            } footer: {
                // one row: the hint goes to the footer without the 「剿灭：」 prefix (view.js:989)
                // annihilation.py:56-65 counts the week from Monday 04:00 Beijing = 05:00 Tokyo (审查 B4)
                Text("打满本周剿灭后自动停掉，下周一 05:00（东京时间）自动恢复")
            }
        }
    }

    /// The yellow lines at the top of a master section (view.js:482-493): the master copy is the last one read
    /// (said once inside each master section), then 「名字没翻译出来」 and 「定义文件里没有这些任务」.
    @ViewBuilder private var masterWarnings: some View {
        if data.masterStale {
            ArknightsWarningRow(text: "配置文件这次读不到——下面是上次读到的，改了要等它能读到才生效")
        }
        ForEach(data.masterNotes, id: \.self) { note in
            ArknightsWarningRow(text: note)
        }
    }

    /// The 领取奖励 rows' names: the header says 领取奖励, so the rows drop 「领取」 and 「奖励」 (HIG Writing).
    private static let awardName = ["Award/Mail": "邮件", "Award/Orundum": "幸运墙合成玉",
                                    "Award/Mining": "开采许可合成玉", "Award/SpecialAccess": "周年月卡"]

    /// Our short name for the row; the machine's own name (view.js labelOf: 「是否理智作战」,
    /// 「活动期间是否优先刷活动关」) only where we have none. Its long question-form names wrapped the rows (HIG Toggles: "the
    /// content in the row provides the context"; Calendar's 「Repeat」 / 「All-day」).
    private func label(_ path: String, _ ours: String) -> String {
        ours.isEmpty ? (data.labels[path] ?? ours) : ours
    }

    /// A row with its 「待保存」 / 「已寄出 / 已应用 / 没生效」 lines under it, drawn by the same EWTagLine as the 终末地 and
    /// 鸣潮 rows (HIG Writing: "use it consistently throughout your app"); no row tint (EWRowView explains).
    /// One shape with or without a tag (as EWRowView, 8c1160d): a branch around `row()` rebuilt the text field on the first
    /// keystroke, when 「待保存」 appears, and dropped the keyboard.
    private func tagged<Row: View>(_ path: String, @ViewBuilder _ row: () -> Row) -> some View {
        let unsaved = edited.contains(path)
        let tag = data.tags[path]
        return VStack(alignment: .leading, spacing: 4) {
            row()
            if unsaved || tag != nil {
                EWTagLine(tag: EWRowTag(unsaved: unsaved, text: tag?.text, resendKey: tag?.resendKey,
                                        bad: tag?.bad ?? false, posted: tag?.posted ?? false),
                          onResend: onResend)
            }
        }
        .listRowBackground(rowBackground(nil))   // never nil on Android (SkipFixes.swift)
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
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: label)
        }
    }
}

struct ArknightsTextRow: View {
    let label: String
    @Binding var text: String

    /// The grey prompt of an empty box (the machine has null): the word the 无人机 menu already uses for a null
    /// (ArknightsPickerRow 「未设」). Not the row's name, which 0.4.4 showed as the prompt under the name: on the same
    /// row as the name it would say it twice.
    static let unset = "未设"

    var body: some View {
        // a stage code (1-7, CE-6): an auto-capital or an autocorrection made it a code the relay's pattern refuses or
        // another stage (edge audit 30); the same input traits as the setup screen's mailbox field
        ArknightsValueRow(label: label) {
            TextField(label, text: $text, prompt: Text(ArknightsTextRow.unset))
                .setupPlainInput()
        }
    }
}

/// One row, the name leading and the value trailing, as Shortcuts › an automation's options lay out each setting
/// (name left, value right; app-page-references P2) and as the 终末地 / 鸣潮 tabs' text rows already do; 0.4.4 put the
/// field on a second line under the name.
/// Not LabeledContent: its form style gives the name a fixed share of the row, and 优先刷取的活动关卡序号 was cut
/// with … beside the field (tried 10-13 on iOS 27) — a cut text is what regression list 8 forbids (10-02 20:49
/// 「不应该是省略号」); a field sized to its text instead would leave a 10 pt tap target for 「1」. Here the name is
/// laid out first (layoutPriority) and wraps if it must, and the field takes the rest of the row, so the whole right
/// side of the row is the field. Android: a Compose Row, the field filling what the name leaves (skip-ui TextField
/// fillWidth), as 终末地's rows.
struct ArknightsValueRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack {
            #if os(Android)
            // skip-fuse-ui has no layoutPriority; the Compose Row measures the name first and the field fills the rest
            Text(verbatim: label)
            #else
            Text(verbatim: label)
                .layoutPriority(1)
            #endif
            field()
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A small 1-based position (活动关序号) as a stepper with its value beside it, as 鸣潮's 周本打第几个 (HIG Steppers:
/// "Steppers work well by themselves for making small changes that require a few taps or clicks."). The text stays the
/// page's value: empty (the machine has null) shows 「未设」 and is only written once a half is pressed, so an
/// untouched row stays as the machine has it.
struct ArknightsStepperRow: View {
    let label: String
    @Binding var text: String

    /// The relay passes any whole number on (commands.py set_config); 99 is where the stepper stops.
    static let range = 1...99

    var body: some View {
        Stepper(value: Binding(get: { Int(text) ?? 0 }, set: { text = String($0) }), in: Self.range) {
            LabeledContent {
                Text(verbatim: text.isEmpty ? ArknightsTextRow.unset : text).foregroundStyle(.secondary)
            } label: {
                Text(verbatim: label)
            }
        }
    }
}

/// Number entry as a text field, like the web's <input type="number"> (999 is a valid value, so no stepper).
/// The box keeps what was typed; an empty box is sent as null (view.js:1097) and a null shows empty (view.js:503).
struct ArknightsNumberRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        ArknightsValueRow(label: label) { numberField }
    }

    @ViewBuilder private var numberField: some View {
        let field = TextField(label, text: Binding(
            get: { text },
            // ASCII digits only, full-width ones (a Chinese keyboard's １２) turned into them: isNumber let １２ in,
            // Int() could not read it and the field went out as null (edge audit 31)
            set: { typed in
                var out = ""
                for s in typed.unicodeScalars {
                    let v = (0xFF10...0xFF19).contains(s.value) ? s.value - 0xFEE0 : s.value   // ０-９ → 0-9
                    if (0x30...0x39).contains(v), let d = Unicode.Scalar(v) { out.unicodeScalars.append(d) }
                }
                text = out
            }
        ), prompt: Text(ArknightsTextRow.unset))
        #if os(macOS)
        field
        #else
        field.keyboardType(.numberPad)
        #endif
    }
}

struct ArknightsPickerRow: View {
    let label: String
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
        // menuPicker (SkipFixes.swift): inside tagged()'s VStack a bare Picker loses its title on Android
        menuPicker(selection: Binding(
            get: { shown.contains { $0.value == selection } ? selection : (options.first?.value ?? "") },
            set: { selection = $0 }
        )) {
            ForEach(shown) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        } title: {
            Text(verbatim: label)
        }
    }
}

/// A row drawn in a section, for its footer line (view.js:978-995): the field's path and our name for it.
struct ArknightsHintRow {
    let path: String
    let name: String
}

/// Shown instead of the rows when the master config can't be read and there is no earlier copy (view.js:418),
/// or above the rows when they are the last copy read (view.js:421).
struct ArknightsWarningRow: View {
    var text = "这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改"

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }
}
