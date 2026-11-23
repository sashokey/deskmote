import Foundation

let dashboardTests = [
    TestCase(name: "dashboard presents session-derived remaining and full durations") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 80, onBattery: true)
        let model = DashboardModel(sample: historyCurrent(), session: DischargeSession(start: start, origin: .observed), forecastStart: start)
        try expect(model.remaining == "3h 0m", "remaining estimate must be visible")
        try expect(model.fullDuration == "5h 0m", "full discharge estimate must be visible")
        try expect(model.startLabel == "Discharge started", "observed unplug may identify the start")
    },
    TestCase(name: "forecasts use the charge measured after the latest wake") {
        let current = historyCurrent(70)
        let unplug = BatterySample(date: current.date.addingTimeInterval(-36000), percent: 90, onBattery: true)
        let wake = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(unplug)
        tracker.update(wake, wakeDate: wake.date)
        let collecting = DashboardModel(sample: wake, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(collecting.remaining == "—" && collecting.fullDuration == "—", "each wake must wait for a new discharge measurement")
        tracker.update(current)
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Wake Wake from sleep Using Batt(Charge: 80%)", current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m", "remaining should use the five points consumed over the half hour after wake")
        try expect(model.fullDuration == "10h 0m", "full runtime should use the same post-wake rate")
        try expect(model.rate == "10%/h", "average drain should use the forecast window")
        try expect(model.startCharge == "90%" && model.chargeUsed == "20%", "session totals should still start at unplug")
    },
    TestCase(name: "startup recovers the latest full wake without using a maintenance wake") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Sleep Using Batt(Charge: 95%)
        2024-01-01 12:10:00 +0000 Wake                 Wake from sleep Using Batt(Charge: 83%)
        2024-01-01 12:30:00 +0000 Wake                 DarkWake to FullWake from sleep Using Batt(Charge: 75%)
        2024-01-01 12:40:00 +0000 DarkWake DarkWake from sleep Using Batt(Charge: 74%)
        """, current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m" && model.fullDuration == "10h 0m", "the full wake should set the charge and elapsed time for both forecasts")
        try expect(model.startCharge == "95%", "history should still recover the original discharge")
    },
    TestCase(name: "startup uses an unplug logged in the same second after the wake") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 12:30:00 +0000 Wake                 Wake from sleep Using Batt(Charge: 80%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 74%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m" && model.fullDuration == "10h 0m", "the newer unplug should set the forecast baseline")
    },
    TestCase(name: "history recovers an unplug missed after an observed wake") {
        let current = historyCurrent(70)
        let wake = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 90, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(wake, wakeDate: wake.date)
        tracker.reconcile(history: """
        2024-01-01 12:29:45 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 74%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m" && model.fullDuration == "10h 0m", "a recovered unplug must take precedence over an older live wake")
    },
    TestCase(name: "startup without a known wake waits for a new discharge measurement") {
        let current = historyCurrent(70)
        let saved = DischargeSession(
            start: BatterySample(date: current.date.addingTimeInterval(-36000), percent: 90, onBattery: true),
            origin: .observed
        )
        var tracker = SessionTracker(session: saved, lastSample: saved.start)
        tracker.reconcile(history: "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80%)", current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "—" && model.fullDuration == "—", "a saved session may include an unobserved sleep")
    },
    TestCase(name: "startup does not recover a forecast across a charge increase after wake") {
        let current = historyCurrent(70)
        let saved = DischargeSession(
            start: BatterySample(date: current.date.addingTimeInterval(-10800), percent: 95, onBattery: true),
            origin: .observed
        )
        var tracker = SessionTracker(session: saved, lastSample: saved.start)
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Wake                 Wake from sleep Using Batt(Charge: 80%)
        2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 60%)
        """, current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "—" && model.fullDuration == "—", "a history ending at a lower charge cannot establish the current discharge")
    },
    TestCase(name: "startup does not use a wake preceding the last sleep") {
        let current = historyCurrent(70)
        for state in ["Sleep", "DarkWake"] {
            var tracker = SessionTracker()
            tracker.reconcile(history: """
            2024-01-01 11:00:00 +0000 Wake Wake from sleep Using Batt(Charge: 90%)
            2024-01-01 12:00:00 +0000 Sleep                Entering \(state) state Using Batt(Charge: 80%)
            2024-01-01 12:00:01 +0000 Wake Requests [process=powerd request=Maintenance]
            2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt(Charge: 75%)
            """, current: current)
            let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
            try expect(model.remaining == "—" && model.fullDuration == "—",
                       "\(state) without a recorded full wake cannot provide a forecast baseline")
        }
    },
    TestCase(name: "startup does not recover a wake from before power history restarted") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Wake                 Wake from sleep Using Batt(Charge: 90%)
        2024-01-01 12:00:00 +0000 Start                powerd process is started
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "—" && model.fullDuration == "—", "a power history restart makes the previous wake unsafe to use")
    },
    TestCase(name: "startup recovers the battery forecast from system boot") {
        let current = historyCurrent(23)
        let boot = Date(timeIntervalSince1970: 1704096000)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 06:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 80%)
        2024-01-01 06:05:00 +0000 Wake Wake from sleep Using Batt(Charge: 80%)
        2024-01-01 08:00:19 +0000 Start powerd process is started
        2024-01-01 08:00:19 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 72%)
        """, current: current, bootDate: boot)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(tracker.forecastStart?.date == boot, "forecast time must be the system boot time")
        try expect(model.forecastStartCharge == "72%", "system startup must supply the forecast charge")
        try expect(model.remaining == "2h 20m", "remaining time must use five hours of battery drain since boot")
        try expect(model.startCharge == "80%", "total discharge still uses the earlier battery session")
    },
    TestCase(name: "a daemon restart in the same boot preserves the latest wake") {
        let current = historyCurrent(70)
        let boot = Date(timeIntervalSince1970: 1704106800)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:15 +0000 Start powerd process is started Using Batt(Charge: 95%)
        2024-01-01 12:30:00 +0000 Wake Wake from sleep Using Batt(Charge: 75%)
        2024-01-01 12:45:00 +0000 Start powerd process is started Using Batt(Charge: 72%)
        """, current: current, bootDate: boot)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m", "only a real system boot takes precedence over an earlier wake")
    },
    TestCase(name: "a later daemon restart cannot supply a missing boot reading") {
        let current = historyCurrent(70)
        let boot = Date(timeIntervalSince1970: 1704106800)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:19 +0000 Start powerd process is started
        2024-01-01 11:01:00 +0000 Start powerd process is started Using Batt(Charge: 85%)
        """, current: current, bootDate: boot)
        try expect(tracker.forecastStart == nil, "only the first startup can establish the boot charge")
    },
    TestCase(name: "a discharge transition can be recovered without a wake") {
        let current = historyCurrent(70)
        let boot = Date(timeIntervalSince1970: 1704106800)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:15 +0000 Start powerd process is started Using Batt(Charge: 95%)
        2024-01-01 12:29:45 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 74%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current, bootDate: boot)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "7h 0m", "the later unplug must be the forecast baseline")
    },
    TestCase(name: "relaunch preserves a confirmed forecast when the log is empty") {
        let current = historyCurrent(70)
        let wake = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(wake, wakeDate: wake.date)
        var restored = try JSONDecoder().decode(SessionTracker.self, from: JSONEncoder().encode(tracker))
        restored.reconcile(history: "", current: current)
        let model = DashboardModel(sample: current, session: restored.session, forecastStart: restored.forecastStart)
        try expect(model.remaining == "7h 0m", "relaunch must continue from the confirmed wake")
    },
    TestCase(name: "launch readings alone never become the start of a forecast") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.update(BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true))
        tracker.update(current)
        let model = DashboardModel(sample: current, session: tracker.session, forecastStart: tracker.forecastStart)
        try expect(model.remaining == "—" && model.forecastStartTime == "—", "an unconfirmed launch measurement is not a forecast start")
    },
    TestCase(name: "missing forecast history has a different explanation from collecting data") {
        let current = historyCurrent(70)
        let session = DischargeSession(start: current, origin: .monitoring)
        let missing = DashboardModel(sample: current, session: session, forecastStart: nil)
        let collecting = DashboardModel(sample: current, session: session, forecastStart: current)
        try expect(missing.explanation != collecting.explanation, "the dashboard must distinguish missing history from an insufficient observation interval")
    },
    TestCase(name: "a wake without a charge reading invalidates the preceding forecast") {
        let current = historyCurrent(70)
        let previousWake = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 80, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(previousWake, wakeDate: previousWake.date)
        tracker.reconcile(history: """
        2024-01-01 12:30:00 +0000 Wake Wake from sleep
        """, current: current)
        try expect(tracker.forecastStart == nil, "a later wake supersedes an older start even without a battery measurement")
    },
    TestCase(name: "stale history cannot restore a boot forecast after a wake without a reading") {
        let current = historyCurrent(70)
        let boot = Date(timeIntervalSince1970: 1704106800)
        let startup = "2024-01-01 11:00:19 +0000 Start powerd process is started Using Batt(Charge: 85%)"
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        \(startup)
        2024-01-01 12:30:00 +0000 Wake Wake from sleep
        """, current: current, bootDate: boot)
        var restored = try JSONDecoder().decode(SessionTracker.self, from: JSONEncoder().encode(tracker))
        restored.reconcile(history: startup, current: current, bootDate: boot)
        try expect(restored.forecastStart == nil, "the persisted wake boundary must reject stale boot history")
    },
    TestCase(name: "a source-only AC event interrupts the forecast") {
        let current = historyCurrent(70)
        let boot = Date(timeIntervalSince1970: 1704106800)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:19 +0000 Start powerd process is started Using Batt(Charge: 85%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
        """, current: current, bootDate: boot)
        try expect(tracker.forecastStart == nil, "a known charging interruption invalidates the earlier forecast without a charge reading")
    },
    TestCase(name: "a source-only AC event ends the previous discharge session") {
        let current = historyCurrent(70)
        let prior = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 85, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(prior)
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 85%)
        2024-01-01 12:20:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        try expect(tracker.session?.start.date == current.date.addingTimeInterval(-1800), "the session starts at the first reading after AC")
        try expect(tracker.session?.start.percent == 75, "previous discharge must not be included")
    },
    TestCase(name: "an unrelated reading in the same second does not supply a missing wake charge") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 12:30:00 +0000 Wake Wake from sleep
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        try expect(tracker.forecastStart == nil, "a wake without its own charge reading cannot start a forecast")
    },
    TestCase(name: "a rounded power sample does not interrupt discharge history") {
        let current = historyCurrent(55.00000000000001)
        let start = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 65, onBattery: true)
        var tracker = SessionTracker(session: DischargeSession(start: start, origin: .observed), lastSample: start)
        tracker.reconcile(history: """
        2024-01-01 12:45:00 +0000 Wake Wake from sleep Using Batt(Charge: 55%)
        """, current: current)
        try expect(tracker.session?.start == start, "sub-ULP variation must preserve the ongoing discharge")
        try expect(tracker.forecastStart?.percent == 55, "the exact logged wake remains an eligible forecast")
    },
    TestCase(name: "a later AC event in the starting second ends a recovered discharge session") {
        let current = historyCurrent(70)
        let started = BatterySample(date: current.date.addingTimeInterval(-3600), percent: 80, onBattery: true)
        var tracker = SessionTracker(session: DischargeSession(start: started, origin: .history), lastSample: started)
        tracker.reconcile(history: """
        2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 80%)
        2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
        2024-01-01 12:01:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        try expect(tracker.session?.start.percent == 75, "the later AC transition must invalidate the old start")
    },
    TestCase(name: "a battery transition during sleep cannot replace a missing wake") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Sleep Entering Sleep state Using AC
        2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt(Charge: 75%)
        """, current: current)
        try expect(tracker.forecastStart == nil, "the start of awake discharge is unknown without a recorded full wake")
    },
    TestCase(name: "widely spaced readings cannot date an unplug") {
        let current = historyCurrent(70)
        var tracker = SessionTracker()
        tracker.reconcile(history: """
        2024-01-01 11:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 85%)
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, current: current)
        try expect(tracker.forecastStart == nil, "unrelated readings cannot locate the unplug within a minute")
    },
    TestCase(name: "a saved wake inside a logged power transition takes precedence") {
        let current = historyCurrent(70)
        let wake = BatterySample(date: current.date.addingTimeInterval(-2400), percent: 75, onBattery: true)
        var tracker = SessionTracker()
        tracker.update(wake, wakeDate: wake.date)
        tracker.reconcile(history: """
        2024-01-01 12:19:50 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 74%)
        2024-01-01 12:20:20 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 74%)
        """, current: current)
        try expect(tracker.forecastStart == wake, "a known event on battery locates the interval more precisely than later log data")
    },
    TestCase(name: "historical and launch-only starts cannot present themselves as exact unplug times") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 80, onBattery: true)
        let historical = DashboardModel(sample: historyCurrent(), session: DischargeSession(start: start, origin: .history), forecastStart: start)
        let monitored = DashboardModel(sample: historyCurrent(), session: DischargeSession(start: start, origin: .monitoring), forecastStart: start)
        try expect(historical.startValue.hasPrefix("≈"), "history must visibly signal uncertainty")
        try expect(monitored.startLabel == "Monitoring since", "launch-only observation cannot claim an unplug time")
    },
    TestCase(name: "dashboard suppresses stale estimates while plugged in") {
        let start = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 80, onBattery: true)
        let model = DashboardModel(sample: historyCurrent(60, onBattery: false), session: DischargeSession(start: start, origin: .history), forecastStart: start)
        try expect(model.remaining == "—", "AC cannot display a running discharge forecast")
        try expect(model.startValue == "—", "AC cannot display an active discharge session")
        try expect(!model.explanation.isEmpty, "AC state must explain why no estimate is shown")
    }
]
