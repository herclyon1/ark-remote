// 分享 on the 诊断记录 / 自检结果 sheet with its outcome said, as the web's (view.js showDiagSheet share.onclick):
// handed over → toast 「已交给分享」, cancelled → toast 「分享已取消」, failed → 「分享没成」 with 「请用「复制」后粘到聊天里」.
// SwiftUI's ShareLink reports nothing back, so:
//   · iOS: UIActivityViewController, presented from the topmost presented controller (the sheet), whose
//     completionWithItemsHandler says completed / not completed / an error;
//   · Android: the system chooser (Android/app/src/main/kotlin/ShareSheet.kt). It reports only the app picked; a
//     dismissed chooser is inferred there (resumed with no pick), and whether the picked app sent anything is not
//     reported at all (ACTION_SEND has no result).

import Foundation
import Observation
import SkipFuse
import SwiftUI
#if !os(Android) && canImport(UIKit)
import UIKit
#endif

@MainActor @Observable final class DiagShare {
    static let shared = DiagShare()

    /// ShareSheet.kt's share(text, title), set once from AndroidAppMain.onCreate (registerSharer).
    nonisolated(unsafe) static var androidShare: ((String, String) -> Void)?

    /// 「分享没成」's message for the sheet's own alert (the page's alert sits under the sheet).
    var failNote: String?

    private var waiting = false

    private init() {}

    func share(_ text: String, title: String) {
        waiting = true
        #if os(Android)
        guard let s = Self.androidShare else { Self.finish(state: 2, message: "分享入口没装上"); return }
        s(text, title)
        #elseif canImport(UIKit)
        guard let top = Self.topController() else { Self.finish(state: 2, message: "没有可以弹出分享面板的界面"); return }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // @Sendable: the handler's block type carries no NS_SWIFT_UI_ACTOR (UIActivityViewController.h:24) and the docs
        // name no thread; written in this @MainActor class the closure would be inferred main-actor isolated, and Swift 6's
        // runtime check traps if UIKit calls it off the main queue (the detectPatterns crash, 0.4.4 second test pass)
        vc.completionWithItemsHandler = { @Sendable _, completed, _, error in
            let why = error.map { $0.localizedDescription }
            Task { @MainActor in DiagShare.finish(state: why != nil ? 2 : (completed ? 0 : 1), message: why ?? "") }
        }
        if let pop = vc.popoverPresentationController {   // iPad: a popover needs an anchor
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
        #else
        Self.finish(state: 2, message: "这台设备没有分享面板")
        #endif
    }

    /// The outcome: 0 = handed to an app (iOS: the activity completed), 1 = cancelled, 2 = failed (`message` says why).
    static func finish(state: Int, message: String) {
        let me = shared
        guard me.waiting else { return }
        me.waiting = false
        switch state {
        case 0: Relay.shared.showToast("已交给分享")
        case 1: Relay.shared.showToast("分享已取消")
        default:
            let why = message.isEmpty ? "" : "（\(message)）"
            me.failNote = "手机没给出分享面板\(why)；请用「复制」后粘到聊天里。"
        }
    }

    #if !os(Android) && canImport(UIKit)
    /// The key window's root, then down its presented controllers (the sheet the 分享 button is on).
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        var vc = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
    #endif
}
