import Foundation
import SwiftUI
#if !os(Android) && !canImport(UIKit) && canImport(AppKit)
import AppKit
#endif

/// The 手机 tab wired to the stores: StaminaStore (the game tokens) and Relay (the mailbox config).
struct PhoneTab: View {
    var body: some View {
        let stamina = StaminaStore.shared
        // tokens is loaded in StaminaStore.init; reading it here makes the page redraw when it changes
        let status = stamina.tokens == nil ? "" : stamina.status()
        PhonePage(data: PhonePageData(pageVersion: PhoneLink.appVersion, staminaStatus: status),
                  actions: PhonePageActions(
                    pasteTokens: { s in
                        // A 免输入链接 (…#k=…&t=…) pasted here goes the way an opened link goes: on Android a tapped link
                        // opens the browser, not the app (no assetlinks.json), so pasting is the only way in once set up.
                        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if str.contains("#"), let u = URL(string: str), PhoneLink.open(u) {
                            Relay.shared.showToast("密钥已存到这台手机")
                            return
                        }
                        // view.js #tokpaste: fromPaste, then toast and a forced refresh
                        try stamina.fromPaste(s)
                        Relay.shared.showToast("密钥已存到这台手机")
                        Task { await stamina.refresh(force: true) }
                    },
                    clearTokens: { stamina.clear() },
                    copyNoInputLink: {
                        guard let link = PhoneLink.make() else { return .noConfig }
                        PhoneLink.copy(link)
                        // this phone's own link: nothing to take back from the clipboard on the next open
                        if let u = URL(string: link) { UserDefaults.standard.set(PhoneLink.linkHash(u), forKey: PhoneLink.takenKey) }
                        // read back: navigator.clipboard.writeText can reject, UIPasteboard just does nothing
                        return PhoneLink.pasted() == link ? .copied : .failed(link)
                    }))
    }
}

/// The no-input link (view.js myLink / fromLink).
enum PhoneLink {
    /// The web page the link opens (view.js uses location.origin + location.pathname of the page itself).
    static let pageURL = "https://herclyon1.github.io/maa/"

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? ""
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) (\(b))"
    }

    /// navigator.clipboard.writeText: UIPasteboard on Android (SkipUI maps it to the system clipboard) and iOS;
    /// NSPasteboard only for the macOS host build.
    static func copy(_ s: String) {
        #if os(Android) || canImport(UIKit)
        UIPasteboard.general.string = s
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }

    static func pasted() -> String? {
        #if os(Android) || canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    /// view.js enc(o): base64 of the UTF-8 JSON, URL-safe, no padding.
    static func enc(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// view.js myLink(): `#k=` the mailbox and PIN, `&t=` the stored game tokens when there are any.
    @MainActor static func make() -> String? {
        guard let cfg = Relay.shared.config else { return nil }
        let k = enc("{\"t\":\(jsonQuote(cfg.topic)),\"p\":\(jsonQuote(cfg.pin))}")
        let stamina = StaminaStore.shared
        let tok = stamina.tokens ?? stamina.loadTokens()
        return pageURL + "#k=" + k + (tok.map { "&t=" + enc($0.encodedString()) } ?? "")
    }

    /// The last link this phone took (its SHA-256, not the link: the link carries the PIN and the game tokens).
    static let takenKey = "ark-remote-link-taken"

    static func linkHash(_ url: URL) -> String {
        Hash.hex(Hash.sha256(Array(url.absoluteString.utf8)))
    }

    /// App back in front with a mailbox already set (AppGlue.enterForeground): a 免输入链接 copied since is taken the
    /// way SetupScreen takes it on 「第一次使用」 (the use the user set 10-02 20:47: copy the link, open the app). One
    /// clipboard read per foreground, no timer; the same link is taken once (takenKey); anything else on the
    /// clipboard is left alone.
    @MainActor static func takeClipboardLink() {
        guard Relay.shared.config != nil,
              let s = pasted()?.trimmingCharacters(in: .whitespacesAndNewlines), s.contains("#k="),
              let u = URL(string: s),
              UserDefaults.standard.string(forKey: takenKey) != linkHash(u) else { return }
        if open(u) { Relay.shared.showToast("已从剪贴板的链接更新密钥") }
    }

    /// An opened link (.onOpenURL): view.js fromLink() for `#k=` and Stamina.fromLink() for `&t=`.
    /// The web then wipes the hash from the address bar; an app has no address bar to wipe.
    /// True when the link carried something this phone took.
    @discardableResult
    @MainActor static func open(_ url: URL) -> Bool {
        var took = false
        if let frag = url.fragment, let re = try? Regex("[#&]?k=([A-Za-z0-9_-]+)"),
           let m = frag.firstMatch(of: re), m.output.count > 1, let sub = m.output[1].substring,
           let j = try? StaminaStore.decodeB64(String(sub)),
           let t = j["t"]?.string, !t.isEmpty, let p = j["p"].map({ $0.string ?? jsStr($0) }), !p.isEmpty {
            // the same mailbox and PIN: leave the config alone, so the page on screen is not redrawn from scratch
            let cur = Relay.shared.config
            if cur?.topic != t.trimmingCharacters(in: .whitespacesAndNewlines)
                || cur?.pin != p.trimmingCharacters(in: .whitespacesAndNewlines) {
                Relay.shared.saveConfig(topic: t, pin: p)
            }
            took = true
        }
        if StaminaStore.shared.fromLink(url) {
            took = true
            // fromLink replaces the stored tokens; view.js render() puts the machine's 森空岛 session back on its next
            // pass (Stamina.fromSnapshot(snap) on every render), so take it again from the state already here.
            if let snap = Relay.shared.snap { StaminaStore.shared.fromSnapshot(snap) }
        }
        if took {
            // taken from any way in (opened, pasted, clipboard on open): the clipboard check skips it after this
            UserDefaults.standard.set(linkHash(url), forKey: takenKey)
            Task { await StaminaStore.shared.refresh(force: true) }
        }
        return took
    }
}
