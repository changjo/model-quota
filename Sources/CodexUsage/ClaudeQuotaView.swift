import SwiftUI
import CodexUsageCore

struct ClaudeQuotaView: View {
    let snapshot: ClaudeUsageSnapshot?
    let error: UsageError?
    let name: String
    let lastUpdated: Date?
    let isRefreshing: Bool
    var weeklyCycle: WeeklyUsageCycle? = nil
    var showsResetTime: Bool = true
    var showsLastUpdated: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            ProviderSectionHeader(name: name, systemImage: "bubble.left.and.text.bubble.right", isRefreshing: isRefreshing)

            if let error {
                ProviderErrorCard(error: error, kind: .claude, name: name, showsLastKnownUsage: snapshot != nil)
            }

            if let snapshot {
                if snapshot.fiveHour != nil || snapshot.sevenDay != nil {
                    VStack(spacing: 0) {
                        if let fiveHour = snapshot.fiveHour {
                            UsageMeterRow(
                                title: "5-Hour Limit",
                                remainingPercent: fiveHour.remainingPercent,
                                remainingFraction: fiveHour.remainingFraction,
                                resetDate: fiveHour.resetsAt,
                                isStale: error != nil,
                                showsResetTime: showsResetTime
                            )
                        }

                        if snapshot.fiveHour != nil && snapshot.sevenDay != nil {
                            Divider().padding(.horizontal, 14)
                        }

                        if let sevenDay = snapshot.sevenDay {
                            UsageMeterRow(
                                title: "Weekly Limit",
                                remainingPercent: sevenDay.remainingPercent,
                                remainingFraction: sevenDay.remainingFraction,
                                resetDate: sevenDay.resetsAt,
                                weeklyCycle: weeklyCycle,
                                isStale: error != nil,
                                showsResetTime: showsResetTime
                            )
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))

                    if !snapshot.breakdownRows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model Breakdown")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)

                            VStack(spacing: 6) {
                                ForEach(snapshot.breakdownRows) { row in
                                    HStack {
                                        Text(row.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(String(format: "%.1f%%", row.percent))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                } else if !snapshot.rateLimitsAvailable {
                    StatusCard(
                        title: "Rate limits not available",
                        detail: "Claude Code CLI reports that rate limit tracking is unavailable for this account.",
                        symbol: "chart.bar"
                    )
                } else {
                    StatusCard(
                        title: "No usage limits available",
                        detail: "\(name) hasn't reported a usage window for this account.",
                        symbol: "chart.bar"
                    )
                }
            } else if error == nil {
                StatusCard(
                    title: "Checking \(name) usage…",
                    detail: "Reading usage from the claude CLI.",
                    symbol: "hourglass"
                )
            }

            if showsLastUpdated, let lastUpdated {
                UpdatedFooter(date: lastUpdated, hasError: error != nil)
            }
        }
    }
}
