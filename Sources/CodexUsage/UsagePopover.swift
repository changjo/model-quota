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
                    Text("Model Usage").font(.headline)
                    Text("Your available capacity").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing || store.isGeminiRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing usage")
                }
            }
            .padding(16)

            ScrollView { details }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack(spacing: 12) {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing || store.isGeminiRefreshing || store.isReconfiguring)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh usage (⌘R)")
                Spacer()
                Button(action: openSettings) { Label("Settings…", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open Settings (⌘,)")
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .help("Quit Codex Usage (⌘Q)")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
        .background(.regularMaterial)
    }

    private var details: some View {
        VStack(spacing: 16) {
            codexSection

            Divider().padding(.horizontal, 4)

            GeminiQuotaView(
                snapshot: store.geminiSnapshot,
                error: store.geminiError,
                label: store.geminiLabel,
                lastUpdated: store.geminiLastUpdated,
                isRefreshing: store.isGeminiRefreshing
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var codexSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(store.codexLabel, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing \(store.codexLabel) usage")
                }
            }
            .padding(.horizontal, 2)

            if let error = store.error {
                statusMessage(error.localizedDescription,
                              detail: (error.recoverySuggestion ?? "") +
                                (store.snapshot == nil ? "" : " Showing the last known usage."),
                              symbol: "exclamationmark.triangle", warning: true)
            }

            if let snapshot = store.snapshot {
                if !snapshot.quotas.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.quotas.enumerated()), id: \.element.id) { index, quota in
                            if index > 0 { Divider().padding(.horizontal, 14) }
                            QuotaView(
                                quota: quota,
                                weeklyCycle: quota.durationMinutes == 10080 ? store.weeklyTracker.currentCycle : nil
                            )
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    statusMessage("No usage limits available", detail: "\(store.codexLabel) hasn't reported a usage window for this account.", symbol: "chart.bar")
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
                statusMessage("Checking \(store.codexLabel) usage…", detail: "Connecting to your Codex CLI account.", symbol: "chart.bar")
            }

            if let updated = store.lastUpdated {
                HStack(spacing: 4) {
                    Text(store.error == nil ? "Updated" : "Last updated")
                    Text(updated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                        .monospacedDigit()
                    Spacer()
                    Text(store.error == nil ? "Every minute" : "Retrying automatically")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct QuotaView: View {
    let quota: Quota
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(quota.usedPercent.rounded()))% used")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(quota.remainingPercent)%")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("remaining").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: quota.remainingFraction)
                .tint(quota.remainingPercent <= 10 ? .orange : .accentColor)
                .accessibilityLabel("\(quota.title) remaining usage")
                .accessibilityValue("\(quota.remainingPercent) percent")

            if let weeklyCycle, quota.durationMinutes == 10080 {
                WeeklyHistogramView(cycle: weeklyCycle)
            }

            if let date = quota.resetDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(remainingTime(until: date, now: context.date), systemImage: "clock")
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US")))
                            .padding(.leading, 16).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Reset time unavailable", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func remainingTime(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset pending an update" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
