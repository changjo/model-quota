import SwiftUI
import CodexUsageCore

struct MenuBarGridView: View {
    let items: [ProviderUsageItem]

    var body: some View {
        if items.isEmpty {
            Text("Codex")
                .font(.system(size: 11.5, weight: .medium))
        } else if items.count == 1, let item = items.first {
            singleItemView(item)
        } else {
            multiItemGridView
        }
    }

    private func singleItemView(_ item: ProviderUsageItem) -> some View {
        HStack(spacing: 4) {
            Text(item.label)
                .font(.system(size: 11.5, weight: .semibold))
            Text(item.summaryValue)
                .font(.system(size: 11.5, weight: .regular).monospacedDigit())
        }
    }

    private var multiItemGridView: some View {
        let columns = MenuBarLayout.organizeColumns(items: items, maxRows: 2)
        return HStack(alignment: .center, spacing: 6) {
            ForEach(0..<columns.count, id: \.self) { colIndex in
                let column = columns[colIndex]
                VStack(alignment: .leading, spacing: -1) {
                    ForEach(column) { item in
                        HStack(spacing: 3) {
                            Text(item.label)
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(item.summaryValue)
                                .font(.system(size: 8.5, weight: .regular).monospacedDigit())
                        }
                    }
                }
                if colIndex < columns.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 16)
                }
            }
        }
    }
}
