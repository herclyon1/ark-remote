// Live data and saving for the 终末地 and 鸣潮 tabs: snap → page data, and sending the changes. Each change goes out as
// its own command (the web's #go handler, view.js:2402-2440) and is recorded in Pending (`pending[e._id] = {...}`).
// The 终末地 tab applies a change as soon as it is made (EWSave.apply), as Settings does: no 「待保存」 batch, no review.

import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported
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

/// Puts a change into the pool of changes not yet sent (nil drops it) where a JS object would: a key already there keeps its place in the
/// change order (`edits[id] = …` on an existing key), a new or re-added one goes last (view.js note / delete edits[id]).
@MainActor
func ewPutEdit(_ key: String, _ edit: EWEdit?) {
    guard var e = edit else { EWEdits.shared.items[key] = nil; return }
    if let old = EWEdits.shared.items[key] { e.at = old.at }
    EWEdits.shared.items[key] = e
}

/// The status under a row (pending.js:47-70, view.js:1268-1275): going out / did not go out, then the receipt.
struct EWRowTag: Equatable {
    var unsaved = false
    var text: String? = nil
    /// 「再发一次」 for this Pending key: under 「没生效」 and under the 10 h 「没回执 · 已寄出 HH:MM」 line (pending.js:59).
    var resendKey: String? = nil
    /// 「没生效」 (class "sent bad"): red. The 10 h line is class "sent": grey, though it has a button too.
    var bad = false
    /// sent and waiting (`.posted`, view.js:60).
    var posted = false
    /// The change is going out now (EWSave.apply / EWSave.resend): a spinner in the row.
    var sending = false
    /// Why the last send of this change did not go out (EWEdit.failure); the row offers 再发一次 / 不改了.
    var failure: String? = nil
    /// The pool key behind `failure`, for EWSave.retry / EWSave.drop.
    var retryKey: String? = nil
}

/// The tag for one Pending key; nil when the row has nothing under it.
@MainActor
func ewTag(_ key: String, edits: [String: EWEdit]) -> EWRowTag? {
    let edit = edits[key]
    let unsaved = edit != nil
    var t = EWRowTag(unsaved: unsaved)
    let q = EWSendQueue.shared
    t.sending = (edit != nil && edit?.failure == nil && q.queued.contains(key)) || q.resending.contains(key)
    if let f = edit?.failure { t.failure = f; t.retryKey = key }
    switch Pending.shared.tag(for: key, editing: unsaved) {
    case .sent(let text)?: t.text = text; t.resendKey = Pending.shared.staleResendKey(for: key); t.posted = true
    case .mismatch(let text, let k)?: t.text = text; t.resendKey = k; t.posted = true; t.bad = true
    case .applied(let text)?: t.text = text
    case nil: break
    }
    return t.unsaved || t.text != nil || t.sending ? t : nil
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

/// One change not yet sent (view.js `edits[id]`). src: "master", "relay" or "wb".
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
    /// Set by EWSave.apply's drain when this change did not go out: the row says why and offers 再发一次. A newer change
    /// of the same row replaces the edit, and with it this note.
    var failure: String? = nil
}

