import AppKit
import SwiftUI
import CodexUsageCore

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let launchAtLogin = LaunchAtLoginStore()

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(store: UsageStore) {
        launchAtLogin.refreshStatus()
        if window == nil {
            let content = SettingsView(store: store, launchAtLogin: launchAtLogin)
                .environment(\.locale, Locale(identifier: "en"))
            let controller = NSHostingController(rootView: content)
            let settingsWindow = NSWindow(contentViewController: controller)
            settingsWindow.title = "Model Quota Settings"
            settingsWindow.styleMask = [.titled, .closable]
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.setContentSize(NSSize(width: 520, height: 600))
            settingsWindow.center()
            window = settingsWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
