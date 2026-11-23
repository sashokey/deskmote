struct ScreenTopologySnapshot: Equatable {
    let physicalDisplayCount: Int
    let identifiedDisplayUUIDs: [String]
    let attributionTable: WindowDisplayAttribution.Table

    var needsUUIDRetry: Bool {
        physicalDisplayCount >= 2 && identifiedDisplayUUIDs.count < physicalDisplayCount
    }
}
