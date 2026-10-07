// Row views shared by the 终末地 and 鸣潮 pages. System controls as Settings uses them: Toggle, Picker (.menu for a short
// list, .navigationLink for one with pictures), a pushed List with checkmarks for several choices, LabeledContent with a
// TextField for numbers and text. A row's explanation and its status sit under the row's name, in secondary text.

import SwiftUI

/// The row's name with its explanation and status underneath (a Settings row's subtitle).
struct EWRowTitle: View {
    var label: String
    var hint: String?
    /// The row's status (「正在寄出」, 「已寄出 …」, 「没生效 …」, 「没发出去 …」), under the explanation.
    var tag: EWRowTag? = nil
    /// A note about the value being typed (「要填整数」), in red under the rest.
    var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let tag {
                EWTagLine(tag: tag)
            }
            if let problem {
                Text(verbatim: problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One footer line's source: a row's name and its hint.
struct EWFootItem {
    var label: String
    var hint: String?
}

/// Each row's hint joined into one paragraph for a section footer, prefixed 「行名：」 when the card has more than one
/// row. The 终末地 pages no longer use it (each hint sits under its row); kept for the 鸣潮 page until its rewrite.
func ewFoot(_ items: [EWFootItem], rows: Int) -> String {
    items.compactMap { i -> String? in
        guard let h = i.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        let t = i.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return (rows > 1 && !t.isEmpty ? t + "：" : "") + h
    }.joined(separator: "\n")
}

/// ewFoot over drawn rows; warnings are not rows, box rows are.
func ewFoot(_ shown: [EWRow], card: [EWRow]) -> String {
    ewFoot(shown.filter { $0.kind != .warning }.map { EWFootItem(label: $0.label, hint: $0.hint) },
           rows: card.filter { $0.kind != .warning }.count)
}

/// One config row. `values` is the page's working copy; `onChange` reports each change (path, new value): a switch or
/// a choice at once, a number or text when it is submitted (Return / Done) or the field loses focus.
struct EWRowView: View {
    var row: EWRow
    @Binding var values: [String: EWValue]
    var readonly: [String: EWValue] = [:]
    var onChange: (String, EWValue) -> Void = { _, _ in }
    /// The row's status (box sub-rows carry none; their header does).
    var tag: EWRowTag? = nil
    /// 再发一次 of a sent change, by its Pending key.
    var onResend: (String) -> Void = { _ in }
    /// false: the explanation is not drawn under the name (the 鸣潮 page still puts it in its card's footer).
    var showHint = true

    private var hint: String? { showHint ? row.hint : nil }

    private var shownTag: EWRowTag? { row.kind == .box ? nil : tag }

    private var value: EWValue { values[row.path] ?? readonly[row.path] ?? .null }

    private func set(_ v: EWValue) {
        values[row.path] = v
        onChange(row.path, v)
    }

    private func pick(_ v: EWValue) -> String {
        row.choices.first { $0.value == v.key }?.label ?? v.display
    }

    private var title: EWRowTitle { EWRowTitle(label: row.label, hint: hint, tag: shownTag) }

    var body: some View {
        control
            .ewRowActions(shownTag, onResend: onResend)
            .listRowBackground(rowBackground(nil))   // never nil on Android: the same row shape as its neighbours (SkipFixes.swift)
    }

    @ViewBuilder
    private var control: some View {
        switch row.kind {
        case .warning:
            warningLabel(row.label)
                .foregroundStyle(.orange)
        case .readOnly:
            LabeledContent {
                Text(pick(value).isEmpty ? "无" : pick(value))
            } label: {
                title
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value.isOn }, set: { set(.bool($0)) })) {
                title
            }
        case .select:
            // menuPicker (SkipFixes.swift): on Android a Picker that is not the bare list row loses its title
            menuPicker(selection: Binding(get: { value == .null ? "" : value.key }, set: { setChoice($0) })) {
                if value == .null {
                    Text("未设").tag("")
                }
                ForEach(row.choices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            } title: {
                title
            }
        case .icons:
            iconsPicker
        case .pills:
            NavigationLink {
                EWChoiceList(title: row.label, choices: row.choices, multi: true, initial: value.items,
                             commit: { set(.list($0)) })
            } label: {
                LabeledContent {
                    Text("已选 \(row.choices.filter { value.items.contains($0.value) }.count)/\(row.choices.count)")
                } label: {
                    title
                }
            }
        case .boxesHeader:
            LabeledContent {
                Text("\(boxCount) 格")
            } label: {
                title
            }
        case .box:
            EWNumberRow(label: row.label, value: Int(value.boxValues[row.boxKey ?? ""] ?? ""), required: false) { n in
                setBox(n.map { String($0) } ?? "")
            } title: { problem in
                EWRowTitle(label: row.label, hint: nil, problem: problem)
            }
        case .number:
            EWNumberRow(label: row.label, value: Int(value.display), required: true) { n in
                if let n { set(.number(Double(n))) }
            } title: { problem in
                EWRowTitle(label: row.label, hint: hint, tag: shownTag, problem: problem)
            }
        case .text:
            EWTextRow(label: row.label, value: value.display) { set(.text($0)) } title: {
                title
            }
        }
    }

    /// One choice from a list with pictures (鸣潮 声骸 sets): a navigation-link Picker, applied when a choice is tapped.
    @ViewBuilder
    private var iconsPicker: some View {
        #if os(Android)
        // skip-ui titles the pushed choice page from the Picker's label only when that label is a Text or Label
        // (skip-ui Controls/Picker.swift:270-279); this label is the row's name with its explanation, so the page would be
        // titled with the selected value's key. A pushed EWChoiceList (single choice, applied on tap) titles it by the row.
        NavigationLink {
            EWChoiceList(title: row.label, choices: row.choices, multi: false, icons: true, initial: [value.key],
                         commit: { setChoice($0.first ?? "") })
        } label: {
            LabeledContent {
                Text(value == .null ? "未设" : pick(value))
            } label: {
                title
            }
        }
        #else
        Picker(selection: Binding(get: { value == .null ? "" : value.key }, set: { setChoice($0) })) {
            if value == .null {
                Text("未设").tag("")
            }
            ForEach(row.choices, id: \.value) { c in
                EWChoiceLabel(choice: c, icons: true).tag(c.value)
            }
        } label: {
            title
        }
        .pickerStyle(.navigationLink)
        #endif
    }

    /// Keeps a number a number (凝素领域 / 无音区 store an index), everything else is the option's value text.
    /// "" is the 「未设」 placeholder: it is shown, never written (view.js:499 `hidden disabled`).
    private func setChoice(_ v: String) {
        if v.isEmpty { return }
        if case .number = value, let n = Double(v) { set(.number(n)) } else { set(.text(v)) }
    }

    /// The header row's count = the machine's inputs for this path; the page passes it through choices.
    private var boxCount: Int { row.choices.count }

    /// A box edit changes only that box (the relay writes only the named boxes).
    private func setBox(_ text: String) {
        guard let k = row.boxKey else { return }
        var d = value.boxValues
        d[k] = text
        set(.boxes(d))
    }
}

/// A number row: the name on the left, a number field on the right (LabeledContent). The field takes only a number
/// (TextField(value:format:)); what is typed is checked as it is typed, and the value goes out when it is submitted or
/// the field loses focus (the number pad has no Return; keyboardDone's 完成 ends the editing).
struct EWNumberRow<Title: View>: View {
    var label: String
    /// The value the page shows (machine / sent / changed).
    var value: Int?
    /// true: an empty field is not a value (a schema `number` field, EWSave.problem 「要填整数」).
    var required: Bool
    var commit: (Int?) -> Void
    var title: (String?) -> Title

    @State var draft: Int?
    /// The last value handed to `commit` or taken from `value`: a commit of the same value again is no change.
    @State var settled: Int?
    @FocusState var focused: Bool

    init(label: String, value: Int?, required: Bool, commit: @escaping (Int?) -> Void,
         @ViewBuilder title: @escaping (String?) -> Title) {
        self.label = label
        self.value = value
        self.required = required
        self.commit = commit
        self.title = title
        _draft = State(initialValue: value)
        _settled = State(initialValue: value)
    }

    /// The field holds no number while the row had one: the field was emptied, or what was typed is not a number.
    private var problem: String? { required && draft == nil && value != nil ? "要填整数" : nil }

    var body: some View {
        LabeledContent {
            // the optional binding: skip-fuse-ui's non-optional one parses with try! (Text/TextField.swift:42-47)
            TextField("", value: $draft, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel(Text(verbatim: label))
        } label: {
            title(problem)
        }
        // iOS writes the typed number into `draft` on submit or when the field loses focus, in either order with the focus
        // change; Android writes it on every keystroke. Sending only while not focused covers both.
        .onChange(of: focused) { _, now in if !now { send() } }
        .onChange(of: draft) { _, _ in if !focused { send() } }
        // leaving the page with the keyboard up (Back) keeps what was typed
        .onDisappear(perform: send)
        // a newer value from the machine or another page, while nobody is typing here
        .onChange(of: value) { _, v in
            if !focused {
                draft = v
                settled = v
            }
        }
    }

    private func send() {
        guard draft != settled else { return }
        if required && draft == nil { return }   // stays on the row as 「要填整数」; nothing is sent
        settled = draft
        commit(draft)
    }
}

/// A text row: the name on the left, the field on the right; the text goes out when submitted or when the field loses
/// focus.
struct EWTextRow<Title: View>: View {
    var label: String
    var value: String
    var commit: (String) -> Void
    var title: () -> Title

    @State var draft: String
    @State var settled: String
    @FocusState var focused: Bool

    init(label: String, value: String, commit: @escaping (String) -> Void, @ViewBuilder title: @escaping () -> Title) {
        self.label = label
        self.value = value
        self.commit = commit
        self.title = title
        _draft = State(initialValue: value)
        _settled = State(initialValue: value)
    }

    var body: some View {
        LabeledContent {
            TextField("", text: $draft)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel(Text(verbatim: label))
        } label: {
            title()
        }
        .onChange(of: focused) { _, now in if !now { send() } }
        .onDisappear(perform: send)
        .onChange(of: value) { _, v in
            if !focused {
                draft = v
                settled = v
            }
        }
    }

    private func send() {
        guard draft != settled else { return }
        settled = draft
        commit(draft)
    }
}

/// The status under a row: a spinner while its change goes out, then the receipt (「已寄出 …」 / 「已应用 …」), or what
/// went wrong in red (「没生效 …」, 「没发出去 …」) with where 再发一次 is.
struct EWTagLine: View {
    var tag: EWRowTag
    /// Kept for the 鸣潮 page's call; 再发一次 is the row's swipe action / context menu now (ewRowActions).
    var onResend: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if tag.sending {
                HStack(spacing: 6) {
                    ProgressView()
                        .smallControl()
                    Text("正在寄出")
                }
                .foregroundStyle(.secondary)
            } else if let failure = tag.failure {
                Text(verbatim: failure + "左滑这一行或长按它可以再发一次。").foregroundStyle(.red)
            } else if let text = tag.text {
                Text(verbatim: text + (tag.resendKey != nil ? "。左滑或长按这一行可以再发一次" : ""))
                    .foregroundStyle(tag.bad ? Color.red : Color.secondary)
            } else if tag.unsaved {
                Text("还没寄出").foregroundStyle(.secondary)   // another tab's change that waits for that tab's own send
            }
        }
        .font(.footnote)
    }

    /// Rows are no longer tinted for their status (the status is the text above); kept for the 鸣潮 page's call.
    static func tint(_ tag: EWRowTag?) -> Color? { nil }
}

extension View {
    /// A row's own actions for its status, as Mail's rows have them: swipe from the trailing edge, or long-press for the
    /// same buttons. 再发一次 for a change that did not go out (EWSave.retry) or that the machine did not take (Pending);
    /// 不改了 drops a change that did not go out.
    func ewRowActions(_ tag: EWRowTag?, onResend: @escaping (String) -> Void) -> some View {
        let retry = tag?.sending == true ? nil : tag?.retryKey
        let resend = tag?.sending == true ? nil : tag?.resendKey
        return self
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let retry {
                    Button("再发一次") { EWSave.retry(retry) }
                    Button("不改了") { EWSave.drop(retry) }
                } else if let resend {
                    Button("再发一次") { onResend(resend) }
                }
            }
            .contextMenu {
                if let retry {
                    Button("再发一次") { EWSave.retry(retry) }
                    Button("不改了") { EWSave.drop(retry) }
                } else if let resend {
                    Button("再发一次") { onResend(resend) }
                }
            }
    }
}

