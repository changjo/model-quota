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
                VStack(alignment: .leading, spacing: isSingleItem ? 0 : -2) {
                    ForEach(column) { item in
                        HStack(spacing: 3.5) {
                            Text(item.label)
                                .font(.system(size: isSingleItem ? 13.0 : 9.5, weight: .semibold))
                            Text(item.summaryValue)
                                .font(.system(size: isSingleItem ? 13.0 : 9.5, weight: .medium).monospacedDigit())
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
