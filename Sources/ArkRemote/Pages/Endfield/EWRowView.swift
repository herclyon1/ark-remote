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

    private var value: EWValue { values[row.path] ?? readonly[row.path] ?? .null }

    private func set(_ v: EWValue) {
        values[row.path] = v
        onChange(row.path, v)
    }

    private func pick(_ v: EWValue) -> String {
        row.choices.first { $0.value == v.key }?.label ?? v.display
    }

    var body: some View {
        switch row.kind {
        case .warning:
            Label(row.label, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .readOnly:
            HStack {
                EWRowTitle(label: row.label, hint: row.hint)
                Spacer()
                Text(pick(value)).foregroundStyle(.secondary)
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
                             selected: Binding(get: { [value.key] }, set: { setChoice($0.first ?? "") }))
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
                             selected: Binding(get: { value.items }, set: { set(.list($0)) }))
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
                TextField(row.label, text: Binding(get: { value.display }, set: { set(Double($0).map { .number($0) } ?? .text($0)) }))
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
    private func setChoice(_ v: String) {
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

/// The checklist page behind an icons (single) or pills (multi) row: one row per choice, a checkmark on the chosen ones.
struct EWChoiceList: View {
    var title: String
    var choices: [EWChoice]
    var multi: Bool
    /// icons rows: each echo set's icon before the label, 28 pt (view.js:1215 `.pico`, index.html:379 --ios-row2-icon).
    var icons = false
    @Binding var selected: [String]

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
                        if selected.contains(c.value) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private func toggle(_ v: String) {
        if !multi {
            selected = [v]
        } else if let i = selected.firstIndex(of: v) {
            selected.remove(at: i)
        } else {
            selected.append(v)
        }
    }
}
