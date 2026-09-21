import SwiftUI
import CodexUsageCore

struct WeeklyHistogramView: View {
    let cycle: WeeklyUsageCycle
    var now: Date = Date()

    private var currentDayIndex: Int {
        let elapsed = max(0, now.timeIntervalSince(cycle.cycleStart))
        return min(6, max(0, Int(elapsed / 86400)))
    }

    private var maxUsage: Double {
        max(cycle.dailyUsage.max() ?? 20.0, 20.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily Usage (7-Day Cycle)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !cycle.offlineGapDays.isEmpty {
                    Text("* Includes offline usage")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    dayBar(index: index)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func dayBar(index: Int) -> some View {
        let isCurrent = index == currentDayIndex
        let isFuture = index > currentDayIndex
        let usage = cycle.dailyUsage[index]
        let fillFraction = isFuture ? 0.0 : min(1.0, max(0.0, usage / maxUsage))
        let hasGap = cycle.offlineGapDays.contains(index)

        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(isFuture ? 0.08 : 0.15))
                    .frame(width: 32, height: 38)

                // Usage fill
                if !isFuture && fillFraction > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.65))
                        .frame(width: 32, height: max(3.0, 38.0 * fillFraction))
                }
            }

            // Day label
            HStack(spacing: 1) {
                Text("D\(index + 1)")
                    .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                if hasGap {
                    Text("*")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
            }

            // Usage percentage
            Text(isFuture ? "-" : "\(Int(usage.rounded()))%")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .help(tooltip(for: index, usage: usage, isCurrent: isCurrent, isFuture: isFuture, hasGap: hasGap))
    }

    private func tooltip(for index: Int, usage: Double, isCurrent: Bool, isFuture: Bool, hasGap: Bool) -> String {
        let dayNum = index + 1
        if isFuture {
            return "Day \(dayNum): Not yet reached"
        }
        var info = "Day \(dayNum): \(Int(usage.rounded()))% used"
        if isCurrent {
            info += " (Today)"
        }
        if hasGap {
            info += " — Includes usage recorded after offline period"
        }
        return info
    }
}
