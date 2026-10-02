// Live data and saving for the 终末地 and 鸣潮 tabs: snap → page data, and the web page's save flow
// (maa-automation/web/view.js): edits wait in 「待保存」, one review, then each goes out as its own command
// (#go handler, view.js:2402-2440) and is recorded in Pending (`pending[e._id] = {...}`).

import SwiftUI

extension EWMaster {
    /// snap.master[game] (view.js:408 `((snap && snap.master) || {})[g.game] || {}`).
    static func from(snap: JSONValue?, game: String) -> EWMaster {
        guard let v = snap?["master"]?[game], !v.isNull,
              let m = try? JSONDecoder().decode(EWMaster.self, from: v.encoded()) else { return EWMaster() }
        return m
    }
}

extension EWValue {
    /// The value as the relay expects it in a command body.
    var json: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? .int(Int(n)) : .double(n)
        case .text(let s): return .string(s)
        case .list(let a): return .array(a.map { .string($0) })
        case .boxes(let d): return .object(d.mapValues { .string($0) })
        }
    }
}

extension JSONValue {
    /// A command value back as a page value (the inverse of EWValue.json).
    var ewValue: EWValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .text(s)
        case .array(let a): return .list(a.map { $0.jsString })
        case .object(let o): return .boxes(o.mapValues { $0.jsString })
        }
    }
}

/// The value a row shows: unsaved → sent (and not refused) → reported (view.js:445 `eff`).
@MainActor
func ewShown(_ m: EWMaster, game: String, edits: [String: EWEdit]) -> EWMaster {
    var out = m
    if m.isEmpty { return out }
    func put(_ path: String, _ to: JSONValue) {
        if case .boxes(let part) = to.ewValue {
            out.values[path] = .boxes((out.values[path]?.boxValues ?? [:]).merging(part) { _, b in b })
        } else {
            out.values[path] = to.ewValue
        }
    }
    let prefix = "master|\(game)|"
    for (k, p) in Pending.shared.items where k.hasPrefix(prefix) && p.mismatchAt == nil { put(p.path, p.to) }
    for (k, e) in edits where k.hasPrefix(prefix) { put(e.path, e.to) }
    return out
}

/// The row's name for the review list, 「卡名 · 行名」 (view.js:1041 `${g.title} · ${labelOf(g, f)}`).
func ewLabel(_ groups: [EWGroupSpec], _ m: EWMaster, _ path: String) -> String {
    for g in groups {
        if let r = ewRows(g, m, values: m.values).first(where: { $0.path == path && $0.kind != .box }) { return "\(g.title) · \(r.label)" }
    }
    return path
}

/// The small lines under a row (pending.js:47-70, view.js:1268-1275): 「待保存」 while unsaved, then the receipt tag.
struct EWRowTag: Equatable {
    var unsaved = false
    var text: String? = nil
    /// 「没生效」: red, with 「再发一次」 for this Pending key.
    var resendKey: String? = nil
    /// sent and waiting (`.posted`, view.js:60).
    var posted = false
}

/// The tag for one Pending key; nil when the row has nothing under it.
@MainActor
func ewTag(_ key: String, edits: [String: EWEdit]) -> EWRowTag? {
    let unsaved = edits[key] != nil
    var t = EWRowTag(unsaved: unsaved)
    switch Pending.shared.tag(for: key, editing: unsaved) {
    case .sent(let text)?: t.text = text; t.posted = true
    case .mismatch(let text, let k)?: t.text = text; t.resendKey = k; t.posted = true
    case .applied(let text)?: t.text = text
    case nil: break
    }
    return t.unsaved || t.text != nil ? t : nil
}

/// Tags for every config path of a game, keyed by path (the rows' own key).
@MainActor
func ewTags(game: String, master: EWMaster, edits: [String: EWEdit]) -> [String: EWRowTag] {
    var out: [String: EWRowTag] = [:]
    let prefix = "master|\(game)|"
    var paths = Set(master.values.keys)
    for k in Array(edits.keys) + Array(Pending.shared.items.keys) + Array(Pending.shared.acked.keys) where k.hasPrefix(prefix) {
        paths.insert(String(k.dropFirst(prefix.count)))
    }
    for p in paths { if let t = ewTag(prefix + p, edits: edits) { out[p] = t } }
    return out
}

/// Pending's receipt check reads the machine's value of every sent field (view.js render: `liveVals[id] = val`).
@MainActor
func ewSyncLive(game: String, master: EWMaster, extra: [String: JSONValue] = [:]) {
    for (path, v) in master.values { Pending.shared.liveVals["master|\(game)|\(path)"] = v.json }
    for (k, v) in extra { Pending.shared.liveVals[k] = v }
    Pending.shared.reconcile()
}

