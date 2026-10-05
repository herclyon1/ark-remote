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

/// The value a row shows: unsaved → sent → reported (view.js:505 `eff`). A sent value the machine answered differently
/// (mismatchAt) is still what the control shows (applyPending, pending.js:37), with 「没生效 … 再发一次」 under it.
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
    for (k, p) in Pending.shared.items where k.hasPrefix(prefix) { put(p.path, p.to) }
    for (k, e) in edits where k.hasPrefix(prefix) { put(e.path, e.to) }
    return out
}

/// The row's name for the review list, 「卡名 · 行名」 (view.js:1292 `${g.title} · ${labelOf(g, f)}`). Looked up in the
/// card's whole field table (locate, view.js:1270: a tree card's g.fields is the whole tree, treeFields :1416), not only
/// the rows the machine's values open: a child that shows after an unsaved parent change keeps its name.
func ewLabel(_ groups: [EWGroupSpec], _ m: EWMaster, _ path: String) -> String {
    for g in groups {
        let fields = g.tree != nil ? ewTreeFields(g, m) : g.fields
        if let f = fields.first(where: { $0.path == path }) { return "\(g.title) · \(ewLabel(f, m))" }
    }
    return path
}

/// view.js base() (:1286): the value the control showed before this change — the sent value while it waits for its
/// receipt (also when the machine answered differently), else the machine's. A change back to it drops the edit; taking
/// the machine's alone made a change back after a save look like no change, and the sent value still landed (检查 09-30).
/// Boxes: the machine's boxes with the sent ones over them (view.js:1374).
@MainActor
func ewBase(game: String, path: String, machine: EWValue?) -> EWValue? {
    guard let p = Pending.shared.items["master|\(game)|\(path)"] else { return machine }
    if case .boxes(let sent) = p.to.ewValue {
        return .boxes((machine?.boxValues ?? [:]).merging(sent) { _, b in b })
    }
    return p.to.ewValue
}

/// Puts a change into 「待保存」 (nil drops it) where a JS object would: a key already there keeps its place in the
/// change order (`edits[id] = …` on an existing key), a new or re-added one goes last (view.js note / delete edits[id]).
@MainActor
func ewPutEdit(_ key: String, _ edit: EWEdit?) {
    guard var e = edit else { EWEdits.shared.items[key] = nil; return }
    if let old = EWEdits.shared.items[key] { e.at = old.at }
    EWEdits.shared.items[key] = e
}

/// The small lines under a row (pending.js:47-70, view.js:1268-1275): 「待保存」 while unsaved, then the receipt tag.
struct EWRowTag: Equatable {
    var unsaved = false
    var text: String? = nil
    /// 「再发一次」 for this Pending key: under 「没生效」 and under the 10 h 「没回执 · 已寄出 HH:MM」 line (pending.js:59).
    var resendKey: String? = nil
    /// 「没生效」 (class "sent bad"): red. The 10 h line is class "sent": grey, though it has a button too.
    var bad = false
    /// sent and waiting (`.posted`, view.js:60).
    var posted = false
}

