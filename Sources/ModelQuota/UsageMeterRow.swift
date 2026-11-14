import SwiftUI
import ModelQuotaCore

/// One quota window (e.g. "Weekly Limit") as shown in the popover. Shared by every provider
/// section so they all render identically.
struct UsageMeterRow: View {
    let title: String
    let remainingPercent: Int
    let remainingFraction: Double
    let resetDate: Date?
    var weeklyCycle: WeeklyUsageCycle? = nil
    /// Last known values shown while the provider is failing; dimmed so they don't read as fresh.
    var isStale: Bool = false
    var showsResetTime: Bool = true

    private var level: QuotaLevel { QuotaLevel(remainingPercent: remainingPercent) }
    /// Derived from the floored remaining value so the two numbers always add up to 100.
    private var usedPercent: Int { 100 - remainingPercent }

    private var tint: Color {
        switch level {
        case .normal: return .accentColor
        case .low: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(remainingPercent)%")
                            .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(level == .normal ? Color.primary : tint)
                        if level != .normal {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(tint)
                        }
                        Text("remaining").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .opacity(isStale ? 0.5 : 1)
                    ProgressView(value: min(1, max(0, remainingFraction)))
                        .tint(tint)
                        .opacity(isStale ? 0.5 : 1)
                    if showsResetTime {
                        Label(Self.resetDescription(until: resetDate, now: context.date), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription(now: context.date))
            }
            .help("\(usedPercent)% used")

            if let weeklyCycle {
                WeeklyHistogramView(cycle: weeklyCycle)
            }
        }
        .padding(14)
    }

    private func accessibilityDescription(now: Date) -> String {
        var parts = [title, "\(remainingPercent) percent remaining"]
        switch level {
        case .normal: break
        case .low: parts.append("low")
        case .critical: parts.append("critical")
        }
        parts.append("\(usedPercent) percent used")
        // VoiceOver reads only what is visible, so a hidden reset line is omitted here too.
        if showsResetTime {
            if let resetDate {
                let reset = Self.remainingTime(until: resetDate, now: now)
                parts.append(reset.prefix(1).lowercased() + reset.dropFirst())
            } else {
                parts.append("reset time unavailable")
            }
        }
        if isStale { parts.append("last known usage") }
        return parts.joined(separator: ", ")
    }

    /// One-line reset summary, e.g. "Resets in 2h 13m · Nov 14, 4:19 AM".
    static func resetDescription(until date: Date?, now: Date) -> String {
        guard let date else { return "Reset time unavailable" }
        guard date > now else { return remainingTime(until: date, now: now) }
        let locale = Locale(identifier: "en_US")
        let day = date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        return "\(remainingTime(until: date, now: now)) · \(day), \(time)"
    }

    static func remainingTime(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting soon" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

/// Provider name, icon, and the provider's own refresh spinner at the top of each section.
struct ProviderSectionHeader: View {
    let name: String
    let systemImage: String
    let isRefreshing: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing \(name) usage")
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Error card for a provider section; notes when the values below are the last known ones.
struct ProviderErrorCard: View {
    let error: UsageError
    let kind: ProviderKind
    let name: String
    let showsLastKnownUsage: Bool

    var body: some View {
        let detail = [error.recoverySuggestion(for: kind, name: name),
                      showsLastKnownUsage ? "Showing the last known usage." : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        StatusCard(title: error.errorDescription(for: kind, name: name), detail: detail,
                   symbol: "exclamationmark.triangle", warning: true)
    }
}

/// Informational / warning card used for errors and empty states.
struct StatusCard: View {
    let title: String
    let detail: String
    let symbol: String
    var warning: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Updated 4:18:57 PM" footer shown under each provider section.
struct UpdatedFooter: View {
    let date: Date
    let hasError: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("\(hasError ? "Last updated" : "Updated") \(date.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "en_US"))))")
                .monospacedDigit()
            Spacer(minLength: 4)
            if hasError {
                Label("Retrying automatically", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
        }
        .lineLimit(1)
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}
