import SwiftUI
import SkipFuse

/// 诊断记录 switch, 运行自检 and the export, in the 这台手机 section (web: #diagsw, #selfcheck).
struct PhoneDiagRows: View {
    var appVersion: String

    @State var diagOn = DiagLog.shared.enabled
    @State var checking = false
    @State var results: [SelfCheckItem] = []

    var body: some View {
        // the count is observed so the share item below is rebuilt after each new event
        let count = DiagCounter.shared.count >= 0 ? DiagLog.shared.count : 0
        Toggle(isOn: Binding(get: { diagOn }, set: { v in
            diagOn = v
            DiagLog.shared.setEnabled(v)
            if v { DiagWatch.start() }
        })) {
            PhoneRowLabel(title: "诊断记录", hint: "开着时记下每次联网的结果、推送通道连上 / 断开、有网 / 没网的变化，可分享给我们")
        }
        .onAppear { if diagOn { DiagWatch.start() } }
        if diagOn {
            ShareLink(item: DiagLog.shared.exportJSON(appVersion: appVersion, selfCheck: results)) {
                Text("分享诊断记录（\(count) 条）")
            }
            Button("清空诊断记录", role: .destructive) { DiagLog.shared.clear() }
        }
        Button(checking ? "正在自检…" : "运行自检") {
            guard !checking else { return }
            checking = true
            Task {
                results = await SelfCheck.run()
                checking = false
            }
        }
        .disabled(checking)
        ForEach(results, id: \.name) { r in
            HStack {
                PhoneRowLabel(title: (r.ok ? "✓ " : "✗ ") + r.name, hint: r.detail)
                Spacer()
            }
            .foregroundStyle(r.ok ? Color.primary : Color.red)
        }
    }
}
