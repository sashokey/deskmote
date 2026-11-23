import Foundation

let runtimeTests = [
    TestCase(name: "history loader reads actual command output") {
        let output = PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["battery history"])
        try expect(output == "battery history", "successful subprocess output must be returned")
    },
    TestCase(name: "history loader rejects a failed subprocess") {
        try expect(PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil, "nonzero exit must not become valid history")
    },
    TestCase(name: "history loader bounds output memory") {
        try expect(PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["too much output"], limit: 4) == nil, "oversized history must fall back safely")
    },
    TestCase(name: "history loader kills a stalled command within its timeout") {
        let start = Date()
        let result = PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
        try expect(result == nil, "timeout must not return valid history")
        try expect(Date().timeIntervalSince(start) < 1, "timeout must stop the child rather than waiting five seconds")
    },
    TestCase(name: "session store writes and reloads a real session file") {
        let url = URL(fileURLWithPath: ".build/state-\(UUID().uuidString).json")
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true))
        try SessionStore.save(tracker, to: url)
        try expect(SessionStore.load(from: url)?.session == tracker.session, "stored state must preserve the real baseline")
    },
    TestCase(name: "session store preserves a valid rounded baseline across restart") {
        let baseline = historyCurrent(55)
        let last = BatterySample(date: baseline.date.addingTimeInterval(60), percent: 55.00000000000001, onBattery: true)
        let session = DischargeSession(start: baseline, origin: .history)
        var tracker = SessionTracker(session: session, lastSample: baseline)
        tracker.reconcile(history: "2024-01-01 13:00:00 +0000 Wake Wake from sleep Using Batt(Charge: 55%)",
                          current: last)
        try expect(tracker.forecastStart == baseline, "the wake record must produce a rounded baseline")
        let url = URL(fileURLWithPath: ".build/rounded-state-\(UUID().uuidString).json")
        try SessionStore.save(tracker, to: url)
        let restored = SessionStore.load(from: url)
        try expect(restored?.session == session && restored?.forecastStart == baseline,
                   "loading must use the same charge comparison as tracking")
    },
    TestCase(name: "a missed wake still awaits a history reading after restart") {
        let current = historyCurrent(70)
        let prior = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 85, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(prior, wakeDate: prior.date)
        tracker.markWake(at: current.date.addingTimeInterval(-90))
        let url = URL(fileURLWithPath: ".build/missed-wake-state-\(UUID().uuidString).json")
        try SessionStore.save(tracker, to: url)
        let restored = SessionStore.load(from: url)
        try expect(restored?.needsWakeHistory == true && restored?.forecastStart == nil,
                   "the monitor must retry delayed history after restart")
        var withoutSample = SessionTracker()
        withoutSample.markWake(at: current.date)
        try SessionStore.save(withoutSample, to: url)
        try expect(SessionStore.load(from: url)?.needsWakeHistory == true,
                   "a wake checkpoint survives even without a previous battery sample")
    },
    TestCase(name: "session store rejects corrupt and invalid persisted state") {
        let url = URL(fileURLWithPath: ".build/corrupt-\(UUID().uuidString).json")
        try Data("invalid state".utf8).write(to: url)
        try expect(SessionStore.load(from: url) == nil, "corrupt state must not prevent launch")
        let invalid = SessionTracker(session: DischargeSession(start: BatterySample(date: Date(), percent: -1, onBattery: true), origin: .observed))
        try JSONEncoder().encode(invalid).write(to: url)
        try expect(SessionStore.load(from: url) == nil, "decoded but invalid state must also be rejected")
    },
    TestCase(name: "history reconciliation discards persisted discharge interrupted while the app was closed") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704103200), percent: 90, onBattery: true))
        let log = """
        2024-01-01 11:00:00 +0000 Sleep Using AC(Charge: 80)
        2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)
        """
        tracker.reconcile(history: log, current: historyCurrent())
        try expectNear(tracker.session?.start.date.timeIntervalSince1970, 1704110400, "known AC interruption must replace the persisted session")
    },
    TestCase(name: "history reconciliation improves a fresh monitoring baseline") {
        var tracker = SessionTracker()
        tracker.update(historyCurrent())
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)", current: historyCurrent())
        try expectNear(tracker.session?.estimate(at: historyCurrent())?.remaining, 10800, "historical baseline must be adopted")
    },
    TestCase(name: "history reconciliation preserves an earlier uninterrupted observed baseline") {
        var tracker = SessionTracker()
        let start = BatterySample(date: Date(timeIntervalSince1970: 1704106800), percent: 90, onBattery: true)
        tracker.update(BatterySample(date: start.date.addingTimeInterval(-60), percent: 90, onBattery: false))
        tracker.update(start)
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)", current: historyCurrent())
        try expect(tracker.session?.start == start, "sparse logs must not overwrite a more complete observed session")
    },
    TestCase(name: "stale history cannot replace a precisely observed newer unplug") {
        var tracker = SessionTracker()
        let start = BatterySample(date: Date(timeIntervalSince1970: 1704112200), percent: 70, onBattery: true)
        tracker.update(BatterySample(date: start.date.addingTimeInterval(-60), percent: 70, onBattery: false))
        tracker.update(start)
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)", current: historyCurrent())
        try expect(tracker.session?.start == start, "a precise live transition takes precedence over an older sparse log")
    },
    TestCase(name: "cold launch after saved AC recovers the discharge that began while the app was closed") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704106800), percent: 80, onBattery: false))
        var restored = try JSONDecoder().decode(SessionTracker.self, from: JSONEncoder().encode(tracker))
        restored.update(historyCurrent())
        try expect(restored.session?.origin != .observed, "saved AC does not establish a live unplug event")
        restored.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)", current: historyCurrent())
        try expectNear(restored.session?.start.date.timeIntervalSince1970, 1704110400, "cold launch must recover the earlier historical discharge")
    },
    TestCase(name: "an unplug during sleep is recovered approximately rather than timed at wake") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704106800), percent: 80, onBattery: false))
        tracker.markObservationGap()
        tracker.update(historyCurrent())
        try expect(tracker.session?.origin != .observed, "wake is not the observed unplug time")
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)", current: historyCurrent())
        try expectNear(tracker.session?.start.date.timeIntervalSince1970, 1704110400, "sleep-time log must recover the earlier start")
    },
    TestCase(name: "stale history cannot cross a known live charge increase even after reopening") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704103200), percent: 90, onBattery: true))
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704106800), percent: 40, onBattery: true))
        let increased = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 65, onBattery: true)
        tracker.update(increased)
        var restored = try JSONDecoder().decode(SessionTracker.self, from: JSONEncoder().encode(tracker))
        restored.reconcile(history: "2024-01-01 10:00:00 +0000 Sleep Using Batt(Charge: 90)", current: historyCurrent())
        try expect(restored.session?.start == increased, "a known charge increase must remain a durable lower bound for recovery")
    },
    TestCase(name: "a known historical charging boundary stays a lower bound for later recovery") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1704103200), percent: 90, onBattery: true))
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Sleep Using AC(Charge: 40)
        2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)
        """, current: historyCurrent())
        tracker.reconcile(history: "2024-01-01 10:00:00 +0000 Sleep Using Batt(Charge: 90)", current: historyCurrent())
        try expectNear(tracker.session?.start.date.timeIntervalSince1970, 1704110400, "later stale reads must not cross a known historical AC boundary")
    }
]
