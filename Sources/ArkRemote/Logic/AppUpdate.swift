// In-app update from GitHub Releases (Android only).
//
// The Android work lives in Kotlin (Android/app/src/main/kotlin/AppUpdater.kt): one GET of
// https://api.github.com/repos/herclyon1/ark-remote/releases/latest, the version compare against
// BuildConfig.VERSION_NAME, the APK download into the cache, and the PackageInstaller session.
// Kotlin reports back through the bridged ArkRemoteAppDelegate.onUpdate* methods (ArkRemoteApp.swift);
// Swift calls Kotlin through the two closures AndroidAppMain registers at startup (registerUpdater).
//
// When: AppGlue.enterForeground (scenePhase → .active, already deduped against .inactive flaps), so at most
// one request each time the app is opened. No timer, no polling. iOS never calls check, so nothing shows.

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
        case idle, available, downloading, installing, failed
    }

    private(set) var phase: Phase = .idle
    /// The newer version found, without the leading "v".
    private(set) var version: String?
    /// 0...1 while downloading with a known size; nil when the size is unknown.
    private(set) var fraction: Double?
    private(set) var downloadedBytes = 0
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

    /// 「更新」.
    func install() {
        #if os(Android)
        guard phase != .downloading && phase != .installing, version != nil else { return }
        message = nil
        Self.hooks?.install()
        #endif
    }

    func dismiss() { dismissed = true }

    // MARK: from Kotlin

    func found(version: String) {
        self.version = version
        if phase == .idle { phase = .available }
    }

    func progress(done: Int, total: Int) {
        phase = .downloading
        message = nil
        downloadedBytes = done
        fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    func installing(message: String) {
        phase = .installing
        self.message = message
    }

    func failed(message: String) {
        phase = .failed
        fraction = nil
        self.message = message
    }
}

/// The banner above the tabs: 「有新版本 0.x.y」 with 「更新」, then the download progress, then errors.
struct UpdateBanner: View {
    let update = AppUpdate.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .bold()
                if update.phase == .downloading {
                    if let f = update.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView()
                    }
                }
                if let m = update.message {
                    Text(m)
                        .font(.caption)
                        .foregroundStyle(update.phase == .failed ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            if update.phase == .available || update.phase == .failed {
                Button("以后") { update.dismiss() }
                    .buttonStyle(.borderless)
                Button("更新") { update.install() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.12))
    }

    private var title: String {
        let v = update.version ?? ""
        switch update.phase {
        case .downloading:
            if let f = update.fraction {
                return "正在下载 \(v) · \(Int((f * 100).rounded(.down)))%"
            }
            return "正在下载 \(v) · \(megabytes(update.downloadedBytes)) MB"
        case .installing:
            return "正在安装 \(v)"
        default:
            return "有新版本 \(v)"
        }
    }

    private func megabytes(_ bytes: Int) -> String {
        let tenths = bytes * 10 / 1_048_576
        return "\(tenths / 10).\(tenths % 10)"
    }
}
