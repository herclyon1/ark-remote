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

/// The select rows whose choices end in their products in brackets (ewYieldLabel): only 刷哪一类, whose
/// 「干员养成（作战记录、协议圆盘、折金票、协议棱柱）」 wrapped to 2 lines on iOS and 3 (cut) on Android (HIG review 1014).
let ewMenuSubtitlePaths: Set<String> = ["ProtocolSpace/ProtocolSpaceTab"]

/// 「干员养成（作战记录、协议圆盘）」 → (「干员养成」, 「作战记录、协议圆盘」) for a row in ewMenuSubtitlePaths; nil otherwise or
/// when the label has no trailing bracket.
func ewMenuParts(_ path: String, _ label: String) -> (title: String, subtitle: String)? {
    guard ewMenuSubtitlePaths.contains(path), label.hasSuffix("）"), let open = label.firstIndex(of: "（"),
          open != label.startIndex else { return nil }
    let title = String(label[..<open])
    let sub = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
    return sub.isEmpty ? nil : (title, sub)
}

/// One footer line's source: a row's name and its hint.
struct EWFootItem {
    var label: String
    var hint: String?
}

/// The card's footer (view.js:976-995, Settings › Accessibility › Motion): each row's hint moves from the row to a
/// paragraph under the card, one sentence a line. No 「行名：」 in front: it repeated every row name drawn right above,
/// and 方舟 / 鸣潮 dropped it (decision A2/W4; HIG Writing: "Check each word to be sure it needs to be there."), so each
/// hint names its own subject (EndfieldSchema). A line already said (the four route rows' 「勾上的路线才会去采。」, the
/// four reward rows') is not said again. `rows` = the card's row count (kept for the callers; the footer no longer depends on it).
func ewFoot(_ items: [EWFootItem], rows: Int) -> String {
    var lines: [String] = []
    for i in items {
        guard let h = i.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty, !lines.contains(h) else { continue }
        lines.append(h)
    }
    return lines.joined(separator: "\n")
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
        // no row tint for 待保存 / 已寄出 (the web's accent / green 8 %): a row tinted for long reads as a selection that
        // never cleared (HIG Lists and tables: a list "highlights a row only briefly"); the line under the row says it
        .listRowBackground(rowBackground(nil))   // never nil on Android (SkipFixes.swift)
    }

    private var selectBinding: Binding<String> {
        Binding(get: { value == .null ? "" : value.key }, set: { setChoice($0) })
    }

    @ViewBuilder private var choiceItems: some View {
        if value == .null {
            Text("未设").tag("")
        }
        ForEach(row.choices, id: \.value) { c in
            if let parts = ewMenuParts(row.path, c.label) {
                // the name as the item's title and the row's value, the products as the item's subtitle (a menu item's
                // second Text): 「干员养成」 on one line in the row, 「作战记录、协议圆盘、…」 still beside it in the menu
                // (HIG Menus: "write a label that clearly and succinctly describes it"; decision E7: the products stay
                // visible on the choice page)
                VStack(alignment: .leading) {
                    Text(verbatim: parts.title)
                    Text(verbatim: parts.subtitle)
                }
                .tag(c.value)
            } else {
                Text(c.label).tag(c.value)
            }
        }
    }

    #if os(Android)
    /// Android, a row whose choices carry products (ewMenuParts): skip-ui draws a Picker's picked value with the very
    /// view its menu item uses (Picker.swift RenderSelectedValue / RenderPickerSelectionMenu), so the products wrapped
    /// into the row again (2-3 lines, the last cut). The system Menu keeps them apart: its label is the name alone,
    /// with the chevron the Picker draws, and each item the name over its products, the picked one ticked.
    private var productMenu: some View {
        HStack(spacing: 12) {
            EWRowTitle(label: row.label, hint: hint).frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(row.choices, id: \.value) { c in
                    let parts = ewMenuParts(row.path, c.label)
                    Button { setChoice(c.value) } label: {
                        if c.value == value.key {
                            Label { productItem(c, parts) } icon: { Image(systemName: "checkmark") }
                        } else {
                            productItem(c, parts)
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(verbatim: value == .null ? "未设" : (ewMenuParts(row.path, pick(value))?.title ?? pick(value)))
                    Image(systemName: "chevron.down").accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder private func productItem(_ c: EWChoice, _ parts: (title: String, subtitle: String)?) -> some View {
        if let parts {
            VStack(alignment: .leading) {
                Text(verbatim: parts.title)
                Text(verbatim: parts.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text(c.label)
        }
    }
    #endif

    /// menuPicker (SkipFixes.swift): inside this row's VStack a bare Picker loses its title on Android.
    private var selectPicker: some View {
        menuPicker(selection: selectBinding) {
            choiceItems
        } title: {
            EWRowTitle(label: row.label, hint: hint)
        }
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
                // view.js fmt(null); a machine list 「梦枢天罗,落渊南丘」 in Chinese punctuation (statusTidyHint)
                Text(pick(value).isEmpty ? "（空）" : statusTidyHint(pick(value))).foregroundStyle(.secondary)
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value.isOn }, set: { set(.bool($0)) })) {
                EWRowTitle(label: row.label, hint: hint)
            }
        case .select:
            #if os(Android)
            if ewMenuSubtitlePaths.contains(row.path) {
                productMenu
            } else {
                selectPicker
            }
            #else
            selectPicker
            #endif
        case .icons:
            SheetLink {   // the 37b / 38 pick page as a sheet (SkipFixes.swift)
                EWChoiceList(title: row.label, choices: row.choices, multi: false, icons: true,
                             initial: [value.key], commit: { setChoice($0.first ?? "") })
            } label: {
                HStack {
                    EWRowTitle(label: row.label, hint: hint)
                    Spacer()
                    Text(value == .null ? "（空）" : pick(value)).foregroundStyle(.secondary)   // view.js:545 fmt(null)
                        // a value that wraps (Android: 「雪落无声之愿 ＋ 剪心辑梦之影」) keeps to the trailing edge, as a
                        // value does, instead of leaving 「影」 alone at the left (HIG review 1014)
                        .multilineTextAlignment(.trailing)
                }
                .foregroundStyle(Color.primary)   // see sheetRowColour
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
                // sheetRowColour: the name in the label colour and 「已选 N/M」 grey, as Calendar › Repeat's row. The
                // row is a Button (SheetLink), whose label takes the accent colour; `.primary` / `.secondary` are
                // hierarchical styles of that accent, so only a Color resets it (the name and value were drawn blue)
                .foregroundStyle(Color.primary)
            }
        case .boxesHeader:
            HStack {
                EWRowTitle(label: row.label, hint: hint)
                Spacer()
                Text("\(boxCount) 格").foregroundStyle(.secondary)
            }
        // The field rows: the system's label + value row (LabeledContent), the field taking the width the name leaves,
        // its text at the trailing edge, as a Form's TextField beside a label. Was an HStack with the field capped at a
        // fixed 100 / 160 pt (HIG Layout: "respecting system-defined safe areas, margins, and guides").
        case .box:
            LabeledContent {
                TextField(row.label, text: Binding(get: { value.boxValues[row.boxKey ?? ""] ?? "" }, set: { setBox($0) }))
                    .multilineTextAlignment(.trailing)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            } label: {
                Text(row.label)
            }
        case .number:
            LabeledContent {
                TextField(row.label, text: Binding(get: { value.display }, set: { setNumber($0) }))
                    .multilineTextAlignment(.trailing)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            } label: {
                EWRowTitle(label: row.label, hint: hint)
            }
        case .text:
            LabeledContent {
                TextField(row.label, text: Binding(get: { value.display }, set: { set(.text($0)) }))
                    .multilineTextAlignment(.trailing)
            } label: {
                EWRowTitle(label: row.label, hint: hint)
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

/// The small lines under a row: 「待保存」 in grey (not the accent colour of things that can be tapped: HIG Color), then the receipt —
/// grey, or red with 「再发一次」 (pending.js:51-58, index.html:691-695; ArknightsPage.tagged).
struct EWTagLine: View {
    var tag: EWRowTag
    var onResend: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if tag.unsaved {
                Text("待保存").font(.footnote).foregroundStyle(.secondary)
            }
            if let text = tag.text {
                HStack(spacing: 6) {
                    Text(verbatim: text)
                        .font(.footnote)
                        .foregroundStyle(tag.bad ? Color.red : Color.secondary)   // the 10 h line has a button but stays grey (class "sent")
                    if let key = tag.resendKey {
                        Button("再发一次") { onResend(key) }
                            .font(.footnote)
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
    /// What the row showed when the page opened.
    let initial: [String]
    @State var draft: [String]
    @Environment(\.dismiss) var dismiss
    /// The echo-set icon, 28 pt at the default text size, growing with Dynamic Type (HIG Typography; was a fixed 28).
    @ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 28

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
            Section {
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
                                            .frame(width: iconSize, height: iconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            // P4 (快捷指令 › Custom 选周几, 日历 › Repeat): the option in the label colour, only the
                            // checkmark in the accent colour; a bare Button label in a List took the accent colour
                            Text(c.label).foregroundStyle(Color.primary)   // a Color: `.primary` is the accent's own level
                            Spacer()
                            if draft.contains(c.value) {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                            }
                        }
                    }
                    // the checkmark is said as the row's selected state, as a native selection list does
                    // (AccessibilityTraits.isSelected: "The accessibility element is currently selected.")
                    .accessibilityAddTraits(draft.contains(c.value) ? .isSelected : Self.noTraits)
                }
            } footer: {
                // why ✓ is grey (shell-api 191, was the toast 「至少要留一个」 view.js:1399): HIG Entering data "make the
                // button available only after people enter the data you require"
                if blocked { Text("至少要留一个") }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                doneButton
                    .accessibilityLabel("完成")   // icon-only: named as EWLive's ✓ (index.html:921 aria-label 完成)
                    // grey until something changed, as Shortcuts' 「Done」 (P4); and while nothing is ticked (blocked)
                    .disabled(blocked || !changed)
            }
        }
    }

    /// ✓ in the prominent confirm style of the save bar's ✓ (SaveBar.swift confirmButton; HIG Toolbars: "Use the
    /// .prominent style for key actions such as Done or Submit."), as Calendar's and Passwords' filled ✓ (P4, P12).
    /// Android: the plain checkmark, as the save bar's.
    @ViewBuilder private var doneButton: some View {
        #if os(Android)
        Button { done() } label: { Image(systemName: "checkmark") }
        #else
        Button(role: .confirm) { done() }
        #endif
    }

    /// The ticks differ from what the row showed when the page opened.
    private var changed: Bool { Set(draft) != Set(initial) }

    /// Nothing ticked on a multi-choice page: MaaEnd ends the task on an empty list, so ✓ cannot write it back.
    private var blocked: Bool { ewChoiceResult(draft: draft, initial: initial, listed: choices.map { $0.value }, multi: multi) == .blocked }

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

    private func toggle(_ v: String) {
        if !multi {
            draft = [v]
        } else if let i = draft.firstIndex(of: v) {
            draft.remove(at: i)
        } else {
            draft.append(v)
        }
    }

    /// ✓: ewChoiceResult below.
    private func done() {
        switch ewChoiceResult(draft: draft, initial: initial, listed: choices.map { $0.value }, multi: multi) {
        case .unchanged: dismiss()
        case .blocked: return   // ✓ is disabled then; the footer says why
        case .commit(let next):
            commit(next)
            dismiss()
        }
    }
}

/// What ✓ on the choice page does with the ticked values (view.js:1146-1149).
enum EWChoiceResult: Equatable {
    /// The same set as when the page opened: close, no edit.
    case unchanged
    /// Nothing ticked: ✓ is disabled (multi: 「至少要留一个」; single: nothing to write).
    case blocked
    /// Write these back, in the option table's order.
    case commit([String])
}

/// view.js:1146-1149: written back in the option table's order; none at all is refused (MaaEnd ends the task).
/// A value the option table does not list (any more) stays, after the listed ones: it has no row to untick, and
/// dropping it on ✓ deleted it from the machine. The same set in another order is no change (edge audit 33): the
/// machine's order differing from the table's made a bare ✓ a 「待保存」 edit.
func ewChoiceResult(draft: [String], initial: [String], listed: [String], multi: Bool) -> EWChoiceResult {
    let next = listed.filter { draft.contains($0) } + draft.filter { !listed.contains($0) }
    if multi && Set(next) == Set(initial) { return .unchanged }
    if next.isEmpty { return .blocked }
    return .commit(next)
}
