import SwiftUI
import AppKit
import CodexUsageCore

@MainActor
final class MenuBarImageRenderer {
    static let shared = MenuBarImageRenderer()

    private var cachedItems: [ProviderUsageItem]?
    private var cachedScale: CGFloat?
    private var cachedImage: NSImage?

    func image(for items: [ProviderUsageItem]) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let cachedItems, cachedItems == items, cachedScale == scale, let cachedImage {
            return cachedImage
        }

        let columns = MenuBarLayout.organizeColumns(items: items, maxRows: 2)
        guard !columns.isEmpty else { return nil }

        let snapshotView = MenuBarSnapshotView(columns: columns)
        let renderer = ImageRenderer(content: snapshotView)
        renderer.scale = scale
        guard let nsImage = renderer.nsImage else { return nil }
        nsImage.isTemplate = true

        cachedItems = items
        cachedScale = scale
        cachedImage = nsImage
        return nsImage
    }
}

struct MenuBarSnapshotView: View {
    let columns: [[ProviderUsageItem]]

    var body: some View {
        let isSingleItem = columns.count == 1 && columns[0].count == 1
        HStack(alignment: .center, spacing: 6) {
            ForEach(0..<columns.count, id: \.self) { colIndex in
                let column = columns[colIndex]
                if isSingleItem, let item = column.first {
                    HStack(spacing: 4) {
                        Text(item.label)
                            .font(.system(size: 13.5, weight: .bold))
                        Text(item.summaryValue)
                            .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                    }
                } else {
                    HStack(alignment: .center, spacing: 5) {
                        VStack(alignment: .leading, spacing: -3.0) {
                            ForEach(column) { item in
                                Text(item.label)
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                        }
                        VStack(alignment: .trailing, spacing: -3.0) {
                            ForEach(column) { item in
                                Text(item.summaryValue)
                                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            }
                        }
                    }
                }
                if colIndex < columns.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 16)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, isSingleItem ? 0 : 1)
        .fixedSize()
    }
}

struct MenuBarGridView: View {
    let items: [ProviderUsageItem]

    var body: some View {
        if let image = MenuBarImageRenderer.shared.image(for: items) {
            Image(nsImage: image)
        } else {
            Text("Codex")
                .font(.system(size: 11.5, weight: .medium))
        }
    }
}
