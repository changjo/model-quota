import SwiftUI
import CodexUsageCore

struct GeminiQuotaView: View {
    let snapshot: GeminiUsageSnapshot?
    let error: UsageError?
    let name: String
    let lastUpdated: Date?
    let isRefreshing: Bool
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(spacing: 12) {
            ProviderSectionHeader(name: name, systemImage: "sparkles", isRefreshing: isRefreshing)

            if let error {
                ProviderErrorCard(error: error, kind: .gemini, name: name, showsLastKnownUsage: snapshot != nil)
            }

            if let snapshot {
                if snapshot.groups.isEmpty {
                    StatusCard(
                        title: "No usage limits available",
                        detail: "\(name) hasn't reported a usage window for this account.",
                        symbol: "chart.bar"
                    )
                } else {
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
                                            // The tracker records `weeklyBucket`, so only that row gets the histogram.
                                            weeklyCycle: bucket.id == snapshot.weeklyBucket?.id ? weeklyCycle : nil,
                                            isStale: error != nil
                                        )
                                    }
                                }
                                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            } else if error == nil {
                StatusCard(
                    title: "Checking \(name) usage…",
                    detail: "Reading usage from the agy CLI.",
                    symbol: "hourglass"
                )
            }

            if let lastUpdated {
                UpdatedFooter(date: lastUpdated, hasError: error != nil)
            }
        }
    }
}

private struct GeminiBucketRow: View {
    let bucket: GeminiUsageSnapshot.Bucket
    var weeklyCycle: WeeklyUsageCycle? = nil
    var isStale: Bool = false

    var body: some View {
        UsageMeterRow(
            title: bucket.title,
            remainingPercent: bucket.remainingPercent,
            remainingFraction: bucket.remainingFraction,
            resetDate: bucket.resetTime,
            weeklyCycle: weeklyCycle,
            isStale: isStale
        )
    }
}
