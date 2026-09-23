import SwiftUI
import CodexUsageCore

struct GeminiQuotaView: View {
    let snapshot: GeminiUsageSnapshot?
    let error: Error?
    let label: String
    let lastUpdated: Date?
    let isRefreshing: Bool
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(label, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing \(label) usage")
                }
            }
            .padding(.horizontal, 2)

            if let error = error {
                statusCard(
                    title: "\(label) Unavailable",
                    detail: error.localizedDescription,
                    symbol: "exclamationmark.triangle",
                    warning: true
                )
            } else if let snapshot = snapshot {
                VStack(spacing: 10) {
                    ForEach(snapshot.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if snapshot.groups.count > 1 {
                                Text(group.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 6)
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(group.buckets.enumerated()), id: \.element.id) { index, bucket in
                                    if index > 0 { Divider().padding(.horizontal, 14) }
                                    GeminiBucketRow(
                                        bucket: bucket,
                                        weeklyCycle: (bucket.id == "gemini-weekly" || (bucket.window == "weekly" && group.name.localizedCaseInsensitiveContains("Gemini"))) ? weeklyCycle : nil
                                    )
                                }
                            }
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                statusCard(
                    title: "Checking \(label) usage…",
                    detail: "Querying agy CLI for quota limits.",
                    symbol: "sparkles",
                    warning: false
                )
            }

            if let updated = lastUpdated {
                HStack(spacing: 4) {
                    Text(error == nil ? "Updated" : "Last updated")
                    Text(updated, format: .dateTime.hour().minute().second().locale(Locale(identifier: "en_US")))
                        .monospacedDigit()
                    Spacer()
                    Text(error == nil ? "Every minute" : "Retrying automatically")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }
        }
    }

    private func statusCard(title: String, detail: String, symbol: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
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

private struct GeminiBucketRow: View {
    let bucket: GeminiUsageSnapshot.Bucket
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(bucket.usedPercent.rounded()))% used")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(bucket.remainingPercent)%")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("remaining").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: bucket.remainingFraction)
                .tint(bucket.remainingPercent <= 10 ? .orange : .accentColor)
                .accessibilityLabel("\(bucket.name) remaining usage")
                .accessibilityValue("\(bucket.remainingPercent) percent")

            if let weeklyCycle, bucket.window == "weekly" || bucket.id.contains("weekly") {
                WeeklyHistogramView(cycle: weeklyCycle)
            }

            if let date = bucket.resetTime {
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