/// A choice's label: the option's name, after its echo-set pictures for icon rows.
struct EWChoiceLabel: View {
    var choice: EWChoice
    var icons = false
    /// The set icon, 28 pt at the default text size (view.js:1215 `.pico`), growing with Dynamic Type.
    @ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 28

    var body: some View {
        HStack {
            if icons {
                ForEach(choice.label.components(separatedBy: " ＋ "), id: \.self) { name in
                    if let asset = WuwaSchema.setIcons[name] {
                        decorativeImage(asset)   // the label beside says the names
                            .resizable()
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: iconSize * 6 / 28))
                    }
                }
            }
            Text(choice.label)
        }
    }
}

/// The pushed list behind a choice row: one row per choice, a checkmark on the chosen ones. A tap applies at once, as
/// Settings' choice lists do. With several allowed the last ticked one cannot be unticked (MaaEnd ends a task given
/// none, view.js:1399); with one, the tap applies and the page goes back.
struct EWChoiceList: View {
    var title: String
    var choices: [EWChoice]
    var multi: Bool
    var icons = false
    var commit: ([String]) -> Void
    @State var chosen: [String]
    @Environment(\.dismiss) var dismiss

    init(title: String, choices: [EWChoice], multi: Bool, icons: Bool = false,
         initial: [String], commit: @escaping ([String]) -> Void) {
        self.title = title
        self.choices = choices
        self.multi = multi
        self.icons = icons
        self.commit = commit
        _chosen = State(initialValue: initial)
    }