/// The tag for one Pending key; nil when the row has nothing under it.
@MainActor
func ewTag(_ key: String, edits: [String: EWEdit]) -> EWRowTag? {
    let unsaved = edits[key] != nil
    var t = EWRowTag(unsaved: unsaved)
    switch Pending.shared.tag(for: key, editing: unsaved) {
    case .sent(let text)?: t.text = text; t.resendKey = Pending.shared.staleResendKey(for: key); t.posted = true
    case .mismatch(let text, let k)?: t.text = text; t.resendKey = k; t.posted = true; t.bad = true
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
    /// When the change was made (ms): the review lists and sends in this order, as the web page's `edits` object keeps
    /// its keys in insertion order (view.js doSave :1609, #go :2962).
    var at: Double = nowMs()
}

/// One entry of the review sheet (view.js doSave :1612-1615): a shift skip in plain words (red, bold), or a change
/// 「卡名 · 行名」 (bold) with old → new by option names.
struct EWReviewLine: Identifiable {
    var id: String
    var title: String
    var old: String? = nil
    var new: String? = nil
    var skip = false
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

    /// What is wrong with a change, in words, or nil when it can go (send). Number rows: the schema's `number` fields
    /// (Logic/Schema.swift, EndfieldSchema, WuwaSchema). An emptied box is null (EWRowView.setNumber, ArknightsBridge
    /// outgoing) and text the machine keeps as text stays text (masterEdit), so a number may arrive as "5".
    static func problem(_ e: EWEdit) -> String? {
        func int(_ v: JSONValue) -> Int? {
            switch v {
            case .int(let i): return i
            case .double(let d): return d == d.rounded() && abs(d) < 1e9 ? Int(d) : nil
            case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            default: return nil
            }
        }
        if e.src == "wb" {
            guard let n = int(e.to), (1...20).contains(n) else { return "要填 1–20" }   // weeklyboss.py:219
            return nil
        }
        if e.src == "mas" && e.path == "Info.Stage" {
            return stageOK(e.to.string ?? "") ? nil : "要写成 1-7、CE-6 这种"   // set_stage's check, commands.py:58 / 160-163
        }
        if e.src == "mas" && e.path == "Info.MedicineNumb" {
            guard let n = int(e.to), (0...999).contains(n) else { return "要填 0–999 的整数" }   // set_medicine, commands.py:186
            return nil
        }
        if numberPaths.contains("\(e.src)|\(e.owner)|\(e.path)") && int(e.to) == nil { return "要填整数" }
        return nil
    }

    /// commands.py _STAGE_RE `^[A-Za-z0-9]{1,4}-[A-Za-z0-9]{1,3}$` (the stage is trimmed and upper-cased before, outgoing).
    static func stageOK(_ s: String) -> Bool {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 2, (1...4).contains(p[0].count), (1...3).contains(p[1].count) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "-" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `src|owner|path` of every number row.
    static let numberPaths: Set<String> = {
        var out = Set<String>()
        for sec in schema {
            for f in sec.fields where f.type == "number" { out.insert("\(sec.src)|\(sec.game ?? sec.script ?? "")|\(f.path)") }
        }
        for f in EndfieldSchema.groups.flatMap({ $0.fields }) where f.type == .number { out.insert("master|MaaEnd|\(f.path)") }
        for f in WuwaSchema.group.fields where f.type == .number { out.insert("master|OK-WW|\(f.path)") }
        return out
    }()

    /// A 状态 shift switch: skip_today / unskip_today (view.js:1606 isSkipEdit).
    static func isSkip(_ e: EWEdit) -> Bool {
        guard e.src == "relay", let a = e.body?["action"]?.string else { return false }
        return a == "skip_today" || a == "unskip_today"
    }

    /// The changes in the order they were made (the web page's `Object.values(edits)` / `Object.entries(edits)`).
    static func ordered(_ edits: [String: EWEdit]) -> [String] {
        edits.keys.sorted { a, b in
            let x = edits[a]?.at ?? 0
            let y = edits[b]?.at ?? 0
            return x != y ? x < y : a < b
        }
    }

    /// The review list (view.js doSave, 1609-1616): the shift skips first, in plain words (skipLine, view.js:1608:
    /// 「今天不跑：早班（09:00）」); then the other changes in the order they were made, 「卡名 · 行名」 with old → new by
    /// their option names (valLabel).
    static func review(_ edits: [String: EWEdit]) -> [EWReviewLine] {
        let keys = ordered(edits)
        let skips = keys.compactMap { k -> EWReviewLine? in
            guard let e = edits[k], isSkip(e) else { return nil }
            let parts = e.label.components(separatedBy: " · ")
            let verb = e.body?["action"]?.string == "skip_today" ? "今天不跑" : "今天照常跑"
            return EWReviewLine(id: k, title: "\(verb)：\(parts[0])\(parts.count > 1 ? "（\(parts[1])）" : "")", skip: true)
        }
        let rest = keys.compactMap { k -> EWReviewLine? in
            guard let e = edits[k], !isSkip(e) else { return nil }
            let p = PendingEdit(label: e.label, src: e.src, owner: e.owner, path: e.path, from: e.from, to: e.to, sentAt: 0,
                                body: e.body)
            return EWReviewLine(id: k, title: e.label, old: Pending.shared.valueLabel(p, e.from),
                                new: Pending.shared.valueLabel(p, e.to))
        }
        return skips + rest
    }

    /// view.js #go: send each change; the sent ones leave 「待保存」, the failed ones stay. Returns the keys still unsent and,
    /// when something did not go out, the message of the 「有改动没发出去」 alert (view.js:3005-3009).
    static func send(_ edits: [String: EWEdit]) async -> (left: [String: EWEdit], failure: String?) {
        // 审查 A5 / B11 / B15: a value the relay refuses (周本 outside 1–20, weeklyboss.py:219; a MaaEnd number its verify
        // rule rejects, mastercfg.py:465-482) or hands to AUTO-MAS unchecked (set_config checks nothing, commands.py:417-449)
        // is not sent; nothing goes until it is fixed, so one review is one send
        let bad = ordered(edits).compactMap { k -> String? in
            guard let e = edits[k], let why = problem(e) else { return nil }
            return "「\(e.label)」\(why)"
        }
        if !bad.isEmpty {
            return (edits, "有几项填得不对，这次一项都没寄出：\(bad.joined(separator: "；"))。改好再保存。")
        }
        let relay = Relay.shared
        var left = edits
        var sent = 0
        var failed: Error? = nil
        // view.js:2964-2973: everything that is not a switch or 周本 is a config field — set_master for a master copy
        // (终末地 / 鸣潮 / 方舟 基建 and 奖励), set_config for AUTO-MAS (方舟 「明日方舟」, src "mas").
        for k in ordered(edits) {
            guard let e = edits[k], e.src == "master" || e.src == "mas" else { continue }
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
        for k in ordered(edits) {
            guard let e = edits[k], e.src == "relay", let raw = e.body else { continue }
            let body = Pending.skipDayNow(raw)   // the day of a skip is today's when it goes out (审查 B10)
            do {
                try await relay.send(body)
                sent += 1
                left[k] = nil
                Pending.shared.add(k, PendingEdit(label: e.label, src: "relay", to: e.to, sentAt: nowSec(), body: body))
            } catch { if failed == nil { failed = error } }
        }
        // 周本 has one editable item, sent as weekly_boss (view.js:2984-2998). It gets the same receipt as the switches
        // (user 09-29 13:39: after saving, the number box showed neither 「已寄出」 nor the new number): Pending keeps the
        // body for 「再发一次」 and `to` for the check against snap.relay 周常.周本.第几个周本 (view.js:576).
        let wb = ordered(edits).filter { edits[$0]?.src == "wb" }
        if let lastKey = wb.last, let last = edits[lastKey] {
            do {
                let n = Int(last.to.number ?? 1)   // view.js: Number(...) || 1
                let idx = n == 0 ? 1 : n
                let body: JSONValue = .object(["action": .string("weekly_boss"), "index": .int(idx)])
                try await relay.send(body)
                sent += wb.count
                for k in wb {
                    left[k] = nil
                    guard let w = edits[k] else { continue }
                    Pending.shared.add(k, PendingEdit(label: w.label, src: "wb", from: w.from, to: .int(idx), sentAt: nowSec(),
                                                      body: body))
                }
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
    /// confirm (the 08:46 skips, 检查 09-30); the sheet stays. The web judges by when the press began (view.js:2953-2955
    /// goPressAt), so a slow press started early and let go late is no confirm either: here 寄出 stays disabled for those
    /// 400 ms, counted from when the sheet is up (showModal), and a press that began on a disabled button never fires.
    @State var armed = true
    /// Bumped on each ✓, so a 400 ms wait left over from a sheet closed early cannot arm a newer one.
    @State var armGen = 0

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
                            armed = !edits.values.contains(where: EWSave.isSkip)   // view.js:1619
                            armGen += 1
                            reviewing = true
                        } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel("完成")
                            .disabled(saving)
                    }
                }
            }
            // index.html:933-939 #confirm; doSave (view.js:1609-1617). A sheet, not an alert: an alert's message is plain
            // text, and the web's list sets each name in bold, a shift skip in red (index.html:875-876 .diff.skip / .diff b),
            // the old value grey and struck through, the new one green (index.html:877-878 .old / .new).
            .sheet(isPresented: $reviewing) {
                NavigationStack {
                    List {
                        ForEach(EWSave.review(edits)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: line.title)
                                    .bold()
                                    .foregroundStyle(line.skip ? Color.red : Color.primary)
                                if let old = line.old, let new = line.new {
                                    HStack(spacing: 4) {
                                        Text(verbatim: old).strikethrough().foregroundStyle(.secondary)
                                        Text(verbatim: "→")
                                        Text(verbatim: new).foregroundStyle(Color.green)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                    }
                    .navigationTitle("确认这次修改")
                    #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("再想想") { reviewing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            // doSave (view.js:1617) names the button by how many orders go out: 「寄出 N 项」
                            Button("寄出 \(edits.count) 项") { go() }
                                .disabled(saving || !armed)
                        }
                    }
                }
                .onAppear {
                    guard !armed else { return }
                    let gen = armGen
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if gen == armGen { armed = true }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            // view.js:3007: ask("有改动没发出去", …, "好", false, { single: true })
            .alert("有改动没发出去", isPresented: Binding(get: { failNote != nil }, set: { if !$0 { failNote = nil } })) {
                Button("好") {}
            } message: {
                Text(verbatim: failNote ?? "")
            }
            // the toast is one layer over all tabs now (Pages/Shell/ToastLayer.swift)
    }

    /// #go (view.js:2954-3016): a tap in the first 400 ms while a skip is listed does nothing and the sheet stays.
    private func go() {
        guard armed else { return }
        guard !saving else { return }   // 2026-09-01: three taps sent three times
        saving = true
        reviewing = false
        Task {
            let r = await EWSave.send(EWEdits.shared.items)
            EWEdits.shared.items = r.left   // view.js:3003: the sent ones go, the unsent stay on the page
            saving = false
            failNote = r.failure
        }
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
