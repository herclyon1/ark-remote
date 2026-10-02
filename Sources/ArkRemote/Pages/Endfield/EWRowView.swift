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

/// One config row. `values` is the page's working copy; `onChange` reports each edit (path, new value).
struct EWRowView: View {
    var row: EWRow
    @Binding var values: [String: EWValue]
    var readonly: [String: EWValue] = [:]
    var onChange: (String, EWValue) -> Void = { _, _ in }
    /// 「待保存」 / 「已寄出 …」 / 「没生效 …」 / 「已应用 …」 under the row (box sub-rows carry none; their header does).
    var tag: EWRowTag? = nil
    var onResend: (String) -> Void = { _ in }

    private var value: EWValue { values[row.path] ?? readonly[row.path] ?? .null }

    private func set(_ v: EWValue) {
        values[row.path] = v
        onChange(row.path, v)
    }

    private func pick(_ v: EWValue) -> String {
        row.choices.first { $0.value == v.key }?.label ?? v.display
    }

    var body: some View {
        if let tag, row.kind != .box {
            VStack(alignment: .leading, spacing: 4) {
                control
                EWTagLine(tag: tag, onResend: onResend)
            }
            // index.html:689-690: unsaved rows tinted accent 8 %, sent rows ok-green 8 % (近似: replaces the card colour, not mixed into it)
            .listRowBackground(tag.unsaved ? Color.accentColor.opacity(0.08) : tag.posted ? Color.green.opacity(0.08) : nil)
        } else {
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch row.kind {
        case .warning:
            Label(row.label, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .readOnly:
            HStack {
                EWRowTitle(label: row.label, hint: row.hint)
                Spacer()
                Text(pick(value).isEmpty ? "（空）" : pick(value)).foregroundStyle(.secondary)   // view.js fmt(null)
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value.isOn }, set: { set(.bool($0)) })) {
                EWRowTitle(label: row.label, hint: row.hint)
            }
        case .select:
            Picker(selection: Binding(get: { value == .null ? "" : value.key }, set: { setChoice($0) })) {
                if value == .null {
                    Text("未设").tag("")
                }
                ForEach(row.choices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            } label: {
                EWRowTitle(label: row.label, hint: row.hint)
            }
            .pickerStyle(.menu)
        case .icons:
            NavigationLink {
                EWChoiceList(title: row.label, choices: row.choices, multi: false, icons: true,
                             initial: [value.key], commit: { setChoice($0.first ?? "") })
            } label: {
                HStack {
                    EWRowTitle(label: row.label, hint: row.hint)
                    Spacer()
                    Text(pick(value)).foregroundStyle(.secondary)
                }
            }
        case .pills:
            NavigationLink {
                EWChoiceList(title: row.label, choices: row.choices, multi: true,
                             initial: value.items, commit: { set(.list($0)) })
            } label: {
                HStack {
                    EWRowTitle(label: row.label, hint: row.hint)
                    Spacer()
                    Text("已选 \(row.choices.filter { value.items.contains($0.value) }.count)/\(row.choices.count)")
                        .foregroundStyle(.secondary)
                }
            }
        case .boxesHeader:
            HStack {
                EWRowTitle(label: row.label, hint: row.hint)
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
                EWRowTitle(label: row.label, hint: row.hint)
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
                EWRowTitle(label: row.label, hint: row.hint)
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
                        .foregroundStyle(tag.resendKey == nil ? Color.secondary : Color.red)
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
    @State var draft: [String]
    @Environment(\.dismiss) var dismiss

    init(title: String, choices: [EWChoice], multi: Bool, icons: Bool = false,
         initial: [String], commit: @escaping ([String]) -> Void) {
        self.title = title
        self.choices = choices
        self.multi = multi
        self.icons = icons
        self.commit = commit
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
                                    Image(asset, bundle: .module, label: Text(name))
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        Text(c.label)
                        Spacer()
                        if draft.contains(c.value) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { done() } label: { Image(systemName: "checkmark") }
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
    private func done() {
        let next = choices.map { $0.value }.filter { draft.contains($0) }
        if next.isEmpty {
            if multi { Relay.shared.showToast("至少要留一个，全不选的话这个任务会直接结束") }
            return
        }
        commit(next)
        dismiss()
    }
}
