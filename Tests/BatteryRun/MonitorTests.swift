import Foundation

let monitorTests = [
    TestCase(name: "native monitor refresh publishes the battery reading and persists its session") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-\(UUID().uuidString).json")
            let reading = historyCurrent(71)
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading })
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil)
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { current }, bootDate: bootDate)
            monitor.refresh()
            try expect(monitor.tracker.forecastStart == nil, "preboot measurements cannot be used while history is unavailable")
        }
    },
    TestCase(name: "native monitor does not use a delayed reading as the wake start") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/monitor-missed-wake-\(UUID().uuidString).json")
            let current = historyCurrent(75)
            var reading: BatterySample? = current
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil)
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil, loadHistory: {
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil, loadHistory: {
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { current }, bootDate: nil, loadHistory: {
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil, loadHistory: { nil })
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { current }, bootDate: nil)
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil)
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: nil)
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
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading }, bootDate: boot)
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
            let monitor = BatteryMonitor(stateURL: stateFile, readSample: { sample }, bootDate: nil)
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
