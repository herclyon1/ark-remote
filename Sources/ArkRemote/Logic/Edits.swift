// The page's unsaved changes, one pool for every tab (maa-automation/web/view.js:15 `let edits = {}`).
//
// On the web page 状态 / 方舟 / 终末地 / 鸣潮 are tabs of one page with one `edits` object: the top bar counts all of
// them (「待保存 N 项」, view.js:1551-1555), ✕ drops all of them (view.js:2950) and ✓ reviews and sends all of them in
// one go (doSave, view.js:1609; #go, view.js:2954). The tabs used to keep their own `@State edits`, so a change on one
// tab was neither counted nor sent from another. Keys are the web's `${src}|${owner}|${path}` (or `relay|…`,
// `wb|…`), so the tabs never collide. In memory only, like the web's `edits` (not in localStorage).

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class EWEdits {
    static let shared = EWEdits()

    /// key -> change waiting in 「待保存」.
    var items: [String: EWEdit] = [:]
    /// A send of this pool is out (EWSaveBar.go). One flag for every tab: a per-page @State let the ✓ of another tab send
    /// the same changes again while the first send was still going (edge audit 1b).
    var saving = false
}

// The changes themselves and their way out (moved from Pages/Endfield/EWLive.swift: one save flow for every tab).

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
            let verb = e.body?["action"]?.string == "skip_today" ? "今天不跑" : "今天跑"
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
        // view.js:3005-3012: a failure is an alert 「有改动没发出去」 with one 「好」 (EWSaveBar shows it). A full success has no
        // message of its own (the web's toast 「已寄出 N 项」): every sent change is in Pending now, so the line under the
        // tab titles reads 「N 项改动已寄出 · …」 and each row's own line 「已寄出 HH:MM」 (Pages/Shell/Feedback.swift)
        var failure: String? = nil
        if let failed {
            failure = sent > 0
                ? "发出去 \(sent) 项，剩下 \(left.count) 项没发出去（\(Live.why(failed))）。没发出去的还在页面上，可以再按一次保存。"
                : "一项都没发出去（\(Live.why(failed))）。改动还在页面上，可以再按一次保存。"
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
