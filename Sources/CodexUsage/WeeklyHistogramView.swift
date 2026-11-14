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

    /// Matches the rest of the popover, which is rendered in English.
    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
    }

    private func date(forDay index: Int) -> Date? {
        calendar.date(byAdding: .day, value: index, to: calendar.startOfDay(for: cycle.cycleStart))
    }

    private func weekday(forDay index: Int) -> String {
        date(forDay: index)?.formatted(dateStyle.weekday(.abbreviated)) ?? "Day \(index + 1)"
    }

    /// An 8-bar cycle starts and ends on the same weekday; add the day of month to tell them apart.
    private func dayLabel(forDay index: Int) -> String {
        let name = weekday(forDay: index)
        let repeats = (0..<barCount).contains { $0 != index && weekday(forDay: $0) == name }
        guard repeats, let date = date(forDay: index) else { return name }
        return "\(name) \(calendar.component(.day, from: date))"
    }

    private func usage(forDay index: Int) -> Double {
        index < cycle.dailyUsage.count ? cycle.dailyUsage[index] : 0.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily Usage")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !cycle.offlineGapDays.isEmpty {
                    Text("* Includes offline usage")
                        .font(.caption2)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily usage")
        .accessibilityValue(accessibilitySummary)
    }

    @ViewBuilder
    private func dayBar(index: Int) -> some View {
        let isCurrent = index == currentDayIndex
        let isFuture = index > currentDayIndex
        let usage = usage(forDay: index)
        let fillFraction = isFuture ? 0.0 : min(1.0, max(0.0, usage / maxUsage))
        let hasGap = cycle.offlineGapDays.contains(index)

        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(isFuture ? 0.08 : 0.15))
                    .frame(height: barHeight)

                // Usage fill; inset on today so the outline stays visible even when the bar is full.
                if !isFuture && fillFraction > 0 {
                    let inset: CGFloat = isCurrent ? 3 : 0
                    RoundedRectangle(cornerRadius: isCurrent ? 1.5 : 3)
                        .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.65))
                        .frame(height: max(3.0, (barHeight - inset * 2) * fillFraction))
                        .padding(inset)
                }
            }
            // Outline today's track so the current day doesn't rely on color alone.
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }

            // Day label
            HStack(spacing: 1) {
                Text(dayLabel(forDay: index))
                    .fontWeight(isCurrent ? .bold : .regular)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                if hasGap {
                    Text("*")
                        .fontWeight(.bold)
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            // Usage percentage
            Text(isFuture ? "-" : "\(Int(usage.rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(minWidth: 0, maxWidth: maxBarWidth)
        .help(tooltip(for: index, usage: usage, isCurrent: isCurrent, isFuture: isFuture, hasGap: hasGap))
    }

    /// e.g. "Mon 0%, Tue 12%, Wed 30% today" — every day up to and including today.
    private var accessibilitySummary: String {
        var days = (0...currentDayIndex).map { index in
            "\(dayLabel(forDay: index)) \(Int(usage(forDay: index).rounded()))%" + (index == currentDayIndex ? " today" : "")
        }
        if cycle.offlineGapDays.contains(where: { $0 <= currentDayIndex }) {
            days.append("includes offline usage")
        }
        return days.joined(separator: ", ")
    }

    private func tooltip(for index: Int, usage: Double, isCurrent: Bool, isFuture: Bool, hasGap: Bool) -> String {
        let day = date(forDay: index)?.formatted(dateStyle.weekday(.abbreviated).month(.abbreviated).day())
            ?? "Day \(index + 1)"
        if isFuture {
            return "\(day): Not yet reached"
        }
        var info = "\(day): \(Int(usage.rounded()))% used"
        if isCurrent {
            info += " (Today)"
        }
        if hasGap {
            info += " — Includes usage recorded after offline period"
        }
        return info
    }
}
