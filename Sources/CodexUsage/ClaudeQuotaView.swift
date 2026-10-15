import SwiftUI
import CodexUsageCore

struct ClaudeQuotaView: View {
    let snapshot: ClaudeUsageSnapshot?
    let error: Error?
    let label: String
    let lastUpdated: Date?
    let isRefreshing: Bool
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(label, systemImage: "bubble.left.and.text.bubble.right")
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
                let errDesc = (error as? UsageError)?.errorDescription(for: label) ?? error.localizedDescription
                let suggestion = (error as? UsageError)?.recoverySuggestion(for: label) ?? (error as? LocalizedError)?.recoverySuggestion ?? ""
                let detail = suggestion.isEmpty
                    ? (snapshot == nil ? "" : "Showing the last known usage.")
                    : suggestion + (snapshot == nil ? "" : " Showing the last known usage.")
                StatusCard(
                    title: errDesc,
                    detail: detail,
                    symbol: "exclamationmark.triangle",
                    warning: true
                )
            }

            if let snapshot = snapshot {
                if snapshot.fiveHour != nil || snapshot.sevenDay != nil {
                    VStack(spacing: 0) {
                        if let fiveHour = snapshot.fiveHour {
                            UsageMeterRow(
                                title: "Current Session (5h)",
                                usedPercent: fiveHour.usedPercent,
                                remainingPercent: fiveHour.remainingPercent,
                                remainingFraction: fiveHour.remainingFraction,
                                resetDate: fiveHour.resetsAt,
                                weeklyCycle: nil
                            )
                        }

                        if snapshot.fiveHour != nil && snapshot.sevenDay != nil {
                            Divider().padding(.horizontal, 14)
                        }

                        if let sevenDay = snapshot.sevenDay {
                            UsageMeterRow(
                                title: "Weekly Limit (7d)",
                                usedPercent: sevenDay.usedPercent,
                                remainingPercent: sevenDay.remainingPercent,
                                remainingFraction: sevenDay.remainingFraction,
                                resetDate: sevenDay.resetsAt,
                                weeklyCycle: weeklyCycle
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
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else if !snapshot.rateLimitsAvailable {
                    StatusCard(
                        title: "Rate limits not available",
                        detail: "Claude Code CLI reports that rate limit tracking is unavailable for this account.",
                        symbol: "chart.bar",
                        warning: false
                    )
                } else {
                    StatusCard(
                        title: "No usage limits available",
                        detail: "\(label) hasn't reported active usage limits.",
                        symbol: "chart.bar",
                        warning: false
                    )
                }
            } else if error == nil {
                StatusCard(
                    title: "Checking \(label) usage…",
                    detail: "Querying Claude CLI for quota limits.",
                    symbol: "bubble.left.and.text.bubble.right",
                    warning: false
                )
            }

            if let updated = lastUpdated {
                UpdatedFooter(date: updated, hasError: error != nil)
            }
        }
    }
}
