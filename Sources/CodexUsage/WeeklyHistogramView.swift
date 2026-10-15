import SwiftUI
import CodexUsageCore

struct WeeklyHistogramView: View {
    let cycle: WeeklyUsageCycle
    var now: Date = Date()
    var calendar: Calendar = .current

    private var barCount: Int {
        max(7, cycle.dailyUsage.count)
    }

    private var currentDayIndex: Int {
        let cycleStartDay = calendar.startOfDay(for: cycle.cycleStart)
        let nowDay = calendar.startOfDay(for: now)
        let dayOffset = calendar.dateComponents([.day], from: cycleStartDay, to: nowDay).day ?? 0
        return min(barCount - 1, max(0, dayOffset))
    }

    private var maxUsage: Double {
        max(cycle.dailyUsage.max() ?? 20.0, 20.0)
    }

    private var barSpacing: CGFloat {
        barCount > 7 ? 4 : 6
    }

    /// Upper bound for a bar's width; bars shrink below this when the cycle has many days
    /// so the histogram never grows wider than its container.
    private let maxBarWidth: CGFloat = 32
    private let barHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily Usage (7-Day Cycle)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !cycle.offlineGapDays.isEmpty {
                    Text("* Includes offline usage")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
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
        let usage = index < cycle.dailyUsage.count ? cycle.dailyUsage[index] : 0.0
        let fillFraction = isFuture ? 0.0 : min(1.0, max(0.0, usage / maxUsage))
        let hasGap = cycle.offlineGapDays.contains(index)

        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(isFuture ? 0.08 : 0.15))
                    .frame(height: barHeight)

                // Usage fill
                if !isFuture && fillFraction > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.65))
                        .frame(height: max(3.0, barHeight * fillFraction))
                }
            }

            // Day label
            HStack(spacing: 1) {
                Text("D\(index + 1)")
                    .font(.system(size: barCount > 7 ? 9 : 10, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                if hasGap {
                    Text("*")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            // Usage percentage
            Text(isFuture ? "-" : "\(Int(usage.rounded()))%")
                .font(.system(size: barCount > 7 ? 8 : 9))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(minWidth: 0, maxWidth: maxBarWidth)
        .help(tooltip(for: index, usage: usage, isCurrent: isCurrent, isFuture: isFuture, hasGap: hasGap))
    }

    private func tooltip(for index: Int, usage: Double, isCurrent: Bool, isFuture: Bool, hasGap: Bool) -> String {
        let dayNum = index + 1
        let cycleStartDay = calendar.startOfDay(for: cycle.cycleStart)
        let barDate = calendar.date(byAdding: .day, value: index, to: cycleStartDay)

        let dateStr: String
        if let barDate {
            let df = DateFormatter()
            // Match the rest of the popover, which is rendered in English.
            df.locale = Locale(identifier: "en_US")
            df.timeZone = calendar.timeZone
            df.dateFormat = "M/d (E)"
            dateStr = " (\(df.string(from: barDate)))"
        } else {
            dateStr = ""
        }

        if isFuture {
            return "Day \(dayNum)\(dateStr): Not yet reached"
        }
        var info = "Day \(dayNum)\(dateStr): \(Int(usage.rounded()))% used"
        if isCurrent {
            info += " (Today)"
        }
        if hasGap {
            info += " — Includes usage recorded after offline period"
        }
        return info
    }
}
