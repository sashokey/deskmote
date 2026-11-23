import Foundation

struct StripDisplayFilter: Equatable {
    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?
    var physicalDisplayCount = 1

    var hasUnidentifiedPrimary: Bool {
        scope == nil && primaryUUID == nil && (physicalDisplayCount > 1 || !connectedUUIDs.isEmpty)
    }

    func needsPrimaryDisplayEvidence(layoutCount: Int) -> Bool {
        scope == nil && primaryUUID == nil && (hasUnidentifiedPrimary || layoutCount > 1)
    }

    func shows(displayUUID: String?) -> Bool {
        guard let scope else {
            return primaryUUID != nil || connectedUUIDs.isEmpty || resolvedWindowDisplayUUID(displayUUID) == nil
        }
        return resolvedWindowDisplayUUID(displayUUID) == scope
    }

    func resolvedWindowDisplayUUID(_ key: String?) -> String? {
        guard let key, connectedUUIDs.contains(key) else { return primaryUUID }
        return key
    }
}