    var body: some View {
        List {
            ForEach(choices, id: \.value) { c in
                let on = chosen.contains(c.value)
                Button {
                    toggle(c.value)
                } label: {
                    HStack {
                        EWChoiceLabel(choice: c, icons: icons)
                        Spacer()
                        if on {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                // the last ticked one stays ticked: a list with none is refused (view.js:1399)
                .disabled(multi && on && chosen.count == 1)
                // the checkmark is said as the row's selected state, as a native selection list does
                // (AccessibilityTraits.isSelected: "The accessibility element is currently selected.")
                .accessibilityAddTraits(on ? .isSelected : Self.noTraits)
            }
        }
        .navigationTitle(title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// No traits. On Android not `[]`: skip-fuse-ui's AccessibilityTraits (SkipSwiftUI/System/Accessibility.swift:899-901)
    /// defines `init() { self = [] }`, and `[]` is SetAlgebra's init(arrayLiteral:), which calls init() — so an empty
    /// literal recursed until the main thread's stack overflowed (SIGSEGV in libSkipFuseUI.so, audit/android-crash-150820.txt):
    /// every row not ticked crashed the page, 鸣潮 无音区 on opening and 终末地 执行周期 on unticking a day (test pass 1, 问题 12).
    /// `rawValue: 0` is the same empty set without the literal; iOS keeps SwiftUI's own `[]`.
    static var noTraits: AccessibilityTraits {
        #if os(Android)
        AccessibilityTraits(rawValue: 0)
        #else
        []
        #endif
    }

    /// Written back in the option table's order; a value the option table does not list (any more) stays, after the
    /// listed ones: it has no row here to untick, and dropping it deleted it from the machine (edge audit 33).
    private func toggle(_ v: String) {
        if !multi {
            chosen = [v]
            commit([v])
            dismiss()
            return
        }
        if let i = chosen.firstIndex(of: v) {
            guard chosen.count > 1 else { return }
            chosen.remove(at: i)
        } else {
            chosen.append(v)
        }
        let listed = choices.map { $0.value }
        commit(listed.filter { chosen.contains($0) } + chosen.filter { !listed.contains($0) })
    }
}
