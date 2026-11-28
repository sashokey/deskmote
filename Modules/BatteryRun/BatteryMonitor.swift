import Combine

struct BatteryDisplaySnapshot: Sendable {
    let report: JournalBatteryReport?
    let watts: PowerWatts
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var snapshot: BatteryDisplaySnapshot?
    @Published private(set) var isReadingHistory = false

    private let readJournal: @Sendable () -> String?
    private let readWatts: @Sendable () -> PowerWatts
    private var refreshPending = false

    init(
        readJournal: @escaping @Sendable () -> String? = { PowerHistoryLoader.run() },
        readWatts: @escaping @Sendable () -> PowerWatts = BatteryReader.readWatts
    ) {
        self.readJournal = readJournal
        self.readWatts = readWatts
    }

    func refresh() {
        guard !isReadingHistory else {
            refreshPending = true
            return
        }
        isReadingHistory = true
        startRead()
    }

    private func startRead() {
        Task { [weak self, readJournal, readWatts] in
            let result = await PowerHistoryLoader.loadSnapshot(readJournal: readJournal, readWatts: readWatts)
            guard let self else { return }
            if refreshPending {
                refreshPending = false
                startRead()
                return
            }
            snapshot = result
            isReadingHistory = false
        }
    }
}
