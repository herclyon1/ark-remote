#if os(iOS)
import AppIntents
import ArkRemote

// 连点's two shortcuts, for the AssistiveTouch button (Settings › Accessibility › Touch › AssistiveTouch: Single-Tap /
// Double-Tap → a shortcut): they run without opening the App, so the game stays in front. The Mac does the tapping
// (Sources/ArkRemote/Pages/Phone/ClickerPage.swift says why).

struct ToggleClickerIntent: AppIntent {
    static let title: LocalizedStringResource = "连点开关"
    static let description = IntentDescription("开始或停止连点：电脑往这台手机屏幕上的框里连续点。")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await ClickerLink.send(["cmd": "toggle"])
        return .result(dialog: IntentDialog(stringLiteral: reply.summary))
    }
}

struct ClickerPictureIntent: AppIntent {
    static let title: LocalizedStringResource = "连点：记下这屏画面"
    static let description = IntentDescription("电脑截下这一屏，回到遥控 › 手机 › 连点 在上面框要点的地方。")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await ClickerLink.send(["cmd": "shot"], timeout: 20)
        return .result(dialog: IntentDialog(stringLiteral: reply.ok ? "记下了，回遥控里框区域" : (reply.why ?? "没记下")))
    }
}

struct ClickerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleClickerIntent(), phrases: ["用\(.applicationName)连点"],
                    shortTitle: "连点开关", systemImageName: "hand.tap")
        AppShortcut(intent: ClickerPictureIntent(), phrases: ["用\(.applicationName)记下连点画面"],
                    shortTitle: "记下连点画面", systemImageName: "camera.viewfinder")
    }
}
#endif
