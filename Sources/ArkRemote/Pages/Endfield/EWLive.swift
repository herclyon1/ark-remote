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

/// The row's name for the review list: the first row drawn for the path, else the path.
func ewLabel(_ groups: [EWGroupSpec], _ m: EWMaster, _ path: String) -> String {
    for g in groups {
        if let r = ewRows(g, m, values: m.values).first(where: { $0.path == path && $0.kind != .box }) { return r.label }
    }
    return path
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
        if let machine, machine == v { return (key, nil) }
        return (key, EWEdit(label: label, src: "master", owner: game, path: path, from: machine?.json, to: v.json))
    }

    /// The review text: one line per change.
    static func summary(_ edits: [String: EWEdit]) -> String {
        edits.values.sorted { $0.label < $1.label }
            .map { "\($0.label)：\(Pending.fmt($0.from)) → \(Pending.fmt($0.to))" }
            .joined(separator: "\n")
    }

    /// view.js #go: send each change; the sent ones leave 「待保存」, the failed ones stay. Returns the keys still unsent.
    static func send(_ edits: [String: EWEdit]) async -> [String: EWEdit] {
        let relay = Relay.shared
        var left = edits
        var sent = 0
        var failed: Error? = nil
        for (k, e) in edits.sorted(by: { $0.key < $1.key }) where e.src == "master" {
            let body: JSONValue = .object(["action": .string("set_master"), "confirmed": .bool(true), "game": .string(e.owner),
                                           "path": .string(e.path), "value": e.to])
            do {
                try await relay.send(body)
                sent += 1
                left[k] = nil
                Pending.shared.add(k, PendingEdit(label: e.label, src: "master", owner: e.owner, path: e.path,
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
        if let failed {
            relay.showToast(sent > 0
                ? "发出去 \(sent) 项，剩下 \(left.count) 项没发出去（\(Live.why(failed))）。没发出去的还在页面上，可以再按一次保存。"
                : "没发出去（\(Live.why(failed))）。改动还在页面上，可以再按一次保存。", ms: 6000)
        } else {
            relay.showToast("已寄出 \(sent) 项（机器开着就是马上，关着就是下次开机）")
        }
        // view.js:2455-2457: ask the machine once, 2 s later, for a state reported after the send. One request, no loop.
        if sent > 0 {
            let after = nowSec()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await Live.shared.ping(minAt: after)
            }
        }
        return left
    }
}

/// The edit bar and its review alert, shared by both tabs (view.js updateBar / #confirm).
struct EWSaveBar: ViewModifier {
    @Binding var edits: [String: EWEdit]
    @State var reviewing = false
    @State var saving = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if !edits.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("放弃") { edits = [:] }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存（\(edits.count)）") { reviewing = true }
                            .disabled(saving)
                    }
                }
            }
            .alert("保存修改？", isPresented: $reviewing) {
                Button("寄出") {
                    guard !saving else { return }   // 2026-09-01: three taps sent three times
                    saving = true
                    Task {
                        edits = await EWSave.send(edits)
                        saving = false
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(EWSave.summary(edits))
            }
            // the toast is one layer over all tabs now (Pages/Shell/ToastLayer.swift)
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