/// The last snap.master the page could read, per game (view.js:416-426, localStorage LS + "-master").
enum EWLastGood {
    static let key = "ark-remote-cfg-master"

    static func load(_ game: String) -> EWMaster? {
        guard let raw = UserDefaults.standard.string(forKey: key), let all = try? JSONValue.parse(raw),
              let v = all[game], !v.isNull else { return nil }
        return try? JSONDecoder().decode(EWMaster.self, from: v.encoded())
    }

    /// Keeps a readable copy; called with the raw snap so the stored JSON is the relay's own.
    static func save(snap: JSONValue?, game: String) {
        guard let v = snap?["master"]?[game], v["values"]?.object?.isEmpty == false else { return }
        var all = (UserDefaults.standard.string(forKey: key).flatMap { try? JSONValue.parse($0) })?.object ?? [:]
        all[game] = v
        UserDefaults.standard.set(JSONValue.object(all).encodedString(), forKey: key)
    }
}

/// One change waiting in 「待保存」 (view.js `edits[id]`). src: "master", "relay" or "wb".
struct EWEdit: Equatable {
    var label: String
    var src: String
    var owner: String = ""
    var path: String = ""
    var from: JSONValue?
    var to: JSONValue
    /// relay switches: the command body (sw.on / sw.off).
    var body: JSONValue? = nil
}

@MainActor
enum EWSave {
    /// A config edit, keyed like the web page (`${g.src}|${g.game}|${p}`). Returns nil when the value is back
    /// to what the machine has (the web page then drops the edit). Box rows keep only the changed boxes (view.js:1120-1127).
    static func masterEdit(game: String, path: String, label: String, to v: EWValue, machine: EWValue?) -> (String, EWEdit?) {
        let key = "master|\(game)|\(path)"
        if case .boxes(let d) = v {
            let now = machine?.boxValues ?? [:]
            var to: [String: JSONValue] = [:]
            var from: [String: JSONValue] = [:]
            for (k, x) in d {
                let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
                if (now[k] ?? "") != t {
                    to[k] = .string(t)
                    from[k] = .string(now[k] ?? "")
                }
            }
            if to.isEmpty { return (key, nil) }
            return (key, EWEdit(label: label, src: "master", owner: game, path: path, from: .object(from), to: .object(to)))
        }
        var v = v
        // view.js:1097-1099: the machine's type wins — MaaEnd stores some numbers as text ("5"), so a text value stays text.
        if case .text? = machine, case .number = v { v = .text(v.key) }
        if let machine, machine == v { return (key, nil) }
        return (key, EWEdit(label: label, src: "master", owner: game, path: path, from: machine?.json, to: v.json))
    }

    /// A 状态 shift switch: skip_today / unskip_today (view.js:1606 isSkipEdit).
    static func isSkip(_ e: EWEdit) -> Bool {
        guard e.src == "relay", let a = e.body?["action"]?.string else { return false }
        return a == "skip_today" || a == "unskip_today"
    }

    /// The review text (view.js doSave, 1609-1616): the shift skips first, in plain words (skipLine, view.js:1608:
    /// 「今天不跑：早班（09:00）」); then one change per line, 「卡名 · 行名」 with old → new by their option names (valLabel).
    static func summary(_ edits: [String: EWEdit]) -> String {
        let all = edits.values.sorted { $0.label < $1.label }
        let skips = all.filter(isSkip).map { e -> String in
            let parts = e.label.components(separatedBy: " · ")
            let verb = e.body?["action"]?.string == "skip_today" ? "今天不跑" : "今天照常跑"
            return "\(verb)：\(parts[0])\(parts.count > 1 ? "（\(parts[1])）" : "")"
        }
        let rest = all.filter { !isSkip($0) }.map { e -> String in
            let p = PendingEdit(label: e.label, src: e.src, owner: e.owner, path: e.path, from: e.from, to: e.to, sentAt: 0,
                                body: e.body)
            return "\(e.label)\n\(Pending.shared.valueLabel(p, e.from)) → \(Pending.shared.valueLabel(p, e.to))"
        }
        return (skips + rest).joined(separator: "\n\n")
    }

