// Row views shared by the 终末地 and 鸣潮 pages. Standard SwiftUI controls only (Skip maps them to Android's own);
// controls checked against skip.dev/docs/modules/skip-ui (Toggle / Picker .menu / TextField / NavigationLink / List).

import SwiftUI

/// The row's name with its hint underneath (the web page's label + .hint).
struct EWRowTitle: View {
    var label: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One footer line's source: a row's name and its hint.
struct EWFootItem {
    var label: String
    var hint: String?
}

/// The card's footer (view.js:976-995, Settings › Accessibility › Motion): each row's hint moves from the row to a
/// paragraph under the card, prefixed 「行名：」 when the card has more than one row. `rows` = the card's row count.
func ewFoot(_ items: [EWFootItem], rows: Int) -> String {
    items.compactMap { i -> String? in
        guard let h = i.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        let t = i.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return (rows > 1 && !t.isEmpty ? t + "：" : "") + h
    }.joined(separator: "\n")
}

/// ewFoot over drawn rows; warnings are not rows (view.js `.warn`), box rows are (view.js `.row` with no hint).
func ewFoot(_ shown: [EWRow], card: [EWRow]) -> String {
    ewFoot(shown.filter { $0.kind != .warning }.map { EWFootItem(label: $0.label, hint: $0.hint) },
           rows: card.filter { $0.kind != .warning }.count)
}

/// One config row. `values` is the page's working copy; `onChange` reports each edit (path, new value).
struct EWRowView: View {
    var row: EWRow
    @Binding var values: [String: EWValue]
    var readonly: [String: EWValue] = [:]
    var onChange: (String, EWValue) -> Void = { _, _ in }
    /// 「待保存」 / 「已寄出 …」 / 「没生效 …」 / 「已应用 …」 under the row (box sub-rows carry none; their header does).
    var tag: EWRowTag? = nil
    var onResend: (String) -> Void = { _ in }
    /// false: the hint is not drawn under the name; the page puts it in the card's footer instead (ewFoot).
    var showHint = true

    private var hint: String? { showHint ? row.hint : nil }

    private var value: EWValue { values[row.path] ?? readonly[row.path] ?? .null }

    private func set(_ v: EWValue) {
        values[row.path] = v
        onChange(row.path, v)
    }

    private func pick(_ v: EWValue) -> String {
        row.choices.first { $0.value == v.key }?.label ?? v.display
    }

    var body: some View {
        // One shape with or without a tag: a branch here would rebuild the TextField on the first keystroke (「待保存」 appears) and drop the keyboard.
        VStack(alignment: .leading, spacing: 4) {
            control
            if let tag, row.kind != .box {
                EWTagLine(tag: tag, onResend: onResend)
            }
        }
        // index.html:689-690: unsaved rows tinted accent 8 %, sent rows ok-green 8 % (近似: replaces the card colour, not mixed into it)
        .listRowBackground(rowBackground(row.kind == .box ? nil : EWTagLine.tint(tag)))   // never nil on Android: a nil → tint swap drops the keyboard (SkipFixes.swift)
    }

