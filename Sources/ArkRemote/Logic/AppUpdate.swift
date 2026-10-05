// In-app update from GitHub Releases (Android only).
//
// The Android work lives in Kotlin (Android/app/src/main/kotlin/AppUpdater.kt): one GET of
// https://api.github.com/repos/herclyon1/ark-remote/releases/latest, the version compare against
// BuildConfig.VERSION_NAME, the APK download into the cache, and the PackageInstaller session.
// Kotlin reports back through the bridged ArkRemoteAppDelegate.onUpdate* methods (ArkRemoteApp.swift);
// Swift calls Kotlin through the two closures AndroidAppMain registers at startup (registerUpdater).
//
// When: AppGlue.enterForeground (scenePhase → .active, already deduped against .inactive flaps), so at most
// one request each time the app is opened. No timer, no polling. iOS never calls check, so no update notice shows
// there (the pending-receipt line under the same top bar, TopNotices below, shows on both).

import Foundation
import Observation
import SkipFuse
import SwiftUI

@MainActor @Observable final class AppUpdate {
    static let shared = AppUpdate()

    /// The Kotlin entry points, set once from AndroidAppMain.onCreate (a JNI thread, before any UI exists).
    struct Hooks {
        let check: () -> Void
        let install: () -> Void
    }
    nonisolated(unsafe) static var hooks: Hooks?

    enum Phase: Equatable {
        /// nothing newer, or the update went in
        case idle
        /// 「有新版本」 with 「以后」 / 「更新」
        case available
        /// 「安装未知应用」 is off for this app; 「去设置」 opens it (AppUpdater.install)
        case needsPermission
        case downloading
        /// the APK goes into the PackageInstaller session
        case installing
        /// the system's confirm sheet is up (STATUS_PENDING_USER_ACTION); 「继续安装」 brings it back from the kept file
        case confirming
        case failed
    }

    private(set) var phase: Phase = .idle
    /// The newer version found, without the leading "v".
    private(set) var version: String?
    /// 0...1 while downloading with a known size; nil when the size is unknown.
    private(set) var fraction: Double?
    private(set) var downloadedBytes = 0
    private(set) var totalBytes = 0
    private(set) var message: String?
    /// 「以后」 hides the banner until the next open.
    private(set) var dismissed = false

    private init() {}

    var showsBanner: Bool { version != nil && phase != .idle && !dismissed }

    /// scenePhase → .active. Skipped while a download or install is running.
    func checkOnOpen() {
        #if os(Android)
        guard phase != .downloading && phase != .installing else { return }
        dismissed = false
        Self.hooks?.check()
        #endif
    }

    /// 「更新」 / 「去设置」 / 「继续安装」 / 「重试」.
    func install() {
        #if os(Android)
        guard phase != .downloading && phase != .installing, version != nil else { return }
        message = nil
        Self.hooks?.install()
        #endif
    }

    func dismiss() { dismissed = true }

    // MARK: from Kotlin

    /// One check's answer. A banner left from the last open (a failure, the permission note) starts over as
    /// 「有新版本」, or as the permission note while 「安装未知应用」 is still off; a running step keeps its state.
    func found(version: String, canInstall: Bool) {
        self.version = version
        switch phase {
        case .idle, .available, .needsPermission, .failed:
            phase = canInstall || phase != .needsPermission ? .available : .needsPermission
            message = nil
            fraction = nil
        case .downloading, .installing, .confirming:
            break
        }
    }

    func needsPermission() {
        phase = .needsPermission
        message = nil
    }

    func progress(done: Int, total: Int) {
        phase = .downloading
        message = nil
        downloadedBytes = done
        totalBytes = total
        fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    func installing(message: String) {
        phase = .installing
        self.message = message
    }

    func confirming() {
        phase = .confirming
        message = nil
    }

    /// The new version is in. The system normally stops this process first; if it did not, there is nothing left to show.
    func installed() {
        phase = .idle
        message = nil
    }

    func failed(message: String) {
        phase = .failed
        fraction = nil
        self.message = message
    }
}

/// The update notice (Android only: iOS updates come from the App Store; AppUpdate never checks there) and the
/// pending-receipt line (#pendbar, web/pending.js:76-88: on every platform, the web page shows it on every tab under
/// its top bar, index.html:929) go under the tab's top bar, above its content.
/// Android: where Material puts a banner ("Banners appear at the top of the screen, below a top app bar",
/// https://m2.material.io/components/banners). Placed above the whole TabView they doubled the status-bar inset:
/// SkipUI's top app bar adds the status bar's window insets whenever the top system bar is there (Navigation.swift
/// hasAbsoluteTopSystemBar → TopAppBarDefaults.windowInsets), so a strip of empty space opened under the banner.
/// iOS: a top safe-area inset with the bar material, so the list stays the scroll view the navigation bar tracks
/// (its large title still collapses) and scrolls under the line instead of through it.
extension View {
    func topNotices() -> some View { TopNotices(content: self) }
}

/// A view of its own so its body is what reads AppUpdate / Pending: the tab roots are built inside TabView's
/// content, which SkipUI composes outside ContentView's body, so a read there did not redraw on a change (the
/// banner stayed hidden after the check found 0.3.3, emulator 10-02 19:29).
struct TopNotices<Content: View>: View {
    let content: Content