    /// view.js #go: send each change; the sent ones leave 「待保存」, the failed ones stay. Returns the keys still unsent and,
    /// when something did not go out, the message of the 「有改动没发出去」 alert (view.js:3005-3009).
    static func send(_ edits: [String: EWEdit]) async -> (left: [String: EWEdit], failure: String?) {
        let relay = Relay.shared
        var left = edits
        var sent = 0
        var failed: Error? = nil
        // view.js:2964-2973: everything that is not a switch or 周本 is a config field — set_master for a master copy
        // (终末地 / 鸣潮 / 方舟 基建 and 奖励), set_config for AUTO-MAS (方舟 「明日方舟」, src "mas").
        for (k, e) in edits.sorted(by: { $0.key < $1.key }) where e.src == "master" || e.src == "mas" {
            let body: JSONValue = e.src == "master"
                ? .object(["action": .string("set_master"), "confirmed": .bool(true), "game": .string(e.owner),
                           "path": .string(e.path), "value": e.to])
                : .object(["action": .string("set_config"), "confirmed": .bool(true), "script": .string(e.owner),
                           "path": .string(e.path), "value": e.to])
            do {
                try await relay.send(body)
                sent += 1
                left[k] = nil
                Pending.shared.add(k, PendingEdit(label: e.label, src: e.src, owner: e.owner, path: e.path,
                                                  from: e.from, to: e.to, sentAt: nowSec()))
            } catch { failed = error; break }
        }
        for (k, e) in edits.sorted(by: { $0.key < $1.key }) where e.src == "relay" {
            guard let body = e.body else { continue }
            do {
                try await relay.send(body)
                sent += 1
                left[k] = nil
                Pending.shared.add(k, PendingEdit(label: e.label, src: "relay", to: e.to, sentAt: nowSec(), body: body))
            } catch { if failed == nil { failed = error } }
        }
        // 周本 has one editable item, sent as weekly_boss; the web page records no receipt for it (view.js:2435-2440).
        let wb = edits.filter { $0.value.src == "wb" }
        if let last = wb.values.first {
            do {
                let n = Int(last.to.number ?? 1)   // view.js: Number(...) || 1
                try await relay.send(.object(["action": .string("weekly_boss"), "index": .int(n == 0 ? 1 : n)]))
                sent += wb.count
                for k in wb.keys { left[k] = nil }
            } catch { if failed == nil { failed = error } }
        }
        // view.js:3005-3012: a failure is an alert 「有改动没发出去」 with one 「好」 (EWSaveBar shows it); a full success is the
        // one-line toast 「已寄出 N 项」 at toast()'s default 2.6 s (view.js:72) — each row's own 「已寄出」 mark says the rest
        var failure: String? = nil
        if let failed {
            failure = sent > 0
                ? "发出去 \(sent) 项，剩下 \(left.count) 项没发出去（\(Live.why(failed))）。没发出去的还在页面上，可以再按一次保存。"
                : "一项都没发出去（\(Live.why(failed))）。改动还在页面上，可以再按一次保存。"
        } else if sent > 0 {
            relay.showToast("已寄出 \(sent) 项")
        }
        // view.js:2455-2457: ask the machine once, 2 s later, for a state reported after the send. One request, no loop.
        if sent > 0 {
            let after = nowSec()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await Live.shared.ping(minAt: after)
            }
        }
        return (left, failure)
    }
}

/// The edit bar and its review alert, on every tab (view.js updateBar / #confirm), over the one pool of unsaved
/// changes (Logic/Edits.swift): the count, ✕ and ✓ cover the changes of all tabs, as the web page's one top bar does.
/// `title`: the page title when nothing waits; while editing the title is 「待保存 N 项」 (view.js:1554 swaps the same span).
struct EWSaveBar: ViewModifier {
    var title: String? = nil
    @State var reviewing = false
    @State var saving = false
    /// The 「有改动没发出去」 alert's message after a send that left changes unsent (view.js:3007 ask(..., { single: true })).
    @State var failNote: String? = nil
    /// view.js:1619 goArmedAt: while the review lists a 今天不跑 / 今天照常跑, a tap on 寄出 in its first 400 ms is not a
    /// confirm (the 08:46 skips, 检查 09-30). 0 = armed at once.
    @State var armedAt: Double = 0

    private var edits: [String: EWEdit] { EWEdits.shared.items }

