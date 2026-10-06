import SwiftUI

// The 月卡 views of the 状态 page (web monthcard.js banner() / section() / pageHtml(); view.js:362 and :404 place them).
// The data and the sends are Logic/MonthCard.swift.

/// The tone of a 月卡 line (monthcard.js tone()): orange from 5 days left, red once lapsed, else secondary.
private func monthCardTone(_ e: MonthCardEntry?) -> Color {
    guard let e else { return .secondary }
    if e.expired { return .red }
    return e.left <= 5 ? .orange : .secondary
}

/// The section at the top of the 状态 page while a card has 0–5 days left (spec §4; monthcard.js banner()): one row per
/// card that opens its registration page (HIG Writing: "If you need to direct someone to a setting, provide a direct link
/// or button, rather than trying to describe its location."). Nothing when no card is that close.
struct MonthCardReminder: View {
    /// MonthCardStore.today(), passed in: 还剩 X 天 counts from it, and a view with no input that changes was not redrawn
    /// past midnight, so it kept yesterday's count (edge audit 22).
    var today: String

    var body: some View {
        let soon = MonthCardStore.shared.soon()
        // listSection, not `if`: a bare `if` leaves an empty grey section on Android (Pages/Shell/SkipFixes.swift)
        listSection("status-monthcard-soon", if: !soon.isEmpty) {
            Section("月卡快到期") {
                ForEach(soon.indices, id: \.self) { i in
                    NavigationLink(value: StatusRoute.monthCard(soon[i].game)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(soon[i].game)还剩 \(soon[i].entry.left) 天")
                            Text("最后一次领取 \(MonthCardStore.md(soon[i].entry.last))").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// The 状态 page's 月卡 group: one row per game pushing its registration page (monthcard.js section()). Goes right after
/// the 机器 section, before 明日安排 (view.js:404).
struct MonthCardRows: View {
    /// MonthCardStore.today(), passed in so the rows recount past midnight (MonthCardReminder.today).
    var today: String

    var body: some View {
        let store = MonthCardStore.shared
        let _ = Live.shared.alive   // the sync note follows the heartbeat verdict
        Section {
            ForEach(MonthCardStore.games, id: \.self) { g in
                let e = store.entry(g)
                // by value (StatusRoute.monthCard; StatusPage's List builds the page), so a reselect of 状态 can pop it (D39)
                NavigationLink(value: StatusRoute.monthCard(g)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g)
                        Text(MonthCardStore.line(e)).font(.footnote).foregroundStyle(monthCardTone(e))
                        if e?.local == true {
                            Text(MonthCardStore.syncNote).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    // monthcard.js section() runs on every render: drop the records the relay caught up with, resend the
                    // unsynced ones. Here: on show, on each newer state, on a change of the local records, and when the
                    // machine comes up. On the rows, not the Section: skip-ui's List finds its sections by type, so a
                    // modifier around the Section is not safe; the three rows share one run (resend() guards re-entry).
                    .task(id: syncKey) {
                        store.reconcile()
                        await store.resend()
                    }
                }
            }
        } header: {
            Text("月卡")
        }
    }

    private var syncKey: String {
        let r = MonthCardStore.shared.records
        return "\(Relay.shared.snapAt ?? 0)|\(r.count)|\(r.values.map { $0.sentAt }.reduce(0, +))|\(Live.shared.alive)"
    }
}

/// The pushed page of one game (monthcard.js pageHtml()): what is registered, 「登记充值」 with a stepper and 「按游戏里的
/// 天数对准」 with the day count the game shows. Each registers on its button, no confirm (HIG Alerts: "Avoid displaying
/// alerts for common, undoable actions"): the rows above show the new date at once, and either form corrects the other.
struct MonthCardPage: View {
    var game: String

    /// 「充值了 N 次」, 1–12 (monthcard.js open(): n starts at 1, back to 1 after a registration).
    @State var count = 1
    /// The day count typed (0–400, MonthCardStore.maxLeft); nil = empty or not a number.
    @State var left: Int? = nil
    @FocusState var leftFocus: Bool
    /// Bumped on each registration: the success haptic (HIG Playing haptics; .sensoryFeedback).
    @State var registered = 0

    private var leftOK: Bool { left.map { (0...MonthCardStore.maxLeft).contains($0) } ?? false }

    var body: some View {
        let store = MonthCardStore.shared
        let e = store.entry(game)
        let _ = Live.shared.alive
        List {
            Section {
                if let e {
                    LabeledContent("最后一次领取", value: MonthCardStore.md(e.last))
                    LabeledContent("还剩") {
                        Text(e.expired ? "已过期" : "\(e.left) 天").foregroundStyle(monthCardTone(e))
                    }
                    if e.local {
                        Text(MonthCardStore.syncNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("还没登记")
                }
            } footer: {
                Text("有效期内每天登录领一次；还剩 1 天＝明天登录那次是最后一次领取。还剩 5 天起每天提醒一次。")
            }
            Section {
                Stepper(value: $count, in: 1...MonthCardStore.maxAdd) {
                    Text("充值了 \(count) 次")
                }
                Button("登记") {
                    let n = count
                    let g = game
                    let to = store.after(g, add: n)
                    count = 1
                    registered += 1
                    Task { await MonthCardStore.shared.register(g, add: n, left: nil, last: to) }
                }
            } header: {
                Text("登记充值")
            } footer: {
                Text("付完钱在这里登记。买一次加 \(MonthCardStore.days) 天，接在最后一次领取日后面；已经过期的从登记当天算第 1 天。")
            }
            Section {
                LabeledContent("游戏里显示还剩") {
                    dayField
                }
                Button("对准") { setLeft() }
                    .disabled(!leftOK)
            } header: {
                Text("按游戏里的天数对准")
            } footer: {
                // the error next to the field, as it is typed (HIG Writing: "Show errors right next to the field")
                if let x = left, !leftOK {
                    Text("\(x) 天超出范围：填 0–\(MonthCardStore.maxLeft)。").foregroundStyle(.red)
                } else {
                    Text("第一次用或者日期对不上时，照游戏里显示的「还剩 X 天」填。")
                }
            }
        }
        // Android: a tap outside the field or back with the keyboard up ends the editing (Pages/Shell/SkipFixes.swift)
        .clearsFocusOnOutsideTap()
        .keyboardDone()
        .navigationTitle("\(game)月卡")
        .sensoryFeedback(.success, trigger: registered)
    }

    /// A number field (TextField(value:format:), skip-fuse-ui TextField.swift:64-79 parses with try? on Android).
    @ViewBuilder private var dayField: some View {
        let field = TextField("天数", value: $left, format: .number)
            .focused($leftFocus)
            .multilineTextAlignment(.trailing)
        #if os(macOS)
        field
        #else
        field.keyboardType(.numberPad)
        #endif
    }

    /// monthcard.js #mcset: the last claim day from the day count the game shows.
    private func setLeft() {
        guard let x = left, leftOK else { return }
        let g = game
        let to = MonthCardStore.plus(MonthCardStore.today(), x)
        left = nil
        leftFocus = false
        registered += 1
        Task { await MonthCardStore.shared.register(g, add: nil, left: x, last: to) }
    }
}
