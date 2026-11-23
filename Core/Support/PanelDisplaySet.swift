import Foundation

enum TaskbarDisplaySet {
    static func desiredUnitKeys(connectedKeys: [String], physicalDisplayCount: Int,
                                hasIdentifiedPrimary: Bool = true) -> [String?] {
        guard physicalDisplayCount > 0 else { return [] }
        guard !connectedKeys.isEmpty else { return [nil] }
        if !hasIdentifiedPrimary, connectedKeys.count < physicalDisplayCount {
            return [nil] + connectedKeys.map(Optional.some)
        }
        return connectedKeys
    }
}
