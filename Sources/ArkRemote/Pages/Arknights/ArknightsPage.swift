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

    /// The first row the page draws, worked out in the page's own order from the same conditions the sections use; nil =
    /// nothing drawn. Every section here has a header, so on Android this row lands flush under the top bar with its
    /// header scrolled off (skip-ui's ScrollViewProxy finds ids of rows only, LazySupport.swift:250-288; a section header
    /// is a count, :283). Field rows carry 「ark-row-<path>」 (tagged); a 母本 note is its ForEach id, the note itself (the
    /// same note also heads 领取奖励, after 基建: skip-ui takes the first match, LazySupport.swift:250-288).
    private var topID: String? {
        if data.notInShift { return "ark-notinshift" }
        if data.configUnreadable { return "ark-stage-warn" }
        if let r = stageRows.first { return "ark-row-" + r.path }
        if let id = masterTopID("infrast", infrastRows) { return id }
        if let id = masterTopID("award", awardRows) { return id }
        if data.annihilationDoneThisWeek != nil { return "ark-weekly" }
        return nil
    }

    /// The first row of a master section (基建 / 领取奖励): its order is masterWarnings, then the field rows.
    private func masterTopID(_ section: String, _ rows: [ArknightsHintRow]) -> String? {
        if data.masterUnreadable { return "ark-\(section)-unreadable" }
        if data.masterStale { return "ark-\(section)-stale" }
        if let note = data.masterNotes.first { return note }
        return rows.first.map { "ark-row-" + $0.path }
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            // listSection, not a bare `if`: a false `if` at the top of a List draws an empty grey section on Android (SkipFixes.swift)
            listSection("ark-notinshift", if: data.notInShift) {
                Section {
                    Text(verbatim: "\(data.shiftName.isEmpty ? "这个班次" : data.shiftName)不跑明日方舟。换班次在「状态」页。")
                        .foregroundStyle(.secondary)
                        .id("ark-notinshift")   // a reselect's scroll target (topID)
                }
            }
            stageSection
            infrastSection
            awardSection
            weeklySection
        }
        // skip-ui animates scrollTo only inside withAnimation (List.swift:242) and ignores the anchor (ScrollView.swift:163);
        // Form is skip-ui's List (Form.swift:9-14), the same ScrollViewReader support
        .keyboardDone()
        .onChange(of: reselect) {
            if let id = topID { withAnimation { proxy.scrollTo(id, anchor: .top) } }
        }
        }
        // the title (「游戏机遥控」, or 「待保存 N 项」 while changes wait, view.js:1554) is set by ArknightsTab's EWSaveBar
    }

    // MARK: 明日方舟 (schema.js:116-127)

    /// Each row's hint, as schema.js:124-133 writes it.
    private static let hints: [String: String] = [
        "Info.Stage": "游戏内的关卡号。例如 1-7（常规）、CE-6（龙门币）、AT-4（活动关）",
        "Info.MedicineNumb": "一趟最多使用几瓶理智药。0＝不使用；999＝不限量",
        "Task.IfFight": "关掉后不刷关卡，只做基建、公招等日常",
        "Task.IfActivityFirst": "开着＝有活动就刷活动关，活动结束后自动回到上面那个固定关。开着时下面的序号才生效",
        "Task.ActivityStageIndex": "刷活动里的第几关，数的是活动关卡列表从上往下的位置，第一关填 1。只在上面那项开着时才有用",
        "Infrast/UsesOfDrones": "贸易站＝加速龙门币或合成玉订单，制造站＝加速对应产物",
        "Award/Mail": "开着＝每趟顺手把邮箱里的奖励全收了。关着邮件会一直躺着，到期作废",
        "Award/Orundum": "开着＝每天去幸运墙领那份合成玉",
        "Award/Mining": "开着＝有限时开采许可时每天领它的合成玉",
        "Award/SpecialAccess": "开着＝周年送的月卡每天的那份也领",
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
                    .id("ark-stage-warn")   // a reselect's scroll target (topID)
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
                    ArknightsNumberRow(label: label("Task.ActivityStageIndex", "活动关序号"),
                                       text: binding(\.activityStageIndex, default: ""))
                }
            }
        } header: {
            Text("明日方舟")
        } footer: {
            hintFooter(stageRows)
        }
        }
    }

    // MARK: 明日方舟 · 基建 (schema.js:128-131)

    private var infrastRows: [ArknightsHintRow] {
        data.usesOfDrones != nil ? [ArknightsHintRow(path: "Infrast/UsesOfDrones", name: "无人机用在哪")] : []
    }

    /// view.js:973 (layoutTabs): a master section is drawn when its card holds anything — a row or a yellow note.
    private var masterHasNotes: Bool { data.masterUnreadable || data.masterStale || !data.masterNotes.isEmpty }

    var infrastSection: some View {
        listSection("ark-infrast", if: masterHasNotes || !infrastRows.isEmpty) {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow().id("ark-infrast-unreadable")   // a reselect's scroll target (topID)
            } else {
                masterWarnings("infrast")
                if data.usesOfDrones != nil {
                    tagged("Infrast/UsesOfDrones") {
                        ArknightsPickerRow(label: label("Infrast/UsesOfDrones", "无人机用在哪"),
                                           options: data.usesOfDronesOptions,
                                           selection: binding(\.usesOfDrones, default: ""))
                    }
                }
            }
        } header: {
            Text("明日方舟 · 基建")
        } footer: {
            hintFooter(data.masterUnreadable ? [] : infrastRows)
        }
        }
    }

    // MARK: 明日方舟 · 领取奖励 (schema.js:132-141)

    private var awardRows: [ArknightsHintRow] {
        var out: [ArknightsHintRow] = []
        if data.awardMail != nil { out.append(ArknightsHintRow(path: "Award/Mail", name: "领取所有邮件奖励")) }
        if data.awardOrundum != nil { out.append(ArknightsHintRow(path: "Award/Orundum", name: "领取幸运墙的每日合成玉")) }
        if data.awardMining != nil { out.append(ArknightsHintRow(path: "Award/Mining", name: "领取限时开采许可的合成玉")) }
        if data.awardSpecialAccess != nil { out.append(ArknightsHintRow(path: "Award/SpecialAccess", name: "领取周年赠送月卡")) }
        return out
    }

    var awardSection: some View {
        listSection("ark-award", if: masterHasNotes || !awardRows.isEmpty) {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow().id("ark-award-unreadable")   // a reselect's scroll target (topID)
            } else {
                masterWarnings("award")
                if data.awardMail != nil {
                    tagged("Award/Mail") {
                        ArknightsToggleRow(label: label("Award/Mail", "领取所有邮件奖励"),
                                           isOn: binding(\.awardMail, default: false))
                    }
                }
                if data.awardOrundum != nil {
                    tagged("Award/Orundum") {
                        ArknightsToggleRow(label: label("Award/Orundum", "领取幸运墙的每日合成玉"),
                                           isOn: binding(\.awardOrundum, default: false))
                    }
                }
                if data.awardMining != nil {
                    tagged("Award/Mining") {
                        ArknightsToggleRow(label: label("Award/Mining", "领取限时开采许可的合成玉"),
                                           isOn: binding(\.awardMining, default: false))
                    }
                }
                if data.awardSpecialAccess != nil {
                    tagged("Award/SpecialAccess") {
                        ArknightsToggleRow(label: label("Award/SpecialAccess", "领取周年赠送月卡"),
                                           isOn: binding(\.awardSpecialAccess, default: false))
                    }
                }
            }
        } header: {
            Text("明日方舟 · 领取奖励")
        } footer: {
            hintFooter(data.masterUnreadable ? [] : awardRows)
        }
        }
    }

    // MARK: 明日方舟 · 周常 (view.js:519-523; shown only when MAA is in this shift)

    var weeklySection: some View {
        listSection("ark-weekly", ifLet: data.annihilationDoneThisWeek) { done in
            Section {
                HStack {
                    Text("剿灭")
                    Spacer()
                    Text(done ? "本周已打满" : "本周还没打满")
                        .foregroundStyle(.secondary)
                }
                .id("ark-weekly")   // a reselect's scroll target (topID)
            } header: {
                Text("明日方舟 · 周常")
            } footer: {
                // one row: the hint goes to the footer without the 「剿灭：」 prefix (view.js:989)
                // annihilation.py:56-65 counts the week from Monday 04:00 Beijing = 05:00 Tokyo (审查 B4)
                Text("打满本周剿灭后自动停掉，下周一 05:00（东京时间）自动恢复")
            }
        }
    }

    /// The yellow lines at the top of a master section (view.js:482-493): the master copy is the last one read
    /// (said once inside each master section), then 「名字没翻译出来」 and 「定义文件里没有这些任务」.
    /// `section` keeps the stale row's id apart between the two sections (a reselect's scroll target, topID).
    @ViewBuilder private func masterWarnings(_ section: String) -> some View {
        if data.masterStale {
            ArknightsWarningRow(text: "配置文件这次读不到——下面是上次读到的，改了要等它能读到才生效")
                .id("ark-\(section)-stale")
        }
        ForEach(data.masterNotes, id: \.self) { note in
            ArknightsWarningRow(text: note)
        }
    }

    /// The machine's name for the row (view.js labelOf), else ours.
    private func label(_ path: String, _ fallback: String) -> String {
        data.labels[path] ?? fallback
    }

    /// A row with its 「已寄出 / 已应用 / 没生效」 line under it (pending.js:47-67: the tag sits under the control).
    /// An unsaved edit adds 「待保存」 in the accent colour under that line (view.js:1523-1528 re-appends it last), so a sent
    /// row being edited again shows both; 「已应用」 is not shown while editing (pending.js:67). The ground: a sent row is
    /// light green (pending.js:63 `.posted`), an edited one accent 8% (`.changed`); with both, `.posted` wins as it comes
    /// later in index.html (:767-768).
    /// One shape with or without a tag (as EWRowView, 8c1160d): a branch around `row()` rebuilt the text field on the first
    /// keystroke, when 「待保存」 appears, and dropped the keyboard.
    private func tagged<Row: View>(_ path: String, @ViewBuilder _ row: () -> Row) -> some View {
        let unsaved = edited.contains(path)
        let tag = data.tags[path]
        let posted = tag?.posted ?? false
        return VStack(alignment: .leading, spacing: 4) {
            row()
            if let tag {
                HStack(spacing: 8) {
                    Text(verbatim: tag.text)
                        .font(.footnote)
                        .foregroundStyle(tag.bad ? Color.red : Color.secondary)
                    if let key = tag.resendKey {
                        Button("再发一次") { onResend(key) }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if unsaved {
                Text("待保存")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .listRowBackground(rowBackground(posted ? Color.green.opacity(0.08)
            : unsaved ? Color.accentColor.opacity(0.08) : nil))   // never nil on Android (SkipFixes.swift)
        .id("ark-row-" + path)   // constant per row, so the shape stays one; a reselect's scroll target (topID)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
            // a stage code (1-7, CE-6): an auto-capital or an autocorrection made it a code the relay's pattern refuses or
            // another stage (edge audit 30); the same input traits as the setup screen's mailbox field
            TextField(label, text: $text)
                .setupPlainInput()
        }
    }
}

/// Number entry as a text field, like the web's <input type="number"> (999 is a valid value, so no stepper).
/// The box keeps what was typed; an empty box is sent as null (view.js:1097) and a null shows empty (view.js:503).
struct ArknightsNumberRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
            numberField
        }
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
        ))
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
