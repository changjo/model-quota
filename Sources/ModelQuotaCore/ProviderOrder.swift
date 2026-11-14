import Foundation

/// The order in which providers are shown. Every stored or edited order is normalized so it
/// always lists each provider exactly once.
public enum ProviderOrder {
    public static let `default`: [ProviderKind] = ProviderKind.allCases

    /// Drops duplicates and appends missing providers in the default order.
    public static func normalized(_ order: [ProviderKind]) -> [ProviderKind] {
        var seen = Set<ProviderKind>()
        let unique = order.filter { seen.insert($0).inserted }
        return unique + `default`.filter { !seen.contains($0) }
    }

    /// Reads a stored order, ignoring unknown provider identifiers.
    public static func normalized(rawValues: [String]) -> [ProviderKind] {
        normalized(rawValues.compactMap(ProviderKind.init(rawValue:)))
    }

    /// Moves `kind` by `offset` positions, stopping at either end.
    public static func move(_ kind: ProviderKind, by offset: Int, in order: [ProviderKind]) -> [ProviderKind] {
        var result = normalized(order)
        guard let index = result.firstIndex(of: kind) else { return result }
        let target = min(max(0, index + offset), result.count - 1)
        result.insert(result.remove(at: index), at: target)
        return result
    }
}
