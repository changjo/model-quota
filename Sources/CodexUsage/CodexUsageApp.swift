import SwiftUI
import AppKit
import CodexUsageCore
import Darwin

@MainActor
enum AppState {
    static let store = UsageStore()
}

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppState.store

    var body: some Scene {
        MenuBarExtra {
            UsagePopover(store: store) { SettingsWindowController.shared.show(store: store) }
                .environment(\.locale, Locale(identifier: "en"))
        } label: {
            MenuBarGridView(items: store.menuBarItems)
                .accessibilityLabel(
                    store.menuBarItems.isEmpty
                        ? "Model Quota"
                        : "Model Quota. \(store.menuBarItems.map(\.accessibilityText).joined(separator: ", "))"
                )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.shared.show(store: store) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var transition: Task<Void, Never>?
    private var quitting = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(store: AppState.store)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIcon.image
        AppState.store.start()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(false) }
        })
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // terminateLater enters a nested AppKit loop. Leave the main dispatch
                // callback first so async cleanup can continue on the main actor.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signals.append(source)
        }
    }

    private func setSleeping(_ sleeping: Bool) {
        guard !quitting else { return }
        let previous = transition
        transition = Task {
            await previous?.value
            if sleeping { await AppState.store.stop() }
            else if !quitting { AppState.store.start() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        let previous = transition
        transition = Task {
            await previous?.value
            await AppState.store.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for source in signals { source.cancel() }
    }
}
