import SwiftUI
import AppKit
import CodexUsageCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginStore
    @State private var path = ""
    @State private var validationFailed = false

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var versionDescription: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development build"
        }
        return "Version \(version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { value in Task { await launchAtLogin.setEnabled(value) } }
                    ))
                    .toggleStyle(.switch)
                    .disabled(launchAtLogin.isUpdating)
                    if launchAtLogin.isUpdating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Updating…").foregroundStyle(.secondary)
                        }
                    }
                    if launchAtLogin.needsApproval {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Approval required in System Settings", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                            HStack {
                                Button("Open System Settings…") { launchAtLogin.openSystemSettings() }
                                Spacer()
                                Button("Cancel Request") { Task { await launchAtLogin.setEnabled(false) } }
                            }
                        }
                        .disabled(launchAtLogin.isUpdating)
                    }
                    if let message = launchAtLogin.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if !launchAtLogin.needsApproval {
                            Button("Open System Settings…") { launchAtLogin.openSystemSettings() }
                        }
                    }
                } header: { Text("General") }
                footer: { Text("Automatically open Codex Usage when you sign in to your Mac.") }

                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: AppIcon.image)
                            .resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex Usage").font(.headline)
                            Text(versionDescription).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    LabeledContent("Status") {
                        if store.isRefreshing || store.isReconfiguring {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Connecting…") }
                        } else if let error = store.error {
                            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        } else if store.snapshot != nil {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not connected").foregroundStyle(.secondary)
                        }
                    }
                    if let error = store.error {
                        Text(error.recoverySuggestion ?? "").font(.caption)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Text("Refresh")
                        Spacer()
                        Text(store.error == nil ? "Every minute" : "Automatically").foregroundStyle(.secondary)
                        Button("Refresh Now") { store.refresh() }
                            .disabled(store.isRefreshing || store.isReconfiguring)
                    }
                    .accessibilityElement(children: .contain)
                    if let updated = store.lastUpdated {
                        LabeledContent("Last updated") {
                            Text(updated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Connection") }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Executable path").font(.subheadline)
                        HStack(spacing: 8) {
                            TextField("", text: $path, prompt: Text("Detect automatically"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Codex executable path")
                                .onSubmit { apply() }
                                .onChange(of: path) { _, _ in validationFailed = false }
                            Button("Choose…", action: chooseExecutable)
                        }
                        if validationFailed {
                            Label("Choose an existing executable file. Your previous setting is unchanged.", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let resolved = store.resolvedPath {
                        LabeledContent("Using") {
                            Text(resolved).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                                .help(resolved)
                        }
                    }
                } header: { Text("Codex CLI") }
                footer: {
                    Text("Leave the path empty to detect Codex automatically. Sign in with codex login in Terminal.")
                }
                .disabled(store.isReconfiguring)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Use Automatic Detection") { path = ""; apply() }
                    .disabled(store.customPath.isEmpty && path.isEmpty)
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPath == store.customPath)
            }
            .disabled(store.isReconfiguring)
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .onAppear { path = store.customPath; launchAtLogin.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    private func apply() {
        guard trimmedPath != store.customPath else { return }
        let candidate = path
        Task {
            await store.applyCustomPath(candidate)
            if path == candidate {
                validationFailed = store.configurationError != nil
                if !validationFailed { path = store.customPath }
            }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Executable"
        panel.message = "Select your installed codex executable."
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: store.resolvedPath ?? "/opt/homebrew/bin/codex").deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
