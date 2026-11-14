import Foundation

public enum MenuBarLayout {
    /// Organizes items into columns where each column contains at most `maxRows` items (default: 2).
    /// When there are more items than `maxRows`, new columns are added.
    public static func organizeColumns(items: [ProviderUsageItem], maxRows: Int = 2) -> [[ProviderUsageItem]] {
        guard !items.isEmpty, maxRows > 0 else { return [] }
        var columns: [[ProviderUsageItem]] = []
        var currentIndex = 0
        while currentIndex < items.count {
            let nextIndex = min(currentIndex + maxRows, items.count)
            columns.append(Array(items[currentIndex..<nextIndex]))
            currentIndex = nextIndex
        }
        return columns
    }
}
