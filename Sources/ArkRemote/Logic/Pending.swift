// Ported from maa-automation/web/pending.js
//
// Changes sent to the machine that have no receipt yet. 2026-09-13, the user, on changing a setting while
// the machine was off: nothing showed it had worked, it felt like a silent failure. The 5-second notice
// vanished and render() wrote the machine's last reported (old) value back into the control, so the
// change looked like it bounced back. Every sent change is kept here (UserDefaults, survives restarts);
// the control shows the sent value with 「已寄出 HH:MM，等机器开机」 under its row; when the machine reports a
// state **newer than the send**, each item is checked: value matches = applied, struck off; mismatch =
// red 「机器上报的还是旧值，这项没生效」 with 「再发一次」.
//
// Third state (2026-09-18, the user wanted all three texts): a matched item shows 「已应用 HH:MM」 under
// its control for one day.
//
// Not ported: the DOM part of applyPending (writing values back into inputs, pick buttons, pills, boxes,
// appending the tag element, the #pendbar markup and its xmark icon). The page reads `shownValue(for:)`,
// `tag(for:editing:)` and `bar` instead and draws them.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

/// One sent change waiting for the machine's receipt (pending.js `pending[id]`).
/// src: "mas" (set_config script/path), "master" (set_master game/path), "relay" (the exact `body` sent) or "wb"
/// (鸣潮 周本 「打第几个」: the weekly_boss `body` as sent, view.js:2992-2997).
struct PendingEdit: Codable, Sendable, Equatable {
    var label: String
    var src: String
    /// set_config script or set_master game; empty for relay switches.
    var owner: String = ""
    var path: String = ""
    var from: JSONValue? = nil
    var to: JSONValue
    /// Seconds.
    var sentAt: Int
    var resentAt: Int? = nil
    /// The `at` of the state that still reported another value.
    var mismatchAt: Int? = nil
    /// That value was neither the one sent nor the one it replaced (`from`): changed after it, by another phone or the
    /// machine. Optional so a record stored before it still decodes.
    var elsewhere: Bool? = nil
    /// relay switches and 周本: the command body as sent, resent as is.
    var body: JSONValue? = nil
}

/// A change whose receipt matched (pending.js `acked[id]`): shown as 「已应用 HH:MM」 for a day.
struct AckedEdit: Codable, Sendable, Equatable {
    var at: Int
    var label: String
}

/// The small line under a control (where Messages puts 「Delivered」).
enum PendingTag: Sendable, Equatable {
    /// 「已寄出 HH:MM · 机器开机后生效」, or past 10 h 「没回执 · 已寄出 HH:MM」 (class "sent"; that one also gets
    /// 「再发一次」: `Pending.staleResendKey(for:)`).
    case sent(text: String)
    /// 「没生效 · 机器 HH:MM 报的还是「…」」 plus a 「再发一次」 button for `key` (class "sent bad").
    case mismatch(text: String, key: String)
    /// 「已应用 HH:MM」 (class "sent ok").
    case applied(text: String)
}

/// The #pendbar line: text, whether any item was refused (the red xmark), and the 「不等了，清掉」 button.
struct PendingBar: Sendable, Equatable {
    let text: String
    let hasMismatch: Bool
    static let clearLabel = "不等了，清掉"
}

@MainActor @Observable final class Pending {
    static let shared = Pending()

    static let pendingKey = "ark-remote-pending"
    static let ackedKey = "ark-remote-acked"

    /// id -> sent change.
    var items: [String: PendingEdit] = [:]
    /// id -> applied change (one day).
    var acked: [String: AckedEdit] = [:]
    /// The value of every field on the machine at the last render: id -> value. The page's render sets it,
    /// then calls `reconcile()`.
    var liveVals: [String: JSONValue] = [:]

    @ObservationIgnored let relay: Relay
    /// Keys whose 「再发一次」 is out: a second tap meanwhile sent a 周本 / skip twice (edge audit 16).
    @ObservationIgnored private var resending: Set<String> = []

