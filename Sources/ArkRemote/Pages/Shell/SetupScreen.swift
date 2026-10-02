import SwiftUI

/// 「第一次使用」: shown instead of the tabs until the mailbox and PIN are saved (web/view.js setupScreen).
/// Same words as the web page. The topic field takes no auto-capitalisation or auto-correction: the topic is
/// case-sensitive and iOS capitalising its first letter silently broke it (view.js note, simulator 2026-09-14).
struct SetupScreen: View {
    @State var topic = ""
    @State var pin = ""
    @State var missingShown = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("信箱名")
                        TextField("ark-…", text: $topic)
                            .setupPlainInput()
                    }
                    HStack {
                        Text("PIN")
                        TextField("4 位数字", text: $pin)
                            .setupNumberInput()
                    }
                    Button("开始使用") {
                        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let p = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty || p.isEmpty {
                            missingShown = true
                            return
                        }
                        // view.js: cfg = {topic, pin}; localStorage; boot(). ContentView switches to the tabs on the
                        // config appearing, and AppShell starts Live on that change (Logic/AppGlue.swift).
                        Relay.shared.saveConfig(topic: t, pin: p)
                    }
                } header: {
                    Text("第一次使用")
                } footer: {
                    Text("填一次就好，之后不再问。这两样只存在这台手机里。")
                }
            }
            .navigationTitle("第一次使用")
            .alert("两样都要填", isPresented: $missingShown) {
                Button("好", role: .cancel) {}
            }
        }
    }
}

extension View {
    /// No auto-capitalisation / correction (view.js: autocapitalize="none" autocorrect="off").
    func setupPlainInput() -> some View {
        #if os(Android) || os(iOS)
        return self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// The numeric keypad (view.js: inputmode="numeric").
    func setupNumberInput() -> some View {
        #if os(Android) || os(iOS)
        return self.keyboardType(.numberPad).autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}
