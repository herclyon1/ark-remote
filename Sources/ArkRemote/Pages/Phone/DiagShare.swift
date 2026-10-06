// Left only so ArkRemoteApp.swift's bridge (registerSharer / onShareResult, ArkRemoteApp.swift:144-151) and
// Android/app/src/main/kotlin/ShareSheet.kt keep compiling. The 诊断记录 / 自检结果 share is a ShareLink now
// (PhoneDiagRows.swift): the system share sheet on iOS, skip-ui's ACTION_SEND chooser on Android
// (skip-ui Components/ShareLink.swift:123-138), and it reports no outcome — none is said (HIG Feedback). Nothing
// calls `androidShare` any more; remove this file with the registration in ArkRemoteApp.swift, ShareSheet.kt, its
// calls in Main.kt and ShareChosenReceiver in AndroidManifest.xml.

import Foundation
import SkipFuse

@MainActor enum DiagShare {
    /// Set once from AndroidAppMain.onCreate (ShareSheet.start → registerSharer); unused.
    nonisolated(unsafe) static var androidShare: ((String, String) -> Void)?

    /// ShareSheet.kt's chooser result (onShareResult); nothing is waiting for one.
    static func finish(state: Int, message: String) {}
}
