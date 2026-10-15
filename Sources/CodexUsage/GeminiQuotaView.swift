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
                let errDesc = (error as? UsageError)?.errorDescription(for: label) ?? error.localizedDescription
                let suggestion = (error as? UsageError)?.recoverySuggestion(for: label) ?? (error as? LocalizedError)?.recoverySuggestion ?? ""
                let detail = suggestion.isEmpty
                    ? (snapshot == nil ? "" : "Showing the last known usage.")
                    : suggestion + (snapshot == nil ? "" : " Showing the last known usage.")
                statusCard(
                    title: errDesc,
                    detail: detail,
                    symbol: "exclamationmark.triangle",
                    warning: true
                )
            }

            if let snapshot = snapshot {
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
            } else if error == nil {
                statusCard(
                    title: "Checking \(label) usage…",
                    detail: "Querying agy CLI for quota limits.",
                    symbol: "sparkles",
                    warning: false
                )
            }

            if let updated = lastUpdated {
                UpdatedFooter(date: updated, hasError: error != nil)
            }
        }
    }

    private func statusCard(title: String, detail: String, symbol: String, warning: Bool) -> some View {
        StatusCard(title: title, detail: detail, symbol: symbol, warning: warning)
    }
}

private struct GeminiBucketRow: View {
    let bucket: GeminiUsageSnapshot.Bucket
    var weeklyCycle: WeeklyUsageCycle? = nil

    var body: some View {
        UsageMeterRow(
            title: bucket.name,
            usedPercent: bucket.usedPercent,
            remainingPercent: bucket.remainingPercent,
            remainingFraction: bucket.remainingFraction,
            resetDate: bucket.resetTime,
            weeklyCycle: (bucket.window == "weekly" || bucket.id.contains("weekly")) ? weeklyCycle : nil
        )
    }
}