    var body: some View {
        #if os(Android)
        VStack(spacing: 0) {
            if AppUpdate.shared.showsBanner { UpdateBanner() }
            if let bar = Pending.shared.bar { PendingBarView(bar: bar) }
            content
        }
        #else
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let bar = Pending.shared.bar {
                // ignoresSafeAreaEdges: [] — a ShapeStyle background spreads into the safe area by default
                // (background(_:ignoresSafeAreaEdges: .all)), so the material ran up over the navigation bar and blurred
                // out the large title on every tab while the line showed (test pass 1, 问题 2: i18 vs i26)
                PendingBarView(bar: bar).background(.bar, ignoresSafeAreaEdges: [])
            }
        }
        #endif
    }
}

#if os(Android)

/// The update notice: plain SwiftUI that SkipUI draws with Material 3 components — Text in the theme's type, a
/// LinearProgressIndicator for the download (determinate once the size is known: Play's flexible-update flow shows
/// "a download progress bar", https://developer.android.com/guide/playcore/in-app-updates/kotlin-java), a TextButton
/// and a FilledButton on their own row at the end (so a long message never squeezes them), and a divider under it.
/// No colours of its own: it sits on the screen's surface like the rest of the app.
struct UpdateBanner: View {
    let update = AppUpdate.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(update.phase == .failed ? Color.red : Color.secondary)
            }
            switch update.phase {
            case .downloading:
                if let f = update.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            case .installing:
                ProgressView().progressViewStyle(.linear)
            default:
                EmptyView()
            }
            if let action {
                HStack(spacing: 8) {
                    Spacer()
                    if update.phase != .confirming {
                        Button("以后") { update.dismiss() }
                    }
                    Button(action) { update.install() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    private var v: String { update.version ?? "" }

    private var title: String {
        switch update.phase {
        case .downloading: return "正在下载 \(v)"
        case .installing, .confirming: return "正在安装 \(v)"
        case .failed: return "没能更新到 \(v)"
        default: return "有新版本 \(v)"
        }
    }

    private var detail: String? {
        switch update.phase {
        case .available:
            return "下载后交给系统安装。"
        case .needsPermission:
            return "先在设置里打开本应用的「安装未知应用」，回来再点「更新」。"
        case .downloading:
            let done = megabytes(update.downloadedBytes)
            if let f = update.fraction {
                return "\(done) / \(megabytes(update.totalBytes)) MB · \(Int((f * 100).rounded(.down)))%"
            }
            return "\(done) MB"
        case .installing:
            return update.message
        case .confirming:
            return "在系统弹出的界面里点「安装」。关掉了的话，点「继续安装」再打开，不用重新下载。"
        case .failed:
            // AppUpdater keeps the file through every failure (cachedApk): a cut-off download resumes, a refused or
            // cancelled install reuses the whole file
            return update.message.map {
                $0 + ($0.hasPrefix("下载没完成") ? "。下好的部分留着，重试会接着下。" : "。安装包留着，重试不用重新下载。")
            }
        case .idle:
            return nil
        }
    }

    /// The filled button's label; nil while a step runs on its own.
    private var action: String? {
        switch update.phase {
        case .available: return "更新"
        case .needsPermission: return "去设置"
        case .confirming: return "继续安装"
        case .failed: return "重试"
        case .idle, .downloading, .installing: return nil
        }
    }

    private func megabytes(_ bytes: Int) -> String {
        let tenths = bytes * 10 / 1_048_576
        return "\(tenths / 10).\(tenths % 10)"
    }
}
#endif
