import SwiftUI
import CodexUsageCore

/// One quota window (e.g. "Weekly Limit") as shown in the popover. Shared by the Codex and
/// Gemini sections so both render identically.
struct UsageMeterRow: View {
    let title: String
    let usedPercent: Double
    let remainingPercent: Int
    let remainingFraction: Double
    let resetDate: Date?
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(Int(usedPercent.rounded()))% used")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(remainingPercent)%")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("remaining").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, remainingFraction)))
                .tint(remainingPercent <= 10 ? .orange : .accentColor)
                .accessibilityLabel("\(title) remaining usage")
                .accessibilityValue("\(remainingPercent) percent")

            if let weeklyCycle {
                WeeklyHistogramView(cycle: weeklyCycle)
            }

            if let resetDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(Self.remainingTime(until: resetDate, now: context.date), systemImage: "clock")
                        Text(resetDate, format: .dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US")))
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

    static func remainingTime(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset pending an update" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

/// Informational / warning card used for errors and empty states.
struct StatusCard: View {
    let title: String
    let detail: String
    let symbol: String
    var warning: Bool = false

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
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Updated 4:18:57 PM · Every minute" footer shown under each provider section.
struct UpdatedFooter: View {
    let date: Date
    let hasError: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(hasError ? "Last updated" : "Updated")
            Text(date, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                .monospacedDigit()
            Spacer(minLength: 4)
            Text(hasError ? "Retrying automatically" : "Every minute")
        }
        .lineLimit(1)
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}
