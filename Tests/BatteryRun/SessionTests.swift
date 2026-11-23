import Foundation

let sessionTests = [
    TestCase(name: "80 to 60 in one hour predicts three hours remaining and five hours total") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: true)
        let estimate = DischargeSession(start: start, origin: .observed).estimate(at: current)
        try expectNear(estimate?.remaining, 10800, "remaining must be 10800 seconds")
        try expectNear(estimate?.fullDuration, 18000, "100 to 0 must be 18000 seconds")
        try expectNear(estimate?.ratePerHour, 20, "average drain must be 20 percentage points per hour")
    },
    TestCase(name: "unchanged or rising charge produces no prediction") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        for percent in [80.0, 81, 90] {
            let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: percent, onBattery: true)
            try expect(DischargeSession(start: start, origin: .observed).estimate(at: current) == nil, "no discharge must not yield an estimate")
        }
    },
    TestCase(name: "AC power suppresses discharge forecasts") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: false)
        try expect(DischargeSession(start: start, origin: .observed).estimate(at: current) == nil, "AC must suppress forecast")
    },
    TestCase(name: "invalid percentages and clock reversal never produce estimates") {
        for percent in [-1.0, 101, .nan, .infinity] {
            let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: percent, onBattery: true)
            let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: true)
            try expect(DischargeSession(start: start, origin: .observed).estimate(at: current) == nil, "invalid start percentage")
        }
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        for time in [999.0, 1000, 1059] {
            let current = BatterySample(date: Date(timeIntervalSince1970: time), percent: 60, onBattery: true)
            try expect(DischargeSession(start: start, origin: .observed).estimate(at: current) == nil, "at least one minute of valid elapsed time is needed")
        }
    },
    TestCase(name: "sub-percent changes wait for a useful measurement") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 79.5, onBattery: true)
        try expect(DischargeSession(start: start, origin: .observed).estimate(at: current) == nil, "at least one percentage point is needed")
    },
    TestCase(name: "a one-point discharge remains usable after normalization rounding") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 56.99999999999999, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 1060), percent: 56, onBattery: true)
        let estimate = DischargeSession(start: start, origin: .observed).estimate(at: current)
        try expectNear(estimate?.fullDuration, 6000, "one point per minute predicts 100 minutes total")
    },
    TestCase(name: "discharge extrapolates the interval between the supplied readings") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 100, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 29800), percent: 80, onBattery: true)
        let estimate = DischargeSession(start: start, origin: .history).estimate(at: current)
        try expectNear(estimate?.fullDuration, 144000, "eight elapsed hours with 20 points consumed means forty hours total")
    },
    TestCase(name: "zero remaining charge has zero time remaining") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 20, onBattery: true)
        let current = BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 0, onBattery: true)
        try expectNear(DischargeSession(start: start, origin: .observed).estimate(at: current)?.remaining, 0, "empty battery has no remaining time")
    },
    TestCase(name: "unplugging starts a precisely observed session") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: false))
        let unplugged = BatterySample(date: Date(timeIntervalSince1970: 1060), percent: 80, onBattery: true)
        tracker.update(unplugged)
        try expect(tracker.session?.start == unplugged, "must anchor to the observed unplug")
        try expect(tracker.session?.origin == .observed, "observed transition is exact")
    },
    TestCase(name: "AC interrupts a session and the next unplug starts a new one") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true))
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: false))
        try expect(tracker.session == nil, "AC must end the previous session")
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 8200), percent: 90, onBattery: true))
        try expect(tracker.session?.start.percent == 90, "new session must not include earlier discharge")
    },
    TestCase(name: "a charge increase restarts monitoring instead of mixing charging with discharge") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true))
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: true))
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 8200), percent: 65, onBattery: true))
        try expect(tracker.session?.start.percent == 65, "increase must reset the baseline")
        try expect(tracker.session?.origin == .monitoring, "unobserved charge boundary cannot claim an exact start")
    },
    TestCase(name: "persisted tracking keeps the original baseline on reopening") {
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true))
        let encoded = try JSONEncoder().encode(tracker)
        var restored = try JSONDecoder().decode(SessionTracker.self, from: encoded)
        restored.update(BatterySample(date: Date(timeIntervalSince1970: 4600), percent: 60, onBattery: true))
        try expectNear(restored.session?.estimate(at: restored.lastSample!)?.remaining, 10800, "persistence must retain the session baseline")
    },
    TestCase(name: "invalid or older observations cannot overwrite a valid session") {
        var tracker = SessionTracker()
        let start = BatterySample(date: Date(timeIntervalSince1970: 1000), percent: 80, onBattery: true)
        tracker.update(start)
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 999), percent: 90, onBattery: false))
        tracker.update(BatterySample(date: Date(timeIntervalSince1970: 4600), percent: .nan, onBattery: true))
        try expect(tracker.session?.start == start, "invalid observation must leave a valid baseline intact")
        try expect(tracker.lastSample == start, "invalid observation must not advance the last observation")
    }
]
