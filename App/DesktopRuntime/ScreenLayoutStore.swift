import Combine

@MainActor
final class DisplayTopologyStore: ObservableObject {
    @Published private(set) var table: WindowDisplayAttribution.Table
    @Published private(set) var physicalDisplayCount: Int

    init(initialSnapshot snapshot: ScreenTopologySnapshot) {
        table = snapshot.attributionTable
        physicalDisplayCount = snapshot.physicalDisplayCount
    }

    func apply(_ snapshot: ScreenTopologySnapshot) {
        if physicalDisplayCount != snapshot.physicalDisplayCount {
            physicalDisplayCount = snapshot.physicalDisplayCount
        }
        if snapshot.attributionTable != table {
            table = snapshot.attributionTable
        }
    }
}