/// One entry of a review of several changes (view.js doSave :1612-1615; no page shows one now, EWSave.review): a shift skip in plain words (red, bold), or a change
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

    /// view.js #go: send each change. Returns the changes still unsent and, when something did not go out, a sentence
    /// saying so (the caller shows it where the change is; EWSave.apply puts it under the row).
    static func send(_ edits: [String: EWEdit]) async -> (left: [String: EWEdit], failure: String?) {
        // 审查 A5 / B11 / B15: a value the relay refuses (周本 outside 1–20, weeklyboss.py:219; a MaaEnd number its verify
        // rule rejects, mastercfg.py:465-482) or hands to AUTO-MAS unchecked (set_config checks nothing, commands.py:417-449)
        // is not sent; nothing in this call goes until it is fixed
        let bad = ordered(edits).compactMap { k -> String? in
            guard let e = edits[k], let why = problem(e) else { return nil }
            return "「\(e.label)」\(why)"
        }
        if !bad.isEmpty {
            return (edits, bad.count == 1 ? "没寄出：\(bad[0])。" : "有几项填得不对，一项都没寄出：\(bad.joined(separator: "；"))。")
        }
        let relay = Relay.shared
        #if !os(Android) && canImport(UIKit)
        // the orders go one after another: leaving the app mid-send must not suspend the rest (edge audit 15)
        let grace = BackgroundGrace("save")
        defer { grace.end() }
        #endif
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
            // a skip's day is the Beijing day it goes out on, as the review just said 「今天不跑」: stamped when the switch
            // was flipped, one flipped at 23:59 and saved at 00:01 carried yesterday and the relay refused it (edge audit 17,
            // 审查 B10)
            let body = Pending.skipDayNow(raw)
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
        // A failure is a sentence the caller shows where the change is (the 终末地 rows: under the row, with 再发一次); a
        // success needs no message: each row's own 「已寄出」 line says it (no toast, HIG Feedback).
        var failure: String? = nil
        if let failed {
            failure = sent > 0
                ? "发出去 \(sent) 项，剩下 \(left.count) 项没发出去（\(Live.why(failed))）。"
                : "没发出去（\(Live.why(failed))）。"
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

/// Where EWSave.apply's changes stand: which keys it queued, and which Pending entries are being sent again. Observed,
/// so a row's spinner comes and goes with them.
@MainActor @Observable final class EWSendQueue {
    static let shared = EWSendQueue()

    /// Pool keys handed to EWSave.apply. Only these are sent by its drain: the other tabs' changes in the same pool
    /// (EWEdits) keep their own way out.
    var queued: Set<String> = []
    /// Pending keys whose 再发一次 is out (EWSave.resend).
    var resending: Set<String> = []
    /// A drain is running; one at a time, so the orders go out one after another, in the order the changes were made.
    @ObservationIgnored var draining = false
    /// The key whose order is out now.
    @ObservationIgnored var current: String? = nil
}

extension EWSave {
    /// Applies one change now, as a Toggle / Picker in Settings does (decision 验收 10-07: native settings apply when
    /// changed). The change goes into the pool (so the row shows it at once, ewShown) and out through `send` as a one-item
    /// send; nil drops a queued or failed change of that row. A row changed again while its order is out waits and goes
    /// next with the newest value (the pool keeps one change per key); orders never overlap, so the machine ends on the
    /// last value.
    static func apply(_ key: String, _ edit: EWEdit?) {
        ewPutEdit(key, edit)
        if edit != nil { EWSendQueue.shared.queued.insert(key) }
        drain()
    }

    /// The change behind a row's 「没发出去」, sent again.
    static func retry(_ key: String) {
        guard EWEdits.shared.items[key]?.failure != nil else { return }
        EWEdits.shared.items[key]?.failure = nil
        EWSendQueue.shared.queued.insert(key)
        drain()
    }

    /// The change behind a row's 「没发出去」, dropped: the row goes back to the machine's value.
    static func drop(_ key: String) {
        guard EWEdits.shared.items[key]?.failure != nil else { return }
        EWEdits.shared.items[key] = nil
        EWSendQueue.shared.queued.remove(key)
    }

    /// Whether this key's order is out right now (EndfieldTab: a change back to the value being sent is no change).
    static func isSending(_ key: String) -> Bool { EWSendQueue.shared.current == key }

    /// 「再发一次」 of a sent change (Pending), with the row's spinner while it is out.
    static func resend(_ key: String) {
        let q = EWSendQueue.shared
        guard !q.resending.contains(key) else { return }
        q.resending.insert(key)
        Task {
            await Pending.shared.resend(key)
            q.resending.remove(key)
        }
    }

    /// Sends the queued changes one at a time, oldest first, until none is left that has not failed.
    private static func drain() {
        let q = EWSendQueue.shared
        guard !q.draining else { return }
        q.draining = true
        Task {
            while let k = nextQueued() {
                guard let e = EWEdits.shared.items[k] else { continue }
                q.current = k
                let r = await send([k: e])
                q.current = nil
                let pool = EWEdits.shared
                // Only a key that still holds the value sent is settled: a newer change made while this one was out stays
                // and goes next (the same rule as the batch send had, edge audit 1a).
                if pool.items[k]?.to == e.to && pool.items[k]?.body == e.body {
                    if r.left[k] == nil {
                        pool.items[k] = nil
                    } else {
                        pool.items[k]?.failure = r.failure ?? "没发出去。"
                    }
                }
                if pool.items[k] == nil { q.queued.remove(k) }
            }
            q.draining = false
        }
    }

    private static func nextQueued() -> String? {
        let q = EWSendQueue.shared
        let pool = EWEdits.shared.items
        q.queued = q.queued.filter { pool[$0] != nil }
        return ordered(pool).first { q.queued.contains($0) && pool[$0]?.failure == nil }
    }
}

/// Formerly the 「待保存」 bar (✕ / 「待保存 N 项」 / ✓ and its review sheet). Changes now apply as they are made
/// (EWSave.apply), so all that is left is the page title, which a pending count no longer replaces.
/// `title`: the page's title; nil leaves the title the page sets itself.
struct EWSaveBar: ViewModifier {
    var title: String? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
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
    /// The material's picture, 28 pt at the default text size, growing with Dynamic Type.
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
                empty(title: title, text: text, button: button, action: action)
            case .list(let sections, let footnote):
                ForEach(sections) { sec in
                    Section {
                        ForEach(sec.rows) { r in
                            LabeledContent {
                                if let v = r.value { Text(v) }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name)
                                        Text(r.subtitle + (r.origin ?? "")).font(.footnote).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    // stockpile.js:74, 98: the material's picture, fit; a picture that fails leaves the space empty
                                    AsyncImage(url: r.icon.flatMap { URL(string: $0) }) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: {
                                        Color.clear
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
        .navigationTitle(Stockpile.title)
        // pull to refresh is the page's one refresh (HIG Refresh content controls); no 刷新 button beside it
        .refreshable { await s.load(force: true) }
        .task { await s.open() }
    }

    /// No stock to show: the system empty state (ContentUnavailableView) with its one action.
    @ViewBuilder
    private func empty(title: String, text: String, button: String, action: StockpileEmptyAction) -> some View {
        #if os(Android)
        // skip-fuse-ui has no ContentUnavailableView, and skip-ui's init is fatalError() (System/ContentUnavailableView.swift:59)
        VStack(alignment: .leading, spacing: 6) {
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
        .listRowBackground(Color.clear)
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
