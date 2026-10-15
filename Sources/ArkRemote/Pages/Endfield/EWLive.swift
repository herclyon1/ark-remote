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

/// The 库存 page (stockpile.js): sections of materials, or a loading / empty state. Apple counterpart (app-page-references
/// P5 / N4): 健康 › 步数 › All Recorded Data, a plain system List of rows with the reading in the label colour.
struct EndfieldStockpilePage: View {
    /// ContentView's tab selection (same AppStorage key), for 「去手机页」.
    @AppStorage("tab") var tab = ContentTab.status
    @Environment(\.dismiss) var dismiss
    /// The material's picture, 28 pt at the default text size, growing with Dynamic Type (was a fixed 28 pt frame).
    @ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 28

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
                #if os(Android)
                empty(title: title, text: text, button: button, action: action)
                #else
                EmptyView()   // iOS: the empty state is the List's overlay (below), centred on the page
                #endif
            case .list(let sections, let footnote):
                // which six-star the numbers are for: the newest released one first, the announced one second, as the
                // table orders them; a segmented control as Health's D / W / M over its list (HIG Segmented controls: "closely
                // related choices that affect an object, state, or view"), on the page ground as the 状态 tab's 班次
                listSection("stock-pick", ifLet: s.top.flatMap { $0.choices.isEmpty ? nil : $0 }) { top in
                    Section {
                        Picker("按哪位干员算", selection: Binding(get: { top.selected },
                                                             set: { k in Task { await Stockpile.shared.pick(k) } })) {
                            ForEach(top.choices) { c in Text(c.title).tag(c.id) }
                        }
                        .pickerStyle(.segmented)
                        #if !os(Android)
                        // skip-ui: listRowInsets unavailable
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        #endif
                    } footer: {
                        if let c = top.caption { Text(c) }
                    }
                }
                // the shown one's essence advice, before the 40-odd material rows: three terms as plain label / value rows
                // (Settings › General › About), where it drops, and the one line on MaaEnd's 目标选择
                listSection("stock-essence", ifLet: s.top?.essence) { e in
                    Section {
                        ForEach(e.terms) { t in
                            LabeledContent(t.slot, value: t.name)
                        }
                        ForEach(e.points.map { [$0] } ?? [], id: \.self) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.pointsTitle)
                                Text(p).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(e.header)
                    } footer: {
                        if let f = e.footer { Text(f) }
                    }
                }
                ForEach(sections) { sec in
                    Section {
                        ForEach(sec.rows) { r in
                            LabeledContent {
                                // P5 (app-page-references): the reading in the label colour, as Health's numbers; a
                                // row short of one build (「差 N」) in the system orange
                                if let v = r.value { Text(v).foregroundStyle(r.short ? Color.orange : Color.primary) }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name)
                                        Text(r.subtitle + (r.origin ?? "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    // stockpile.js:74, 98: the material's picture, fit. One that is not there or does not
                                    // load is a grey system picture, not an empty space before the name (HIG Lists: "a
                                    // small image in the leading end of a row"; Health's rows line up with the header)
                                    AsyncImage(url: r.icon.flatMap { URL(string: $0) }) { phase in
                                        if let img = phase.image {
                                            img.resizable().scaledToFit()
                                        } else {
                                            missingPicture
                                        }
                                    }
                                    .frame(width: iconSize, height: iconSize)
                                    .accessibilityHidden(true)   // r.name beside names it (HIG VoiceOver: decorative)
                                }
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
        #if !os(Android)
        // the system empty state over the (empty) List, centred on the page, the way the ContentUnavailableView
        // documentation places it (`.overlay { if … { ContentUnavailableView.search } }`, 7b6a3f1); the List under it
        // keeps pull to refresh
        .overlay {
            if case .empty(let title, let text, let button, let action) = s.content {
                empty(title: title, text: text, button: button, action: action)
            }
        }
        #endif
        .navigationTitle(Stockpile.title)
        #if os(iOS)
        // a pushed page's title small and centred, as Health › All Recorded Data (P5); iOS only (MonthCardPage says why)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // refreshed by pulling down only, as every other page (BOARD/App-待他定项-从记录定-1014.md E4: the toolbar 刷新
        // was a duplicate found only here; the page loads itself on open, .task below, and his 09-02 10:29 asks for manual
        // refresh as a fallback); under the empty state too, whose own button stays
        .refreshable { await s.load(force: true) }
        .task { await s.open() }
    }

    /// The stand-in for a material picture that is not there.
    @ViewBuilder private var missingPicture: some View {
        #if os(Android)
        Color.clear   // skip-ui maps no picture symbol to a Material icon (Components/Image.swift table)
        #else
        Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary)
        #endif
    }

    /// No stock to show: the system empty state (ContentUnavailableView) with its one action.
    @ViewBuilder
    private func empty(title: String, text: String, button: String, action: StockpileEmptyAction) -> some View {
        #if os(Android)
        // skip-fuse-ui has no ContentUnavailableView and skip-ui's init is fatalError() (System/ContentUnavailableView.swift:59);
        // Skip maps no box symbol to a Material icon (Components/Image.swift symbol table), so the web page's box stays here
        VStack(alignment: .leading, spacing: 6) {
            EWStockBox()   // stockpile.js:146 the empty-state box
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary)
            emptyAction(button: button, action: action)
        }
        #else
        ContentUnavailableView {
            Label(title, systemImage: "shippingbox")
        } description: {
            Text(text)
        } actions: {
            emptyAction(button: button, action: action)
        }
        #endif
    }

    @ViewBuilder
    private func emptyAction(button: String, action: StockpileEmptyAction) -> some View {
        if action == .retry {
            Button(button) { Task { await Stockpile.shared.load(force: true) } }
        } else {
            // 「去手机页」: pop 库存 and select 手机 (accept-stockpile.js ⑨).
            Button(button) {
                dismiss()
                tab = .phone
            }
        }
    }
}

/// Android's empty-state box, traced from stockpile.js:146's SVG (viewBox 24, stroke 1.2, secondary label colour), 60 pt
/// at the default text size. iOS shows the system symbol shippingbox in ContentUnavailableView instead.
struct EWStockBox: View {
    @ScaledMetric(relativeTo: .largeTitle) var side: CGFloat = 60

    var body: some View {
        let k: CGFloat = side / 24.0
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
            .frame(width: side, height: side)
    }
}
