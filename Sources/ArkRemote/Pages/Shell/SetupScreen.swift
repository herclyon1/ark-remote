import SwiftUI

/// 「第一次使用」: shown instead of the tabs until the mailbox and PIN are saved (web/view.js setupScreen).
/// The topic field takes no auto-capitalisation or auto-correction: the topic is case-sensitive and iOS capitalising its
/// first letter silently broke it (view.js note, simulator 2026-09-14).
struct SetupScreen: View {
    enum Field: Hashable { case topic, pin }

    @State var topic = ""
    @State var pin = ""
    /// The last paste held no 免输入链接: said in the paste section's footer.
    @State var notALink = false
    @FocusState var focus: Field?

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPin: String { pin.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is wrong with what is typed, said under the fields as it is typed (HIG Text fields: "Validate fields when it
    /// makes sense"); nil = both are fine. Empty fields are not an error yet: the button stays disabled.
    /// A PIN still being typed is not short yet: that is said once the field is left.
    private var problem: String? { SetupScreen.problem(topic: trimmedTopic, pin: trimmedPin, pinTyping: focus == .pin) }
    private var ready: Bool {
        !trimmedTopic.isEmpty && !trimmedPin.isEmpty && SetupScreen.problem(topic: trimmedTopic, pin: trimmedPin) == nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("信箱名") {
                        TextField("信箱名", text: $topic, prompt: Text(verbatim: "ark-…"))
                            .setupPlainInput()
                            .focused($focus, equals: .topic)
                            .submitLabel(.next)
                            .onSubmit { focus = .pin }
                    }
                    LabeledContent("PIN") {
                        SecureField("PIN", text: $pin, prompt: Text("4 位数字"))
                            .setupNumberInput()
                            .focused($focus, equals: .pin)
                    }
                    // HIG Buttons: disabled until it can act, not an error after the tap
                    Button("开始使用") {
                        // case kept: ntfy topics are case-sensitive (Relay.saveConfig). ContentView switches to the tabs on
                        // the config appearing, and AppShell starts Live on that change (Logic/AppGlue.swift).
                        Relay.shared.saveConfig(topic: trimmedTopic, pin: trimmedPin)
                    }
                    .disabled(!ready)
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("填一次就好，之后不再问。这两样只存在这台手机里。")
                    }
                }
                // The web page is entered with the 免输入链接 (#k=…); on Android that link opens the browser, not the app
                // (no assetlinks.json on herclyon1.github.io), so the app takes the same link from the clipboard instead.
                Section {
                    paste
                } footer: {
                    Text(notALink ? "剪贴板里的不是免输入链接。在网页「手机」页复制免输入链接，再回来粘贴。"
                                  : "已在网页里用过免输入链接的，在网页「手机」页复制它，再回来粘贴。")
                }
            }
            #if os(Android)
            .topNotices()   // the update notice under the top bar (Logic/AppUpdate.swift); iOS never shows it
            #endif
            .keyboardDone($focus)   // 完成 over the number pad, and a drag of the list takes the keyboard down
            .navigationTitle("第一次使用")
            // a link already copied: take it on open, no tap needed
            .onAppear { Self.takeLinkOnOpen() }
        }
    }

    /// iOS: the system PasteButton, which reads the clipboard without the 「允许粘贴」 prompt (SwiftUI PasteButton: "A system
    /// button that reads items from the pasteboard and delivers it to a closure."). Android: skip-fuse-ui has no
    /// PasteButton (skip-ui System/Transferable.swift:475 fatalError), so a plain Button reads the clipboard.
    @ViewBuilder private var paste: some View {
        #if os(Android)
        Button("粘贴免输入链接") { notALink = !Self.takeLink() }
        #else
        PasteButton(payloadType: String.self) { strings in
            Task { @MainActor in notALink = !Self.take(strings.first ?? "") }
        }
        #endif
    }
}

extension SetupScreen {
    /// The mailbox is an ntfy topic: ntfy takes only `^[-_A-Za-z0-9]{1,64}$` (ntfy server/server.go:87 topicRegex), so
    /// anything else could never reach the machine. The PIN is the 4 digits the field's prompt asks for (「4 位数字」, the
    /// web page's placeholder, view.js setupScreen). An empty field is not reported (nothing typed yet).
    static func problem(topic: String, pin: String, pinTyping: Bool = false) -> String? {
        let topicChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if !topic.isEmpty && (topic.count > 64 || !topic.allSatisfy { topicChars.contains($0) }) {
            return "信箱名只能有英文字母、数字、- 和 _，最长 64 个。"
        }
        let digits = pin.allSatisfy { "0123456789".contains($0) }
        if !pin.isEmpty && (!digits || pin.count > 4 || (pin.count < 4 && !pinTyping)) {
            return "PIN 要 4 位数字。"
        }
        return nil
    }

    /// A 免输入链接 (…#k=…) → PhoneLink.open, the same path as an opened link. True when it took.
    @MainActor static func take(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains("#k="), let u = URL(string: s) else { return false }
        PhoneLink.open(u)
        return Relay.shared.config != nil
    }

    /// The link on the clipboard (Android's paste button, and the open-time check).
    @MainActor static func takeLink() -> Bool {
        take(PhoneLink.pasted() ?? "")
    }

    /// On open nobody has tapped anything yet: reading another app's clip there made iOS ask 「允许粘贴」 on the very first
    /// screen (edge audit 19). iOS reads it only when detectPatterns (no prompt) sees a probable link, as
    /// AppGlue.takeClipboardIfDue does; the paste button reads it on a tap.
    @MainActor static func takeLinkOnOpen() {
        #if !os(Android) && canImport(UIKit)
        let pb = UIPasteboard.general
        guard pb.hasStrings else { return }
        // @Sendable: UIKit calls this back on a background queue; written inside a @MainActor func the closure would
        // otherwise be inferred main-actor isolated, and Swift 6's runtime isolation check traps (SIGTRAP on open
        // whenever the clipboard holds text - 0.4.4 second test pass, iOS 27 simulator).
        pb.detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { @Sendable r in
            guard case .success(let found) = r, found.contains(\UIPasteboard.DetectedValues.probableWebURL) else { return }
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
