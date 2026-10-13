import SwiftUI

// The 月卡 views of the 状态 page (web monthcard.js banner() / section() / pageHtml(); view.js:362 and :404 place them).
// The data and the sends are Logic/MonthCard.swift.

/// The tone of a 月卡 line (monthcard.js tone()): orange from 5 days left (.mc-soon, --ios-orange), red once lapsed
/// (.mc-bad, --bad), else the subtitle grey.
private func monthCardTone(_ e: MonthCardEntry?) -> Color {
    guard let e else { return .secondary }
    if e.expired { return .red }
    return e.left <= 5 ? .orange : .secondary
}

/// The card at the top of the 状态 page while a card has 0–5 days left (spec §4; monthcard.js banner(), drawn with view.js
/// notice(): caption, title, body). Nothing when no card is that close. Goes right after the 刷声骸 card (view.js:362).
struct MonthCardReminder: View {
    /// MonthCardStore.today(), passed in: 还剩 X 天 counts from it, and a view with no input that changes was not redrawn by
    /// the page's 30-s tick, so past midnight it kept yesterday's count (edge audit 22).
    var today: String

    var body: some View {
        let soon = MonthCardStore.shared.soon()
        // listSection, not `if`: a bare `if` leaves an empty grey section on Android (Pages/Shell/SkipFixes.swift)
        listSection("status-monthcard-soon", if: !soon.isEmpty) {
            Section("月卡快到期") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(soon.map { "\($0.game)还剩 \($0.entry.left) 天" }.joined(separator: "、"))
                    Text(soon.map { "\($0.game)最后一次领取是 \(MonthCardStore.md($0.entry.last))" }.joined(separator: "；")
                         + "。续费后点下面的月卡行登记")
                        .font(.footnote).foregroundStyle(.secondary)
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

/// The pushed page of one game (monthcard.js pageHtml() / open()): what is registered, 「登记充值」 with a stepper and
/// 「按游戏里的天数对准」 with the day count the game shows; each asks before it registers. The first group reads as a
/// Health Summary card (ios27-健康Summary-满数据-1.png): the game's own colour icon and name on top, the day count large
/// with its unit small and grey (「7,891 steps」), the last day under it; the asks are confirmationDialogs from their
/// buttons (reference P10).
struct MonthCardPage: View {
    var game: String

    /// 「充值了 N 次」, 1–12 (monthcard.js open(): n starts at 1, back to 1 after a registration).
    @State var count = 1
    @State var leftText = ""
    @FocusState var leftFocus: Bool
    @State var ask: MonthCardAsk? = nil

    var body: some View {
        let store = MonthCardStore.shared
        let e = store.entry(game)
        let _ = Live.shared.alive
        List {
            Section {
                if let e {
                    // the card: the game's tab icon (his 09-14 project colour icons, design rule 6) and name, then the day
                    // count large (orange from 5 days left, red once lapsed, else the primary colour) with 「还剩」 and
                    // 「天」 small and grey, 「最后一次领取 X月X日」 grey under it, the sync note last
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            decorativeImage(Self.icon[game] ?? "tab-arknights").resizable().scaledToFit()
                                .frame(width: iconSide, height: iconSide)
                            Text(game).font(.subheadline).bold()
                        }
                        dayCount(e)
                        Text("最后一次领取 \(MonthCardStore.md(e.last))").foregroundStyle(.secondary)
                        if e.local {
                            Text(MonthCardStore.syncNote).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没登记")
                        Text("买过月卡的话，用下面任一种登记一次").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                // one sentence (HIG Writing: "If you can use fewer words, do so.")
                Text("还剩 5 天起每天提醒一次。")
            }
            Section {
                // UIStepper row (monthcard.js .mc-step): minus off at 1, plus off at 12
                Stepper(value: $count, in: 1...MonthCardStore.maxAdd) {
                    Text("充值了 \(count) 次")
                }
                Button("登记") {
                    let n = count
                    let to = store.after(game, add: n)
                    ask = MonthCardAsk(title: "登记充值 \(n) 次？",
                                       message: "\(game)月卡加 \(MonthCardStore.days * n) 天，最后一次领取改到 \(MonthCardStore.md(to))。",
                                       ok: "登记", add: n, left: nil, last: to)
                }
                .modifier(MonthCardAsking(ask: $ask, kind: "add", confirm: register))
            } header: {
                Text("登记充值")
            } footer: {
                Text("买一次加 \(MonthCardStore.days) 天，接在最后一次领取后面。")
            }
            Section {
                // Health's Add Data row: the name on the left, the number field taking the rest, right-aligned
                HStack(spacing: 6) {
                    Text("游戏里显示还剩")
                    dayField
                    Text("天").foregroundStyle(.secondary)
                }
                Button("对准") { setLeft() }
                    .disabled(leftValue == nil)
                    .modifier(MonthCardAsking(ask: $ask, kind: "left", confirm: register))
            } header: {
                Text("按游戏里的天数对准")
            } footer: {
                // HIG Entering data: 对准 is grey until the field holds a day count; a wrong entry is said here (monthcard.js
                // #mcset said it in a toast)
                Text((leftText.isEmpty || leftValue != nil ? "" : "填 0–\(MonthCardStore.maxLeft) 的整数。")
                     + "照游戏里显示的「还剩 X 天」填。")
            }
        }
        .clearsFocusOnOutsideTap()
        .keyboardDone()
        .navigationTitle("\(game)月卡")
        #if os(iOS)
        // a pushed page's title small and centred, as Health's pushed pages (P8); iOS only: on Android the inline title
        // was the one he called uglier (10-07 21:10)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The tab icon of each game (ContentView tabIcon), as the card's category icon.
    private static let icon = ["明日方舟": "tab-arknights", "终末地": "tab-endfield", "鸣潮": "tab-wuwa"]
    @ScaledMetric(relativeTo: .subheadline) var iconSide: CGFloat = 20

    /// 「还剩 15 天」 as Health's card value: the number large and bold, the words around it small and grey; read as one
    /// element 「还剩 15 天」.
    @ViewBuilder private func dayCount(_ e: MonthCardEntry) -> some View {
        let tone = e.expired || e.left <= 5 ? monthCardTone(e) : Color.primary
        if e.expired {
            Text("已过期").font(.title).bold().foregroundStyle(tone)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("还剩").font(.subheadline).foregroundStyle(.secondary)
                Text("\(e.left)").font(.largeTitle).bold().foregroundStyle(tone)
                Text("天").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("还剩 \(e.left) 天")
        }
    }

    /// The yes of a registration: the rows show the new date and days at once (no toast; HIG Alerts "Avoid using an
    /// alert merely to provide information").
    private func register(_ a: MonthCardAsk) {
        let g = game
        Task {
            await MonthCardStore.shared.register(g, add: a.add, left: a.left, last: a.last)
        }
        if a.add != nil { count = 1 } else { leftText = ""; leftFocus = false }
    }

    /// index.html .row input.short with inputmode="numeric". The prompt shows the format (HIG Text fields: "Show a hint in
    /// a text field to help communicate its purpose"); the row's name already says what to enter, 「天」 follows it.
    @ViewBuilder private var dayField: some View {
        let field = TextField("天数", text: $leftText, prompt: Text("0–\(MonthCardStore.maxLeft)"))
            .focused($leftFocus)
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
        #if os(macOS)
        field
        #else
        field.keyboardType(.numberPad)
        #endif
    }

    /// monthcard.js #mcset: full-width digits count, 0–400 only; nil while the field holds anything else.
    private var leftValue: Int? {
        var s = ""
        for u in leftText.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if u.value >= 0xFF10 && u.value <= 0xFF19, let a = Unicode.Scalar(u.value - 0xFEE0) {
                s.unicodeScalars.append(a)
            } else {
                s.unicodeScalars.append(u)
            }
        }
        guard (1...3).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }), let x = Int(s), x <= MonthCardStore.maxLeft else {
            return nil
        }
        return x
    }

    private func setLeft() {
        guard let x = leftValue else { return }
        let to = MonthCardStore.plus(MonthCardStore.today(), x)
        ask = MonthCardAsk(title: "对准为还剩 \(x) 天？", message: "\(game)月卡最后一次领取改到 \(MonthCardStore.md(to))。",
                           ok: "对准", add: nil, left: x, last: to)
    }
}

/// The confirmation of 登记 (kind "add") or 对准 (kind "left"), drawn from its button (as StatusPage's `StatusAsking`).
struct MonthCardAsking: ViewModifier {
    @Binding var ask: MonthCardAsk?
    var kind: String
    var confirm: (MonthCardAsk) -> Void

    private func mine(_ a: MonthCardAsk?) -> Bool { (a?.add != nil ? "add" : a == nil ? "" : "left") == kind }

    /// The last question shown, so the title stays while the dialog animates away after `ask` went nil.
    @State var last: MonthCardAsk? = nil

    func body(content: Content) -> some View {
        let shown = mine(ask) ? ask : nil
        content
            .onChange(of: shown) { _, v in if let v { last = v } }
            .confirmationDialog((shown ?? last)?.title ?? "",
                                isPresented: Binding(get: { mine(ask) }, set: { if !$0, mine(ask) { ask = nil } }),
                                titleVisibility: .visible, presenting: shown ?? last) { a in
                Button(a.ok) { confirm(a) }
                Button("取消", role: .cancel) {}
            } message: { a in
                Text(a.message)
            }
    }
}

/// One confirm of the registration page (web ask(title, msg, okLabel)).
struct MonthCardAsk: Equatable {
    var title: String
    var message: String
    var ok: String
    var add: Int?
    var left: Int?
    var last: String
}
