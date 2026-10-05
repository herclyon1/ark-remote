import SwiftUI

/// 「第一次使用」: shown instead of the tabs until the mailbox and PIN are saved (web/view.js setupScreen).
/// Same words as the web page. The topic field takes no auto-capitalisation or auto-correction: the topic is
/// case-sensitive and iOS capitalising its first letter silently broke it (view.js note, simulator 2026-09-14).
struct SetupScreen: View {
    @State var topic = ""
    @State var pin = ""
    @State var noLinkShown = false

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
                        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)   // case kept: ntfy topics are case-sensitive (Relay.saveConfig)
                        let p = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty || p.isEmpty {
                            Relay.shared.showToast("两样都要填")   // view.js:126 toast, not an alert
                            return
                        }
                        // view.js: cfg = {topic, pin}; localStorage; boot(). ContentView switches to the tabs on the
                        // config appearing, and AppShell starts Live on that change (Logic/AppGlue.swift).
                        Relay.shared.saveConfig(topic: t, pin: p)
                    }
                } footer: {
                    Text("填一次就好，之后不再问。这两样只存在这台手机里。")
                }
                // The web page is entered with the 免输入链接 (#k=…); on Android that link opens the browser, not the app
                // (no assetlinks.json on herclyon1.github.io), so the app takes the same link from the clipboard instead.
                Section {
                    Button("粘贴免输入链接") {
                        if !Self.takeLink() { noLinkShown = true }
                    }
                } footer: {
                    Text("用免输入链接进网页的：在网页「手机」页复制免输入链接（或从书签复制那条链接），回来点这里。")
                }
            }
            #if os(Android)
            .topNotices()   // the update notice under the top bar (Logic/AppUpdate.swift); iOS never shows it
            #endif
            .keyboardDone()
            .navigationTitle("第一次使用")
            .alert("剪贴板里没有免输入链接", isPresented: $noLinkShown) {
                Button("好") {}
            }
            // a link already copied: take it on open, no tap needed
            .onAppear { Self.takeLinkOnOpen() }
        }
        // view.js toast(): ContentView draws the toast layer over the tabs only, and this screen stands in for them
        .overlay { ToastLayer() }
    }
}

extension SetupScreen {
    /// A 免输入链接 (…#k=…) on the clipboard → PhoneLink.open, the same path as an opened link. True when it took.
    @MainActor static func takeLink() -> Bool {
        guard let s = PhoneLink.pasted()?.trimmingCharacters(in: .whitespacesAndNewlines), s.contains("#k="),
              let u = URL(string: s) else { return false }
        PhoneLink.open(u)
        return Relay.shared.config != nil
    }

    /// On open nobody has tapped anything yet: reading another app's clip there made iOS ask 「允许粘贴」 on the very first
    /// screen (edge audit 19). iOS reads it only when detectPatterns (no prompt) sees a probable link, as
    /// AppGlue.takeClipboardIfDue does; the 「粘贴免输入链接」 tap reads it directly.
    @MainActor static func takeLinkOnOpen() {
        #if !os(Android) && canImport(UIKit)
        let pb = UIPasteboard.general
        guard pb.hasStrings else { return }
        // @Sendable: UIKit calls this back on a background queue; written inside a @MainActor func the closure would
        // otherwise be inferred main-actor isolated, and Swift 6's runtime isolation check traps (SIGTRAP on open
        // whenever the clipboard holds text - 0.4.4 second test pass, iOS 27 simulator).
        pb.detectPatterns(for: [.probableWebURL]) { @Sendable r in
            guard case .success(let found) = r, found.contains(.probableWebURL) else { return }
            Task { @MainActor in _ = takeLink() }
        }
        #else
        _ = takeLink()
        #endif
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
