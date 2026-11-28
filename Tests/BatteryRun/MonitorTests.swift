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

let journalRefreshTests = [
    TestCase(name: "Journal refresh coalesces superseded requests and reads off main") {
        try MainActor.assumeIsolated {
            let calls = Mutex((journal: 0, watts: 0, allOffMain: true))
            let firstStarted = DispatchSemaphore(value: 0)
            let finishFirst = DispatchSemaphore(value: 0)
            let secondStarted = DispatchSemaphore(value: 0)
            let finishSecond = DispatchSemaphore(value: 0)
            defer { finishFirst.signal(); finishSecond.signal() }
            let monitor = BatteryMonitor(readJournal: {
                let count = calls.withLock { state in
                    state.journal += 1
                    state.allOffMain = state.allOffMain && !Thread.isMainThread
                    return state.journal
                }
                if count == 1 {
                    firstStarted.signal()
                    _ = finishFirst.wait(timeout: .now() + 3)
                } else {
                    secondStarted.signal()
                    _ = finishSecond.wait(timeout: .now() + 3)
                }
                return journalReading(0, "Batt", count == 1 ? 90 : 70)
            }, readWatts: {
                calls.withLock { state in
                    state.watts += 1
                    state.allOffMain = state.allOffMain && !Thread.isMainThread
                    return PowerWatts(battery: state.watts == 1 ? -9 : -7, input: nil)
                }
            })
            try expect(calls.withLock { $0.journal == 0 && $0.watts == 0 }, "initialization performs no reads")
            monitor.refresh()
            try expect(drainBatteryHistory(until: { firstStarted.wait(timeout: .now()) == .success }), "first request starts")
            monitor.refresh()
            monitor.refresh()
            monitor.refresh()
            finishFirst.signal()
            try expect(drainBatteryHistory(until: { secondStarted.wait(timeout: .now()) == .success }), "pending request starts")
            try expect(monitor.snapshot == nil, "superseded snapshot was never published")
            try expect(monitor.isReadingHistory, "loading stays active through coalescing")
            finishSecond.signal()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "latest refresh completes")
            try expect(monitor.snapshot?.report?.latest?.percent == 70, "newest journal result wins")
            try expectNear(monitor.snapshot?.watts.battery, -7, "latest watts publish with the newest journal")
            try expect(calls.withLock { $0.journal == 2 && $0.watts == 2 && $0.allOffMain }, "one pending refresh and both readers off main")
        }
    },
    TestCase(name: "Journal refresh uses the same dated estimate with changing watts and clears a failed read") {
        try MainActor.assumeIsolated {
            let sequence = Mutex(0)
            let journal = [journalReading(0, "Batt", 80), journalReading(1200, "Batt", 70)].joined(separator: "\n")
            let monitor = BatteryMonitor(readJournal: {
                sequence.withLock { count in
                    count += 1
                    return count < 3 ? journal : nil
                }
            }, readWatts: { PowerWatts(battery: sequence.withLock { -Double($0) }, input: nil) })
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "first refresh completes")
            let first = monitor.snapshot?.report
            try expectNear(first?.estimate?.remainingSeconds, 8400, "uses both historical observations")
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "repeat refresh completes")
            try expect(monitor.snapshot?.report == first, "report is fully independent of watts and request time")
            try expectNear(monitor.snapshot?.watts.battery, -2, "watts have refreshed")
            monitor.refresh()
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "failed read completes")
            try expect(monitor.snapshot?.report == nil, "failure clears previous journal results")
            try expectNear(monitor.snapshot?.watts.battery, -3, "independent watts are still shown")
        }
    },
]
