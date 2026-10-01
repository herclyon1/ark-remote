import SwiftUI

/// The 方舟 tab: the four sections the web remote shows for 明日方舟
/// (maa-automation/web/view.js:753 puts every section titled 明日方舟… on this tab).
/// Labels and hints are copied from web/schema.js:116-141 and view.js:519-523.
/// Plain SwiftUI controls only; Skip renders them as Android-native controls.
struct ArknightsPage: View {
    @Binding var data: ArknightsPageData

    var body: some View {
        Form {
            stageSection
            infrastSection
            awardSection
            weeklySection
        }
        .navigationTitle("方舟")
    }

    // MARK: 明日方舟 (schema.js:116-127)

    @ViewBuilder var stageSection: some View {
        Section {
            if data.stage != nil {
                ArknightsTextRow(label: "关卡",
                                 hint: "游戏内的关卡号。例如 1-7（常规）、CE-6（龙门币）、AT-4（活动关）",
                                 text: binding(\.stage, default: ""))
            }
            if data.medicineNumb != nil {
                ArknightsNumberRow(label: "理智药",
                                   hint: "一趟最多使用几瓶理智药。0＝不使用；999＝不限量",
                                   value: binding(\.medicineNumb, default: 0))
            }
            if data.ifFight != nil {
                ArknightsToggleRow(label: "作战开关",
                                   hint: "关掉后不刷关卡，只做基建、公招等日常",
                                   isOn: binding(\.ifFight, default: false))
            }
            if data.ifActivityFirst != nil {
                ArknightsToggleRow(label: "活动关优先",
                                   hint: "开着＝有活动就刷活动关，活动结束后自动回到上面那个固定关。开着时下面的序号才生效",
                                   isOn: binding(\.ifActivityFirst, default: false))
            }
            if data.activityStageIndex != nil {
                ArknightsNumberRow(label: "活动关序号",
                                   hint: "刷活动里的第几关，数的是活动关卡列表从上往下的位置，第一关填 1。只在上面那项开着时才有用",
                                   value: binding(\.activityStageIndex, default: 1))
            }
        } header: {
            Text("明日方舟")
        }
    }

    // MARK: 明日方舟 · 基建 (schema.js:128-131)

    @ViewBuilder var infrastSection: some View {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow()
            } else if data.usesOfDrones != nil {
                ArknightsPickerRow(label: "无人机用在哪",
                                   hint: "贸易站＝加速龙门币或合成玉订单，制造站＝加速对应产物",
                                   options: data.usesOfDronesOptions,
                                   selection: binding(\.usesOfDrones, default: ""))
            }
        } header: {
            Text("明日方舟 · 基建")
        }
    }

    // MARK: 明日方舟 · 领取奖励 (schema.js:132-141)

    @ViewBuilder var awardSection: some View {
        Section {
            if data.masterUnreadable {
                ArknightsWarningRow()
            } else {
                if data.awardMail != nil {
                    ArknightsToggleRow(label: "领取所有邮件奖励",
                                       hint: "开着＝每趟顺手把邮箱里的奖励全收了。关着邮件会一直躺着，到期作废",
                                       isOn: binding(\.awardMail, default: false))
                }
                if data.awardOrundum != nil {
                    ArknightsToggleRow(label: "领取幸运墙的每日合成玉",
                                       hint: "开着＝每天去幸运墙领那份合成玉",
                                       isOn: binding(\.awardOrundum, default: false))
                }
                if data.awardMining != nil {
                    ArknightsToggleRow(label: "领取限时开采许可的合成玉",
                                       hint: "开着＝有限时开采许可时每天领它的合成玉",
                                       isOn: binding(\.awardMining, default: false))
                }
                if data.awardSpecialAccess != nil {
                    ArknightsToggleRow(label: "领取周年赠送月卡",
                                       hint: "开着＝周年送的月卡每天的那份也领",
                                       isOn: binding(\.awardSpecialAccess, default: false))
                }
            }
        } header: {
            Text("明日方舟 · 领取奖励")
        }
    }

    // MARK: 明日方舟 · 周常 (view.js:519-523; shown only when MAA is in this shift)

    @ViewBuilder var weeklySection: some View {
        if let done = data.annihilationDoneThisWeek {
            Section {
                HStack {
                    ArknightsLabel(label: "剿灭", hint: "打满本周剿灭后自动停掉，下周一 04:00 自动恢复")
                    Spacer()
                    Text(done ? "本周已打满" : "本周还没打满")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("明日方舟 · 周常")
            }
        }
    }

    /// A binding to an optional field that the row only draws when the field is non-nil.
    private func binding<T>(_ keyPath: WritableKeyPath<ArknightsPageData, T?>, default fallback: T) -> Binding<T> {
        Binding(
            get: { data[keyPath: keyPath] ?? fallback },
            set: { data[keyPath: keyPath] = $0 }
        )
    }
}

/// Row title with the grey explanation under it, like the web's label + .hint.
struct ArknightsLabel: View {
    let label: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
            Text(verbatim: hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct ArknightsToggleRow: View {
    let label: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            ArknightsLabel(label: label, hint: hint)
        }
    }
}

struct ArknightsTextRow: View {
    let label: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArknightsLabel(label: label, hint: hint)
            TextField(label, text: $text)
        }
    }
}

/// Number entry as a text field, like the web's <input type="number"> (999 is a valid value, so no stepper).
struct ArknightsNumberRow: View {
    let label: String
    let hint: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArknightsLabel(label: label, hint: hint)
            numberField
        }
    }

    @ViewBuilder private var numberField: some View {
        let field = TextField(label, text: Binding(
            get: { String(value) },
            set: { value = Int($0.filter { $0.isNumber }) ?? 0 }
        ))
        #if os(macOS)
        field
        #else
        field.keyboardType(.numberPad)
        #endif
    }
}

struct ArknightsPickerRow: View {
    let label: String
    let hint: String
    let options: [ArknightsOption]
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            // The web shows 未设 when the machine reports no value (view.js:494).
            if selection.isEmpty {
                Text("未设").tag("")
            }
            ForEach(options) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        } label: {
            ArknightsLabel(label: label, hint: hint)
        }
    }
}

/// Shown instead of the rows when the master config can't be read (view.js:418).
struct ArknightsWarningRow: View {
    var body: some View {
        Label {
            Text("这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