    @ViewBuilder
    private var control: some View {
        switch row.kind {
        case .warning:
            warningLabel(row.label)
                .foregroundStyle(.orange)
        case .readOnly:
            HStack {
                EWRowTitle(label: row.label, hint: hint)
                Spacer()
                Text(pick(value).isEmpty ? "（空）" : pick(value)).foregroundStyle(.secondary)   // view.js fmt(null)
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value.isOn }, set: { set(.bool($0)) })) {
                EWRowTitle(label: row.label, hint: hint)
            }
        case .select:
            // menuPicker (SkipFixes.swift): inside this row's VStack a bare Picker loses its title on Android
            menuPicker(selection: Binding(get: { value == .null ? "" : value.key }, set: { setChoice($0) })) {
                if value == .null {
                    Text("未设").tag("")
                }
                ForEach(row.choices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            } title: {
                EWRowTitle(label: row.label, hint: hint)
            }
        case .icons:
            SheetLink {   // the 37b / 38 pick page as a sheet (SkipFixes.swift)
                EWChoiceList(title: row.label, choices: row.choices, multi: false, icons: true,
                             initial: [value.key], commit: { setChoice($0.first ?? "") })
            } label: {
                HStack {
                    EWRowTitle(label: row.label, hint: hint)
                    Spacer()
                    Text(value == .null ? "（空）" : pick(value)).foregroundStyle(.secondary)   // view.js:545 fmt(null)
                }
            }
        case .pills:
            SheetLink {   // the 37b / 38 pick page as a sheet (SkipFixes.swift)
                EWChoiceList(title: row.label, choices: row.choices, multi: true,
                             initial: value.items, commit: { set(.list($0)) })
            } label: {
                HStack {
                    EWRowTitle(label: row.label, hint: hint)
                    Spacer()
                    Text("已选 \(row.choices.filter { value.items.contains($0.value) }.count)/\(row.choices.count)")
                        .foregroundStyle(.secondary)
                }
            }
        case .boxesHeader:
            HStack {
                EWRowTitle(label: row.label, hint: hint)
                Spacer()
                Text("\(boxCount) 格").foregroundStyle(.secondary)
            }
        case .box:
            HStack {
                Text(row.label)
                Spacer()
                TextField(row.label, text: Binding(get: { value.boxValues[row.boxKey ?? ""] ?? "" }, set: { setBox($0) }))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        case .number:
            HStack {
                EWRowTitle(label: row.label, hint: hint)
                Spacer()
                TextField(row.label, text: Binding(get: { value.display }, set: { setNumber($0) }))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        case .text:
            HStack {
                EWRowTitle(label: row.label, hint: hint)
                Spacer()
                TextField(row.label, text: Binding(get: { value.display }, set: { set(.text($0)) }))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
            }
        }
    }

    /// Keeps a number a number (凝素领域 / 无音区 store an index), everything else is the option's value text.
    /// "" is the 「未设」 placeholder: it is shown, never written (view.js:499 `hidden disabled`).
    private func setChoice(_ v: String) {
        if v.isEmpty { return }
        if case .number = value, let n = Double(v) { set(.number(n)) } else { set(.text(v)) }
    }

    /// view.js:1097: an emptied number field is null; text the machine keeps as text stays text (EWSave.masterEdit).
    private func setNumber(_ t: String) {
        if t.isEmpty { set(.null) } else { set(Double(t).map { .number($0) } ?? .text(t)) }
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

/// The small lines under a row: 「待保存」 in the accent colour (view.js:1273, index.html:686), then the receipt —
/// grey, or red with 「再发一次」 (pending.js:51-58, index.html:691-695; ArknightsPage.tagged).
struct EWTagLine: View {
    var tag: EWRowTag
    var onResend: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if tag.unsaved {
                Text("待保存").font(.caption2).foregroundStyle(Color.accentColor)
            }
            if let text = tag.text {
                HStack(spacing: 6) {
                    Text(verbatim: text)
                        .font(.caption2)
                        .foregroundStyle(tag.bad ? Color.red : Color.secondary)   // the 10 h line has a button but stays grey (class "sent")
                    if let key = tag.resendKey {
                        Button("再发一次") { onResend(key) }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func tint(_ tag: EWRowTag?) -> Color? {
        guard let tag else { return nil }
        return tag.unsaved ? Color.accentColor.opacity(0.08) : tag.posted ? Color.green.opacity(0.08) : nil
    }
}

/// The checklist page behind an icons (single) or pills (multi) row: one row per choice, a checkmark on the chosen ones.
/// Taps change only this page; ✓ 完成 writes it back, Back drops it (view.js:1136-1158, openPicker 1228-1235).
struct EWChoiceList: View {
    var title: String
    var choices: [EWChoice]
    var multi: Bool
    /// icons rows: each echo set's icon before the label, 28 pt (view.js:1215 `.pico`, index.html:379 --ios-row2-icon).
    var icons = false
    var commit: ([String]) -> Void
    /// What the row showed when the page opened.
    let initial: [String]
    @State var draft: [String]
    @Environment(\.dismiss) var dismiss

    init(title: String, choices: [EWChoice], multi: Bool, icons: Bool = false,
         initial: [String], commit: @escaping ([String]) -> Void) {
        self.title = title
        self.choices = choices
        self.multi = multi
        self.icons = icons
        self.commit = commit
        self.initial = initial
        _draft = State(initialValue: initial)
    }

    var body: some View {
        List {
            ForEach(choices, id: \.value) { c in
                Button {
                    toggle(c.value)
                } label: {
                    HStack {
                        if icons {
                            ForEach(c.label.components(separatedBy: " ＋ "), id: \.self) { name in
                                if let asset = WuwaSchema.setIcons[name] {
                                    decorativeImage(asset)   // c.label beside says the names
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        Text(c.label)
                        Spacer()
                        if draft.contains(c.value) {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                }
                // the checkmark is said as the row's selected state, as a native selection list does
                // (AccessibilityTraits.isSelected: "The accessibility element is currently selected.")
                .accessibilityAddTraits(draft.contains(c.value) ? .isSelected : [])
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { done() } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("完成")   // icon-only: named as EWLive's ✓ (index.html:921 aria-label 完成)
            }
        }
    }

    private func toggle(_ v: String) {
        if !multi {
            draft = [v]
        } else if let i = draft.firstIndex(of: v) {
            draft.remove(at: i)
        } else {
            draft.append(v)
        }
    }

    /// view.js:1146-1149: written back in the option table's order; none at all is refused (MaaEnd ends the task).
    /// A value the option table does not list (any more) stays, after the listed ones: it has no row here to untick, and
    /// dropping it on ✓ deleted it from the machine. The same set in another order is no change (edge audit 33): the
    /// machine's order differing from the table's made a bare ✓ a 「待保存」 edit.
    private func done() {
        let listed = choices.map { $0.value }
        let next = listed.filter { draft.contains($0) } + draft.filter { !listed.contains($0) }
        if multi && Set(next) == Set(initial) {
            dismiss()
            return
        }
        if next.isEmpty {
            if multi { Relay.shared.showToast("至少要留一个") }   // view.js:1399 toast("至少要留一个")
            return
        }
        commit(next)
        dismiss()
    }
}
