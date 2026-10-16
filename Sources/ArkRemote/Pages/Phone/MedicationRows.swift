import SwiftUI

// The 用药 views at the top of the 手机 tab (owner 10-16 21:2x: the 手机 tab's first page, where it is most visible), after Health's Medications (Health › Browse › Medications): a section of scheduled
// medicines and one of as-needed medicines, each medicine a row that pushes its page, a Log action that opens a sheet
// whose time starts at now and can be moved back, and the logged doses listed on the medicine's page, deletable by swipe.
// The data and the texts are Logic/Medication.swift. Local only: these draw with no relay data at all.

/// The pages the 手机 tab pushes, as values on the tab's NavigationPath (ContentView.phonePath), so a reselect of the tab
/// can pop them (D39) and a cold launch can push the one that was open (ContentView.restoredPhonePath).
enum PhoneRoute: Hashable {
    /// A 用药 row → MedicationPage(med:), by the Medication's raw value (a String payload, as StatusRoute.monthCard's).
    case medication(String)
}

/// The UserDefaults key of the medicine page left open on the 手机 tab (its raw value; absent when none is open): the
/// owner 10-16 21:2x wants the App to reopen where he left it, and the tabs' NavigationPaths are not stored otherwise.
let phoneOpenMedicationKey = "ark-phone-open-med"

/// Redraws `content` with the time every 30 s while it is on screen, so 离上次 / X 小时前 follow the clock (at least once a
/// minute). iOS: the system's TimelineView schedule. Android: skip-ui's TimelineView is commented out
/// (Animation/Timeline.swift:3) and skip-fuse-ui has none, so a sleep loop bumps a counter, as StatusPage's tick.
struct MedicationClock<Content: View>: View {
    @ViewBuilder var content: (Date) -> Content

    /// Android only: bumped every 30 s.
    @State var tick = 0

    var body: some View {
        #if os(Android)
        let _ = tick
        content(Date()).task {
            let wait = 30.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                tick &+= 1
            }
        }
        #else
        TimelineView(.periodic(from: .now, by: 30)) { context in content(context.date) }
        #endif
    }
}

/// One medicine's group at the very top of the 手机 tab: the row (pushing MedicationPage) and 「记录服用」. Health puts
/// scheduled and as-needed medicines in groups of their own, so each medicine is its own Section (按时 / 按需).
struct MedicationSection: View {
    var med: Medication
    /// 「记录服用」: PhonePage presents MedicationLogSheet itself, outside its List's `.refreshable`, which a sheet presented
    /// from a row would inherit (PhonePage's comment at its `.refreshable`; 9668e7d).
    var log: (Medication) -> Void

    var body: some View {
        Section {
            // by value (PhoneRoute.medication; PhonePage's List builds the page), so a reselect of 手机 can pop it (D39)
            NavigationLink(value: PhoneRoute.medication(med.rawValue)) {
                MedicationClock { now in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(med.name).font(.headline)
                        MedicationSummary(med: med, now: now)
                    }
                }
            }
            Button("记录服用") { log(med) }
        } header: {
            Text(med.perDay == nil ? "用药 · 按需" : "用药 · 按时")
        }
    }
}

/// 离上次 …, loxoprofen's interval line, and the counts (today's and what is left); shared by the row and the page.
struct MedicationSummary: View {
    var med: Medication
    var now: Date

    var body: some View {
        let doses = MedicationStore.shared.doses
        VStack(alignment: .leading, spacing: 2) {
            Text(MedicationStore.sinceLine(doses, med, now: now)).tabularDigits()
            if let line = MedicationStore.intervalLine(doses, med, now: now) {
                Text(line).font(.subheadline).tabularDigits().foregroundStyle(waiting(doses) ? Color.orange : Color.secondary)
            }
            Text(MedicationStore.countLine(doses, med, now: now)).font(.footnote).tabularDigits().foregroundStyle(.secondary)
        }
    }

    /// Under 4 hours since the last loxoprofen.
    private func waiting(_ doses: [MedicationDose]) -> Bool {
        guard let e = MedicationStore.elapsed(doses, med, now: now) else { return false }
        if case .wait = MedicationStore.interval(elapsed: e) { return true }
        return false
    }
}

/// Health's Log sheet: the medicine's name, the time it was taken (date and time, starting at now, never past it),
/// Cancel / 记录. Opened fresh each time, so its time starts at the moment it opens.
struct MedicationLogSheet: View {
    var med: Medication
    var close: () -> Void

    @State var at = Date()
    /// The latest time the picker allows: now, read when the sheet opens.
    @State var latest = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(med.name).font(.headline)
                    // date and time: a dose remembered late can be moved back, never past now (Health's Log time row)
                    DatePicker("服用时间", selection: $at, in: latest.addingTimeInterval(-30 * 86400)...latest,
                               displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text(med.howTo)
                }
            }
            .navigationTitle("记录服用")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Cancel leading, the action trailing (HIG Sheets: "the Cancel button belongs on the leading edge of
                // the top toolbar. When present, the Done button belongs on the trailing edge"), as SaveBar's sheet
                ToolbarItem(placement: .cancellationAction) {
                    cancelButton.accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记录", role: .confirm) {
                        MedicationStore.shared.log(med, at: at)
                        close()
                    }
                }
            }
        }
    }

    /// The system ✕ (iOS 26 `Button(role: .cancel)`); Android: the same ✕ glyph as SaveBar's and the paste sheet's cancel.
    @ViewBuilder private var cancelButton: some View {
        #if os(Android)
        Button { close() } label: { Image(systemName: "xmark") }
        #else
        Button(role: .cancel) { close() }
        #endif
    }
}

/// A medicine's page (Health's medication detail): the summary, 「记录服用」, and every logged dose newest first with its
/// time and how long ago, each deletable by swipe (ForEach.onDelete; skip-fuse-ui Containers/ForEach.swift:168).
struct MedicationPage: View {
    var med: Medication

    @State var logging = false

    var body: some View {
        MedicationClock { now in page(now) }
            // remembered while open, so a cold launch pushes it again (ContentView.restoredPhonePath); ContentView drops
            // it when the 手机 tab's path goes back to its root
            .onAppear { UserDefaults.standard.set(med.rawValue, forKey: phoneOpenMedicationKey) }
    }

    private func page(_ now: Date) -> some View {
        let history = MedicationStore.history(MedicationStore.shared.doses, med)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.name).font(.headline)
                    MedicationSummary(med: med, now: now)
                }
            } footer: {
                Text(med.howTo)
            }
            Section {
                Button("记录服用") { logging = true }
            }
            Section {
                if history.isEmpty {
                    Text("还没记录").foregroundStyle(.secondary)
                } else {
                    ForEach(history.indices, id: \.self) { i in
                        LabeledContent {
                            Text(MedicationStore.agoText(history[i].at, now: now)).tabularDigits()
                        } label: {
                            Text(MedicationStore.timeText(history[i].at, now: now)).tabularDigits()
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets.sorted(by: >) where i < history.count {
                            MedicationStore.shared.remove(history[i])
                        }
                    }
                }
            } header: {
                Text("服用记录")
            } footer: {
                Text("记错了的话，向左滑删除。")
            }
        }
        // this page has no refresh action (PhonePage registers its navigationDestination outside its `.refreshable`)
        .sheet(isPresented: $logging) {
            MedicationLogSheet(med: med) { logging = false }
        }
        .navigationTitle(med.shortName)
        #if os(iOS)
        // a pushed page's title small and centred, as MonthCardPage
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