    init(relay: Relay = .shared) {
        self.relay = relay
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.pendingKey), let data = raw.data(using: .utf8),
           let v = try? JSONDecoder().decode([String: PendingEdit].self, from: data) {
            items = v
        }
        if let raw = d.string(forKey: Self.ackedKey), let data = raw.data(using: .utf8),
           let v = try? JSONDecoder().decode([String: AckedEdit].self, from: data) {
            acked = v
        }
    }

    func savePending() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.pendingKey)
        }
    }

    func saveAcked() {
        if let data = try? JSONEncoder().encode(acked) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.ackedKey)
        }
    }

    /// Records a change that was just sent (the save flow in view.js writes `pending[id] = {...}`).
    func add(_ key: String, _ edit: PendingEdit) {
        items[key] = edit
        savePending()
    }

    /// pending.js sameVal(a, b): a multi-input object compares only the boxes that were sent;
    /// arrays compare as sorted string lists; anything else as JS `String(x ?? "")`.
    nonisolated static func sameVal(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        func str(_ x: JSONValue?) -> String {
            guard let x, !x.isNull else { return "" }
            return x.jsString
        }
        func list(_ x: JSONValue?) -> [String] {
            guard let x, !x.isNull else { return [] }
            if let arr = x.array { return arr.map { $0.jsString } }
            return [x.jsString]
        }
        if let bo = b?.object {
            let ao = a?.object ?? [:]
            return bo.allSatisfy { k, x in str(ao[k]) == str(x) }
        }
        if a?.array != nil || b?.array != nil {
            return list(a).sorted() == list(b).sorted()
        }
        return str(a) == str(b)
    }

    /// `new Date(ts * 1000).toTimeString().slice(0, 5)`.
    nonisolated static func hhmm(_ ts: Int) -> String { clockHHMM(ms: Double(ts) * 1000) }

    // MARK: applyPending (state only)

    /// The value the control should show: the sent value while the change waits, unless the user is
    /// editing the field again (`key in edits`). nil = show the machine's value.
    func shownValue(for key: String, editing: Bool = false) -> JSONValue? {
        guard !editing, let p = items[key] else { return nil }
        return p.to
    }

    /// The tag under a row, or nil. `editing` = the field has an unsaved edit (view.js `key in edits`).
    func tag(for key: String, editing: Bool = false) -> PendingTag? {
        if let p = items[key] {
            if let mm = p.mismatchAt {
                // no 「再发一次」 here: a tap put this older change back over the newer one (edge audit 13)
                if p.elsewhere == true {
                    return .sent(text: "机器 \(Self.hhmm(mm)) 报的是「\(valueLabel(p, liveVals[key]))」，别处改过")
                }
                return .mismatch(text: "没生效 · 机器 \(Self.hhmm(mm)) 报的还是「\(valueLabel(p, liveVals[key]))」", key: key)
            }
            let at = p.resentAt ?? p.sentAt
            // pending.js:58-59: past 10 h the mailbox (12 h) may have dropped it; resent only by a tap, never automatically
            if Self.isStale(p) { return .sent(text: "没回执 · 已寄出 \(Self.hhmm(at))") }
            let fresh = relay.snapAt.map { relay.serverNowMs() / 1000 - Double($0) < Live.freshMs / 1000 } ?? false
            return .sent(text: "已寄出 \(Self.hhmm(at)) · \(fresh ? "几秒内回执" : "机器开机后生效")")
        }
        if editing { return nil }
        guard let a = acked[key], nowSec() - a.at <= 24 * 3600 else { return nil }
        return .applied(text: "已应用 \(Self.hhmm(a.at))")
    }

    /// pending.js:58: no receipt for more than 10 h since the last send (the resend when there is one).
    nonisolated static func isStale(_ p: PendingEdit) -> Bool {
        p.mismatchAt == nil && nowSec() - (p.resentAt ?? p.sentAt) > 10 * 3600
    }

    /// The key for the 「再发一次」 button under a 「没回执 · 已寄出 HH:MM」 line (pending.js:59 `data-again`), or nil.
    /// That line is a `.sent` tag (grey, class "sent", not "sent bad"), so the page asks for the button here.
    func staleResendKey(for key: String) -> String? {
        guard let p = items[key], Self.isStale(p) else { return nil }
        return key
    }

    /// Drops 「已应用」 marks older than a day (applyPending does it while painting).
    func pruneAcked() {
        let stale = acked.filter { nowSec() - $0.value.at > 24 * 3600 }.map { $0.key }
        guard !stale.isEmpty else { return }
        for k in stale { acked[k] = nil }
        saveAcked()
    }

    /// The #pendbar line; nil hides the bar.
    var bar: PendingBar? {
        let n = items.count
        guard n > 0 else { return nil }
        let bad = items.values.filter { $0.mismatchAt != nil }.count
        let text = bad > 0
            ? "\(bad) 项改动机器没接受（见红字）" + (n - bad > 0 ? "，另 \(n - bad) 项还在等回执" : "")
            : "\(n) 项改动已寄出 · 机器开机后生效"
        return PendingBar(text: text, hasMismatch: bad > 0)
    }

    /// 「不等了，清掉」.
    func clearAll() {
        items = [:]
        savePending()
    }

    // MARK: reconcile / resend

    /// The machine reported a state newer than the send: check each item against it.
    func reconcile() {
        guard let at = relay.snapAt, at != 0 else { return }
        var changed = false
        for (key, p) in items {
            // sentAt is this phone's clock, `at` the machine's: compare on ntfy's (Relay.clockSkewMs, edge audit 3)
            if Double(at) <= Double(p.resentAt ?? p.sentAt) + relay.clockSkewMs / 1000 { continue }
            guard let live = liveVals[key] else { continue }   // this state does not carry the field; wait for the next
            if Self.sameVal(live, p.to) {
                items[key] = nil
                changed = true
                acked[key] = AckedEdit(at: at, label: p.label)
                saveAcked()
                // pending.js:101: one line ≤ 13 at 28 pt (the native HUD never wraps); the value is on the row
                let t = "「\(p.label)」已生效"
                relay.showToast(t.count <= 13 ? t : "改动已生效")
            } else if p.mismatchAt != at {
                items[key]?.mismatchAt = at
                items[key]?.elsewhere = p.from.map { !Self.sameVal(live, $0) }
                changed = true
            }
        }
        if changed { savePending() }
    }

    /// 「再发一次」.
    func resend(_ key: String) async {
        guard let p = items[key], !resending.contains(key) else { return }
        // a skip carries its Beijing day and the relay refuses another day's (commands.py _skip_today): resent the next
        // day it could only be refused again, after 「又发了一次」 (edge audit 17)
        if p.body?["action"]?.string == "skip_today", let day = p.body?["day"]?.string, !day.isEmpty,
           day != statusBeijingToday() {
            items[key] = nil
            savePending()
            relay.showAlert("不再发", "这是 \(day) 那天的跳过，那天已经过了，机器不会再收。要跳过今天，重新关一次开关再保存。")
            return
        }
        resending.insert(key)
        defer { resending.remove(key) }
        let body: JSONValue
        if p.src == "relay" || p.src == "wb" {
            body = p.body ?? .null
        } else if p.src == "master" {
            body = .object(["action": .string("set_master"), "confirmed": .bool(true), "game": .string(p.owner),
                            "path": .string(p.path), "value": p.to])
        } else {
            body = .object(["action": .string("set_config"), "confirmed": .bool(true), "script": .string(p.owner),
                            "path": .string(p.path), "value": p.to])
        }
        do {
            try await relay.send(body)
            items[key]?.resentAt = nowSec()
            items[key]?.mismatchAt = nil
            items[key]?.elsewhere = nil
            savePending()
            relay.showToast("又发了一次")   // pending.js:117
        } catch {
            // pending.js:118: a reason is a sentence: alert, not the one-line HUD
            relay.showAlert("发不出去", Live.why(error))
        }
    }

    // No automatic resend (web 188a5339, 09-30, pending.js:121-124): the old resendStale re-sent every change without
    // a receipt after 10 h on each heartbeat / state, with nobody tapping; a skip / unskip / weekly-boss order is not
    // harmless twice, and a config value sent again can undo a newer change made elsewhere. Such a change now shows
    // 「没回执 · 已寄出 HH:MM」 with 「再发一次」 (tag / staleResendKey) and goes again only when tapped (resend).

    // MARK: value names (view.js valLabel / fmt)

    /// view.js fmt(v).
    nonisolated static func fmt(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "（空）" }
        if case .bool(let b) = v { return b ? "开" : "关" }
        return v.jsString
    }

    /// view.js valLabel(e, v): internal value → what a person reads, in the same order the dropdown is named:
    /// the machine's option list → valueZh → as is (2026-09-01: the confirm box showed a raw UUID).
    func valueLabel(_ e: PendingEdit, _ v: JSONValue?) -> String {
        // view.js:1584-1587: a queue row's switch is 「今天照常 / 今天跳过」, not on / off
        if e.src == "relay", let a = e.body?["action"]?.string, a == "skip_today" || a == "unskip_today" {
            return (v?.truthy ?? false) ? "今天照常" : "今天跳过"
        }
        if e.src == "relay" { return (v?.truthy ?? false) ? "开" : "关" }
        if e.src == "wb" {   // String(v ?? "")
            guard let v, !v.isNull else { return "" }
            return v.jsString
        }
        let snap = relay.snap
        let live: [(String, JSONValue)]
        if let fixed = choices[e.path] {
            live = fixed.map { ($0.label, $0.value) }
        } else {
            let opts = e.src == "master"
                ? snap?["master"]?[e.owner]?["options"]?[e.path]
                : snap?["options"]?[e.owner]?[e.path]
            live = (opts?.array ?? []).compactMap { pair in
                guard let lb = pair[0], let val = pair[1] else { return nil }
                return (lb.string ?? lb.jsString, val)
            }
        }
        func one(_ x: JSONValue) -> String {
            if let hit = live.first(where: { $0.1.jsString == x.jsString }) {
                return yieldLabel(e.path, hit.0, x)
            }
            return valueZh[e.path]?[x.jsString] ?? Self.fmt(x)
        }
        if let o = v?.object {   // multi-input: 格名 值, only the boxes in the edit
            let bx = snap?["master"]?[e.owner]?["inputs"]?[e.path]?.array ?? []
            let parts = o.keys.sorted().map { k -> String in
                let x = o[k] ?? .null
                let name = bx.first(where: { $0[1]?.string == k })?[0]?.string ?? k
                return "\(name) \(x.string == "" ? "（空）" : x.jsString)"
            }
            return parts.isEmpty ? "（没改）" : parts.joined(separator: "、")
        }
        if let arr = v?.array {
            return arr.isEmpty ? "（一个都没选）" : arr.map(one).joined(separator: "、")
        }
        return one(v ?? .null)
    }
}
