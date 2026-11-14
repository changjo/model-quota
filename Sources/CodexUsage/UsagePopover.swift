import SwiftUI
import CodexUsageCore

@MainActor
enum AppIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }()
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppIcon.image)
                    .resizable().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Quota").font(.headline)
                    Text("Your available capacity").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing || store.isGeminiRefreshing || store.isClaudeRefreshing {
                    // Each section announces its own refresh; this one is visual only.
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)

            ScrollView { details }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 470)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack(spacing: 12) {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing || store.isGeminiRefreshing || store.isClaudeRefreshing
                              || store.isReconfiguring || !anyProviderEnabled)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh usage (⌘R)")
                Spacer()
                Button(action: openSettings) { Label("Settings…", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open Settings (⌘,)")
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .help("Quit Model Quota (⌘Q)")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
        .background(.regularMaterial)
    }

    private var anyProviderEnabled: Bool {
        store.isCodexEnabled || store.isGeminiEnabled || store.isClaudeEnabled
    }

    private var details: some View {
        VStack(spacing: 16) {
            ForEach(Array(store.popoverProviders.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    Divider().padding(.horizontal, 4)
                }
                section(for: kind)
            }

            if !anyProviderEnabled {
                StatusCard(
                    title: "No providers enabled",
                    detail: "Turn on a provider in Settings.",
                    symbol: "gauge.with.dots.needle.33percent",
                    actionTitle: "Open Settings…",
                    action: openSettings
                )
            } else if store.allEnabledProvidersHiddenFromPopover {
                StatusCard(
                    title: "All providers hidden",
                    detail: "Turn on Show in Popover for a provider in Settings.",
                    symbol: "eye.slash",
                    actionTitle: "Open Settings…",
                    action: openSettings
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func section(for kind: ProviderKind) -> some View {
        switch kind {
        case .codex:
            codexSection
        case .gemini:
            GeminiQuotaView(
                snapshot: store.geminiSnapshot,
                error: store.geminiError,
                name: store.geminiName,
                lastUpdated: store.geminiLastUpdated,
                isRefreshing: store.isGeminiRefreshing,
                weeklyCycle: store.showDailyUsageInPopover ? store.geminiWeeklyTracker.currentCycle : nil,
                showsResetTime: store.showResetTimeInPopover,
                showsLastUpdated: store.showLastUpdatedInPopover
            )
        case .claude:
            ClaudeQuotaView(
                snapshot: store.claudeSnapshot,
                error: store.claudeError,
                name: store.claudeName,
                lastUpdated: store.claudeLastUpdated,
                isRefreshing: store.isClaudeRefreshing,
                weeklyCycle: store.showDailyUsageInPopover ? store.claudeWeeklyTracker.currentCycle : nil,
                showsResetTime: store.showResetTimeInPopover,
                showsLastUpdated: store.showLastUpdatedInPopover
            )
        }
    }

    private var codexSection: some View {
        VStack(spacing: 12) {
            ProviderSectionHeader(name: store.codexName, systemImage: "chevron.left.forwardslash.chevron.right",
                                  isRefreshing: store.isRefreshing)

            if let error = store.error {
                ProviderErrorCard(error: error, kind: .codex, name: store.codexName, showsLastKnownUsage: store.snapshot != nil)
            }

            if let snapshot = store.snapshot {
                if !snapshot.quotas.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.quotas.enumerated()), id: \.element.id) { index, quota in
                            if index > 0 { Divider().padding(.horizontal, 14) }
                            QuotaView(
                                quota: quota,
                                weeklyCycle: quota.durationMinutes == 10080 && store.showDailyUsageInPopover
                                    ? store.weeklyTracker.currentCycle : nil,
                                isStale: store.error != nil,
                                showsResetTime: store.showResetTimeInPopover
                            )
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    statusMessage("No usage limits available", detail: "\(store.codexName) hasn't reported a usage window for this account.", symbol: "chart.bar")
                }
                if snapshot.ordinaryUsageAllowed == false || snapshot.bucket?.spendControlReached == true {
                    statusMessage("Usage is restricted", detail: "Your account currently has a usage restriction.", symbol: "pause.circle", warning: true)
                }
                if snapshot.bucket?.credits != nil || snapshot.resetCredits != nil {
                    VStack(spacing: 10) {
                        if let credits = snapshot.bucket?.credits {
                            detailRow("Additional credits", value: credits.display)
                        }
                        if snapshot.bucket?.credits != nil && snapshot.resetCredits != nil { Divider() }
                        if let resets = snapshot.resetCredits {
                            detailRow("Available resets", value: "\(max(0, resets.availableCount))")
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
            } else if store.error == nil {
                statusMessage("Checking \(store.codexName) usage…", detail: "Reading usage from the codex CLI.", symbol: "hourglass")
            }

            if store.showLastUpdatedInPopover, let updated = store.lastUpdated {
                UpdatedFooter(date: updated, hasError: store.error != nil)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func statusMessage(_ title: String, detail: String, symbol: String, warning: Bool = false) -> some View {
        StatusCard(title: title, detail: detail, symbol: symbol, warning: warning)
    }
}

private struct QuotaView: View {
    let quota: Quota
    var weeklyCycle: WeeklyUsageCycle? = nil
    var isStale: Bool = false
    var showsResetTime: Bool = true

    var body: some View {
        UsageMeterRow(
            title: quota.title,
            remainingPercent: quota.remainingPercent,
            remainingFraction: quota.remainingFraction,
            resetDate: quota.resetDate,
            weeklyCycle: quota.durationMinutes == 10080 ? weeklyCycle : nil,
            isStale: isStale,
            showsResetTime: showsResetTime
        )
    }
}
