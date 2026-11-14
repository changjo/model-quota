import SwiftUI
import AppKit
import CodexUsageCore

enum SettingsTab: Hashable {
    case general, codex, gemini, claude
}

struct SettingsView: View {
    /// Shared with `SettingsWindowController` so the window and the SwiftUI frame agree.
    static let contentSize = CGSize(width: 520, height: 600)

    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginStore
    @State private var selection: SettingsTab
    @State private var path = ""
    @State private var agyPath = ""
    @State private var claudePath = ""
    @State private var validationFailed = false
    /// The last path each provider rejected; the warning shows only while the field still holds it.
    @State private var rejectedAgyPath: String?
    @State private var rejectedClaudePath: String?

    init(store: UsageStore, launchAtLogin: LaunchAtLoginStore, initialTab: SettingsTab = .general) {
        _store = ObservedObject(wrappedValue: store)
        _launchAtLogin = ObservedObject(wrappedValue: launchAtLogin)
        _selection = State(initialValue: initialTab)
    }

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAgyPath: String { agyPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedClaudePath: String { claudePath.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var versionDescription: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development build"
        }
        return "Version \(version)"
    }

    var body: some View {
        TabView(selection: $selection) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            codexTab
                .tabItem { Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(SettingsTab.codex)
            geminiTab
                .tabItem { Label("Gemini", systemImage: "sparkles") }
                .tag(SettingsTab.gemini)
            claudeTab
                .tabItem { Label("Claude", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(SettingsTab.claude)
        }
        .padding(.top, 8)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onChange(of: path) { _, _ in validationFailed = false }
        .onAppear {
            path = store.customPath
            agyPath = store.agyCustomPath
            claudePath = store.claudeCustomPath
            launchAtLogin.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
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
                            Button("Turn Off") { Task { await launchAtLogin.setEnabled(false) } }
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
            } footer: {
                Text("Automatically open Model Quota when you sign in to your Mac.")
            }

            Section {
                Picker("Limit Format", selection: $store.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Choose which limits each provider shows in the menu bar: both session and weekly, one of them, or only the most restrictive. Providers stack in up to 2 rows; more providers add a column.")
            }

            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: AppIcon.image)
                        .resizable().frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Quota").font(.headline)
                        Text(versionDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .formStyle(.grouped)
    }

    private var codexTab: some View {
        Form {
            providerSection(kind: .codex, isEnabled: $store.isCodexEnabled,
                            showInMenuBar: $store.showCodexInMenuBar, label: $store.codexLabel)
            statusSection(kind: .codex, name: store.codexName, isEnabled: store.isCodexEnabled,
                          isRefreshing: store.isRefreshing || store.isReconfiguring,
                          error: store.error, hasSnapshot: store.snapshot != nil,
                          lastUpdated: store.lastUpdated, refresh: store.refreshCodex)
            executableSection(
                path: $path, prompt: "Detect automatically", savedPath: store.customPath,
                accessibilityName: "Codex executable path", showsValidationError: validationFailed,
                resolvedPath: store.resolvedPath,
                footer: "Leave the path empty to detect Codex automatically. Sign in with codex login in Terminal.",
                isSelected: selection == .codex, choose: chooseCodexExecutable, apply: applyCodex
            )
        }
        .formStyle(.grouped)
        .disabled(store.isReconfiguring)
    }

    private var geminiTab: some View {
        Form {
            providerSection(kind: .gemini, isEnabled: $store.isGeminiEnabled,
                            showInMenuBar: $store.showGeminiInMenuBar, label: $store.geminiLabel)
            statusSection(kind: .gemini, name: store.geminiName, isEnabled: store.isGeminiEnabled,
                          isRefreshing: store.isGeminiRefreshing,
                          error: store.geminiError, hasSnapshot: store.geminiSnapshot != nil,
                          lastUpdated: store.geminiLastUpdated, refresh: store.refreshGemini)
            executableSection(
                path: $agyPath, prompt: "Detect automatically", savedPath: store.agyCustomPath,
                accessibilityName: "Gemini agy executable path",
                showsValidationError: rejectedAgyPath == trimmedAgyPath,
                resolvedPath: store.geminiResolvedPath,
                footer: "Uses your local Antigravity CLI session. No API keys or tokens are stored.",
                isSelected: selection == .gemini, choose: chooseAgyExecutable, apply: applyGemini
            )
        }
        .formStyle(.grouped)
    }

    private var claudeTab: some View {
        Form {
            providerSection(kind: .claude, isEnabled: $store.isClaudeEnabled,
                            showInMenuBar: $store.showClaudeInMenuBar, label: $store.claudeLabel)
            statusSection(kind: .claude, name: store.claudeName, isEnabled: store.isClaudeEnabled,
                          isRefreshing: store.isClaudeRefreshing,
                          error: store.claudeError, hasSnapshot: store.claudeSnapshot != nil,
                          lastUpdated: store.claudeLastUpdated, refresh: store.refreshClaude)
            executableSection(
                path: $claudePath, prompt: "Detect automatically", savedPath: store.claudeCustomPath,
                accessibilityName: "Claude executable path",
                showsValidationError: rejectedClaudePath == trimmedClaudePath,
                resolvedPath: store.claudeResolvedPath,
                footer: "Uses your local Claude CLI session via stream-json. No API keys or tokens are stored.",
                isSelected: selection == .claude, choose: chooseClaudeExecutable, apply: applyClaude
            )
        }
        .formStyle(.grouped)
    }

    // MARK: - Provider sections

    private func providerSection(kind: ProviderKind, isEnabled: Binding<Bool>,
                                 showInMenuBar: Binding<Bool>, label: Binding<String>) -> some View {
        Section("Provider") {
            Toggle(isOn: isEnabled) {
                Text("Enabled")
                Text("When off, \(kind.defaultName) is hidden and its usage is no longer checked.")
            }
            .toggleStyle(.switch)
            Toggle("Show in Menu Bar", isOn: showInMenuBar)
                .toggleStyle(.switch)
                .disabled(!isEnabled.wrappedValue)
            LabeledContent("Menu bar label") {
                TextField("Menu bar label", text: label, prompt: Text(kind.defaultName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
        }
    }

    private func statusSection(kind: ProviderKind, name: String, isEnabled: Bool, isRefreshing: Bool, error: UsageError?,
                               hasSnapshot: Bool, lastUpdated: Date?,
                               refresh: @escaping () -> Void) -> some View {
        Section("Status") {
            LabeledContent("Connection") {
                if !isEnabled {
                    Text("Off").foregroundStyle(.secondary)
                } else if isRefreshing {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…") }
                } else if let error {
                    Label(error.errorDescription(for: kind, name: name), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if hasSnapshot {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not checked yet").foregroundStyle(.secondary)
                }
            }
            if isEnabled, let error {
                Text(error.recoverySuggestion(for: kind, name: name)).font(.caption)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Last updated") {
                HStack(spacing: 10) {
                    Group {
                        if let lastUpdated {
                            Text(lastUpdated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                                .monospacedDigit()
                        } else {
                            Text("Never")
                        }
                    }
                    .foregroundStyle(.secondary)
                    Button("Refresh Now", action: refresh)
                        .disabled(!isEnabled || isRefreshing)
                }
            }
        }
    }

    private func executableSection(path: Binding<String>, prompt: String, savedPath: String,
                                   accessibilityName: String, showsValidationError: Bool,
                                   resolvedPath: String?, footer: String, isSelected: Bool,
                                   choose: @escaping () -> Void,
                                   apply: @escaping () -> Void) -> some View {
        let trimmed = path.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Executable path", text: path, prompt: Text(prompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(accessibilityName)
                        .onSubmit(apply)
                    Button("Choose…", action: choose)
                }
                if showsValidationError {
                    Label("Choose an existing executable file. Your previous setting is unchanged.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let resolvedPath {
                    Text("Using \(resolvedPath)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(resolvedPath)
                }
                Spacer(minLength: 8)
                Button("Use Automatic Detection") {
                    path.wrappedValue = ""
                    apply()
                }
                .disabled(savedPath.isEmpty && trimmed.isEmpty)
                Button("Apply", action: apply)
                    .keyboardShortcut(isSelected ? .defaultAction : nil)
                    .disabled(trimmed == savedPath)
            }
        } header: {
            Text("Executable")
        } footer: {
            Text(footer)
        }
    }

    // MARK: - Actions

    private func applyCodex() {
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

    private func applyGemini() {
        guard trimmedAgyPath != store.agyCustomPath else { return }
        let candidate = agyPath
        Task {
            await store.applyAgyCustomPath(candidate)
            // Keep a rejected path in the field so it can be corrected.
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            rejectedAgyPath = store.geminiConfigurationError == nil ? nil : trimmed
            if agyPath == candidate, store.geminiConfigurationError == nil { agyPath = store.agyCustomPath }
        }
    }

    private func applyClaude() {
        guard trimmedClaudePath != store.claudeCustomPath else { return }
        let candidate = claudePath
        Task {
            await store.applyClaudeCustomPath(candidate)
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            rejectedClaudePath = store.claudeConfigurationError == nil ? nil : trimmed
            if claudePath == candidate, store.claudeConfigurationError == nil { claudePath = store.claudeCustomPath }
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
        // Like Codex, choosing fills the field; Apply validates and saves it.
        if panel.runModal() == .OK, let url = panel.url { agyPath = url.path }
    }

    private func chooseClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Executable"
        panel.message = "Select your installed claude executable."
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = home.appendingPathComponent(".local/bin")
        if panel.runModal() == .OK, let url = panel.url { claudePath = url.path }
    }
}
