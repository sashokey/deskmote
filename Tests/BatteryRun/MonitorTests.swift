import Foundation
import Synchronization

@MainActor
func drainBatteryHistory(until condition: () -> Bool, timeout: TimeInterval = 1) -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

private final class HistoryFixture: Sendable {
    private let logs: [String]
    private let reads = Mutex(0)
    private let currentDate: Date

    init(_ logs: [String], currentDate: Date) {
        self.logs = logs
        self.currentDate = currentDate
    }

    func load() -> PowerHistory? {
        let index = reads.withLock { count in
            defer { count += 1 }
            return count
        }
        guard logs.indices.contains(index) else { return nil }
        return PowerHistory(from: logs[index], before: currentDate)
    }

    var readCount: Int { reads.withLock { $0 } }
}

let monitorTests = [
    TestCase(name: "a power history record inside a gap cannot confirm the persisted forecast") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-uncovered-gap-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let checkpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            var tracker = SessionTracker()
            tracker.update(wake, wakeDate: wake.date)
            tracker.update(checkpoint)
            try SessionStore.save(tracker, to: url)
            let partial = """
            2024-01-01 10:00:00 +0000 Wake Wake from sleep Using Batt (Charge: 90%)
            2024-01-01 11:15:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 83%)
            """
            let trailingDate = current.date.addingTimeInterval(31)
            let later = partial + "\n2024-01-01 13:00:30 +0000 Wake Requests [process=powerd request=Maintenance deltaSecs=1800 wakeAt=2024-01-01 13:30:30]"
            let history = HistoryFixture([partial, later], currentDate: trailingDate)
            var uptime = ContinuousClock.now
            var reading = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil,
                                         loadHistory: history.load, readClock: { (reading.date, uptime) })
            monitor.start()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "first read must finish")
            try expect(monitor.forecastStart == nil, "a record inside the outage does not cover its unobserved end")
            try expect(SessionStore.load(from: url)?.forecastStart == wake, "inconclusive history keeps the stored forecast")
            monitor.refresh()
            try expect(history.readCount == 1 && !monitor.isReadingHistory, "inconclusive history must respect backoff")
            uptime = uptime.advanced(by: .seconds(31))
            reading = BatterySample(date: trailingDate, percent: 69, onBattery: true)
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "second read must finish")
            try expect(monitor.forecastStart == wake, "a later read can verify the original observation gap")
        }
    },
    TestCase(name: "an unresolved forecast checkpoint survives relaunch") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-gap-relaunch-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let checkpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            let resumed = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 75, onBattery: true)
            var tracker = SessionTracker()
            tracker.update(wake, wakeDate: wake.date)
            tracker.update(checkpoint)
            try SessionStore.save(tracker, to: url)
            do {
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in resumed }, bootDate: nil, loadHistory: { nil })
                monitor.start()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the missing log read must finish")
                try expect(monitor.forecastStart == nil, "the first relaunch has no journal coverage")
            }
            let logDate = current.date.addingTimeInterval(5)
            let history = HistoryFixture(["""
                2024-01-01 11:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 82%)
                2024-01-01 13:00:03 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 70%)
                """], currentDate: logDate)
            var reading = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: history.load)
            monitor.start()
            reading = BatterySample(date: logDate, percent: current.percent, onBattery: true)
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the second log read must finish")
            try expect(monitor.forecastStart == nil, "a later sample must not replace the original gap boundary")
            try expect(SessionStore.load(from: url)?.forecastStart == wake, "missing older records must leave the saved forecast intact")
        }
    },
    TestCase(name: "confirmed AC interrupts the discharge even when the forecast gap is unresolved") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-confirmed-interruption-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let checkpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            let nextDischarge = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
            var tracker = SessionTracker()
            tracker.update(wake, wakeDate: wake.date)
            tracker.update(checkpoint)
            try SessionStore.save(tracker, to: url)
            let partial = """
            2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
            2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 75%)
            """
            let history = HistoryFixture([partial, partial], currentDate: current.date)
            var uptime = ContinuousClock.now
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil,
                                         loadHistory: history.load, readClock: { (current.date, uptime) })
            monitor.start()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "truncated history must finish")
            try expect(monitor.tracker.session == DischargeSession(start: nextDischarge, origin: .history),
                       "discharge totals must begin after confirmed AC")
            try expect(monitor.forecastStart == nil, "widely spaced samples still cannot time the unplug")
            let saved = SessionStore.load(from: url)
            try expect(saved?.session == monitor.tracker.session && saved?.forecastStart == nil,
                       "a confirmed interruption must survive relaunch")
            monitor.refresh()
            try expect(history.readCount == 1 && !monitor.isReadingHistory, "retry must still wait for its backoff")
            uptime = uptime.advanced(by: .seconds(31))
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the unresolved forecast must retry")
            try expect(history.readCount == 2 && monitor.forecastStart == nil,
                       "retrying unchanged history must leave the forecast unresolved")
        }
    },
    TestCase(name: "confirmed AC updates the session while a full wake is still pending") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let initial = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let checkpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            let newerWake = BatterySample(date: current.date.addingTimeInterval(-1200), percent: 74, onBattery: true)
            let nextDischarge = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
            let history = """
            2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
            2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)
            """
            for liveWake in [nil, newerWake] {
                let url = URL(fileURLWithPath: ".build/monitor-interruption-before-full-wake-\(UUID().uuidString).json")
                var tracker = SessionTracker()
                tracker.update(initial, wakeDate: initial.date)
                tracker.update(checkpoint)
                try SessionStore.save(tracker, to: url)
                var reading = liveWake ?? current
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                    PowerHistory(from: history, before: current.date)
                })
                if let liveWake {
                    monitor.refresh(wakeDate: liveWake.date)
                    reading = current
                    monitor.recoverHistory()
                } else {
                    monitor.start()
                }
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                try expect(monitor.tracker.session == DischargeSession(start: nextDischarge, origin: .history),
                           "the journal proves the old discharge ended at AC")
                try expect(monitor.forecastStart == liveWake, "only the newer directly observed wake can anchor a forecast")
                try expect(SessionStore.load(from: url)?.session == monitor.tracker.session,
                           "the confirmed discharge boundary must persist")
            }
        }
    },
    TestCase(name: "a pending wake checkpoint does not block a confirmed AC interruption") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-interruption-unlogged-wake-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let initial = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let nextDischarge = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
            var reading: BatterySample? = initial
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                PowerHistory(from: """
                    2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
                    2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 75%)
                    """, before: current.date)
            })
            monitor.refresh()
            reading = nil
            monitor.refresh(wakeDate: current.date.addingTimeInterval(-1200))
            reading = current
            monitor.refresh()
            monitor.recoverHistory()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
            try expect(monitor.tracker.session == DischargeSession(start: nextDischarge, origin: .history),
                       "an older confirmed AC transition resets session totals")
            try expect(monitor.forecastStart == nil && monitor.tracker.needsWakeHistory,
                       "the newer unlogged wake must keep waiting for history")
        }
    },
    TestCase(name: "the order of an AC event and a wake in the same second governs forecast invalidation") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            let ac = "2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC"
            let awake = "2024-01-01 12:00:00 +0000 Wake Wake from sleep Using Batt (Charge: 80%)"
            let later = "2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)"
            for acAfterWake in [true, false] {
                let url = URL(fileURLWithPath: ".build/monitor-ordered-ac-\(UUID().uuidString).json")
                var reading = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 90, onBattery: true)
                let rows = acAfterWake ? [awake, ac, later] : [ac, awake, later]
                let history = rows.joined(separator: "\n")
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                    PowerHistory(from: history, before: current.date)
                })
                monitor.refresh()
                reading = wake
                monitor.refresh(wakeDate: wake.date)
                try expect(monitor.forecastStart == wake, "the live wake creates a forecast")
                reading = current
                monitor.refresh()
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                try expect(monitor.forecastStart == (acAfterWake ? nil : wake), "only AC ordered after the wake invalidates the forecast")
                try expect(SessionStore.load(from: url)?.forecastStart == monitor.forecastStart, "the decision must persist")
            }
        }
    },
    TestCase(name: "equal-charge dark wake cannot place AC after the live full wake") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            let dark = "2024-01-01 12:00:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 80%)"
            let ac = "2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC"
            let full = "2024-01-01 12:00:00 +0000 Wake DarkWake to FullWake from sleep Using Batt (Charge: 80%)"
            let laterDark = "2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)"
            for acAfterFullWake in [false, true] {
                let url = URL(fileURLWithPath: ".build/monitor-dark-before-full-\(UUID().uuidString).json")
                var reading = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 90, onBattery: true)
                let rows = acAfterFullWake ? [dark, full, ac, laterDark] : [dark, ac, full, laterDark]
                let history = HistoryFixture([full, rows.joined(separator: "\n")], currentDate: current.date)
                @MainActor func makeMonitor() -> BatteryMonitor {
                    BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: history.load)
                }
                var monitor = makeMonitor()
                monitor.refresh()
                reading = wake
                monitor.refresh(wakeDate: wake.date)
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the full wake must finish reconciliation")
                try expect(monitor.forecastStart == wake && !monitor.tracker.needsWakeHistory,
                           "the observed forecast must survive clearing the pending wake")
                monitor = makeMonitor()
                reading = current
                monitor.refresh()
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                try expect(monitor.forecastStart == (acAfterFullWake ? nil : wake),
                           "a full-wake forecast requires a full wake before an ordered interruption")
            }
        }
    },
    TestCase(name: "a same-second battery source summary can match an observed unplug") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-ordered-unplug-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let unplug = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            var reading = BatterySample(date: current.date.addingTimeInterval(-3660), percent: 80, onBattery: false)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                PowerHistory(from: """
                    2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 80%)
                    2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
                    2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)
                    """, before: current.date)
            })
            monitor.refresh()
            reading = unplug
            monitor.refresh()
            try expect(monitor.forecastStart == unplug, "the observed unplug must establish its forecast")
            reading = current
            monitor.refresh()
            monitor.recoverHistory()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
            try expect(monitor.forecastStart == nil, "logged AC after the matching source summary invalidates the unplug")
        }
    },
    TestCase(name: "a full wake without a logged charge still establishes the order of AC") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            let dark = "2024-01-01 12:00:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 80%)"
            let ac = "2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC"
            let full = "2024-01-01 12:00:00 +0000 Wake DarkWake to FullWake from sleep"
            let laterDark = "2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)"
            for event in [full, full + " Using Batt"] {
                for acAfterFullWake in [true, false] {
                    let url = URL(fileURLWithPath: ".build/monitor-unmeasured-full-wake-\(UUID().uuidString).json")
                    var tracker = SessionTracker()
                    tracker.update(BatterySample(date: wake.date.addingTimeInterval(-3600), percent: 90, onBattery: true))
                    tracker.update(wake, wakeDate: wake.date)
                    try SessionStore.save(tracker, to: url)
                    let rows = acAfterFullWake ? [dark, event, ac, laterDark] : [dark, ac, event, laterDark]
                    let history = rows.joined(separator: "\n")
                    let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil, loadHistory: {
                        PowerHistory(from: history, before: current.date)
                    })
                    monitor.refresh()
                    monitor.recoverHistory()
                    try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                    let expected = acAfterFullWake ? nil : wake
                    try expect(monitor.forecastStart == expected, "only AC after the logged wake invalidates the observed forecast")
                    try expect(SessionStore.load(from: url)?.forecastStart == expected,
                               "the state must retain the original observed charge unless the wake was interrupted")
                }
            }
        }
    },
    TestCase(name: "a full wake with a matching charge wins over an earlier unmeasured full wake") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(75)
            let wake = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            let weak = "2024-01-01 12:00:00 +0000 Wake Wake from sleep"
            let ac = "2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC"
            let measured = "2024-01-01 12:00:00 +0000 Wake Wake from sleep Using Batt (Charge: 80%)"
            let laterDark = "2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 79%)"
            for acAfterWake in [false, true] {
                let url = URL(fileURLWithPath: ".build/monitor-strong-wake-\(UUID().uuidString).json")
                var tracker = SessionTracker()
                tracker.update(BatterySample(date: wake.date.addingTimeInterval(-3600), percent: 90, onBattery: true))
                tracker.update(wake, wakeDate: wake.date)
                try SessionStore.save(tracker, to: url)
                let rows = acAfterWake ? [weak, measured, ac, laterDark] : [weak, ac, measured, laterDark]
                let history = rows.joined(separator: "\n")
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil, loadHistory: {
                    PowerHistory(from: history, before: current.date)
                })
                monitor.refresh()
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                try expect(monitor.forecastStart == (acAfterWake ? nil : wake),
                           "only AC after the measured full wake invalidates the local forecast")
            }
        }
    },
    TestCase(name: "the local wake charge supersedes pre-wake readings for forecast interruptions") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(75)
            let wake = BatterySample(date: current.date.addingTimeInterval(-3600 + 0.4), percent: 80, onBattery: true)
            let preceding = """
            2024-01-01 12:00:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 70%)
            2024-01-01 12:00:00 +0000 Wake DarkWake to FullWake from sleep
            """
            let darkWake = "\n2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep"
            for chargeIncreased in [false, true] {
                let url = URL(fileURLWithPath: ".build/monitor-pre-wake-charge-\(UUID().uuidString).json")
                var tracker = SessionTracker()
                tracker.update(BatterySample(date: wake.date.addingTimeInterval(-3600), percent: 90, onBattery: true))
                tracker.update(wake, wakeDate: wake.date)
                try SessionStore.save(tracker, to: url)
                let history = preceding + darkWake + (chargeIncreased ? " Using Batt (Charge: 82%)" : " Using Batt")
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil, loadHistory: {
                    PowerHistory(from: history, before: current.date)
                })
                monitor.refresh()
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "history must finish")
                try expect(monitor.forecastStart == (chargeIncreased ? nil : wake),
                           "only charge growth after the local wake invalidates its forecast")
            }
        }
    },
    TestCase(name: "a second gap without a saved forecast requires coverage or a newer wake") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let checkpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            let resumed = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 86, onBattery: true)
            let afterJournal = BatterySample(date: current.date.addingTimeInterval(31), percent: 69, onBattery: true)
            let oldWake = "2024-01-01 11:30:00 +0000 Wake Wake from sleep Using Batt (Charge: 87%)"
            let verified = oldWake + "\n2024-01-01 13:00:30 +0000 Wake Requests [process=powerd request=Maintenance]"
            for relaunch in [true, false] {
                let url = URL(fileURLWithPath: ".build/monitor-gap-no-forecast-\(UUID().uuidString).json")
                let tracker = SessionTracker(session: DischargeSession(start: checkpoint, origin: .monitoring), lastSample: checkpoint)
                try SessionStore.save(tracker, to: url)
                let history = HistoryFixture(["", oldWake, verified], currentDate: afterJournal.date)
                var reading: BatterySample? = resumed
                @MainActor func makeMonitor() -> BatteryMonitor {
                    BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: history.load)
                }
                var monitor = makeMonitor()
                monitor.start()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the first gap must finish reading")
                if relaunch {
                    monitor = makeMonitor()
                    reading = current
                    monitor.start()
                } else {
                    reading = nil
                    monitor.refresh()
                    reading = current
                    monitor.refresh()
                    monitor.recoverHistory()
                }
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the second gap must finish reading")
                try expect(monitor.forecastStart == nil, "an old wake must not cross the latest unobserved gap")
                reading = afterJournal
                monitor.refresh()
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the complete range must finish reading")
                try expect(monitor.forecastStart?.percent == 87, "journal coverage through the resumed reading can corroborate the old wake")
            }
        }
    },
    TestCase(name: "a wake inside an earlier unresolved outage cannot cross a newer gap") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let originalWake = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            let firstCheckpoint = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 86, onBattery: true)
            let resumed = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 86, onBattery: true)
            let priorWake = "2024-01-01 11:30:00 +0000 Wake Wake from sleep Using Batt (Charge: 87%)"
            let recentWake = "\n2024-01-01 12:30:00 +0000 Wake Wake from sleep Using Batt (Charge: 75%)"
            for relaunch in [true, false] {
                let url = URL(fileURLWithPath: ".build/monitor-latest-gap-\(UUID().uuidString).json")
                var tracker = SessionTracker()
                tracker.update(originalWake, wakeDate: originalWake.date)
                tracker.update(firstCheckpoint)
                try SessionStore.save(tracker, to: url)
                var reading: BatterySample? = resumed
                let history = HistoryFixture(["", priorWake, priorWake + recentWake], currentDate: current.date)
                @MainActor func makeMonitor() -> BatteryMonitor {
                    BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: history.load)
                }
                var monitor = makeMonitor()
                monitor.start()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "first gap must finish reading")
                try expect(monitor.forecastStart == nil, "the first gap remains unresolved")
                if relaunch {
                    monitor = makeMonitor()
                    reading = current
                    monitor.start()
                } else {
                    reading = nil
                    monitor.refresh()
                    reading = current
                    monitor.refresh()
                    monitor.recoverHistory()
                }
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "second gap must finish reading")
                try expect(monitor.forecastStart == nil, "the earlier wake cannot validate the later outage")
                try expect(SessionStore.load(from: url)?.forecastStart == originalWake, "inconclusive history retains the old metadata")
                monitor.recoverHistory()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "newer wake must finish reading")
                try expect(monitor.forecastStart?.date == current.date.addingTimeInterval(-1800),
                           "a positive full wake in the latest gap can establish a forecast")
            }
        }
    },
    TestCase(name: "startup awaits a full wake after history ends with sleep") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-deferred-wake-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let sleeping = """
            2024-01-01 11:00:00 +0000 Sleep Entering Sleep state Using AC (Charge: 90%)
            2024-01-01 12:15:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 76%)
            """
            let history = HistoryFixture([sleeping, sleeping + "\n2024-01-01 12:30:00 +0000 Wake DarkWake to FullWake from sleep Using Batt (Charge: 75%)"],
                                         currentDate: current.date)
            var uptime = ContinuousClock.now
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil,
                                         loadHistory: history.load, readClock: { (current.date, uptime) })
            monitor.start()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "sleep-only read must finish")
            try expect(monitor.forecastStart == nil, "dark wake must not establish the forecast")
            monitor.refresh()
            try expect(history.readCount == 1 && !monitor.isReadingHistory, "waiting for a full wake must use the backoff")
            uptime = uptime.advanced(by: .seconds(31))
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "retry must finish")
            try expect(monitor.forecastStart?.percent == 75, "a delayed full wake must establish its own forecast")
        }
    },
    TestCase(name: "truncated dark-wake history requires a later full wake") {
        try MainActor.assumeIsolated {
            let current = historyCurrent(70)
            let oldWake = "2024-01-01 12:15:00 +0000 Wake Wake from sleep Using Batt (Charge: 77%)\n"
            let darkWake = "2024-01-01 12:15:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 76%)"
            let fullWake = "\n2024-01-01 12:30:00 +0000 Wake DarkWake to FullWake from sleep Using Batt (Charge: 75%)"
            for prefix in [oldWake, ""] {
                let url = URL(fileURLWithPath: ".build/monitor-truncated-dark-wake-\(UUID().uuidString).json")
                let partial = prefix + darkWake
                let history = HistoryFixture([partial, partial + fullWake], currentDate: current.date)
                var uptime = ContinuousClock.now
                let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil,
                                             loadHistory: history.load, readClock: { (current.date, uptime) })
                monitor.start()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "first read must finish")
                try expect(monitor.forecastStart == nil, "a dark wake supersedes a preceding wake in the same second")
                monitor.refresh()
                try expect(history.readCount == 1 && !monitor.isReadingHistory, "the pending full wake must use backoff")
                uptime = uptime.advanced(by: .seconds(31))
                monitor.refresh()
                try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "retry must finish")
                try expect(monitor.forecastStart?.percent == 75, "retry must recover the later full wake")
            }
        }
    },
    TestCase(name: "blocking history does not occupy the cooperative executor") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-blocking-history-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let independent = DispatchSemaphore(value: 0)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil, loadHistory: {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return PowerHistory(from: "2024-01-01 12:30:00 +0000 Wake Wake from sleep Using Batt (Charge: 75%)",
                                    before: current.date)
            })
            monitor.refresh()
            monitor.recoverHistory()
            let admitted = drainBatteryHistory(until: { started.wait(timeout: .now()) == .success })
            Task.detached(priority: .utility) { independent.signal() }
            let progressed = drainBatteryHistory(until: { independent.wait(timeout: .now()) == .success })
            let stillReading = monitor.isReadingHistory
            release.signal()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "the history read must drain")
            try expect(admitted && stillReading && progressed, "independent Swift work must complete while history I/O is blocked")
            try expect(monitor.forecastStart?.percent == 75, "the returned history must still reach the monitor")
        }
    },
    TestCase(name: "an hour added to the wall clock cannot inflate a one-minute discharge forecast") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-forward-discharge-\(UUID().uuidString).json")
            let current = historyCurrent(80)
            var sample = BatterySample(date: current.date, percent: 80, onBattery: false)
            var uptime = ContinuousClock.now
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in sample }, bootDate: nil, loadHistory: { nil },
                                         readClock: { (sample.date, uptime) })
            monitor.refresh()
            sample = BatterySample(date: current.date.addingTimeInterval(1), percent: 80, onBattery: true)
            uptime = uptime.advanced(by: .seconds(1))
            monitor.refresh()
            try expect(monitor.forecastStart == sample, "the observed unplug must start the forecast")
            sample = BatterySample(date: sample.date.addingTimeInterval(3660), percent: 79, onBattery: true)
            uptime = uptime.advanced(by: .seconds(60))
            monitor.refresh()
            try expect(monitor.forecastStart == nil, "a wall-clock jump invalidates the time baseline")
            try expect(SessionStore.load(from: url)?.session?.start == sample, "the corrected baseline must be saved")
        }
    },
    TestCase(name: "an hour added to the wall clock cannot inflate a one-minute charging forecast") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-forward-charge-\(UUID().uuidString).json")
            var sample = BatterySample(date: historyCurrent().date, percent: 60, onBattery: false, isCharging: true)
            var uptime = ContinuousClock.now
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in sample }, bootDate: nil, loadHistory: { nil },
                                         readClock: { (sample.date, uptime) })
            monitor.refresh()
            sample = BatterySample(date: sample.date.addingTimeInterval(3660), percent: 61, onBattery: false, isCharging: true)
            uptime = uptime.advanced(by: .seconds(60))
            monitor.refresh()
            try expect(monitor.chargingSession?.secondsPerPoint(at: sample) == nil, "pre-adjustment charge cannot supply a rate")
            sample = BatterySample(date: sample.date.addingTimeInterval(60), percent: 62, onBattery: false, isCharging: true)
            uptime = uptime.advanced(by: .seconds(60))
            monitor.refresh()
            try expectNear(monitor.chargingSession?.secondsPerPoint(at: sample), 60, "the new charge rate uses one minute")
        }
    },
    TestCase(name: "a wall-clock jump during the charging read cannot seed calibration with the old date") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-charge-read-clock-\(UUID().uuidString).json")
            var wall = historyCurrent().date
            var uptime = ContinuousClock.now
            var percent = 60.0
            var adjustWhileReading = false
            let monitor = BatteryMonitor(stateURL: url, readSample: { date in
                let reading = BatterySample(date: date, percent: percent, onBattery: false, isCharging: true)
                if adjustWhileReading { wall = wall.addingTimeInterval(3600) }
                return reading
            }, bootDate: nil, loadHistory: { nil }, readClock: { (wall, uptime) })
            monitor.refresh()

            wall = wall.addingTimeInterval(60)
            uptime = uptime.advanced(by: .seconds(60))
            percent = 61
            adjustWhileReading = true
            monitor.refresh()
            adjustWhileReading = false

            wall = wall.addingTimeInterval(60)
            uptime = uptime.advanced(by: .seconds(60))
            percent = 62
            monitor.refresh()
            try expect(monitor.chargingSession?.start.date == wall, "the first reading in the new clock range must start calibration")
            let postAdjustment = BatterySample(date: wall.addingTimeInterval(60), percent: 63, onBattery: false, isCharging: true)
            try expectNear(monitor.chargingSession?.secondsPerPoint(at: postAdjustment), 60,
                           "elapsed charging time must exclude the one-hour jump")
        }
    },
    TestCase(name: "a wall-clock jump during the discharge read cannot seed a session with the old date") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-discharge-read-clock-\(UUID().uuidString).json")
            var wall = historyCurrent().date
            var uptime = ContinuousClock.now
            var percent = 80.0
            var onBattery = false
            var adjustWhileReading = false
            let monitor = BatteryMonitor(stateURL: url, readSample: { date in
                let reading = BatterySample(date: date, percent: percent, onBattery: onBattery)
                if adjustWhileReading { wall = wall.addingTimeInterval(3600) }
                return reading
            }, bootDate: nil, loadHistory: { nil }, readClock: { (wall, uptime) })
            monitor.refresh()

            wall = wall.addingTimeInterval(1)
            uptime = uptime.advanced(by: .seconds(1))
            onBattery = true
            monitor.refresh()
            try expect(monitor.forecastStart?.date == wall, "a live unplug establishes the original forecast")

            wall = wall.addingTimeInterval(60)
            uptime = uptime.advanced(by: .seconds(60))
            percent = 79
            adjustWhileReading = true
            monitor.refresh()
            adjustWhileReading = false

            wall = wall.addingTimeInterval(60)
            uptime = uptime.advanced(by: .seconds(60))
            percent = 78
            monitor.refresh()
            try expect(monitor.tracker.session?.start.date == wall, "post-adjustment discharge totals begin in the new clock range")
            try expect(monitor.forecastStart == nil, "the pre-adjustment unplug cannot calibrate the forecast")
        }
    },
    TestCase(name: "elapsed sleep advances both clocks") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-elapsed-sleep-\(UUID().uuidString).json")
            let initial = historyCurrent(80)
            var sample = initial
            var uptime = ContinuousClock.now
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in sample }, bootDate: nil, loadHistory: { nil },
                                         readClock: { (sample.date, uptime) })
            monitor.refresh()
            sample = BatterySample(date: sample.date.addingTimeInterval(7200), percent: 79, onBattery: true)
            uptime = uptime.advanced(by: .seconds(7200))
            monitor.refresh(wakeDate: sample.date)
            try expect(monitor.tracker.session?.start == initial, "real sleep must preserve discharge totals")
            try expect(monitor.forecastStart == sample, "wake must still establish its own forecast")
        }
    },
    TestCase(name: "a single ULP decrease cannot reset charging calibration") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-charge-noise-\(UUID().uuidString).json")
            let start = BatterySample(date: historyCurrent().date, percent: 60, onBattery: false, isCharging: true)
            var sample = start
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in sample }, bootDate: nil)
            monitor.refresh()
            sample = BatterySample(date: start.date.addingTimeInterval(60), percent: 61, onBattery: false, isCharging: true)
            monitor.refresh()
            sample = BatterySample(date: start.date.addingTimeInterval(61), percent: 61.0.nextDown, onBattery: false, isCharging: true)
            monitor.refresh()
            try expectNear(monitor.chargingSession?.secondsPerPoint(at: sample), 61, "rounding noise must preserve the calibrated rate")
        }
    },
    TestCase(name: "native monitor refresh publishes the battery reading and persists its session") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-\(UUID().uuidString).json")
            let reading = historyCurrent(71)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading })
            monitor.refresh()
            try expect(monitor.sample == reading, "refresh must publish the battery reading")
            try expect(SessionStore.load(from: url)?.lastSample?.percent == monitor.sample?.percent, "refresh must persist the latest measured charge")
        }
    },
    TestCase(name: "native monitor loads a valid persisted baseline") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-load-\(UUID().uuidString).json")
            var tracker = SessionTracker()
            tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true))
            try SessionStore.save(tracker, to: url)
            let monitor = BatteryMonitor(stateURL: url)
            try expect(monitor.tracker.session?.start.percent == 80, "launch must recover valid saved state")
        }
    },
    TestCase(name: "native monitor persists a wake with unchanged battery charge") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-wake-\(UUID().uuidString).json")
            let current = historyCurrent(75)
            let previousWake = BatterySample(date: current.date.addingTimeInterval(-600), percent: 75, onBattery: true)
            var tracker = SessionTracker()
            tracker.update(previousWake, wakeDate: previousWake.date)
            tracker.update(current)
            try SessionStore.save(tracker, to: url)
            var reading = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == previousWake, "monitor must load the previously saved wake")

            let nextWake = BatterySample(date: current.date.addingTimeInterval(1), percent: 75, onBattery: true)
            reading = nextWake
            monitor.refresh(wakeDate: nextWake.date)
            try expect(monitor.tracker.forecastStart == nextWake, "the wake must start a new forecast")
            try expect(SessionStore.load(from: url)?.forecastStart == nextWake, "an unchanged charge must not suppress persistence")
        }
    },
    TestCase(name: "native monitor invalidates a stored forecast from before system boot") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-boot-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let previousWake = BatterySample(date: current.date.addingTimeInterval(-600), percent: 75, onBattery: true)
            let bootDate = current.date.addingTimeInterval(-300)
            var tracker = SessionTracker()
            tracker.update(previousWake, wakeDate: previousWake.date)
            try SessionStore.save(tracker, to: url)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: bootDate)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == nil, "preboot measurements cannot be used while history is unavailable")
        }
    },
    TestCase(name: "native monitor does not use a delayed reading as the wake start") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-missed-wake-\(UUID().uuidString).json")
            let current = historyCurrent(75)
            var reading: BatterySample? = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil)
            monitor.refresh()

            reading = nil
            monitor.refresh(wakeDate: current.date.addingTimeInterval(1))
            try expect(monitor.sample == nil, "the reading at wake must be unavailable")
            reading = BatterySample(date: current.date.addingTimeInterval(600), percent: 70, onBattery: true)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == nil, "a later timer reading cannot stand in for the missing wake sample")
        }
    },
    TestCase(name: "native monitor recovers a missed wake on the first later battery sample") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-delayed-history-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let loggedWake = current.date.addingTimeInterval(-1800)
            var reading: BatterySample?
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                PowerHistory(from: "2024-01-01 12:30:00 +0000 Wake Wake from sleep Using Batt(Charge: 75%)",
                             before: current.date)
            })
            monitor.start()
            monitor.refresh(wakeDate: loggedWake.addingTimeInterval(0.4))
            reading = current
            monitor.refresh()
            let deadline = Date().addingTimeInterval(1)
            while monitor.isReadingHistory, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            try expect(monitor.tracker.forecastStart?.date == loggedWake, "the log must supply the wake missed by the reader")
            try expect(monitor.tracker.forecastStart?.percent == 75, "the delayed charge must not replace the logged wake charge")
        }
    },
    TestCase(name: "a logged unplug can recover the forecast after a missed wake on external power") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-missed-wake-unplug-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let wake = current.date.addingTimeInterval(-1800)
            var reading: BatterySample?
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: {
                PowerHistory(from: """
                2024-01-01 12:30:00 +0000 Wake Wake from sleep Using AC (Charge: 78%)
                2024-01-01 12:30:40 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 78%)
                """, before: current.date)
            })
            monitor.start()
            monitor.refresh(wakeDate: wake)
            reading = current
            monitor.refresh()
            let deadline = Date().addingTimeInterval(1)
            while monitor.isReadingHistory, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try expect(monitor.forecastStart?.date == wake.addingTimeInterval(40),
                       "a confirmed unplug after wake can establish the baseline")
        }
    },
    TestCase(name: "startup hides a saved forecast until the power history confirms the gap") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-saved-forecast-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let previousWake = BatterySample(date: current.date.addingTimeInterval(-10800), percent: 90, onBattery: true)
            var tracker = SessionTracker()
            tracker.update(previousWake, wakeDate: previousWake.date)
            try SessionStore.save(tracker, to: url)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil, loadHistory: {
                PowerHistory(from: "2024-01-01 10:00:00 +0000 Wake Wake from sleep Using Batt(Charge: 90%)",
                             before: current.date)
            })
            monitor.start()
            try expect(monitor.forecastStart == nil, "the old forecast must stay hidden during history loading")
            let deadline = Date().addingTimeInterval(1)
            while monitor.isReadingHistory, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try expect(!monitor.isReadingHistory, "the stale history read must finish")
            try expect(monitor.forecastStart == nil, "a log ending at the checkpoint cannot validate a pre-sleep forecast")
            try expect(monitor.tracker.session?.start == previousWake, "the known discharge session must remain available")
        }
    },
    TestCase(name: "an unavailable battery reading hides a forecast until the gap can be checked") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-unchecked-forecast-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let wake = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 80, onBattery: true)
            var reading: BatterySample? = wake
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil, loadHistory: { nil })
            monitor.start()
            monitor.refresh(wakeDate: wake.date)
            try expect(monitor.forecastStart == wake, "the observed wake can start a forecast")
            reading = nil
            monitor.refresh()
            reading = current
            monitor.refresh()
            try expect(monitor.forecastStart == nil, "a missed reading must suspend the earlier forecast")
        }
    },
    TestCase(name: "a pending wake without measurements cannot pin history after a clock rollback") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-pending-clock-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            var tracker = SessionTracker()
            tracker.markWake(at: current.date.addingTimeInterval(3600))
            try SessionStore.save(tracker, to: url)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in current }, bootDate: nil)
            try expect(monitor.tracker.needsWakeHistory, "the pending wake must load before comparison")
            monitor.refresh()
            try expect(!monitor.tracker.needsWakeHistory && monitor.tracker.lastSample == current,
                       "discard the future checkpoint after correcting the clock")
        }
    },
    TestCase(name: "native monitor restarts measurements after the system clock moves backward") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-clock-\(UUID().uuidString).json")
            var reading = historyCurrent(70)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil)
            monitor.refresh()
            reading = BatterySample(date: reading.date.addingTimeInterval(-3600), percent: 70, onBattery: false)
            monitor.refresh()
            try expect(monitor.tracker.session == nil, "AC must end the session after the clock correction")
            try expect(SessionStore.load(from: url)?.lastSample == reading, "the corrected time and AC state must persist")
        }
    },
    TestCase(name: "native monitor does not date an unplug across missing battery readings") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-missed-unplug-\(UUID().uuidString).json")
            let current = historyCurrent(75, onBattery: false)
            var reading: BatterySample? = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: nil)
            monitor.refresh()
            reading = nil
            monitor.refresh()
            reading = BatterySample(date: current.date.addingTimeInterval(600), percent: 70, onBattery: true)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == nil, "a delayed battery reading cannot timestamp a missed power transition")
        }
    },
    TestCase(name: "a live unplug after a clock correction can start a forecast before the old boot time") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-boot-correction-\(UUID().uuidString).json")
            let boot = historyCurrent().date
            var reading = BatterySample(date: boot.addingTimeInterval(60), percent: 80, onBattery: false)
            let monitor = BatteryMonitor(stateURL: url, readSample: { _ in reading }, bootDate: boot)
            monitor.refresh()
            reading = BatterySample(date: boot.addingTimeInterval(-3600), percent: 80, onBattery: false)
            monitor.refresh()
            let unplugged = BatterySample(date: boot.addingTimeInterval(-3540), percent: 79, onBattery: true)
            reading = unplugged
            monitor.refresh()
            reading = BatterySample(date: boot.addingTimeInterval(-3480), percent: 78, onBattery: true)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == unplugged, "later readings must preserve a live unplug after clock correction")
        }
    },
    TestCase(name: "unchanged external power refresh retries a failed session save") {
        try MainActor.assumeIsolated {
            let parent = URL(fileURLWithPath: ".build/storage-retry-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: parent)
            defer { try? FileManager.default.removeItem(at: parent) }
            let stateFile = parent.appending(path: "session.json")
            let sample = historyCurrent(70, onBattery: false)
            let monitor = BatteryMonitor(stateURL: stateFile, readSample: { _ in sample }, bootDate: nil)
            monitor.refresh()
            try expect(monitor.notice != nil, "a failed save must report an error")
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            monitor.refresh()
            try expect(monitor.notice == nil, "a successful retry must clear the error")
            try expect(SessionStore.load(from: stateFile)?.lastSample == sample, "the unchanged reading must be saved on retry")
        }
    },
    TestCase(name: "duration display converts seconds into readable time without misleading precision") {
        try expect(DurationText.string(10800) == "3h 0m", "three hours must display as hours and minutes")
        try expect(DurationText.string(3660) == "1h 1m", "hour and minute should both be visible")
        try expect(DurationText.string(0) == "0m", "zero must not look unavailable")
        try expect(DurationText.string(30) == "<1m", "seconds must not look like precise long-term predictions")
        try expect(DurationText.string(nil) == "—", "missing prediction must be clearly unavailable")
        try expect(DurationText.string(.infinity) == "—", "invalid prediction must not overflow formatting")
    }
]
