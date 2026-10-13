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

    /// The decoded copy of each game's snap.master per snapshot, for `live` below. A plain static, not a property of an
    /// @Observable type: a tracked write during body re-runs the body (StatusMapping.swift:55-57).
    @MainActor private static var liveCache: [String: (at: Double, master: EWMaster)] = [:]

    /// `from(snap: Relay.shared.snap, game:)`, decoded once per snapshot. A switch to 终末地 stalled the user's Android
    /// phone 166-187 ms every time and 手机 → 鸣潮 122-123 ms (fluency audit 10-05, 0.4.3): skip-ui composes only the
    /// selected tab (TabView.swift:537-541 hands NavDisplay the selected tab's entries alone), so every switch ran the tab's
    /// body afresh, and it encoded and re-decoded snap.master twice on the main thread. snap.at names one snapshot: adopt
    /// takes only a strictly newer `at` (Net.swift:307-310) and is the only writer besides init; a snap without `at`
    /// (only a cached one from before the first adopt) is decoded every time, as before.
    @MainActor static func live(_ game: String) -> EWMaster {
        let snap = Relay.shared.snap
        guard let at = snap?["at"]?.number else { return from(snap: snap, game: game) }
        if let c = liveCache[game], c.at == at { return c.master }
        let m = from(snap: snap, game: game)
        liveCache[game] = (at, m)
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

    // In-memory copies, so a tab's body does not parse the stored string: load ran twice per body of the 终末地 and 鸣潮
    // tabs, each parsing every game's stored master and re-decoding one (see EWMaster.live for the stalls it was part of).
    // `save` is the only writer of `key` (ArknightsBridge.swift:222 only reads it), so the copies change only there.
    /// The stored object, parsed once per process.
    @MainActor private static var stored: [String: JSONValue]? = nil
    /// One game's decoded copy; a wrapper so "read, none stored" (nil master) differs from "not read yet" (no entry).
    private struct Decoded { var master: EWMaster? }
    @MainActor private static var decoded: [String: Decoded] = [:]
    /// snap.at of the copy each game last saved: a newer tab body or sync with the same snapshot has nothing new to keep.
    @MainActor private static var savedAt: [String: Double] = [:]

    @MainActor private static func all() -> [String: JSONValue] {
        if let stored { return stored }
        let a = (UserDefaults.standard.string(forKey: key).flatMap { try? JSONValue.parse($0) })?.object ?? [:]
        stored = a
        return a
    }

    @MainActor static func load(_ game: String) -> EWMaster? {
        if let d = decoded[game] { return d.master }
        var m: EWMaster? = nil
        if let v = all()[game], !v.isNull { m = try? JSONDecoder().decode(EWMaster.self, from: v.encoded()) }
        decoded[game] = Decoded(master: m)
        return m
    }

    /// Keeps a readable copy; called with the raw snap so the stored JSON is the relay's own.
    @MainActor static func save(snap: JSONValue?, game: String) {
        guard let v = snap?["master"]?[game], v["values"]?.object?.isEmpty == false else { return }
        // the same snapshot again (each tab's .task and onChange(of: snapAt) call this): already stored as is.
        // snap.at names one snapshot (Net.swift:307-310); a snap without one is stored every time, as before
        let at = snap?["at"]?.number
        if let at, savedAt[game] == at { return }
        var a = all()
        a[game] = v
        UserDefaults.standard.set(JSONValue.object(a).encodedString(), forKey: key)
        stored = a
        decoded[game] = nil   // the next load decodes the copy just stored
        if let at { savedAt[game] = at }
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