    func body(content: Content) -> some View {
        titled(content)
            .toolbar {
                if !edits.isEmpty {
                    // index.html:921 #discard (aria-label 放弃, xmark) / #save (aria-label 完成, checkmark)
                    ToolbarItem(placement: .cancellationAction) {
                        Button { EWEdits.shared.items = [:] } label: { Image(systemName: "xmark") }   // view.js:2950
                            .accessibilityLabel("放弃")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            armedAt = edits.values.contains(where: EWSave.isSkip) ? nowMs() + 400 : 0   // view.js:1619
                            reviewing = true
                        } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel("完成")
                            .disabled(saving)
                    }
                }
            }
            // index.html:933-939; doSave (view.js:1617) names the button by how many orders go out: 「寄出 N 项」
            .alert("确认这次修改", isPresented: $reviewing) {
                Button("寄出 \(edits.count) 项") {
                    // view.js:2955: a tap in the first 400 ms does nothing and the sheet stays; an alert closes on any button,
                    // so it is shown again (on the next turn: setting it here is undone by the dismissal)
                    if nowMs() < armedAt {
                        Task { @MainActor in reviewing = true }
                        return
                    }
                    guard !saving else { return }   // 2026-09-01: three taps sent three times
                    saving = true
                    Task {
                        let r = await EWSave.send(EWEdits.shared.items)
                        EWEdits.shared.items = r.left   // view.js:3003: the sent ones go, the unsent stay on the page
                        saving = false
                        failNote = r.failure
                    }
                }
                Button("再想想", role: .cancel) {}
            } message: {
                Text(verbatim: EWSave.summary(edits))
            }
            // view.js:3007: ask("有改动没发出去", …, "好", false, { single: true })
            .alert("有改动没发出去", isPresented: Binding(get: { failNote != nil }, set: { if !$0 { failNote = nil } })) {
                Button("好") {}
            } message: {
                Text(verbatim: failNote ?? "")
            }
            // the toast is one layer over all tabs now (Pages/Shell/ToastLayer.swift)
    }

    /// Branches on `title` only (fixed per tab), so a first edit never swaps the page's view identity.
    /// StatusTab passes none and keeps the title StatusPage sets.
    @ViewBuilder
    private func titled(_ content: Content) -> some View {
        if let title {
            content.navigationTitle(edits.isEmpty ? title : "待保存 \(edits.count) 项")
        } else {
            content
        }
    }
}

/// The 库存 page (stockpile.js): sections of materials, or a loading / empty state.
struct EndfieldStockpilePage: View {
    /// ContentView's tab selection (same AppStorage key), for 「去手机页」.
    @AppStorage("tab") var tab = ContentTab.status
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let s = Stockpile.shared
        List {
            switch s.content {
            case .loading:
                HStack {
                    ProgressView()
                    Text(Stockpile.loadingText).foregroundStyle(.secondary)
                }
            case .zero(let text):
                Text(text).foregroundStyle(.secondary)
            case .empty(let title, let text, let button, let action):
                VStack(alignment: .leading, spacing: 6) {
                    EWStockBox()   // stockpile.js:146 the empty-state box
                    Text(title).font(.headline)
                    Text(text).foregroundStyle(.secondary)
                    if action == .retry {
                        Button(button) { Task { await s.load(force: true) } }
                    } else {
                        // 「去手机页」: pop 库存 and select 手机 (accept-stockpile.js ⑨).
                        Button(button) {
                            dismiss()
                            tab = .phone
                        }
                    }
                }
            case .list(let sections, let footnote):
                ForEach(sections) { sec in
                    Section {
                        ForEach(sec.rows) { r in
                            HStack {
                                // stockpile.js:74, 98: the material's picture, 28 pt, fit; a picture that fails leaves the space empty
                                AsyncImage(url: r.icon.flatMap { URL(string: $0) }) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    Color.clear
                                }
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)   // r.name beside names it (HIG VoiceOver: decorative)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name)
                                    Text(r.subtitle + (r.origin ?? "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let v = r.value { Text(v).foregroundStyle(.secondary) }
                            }
                        }
                    } header: {
                        Text(sec.name)
                    } footer: {
                        if sec.id == sections.last?.id, !footnote.isEmpty {
                            Text(footnote.joined(separator: "\n"))
                        }
                    }
                }
            }
        }
        .navigationTitle(Stockpile.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(Stockpile.refreshLabel) { Task { await s.load(force: true) } }
                    .disabled(s.busy)
            }
        }
        .refreshable { await s.load(force: true) }
        .task { await s.open() }
    }
}

/// The empty-state box, traced from stockpile.js:146's SVG (viewBox 24, drawn 60 pt, stroke 1.2, secondary label colour).
struct EWStockBox: View {
    var body: some View {
        let k: CGFloat = 60.0 / 24.0
        var p = Path()
        p.move(to: CGPoint(x: 3 * k, y: 7.5 * k))
        p.addLine(to: CGPoint(x: 12 * k, y: 3 * k))
        p.addLine(to: CGPoint(x: 21 * k, y: 7.5 * k))
        p.addLine(to: CGPoint(x: 21 * k, y: 16.5 * k))
        p.addLine(to: CGPoint(x: 12 * k, y: 21 * k))
        p.addLine(to: CGPoint(x: 3 * k, y: 16.5 * k))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3 * k, y: 7.5 * k))
        p.addLine(to: CGPoint(x: 12 * k, y: 12 * k))
        p.addLine(to: CGPoint(x: 21 * k, y: 7.5 * k))
        p.move(to: CGPoint(x: 12 * k, y: 12 * k))
        p.addLine(to: CGPoint(x: 12 * k, y: 21 * k))
        return p.stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.2 * k, lineJoin: .round))
            .frame(width: 60, height: 60)
    }
}
