import SwiftUI
import AppKit
import CodexUsageCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginStore
    @State private var path = ""
    @State private var agyPath = ""
    @State private var validationFailed = false

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAgyPath: String { agyPath.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                    VStack(alignment: .leading, spacing: 14) {
                        // Codex Settings
                        HStack(alignment: .center, spacing: 12) {
                            Toggle("Show Codex in Menu Bar", isOn: $store.showCodexInMenuBar)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Codex").font(.headline)
                                Text("OpenAI Codex CLI").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Text("Label:").font(.caption).foregroundStyle(.secondary)
                                TextField("Codex", text: $store.codexLabel)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 85)
                            }
                        }

                        Divider()

                        // Gemini Settings
                        HStack(alignment: .center, spacing: 12) {
                            Toggle("Show Gemini in Menu Bar", isOn: $store.showGeminiInMenuBar)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gemini").font(.headline)
                                Text("Google Antigravity CLI (agy)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Text("Label:").font(.caption).foregroundStyle(.secondary)
                                TextField("Gemini", text: $store.geminiLabel)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 85)
                            }
                        }

                        Divider()

                        // Menu bar layout description
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Menu Bar Layout")
                                .font(.subheadline.weight(.medium))
                            Text("Up to 2 rows are displayed in the menu bar. If more than 2 providers are enabled, new columns are added automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Providers & Menu Bar")
                }

                Section {
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
                        Button("Refresh Now") { store.refreshCodex() }
                            .disabled(store.isRefreshing || store.isReconfiguring)
                    }
                    .accessibilityElement(children: .contain)
                    if let updated = store.lastUpdated {
                        LabeledContent("Last updated") {
                            Text(updated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Executable path").font(.subheadline)
                        HStack(spacing: 8) {
                            TextField("", text: $path, prompt: Text("Detect automatically"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Codex executable path")
                                .onSubmit { apply() }
                                .onChange(of: path) { _, _ in validationFailed = false }
                            Button("Choose…", action: chooseCodexExecutable)
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

                Section {
                    LabeledContent("Status") {
                        if store.isGeminiRefreshing {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Querying…") }
                        } else if let error = store.geminiError {
                            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        } else if store.geminiSnapshot != nil {
                            Label("Connected (agy)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Ready").foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Text("Refresh")
                        Spacer()
                        Text("Every minute").foregroundStyle(.secondary)
                        Button("Refresh Now") { store.refreshGemini() }
                            .disabled(store.isGeminiRefreshing)
                    }
                    .accessibilityElement(children: .contain)
                    if let updated = store.geminiLastUpdated {
                        LabeledContent("Last updated") {
                            Text(updated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Executable path").font(.subheadline)
                        HStack(spacing: 8) {
                            TextField("", text: $agyPath, prompt: Text("Detect automatically (/opt/homebrew/bin/agy)"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Gemini agy executable path")
                                .onSubmit { apply() }
                            Button("Choose…", action: chooseAgyExecutable)
                        }
                    }
                } header: { Text("Gemini CLI (agy)") }
                footer: {
                    Text("Uses your local Antigravity CLI session. No API keys or tokens are stored.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Use Automatic Detection") {
                    path = ""
                    agyPath = ""
                    apply()
                }
                .disabled(store.customPath.isEmpty && path.isEmpty && store.agyCustomPath.isEmpty && agyPath.isEmpty)
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPath == store.customPath && trimmedAgyPath == store.agyCustomPath)
            }
            .disabled(store.isReconfiguring)
            .padding(16)
        }
        .frame(width: 540, height: 600)
        .onAppear {
            path = store.customPath
            agyPath = store.agyCustomPath
            launchAtLogin.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    private func apply() {
        if trimmedPath != store.customPath {
            let candidate = path
            Task {
                await store.applyCustomPath(candidate)
                if path == candidate {
                    validationFailed = store.configurationError != nil
                    if !validationFailed { path = store.customPath }
                }
            }
        }
        if trimmedAgyPath != store.agyCustomPath {
            let candidate = agyPath
            Task {
                await store.applyAgyCustomPath(candidate)
                agyPath = store.agyCustomPath
            }
        }
    }

    private func chooseCodexExecutable() {
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

    private func chooseAgyExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose agy Executable"
        panel.message = "Select your installed agy executable."
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            agyPath = url.path
            apply()
        }
    }
}
