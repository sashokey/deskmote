import Foundation

func historyCurrent(_ percent: Double = 60, onBattery: Bool = true) -> BatterySample {
    BatterySample(date: Date(timeIntervalSince1970: 1704114000), percent: percent, onBattery: onBattery)
}

let historyTests = [
    TestCase(name: "a real wake boundary recorded after a clock rollback starts a new history range") {
        let current = historyCurrent(70)
        let history = PowerHistory(from: """
        2024-01-01 13:30:00 +0000 Sleep Entering Sleep state Using AC
        2024-01-01 12:30:00 +0000 Wake Wake from sleep Using Batt (Charge: 75%)
        """, before: current.date)
        let forecast = history.recoverForecast(at: current, bootDate: nil, historyFloor: nil, forecastFloor: nil, saved: nil)
        try expect(forecast.start?.percent == 75, "a future old record must not discard a newer wake")
    },
    TestCase(name: "power-source summaries after a clock rollback establish the current discharge") {
        let current = historyCurrent(70)
        let history = PowerHistory(from: """
        2024-01-01 12:50:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 90%)
        2024-01-01 12:15:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
        2024-01-01 12:20:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 80%)
        """, before: current.date)
        try expect(history.recoverSession(at: current).session?.start.percent == 80,
                   "the newer unplug belongs to the current clock range")
    },
    TestCase(name: "dark wake measurement cannot establish a forecast for the following full wake in the same second") {
        let current = historyCurrent(70)
        let history = PowerHistory(from: """
        2024-01-01 12:29:50 +0000 Sleep Entering Sleep state Using AC
        2024-01-01 12:30:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 75%)
        2024-01-01 12:30:00 +0000 Wake DarkWake to FullWake from sleep
        """, before: current.date)
        let forecast = history.recoverForecast(at: current, bootDate: nil, historyFloor: nil, forecastFloor: nil, saved: nil)
        try expect(forecast.start == nil, "only an observation at or after the full wake is eligible")
    },
    TestCase(name: "power evidence must extend beyond the last observation to validate a gap") {
        let current = historyCurrent()
        let checkpoint = current.date.addingTimeInterval(-1800)
        let first = "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 90%)"
        let stale = PowerHistory(from: first, before: current.date)
        let spanning = PowerHistory(from: first + "\n2024-01-01 12:45:00 +0000 Wake Wake from sleep Using Batt(Charge: 70%)",
                                    before: current.date)
        try expect(!stale.covers(checkpoint), "a log ending before the observation cannot cover the gap")
        try expect(spanning.covers(checkpoint), "observations both before and after the checkpoint cover the gap")
    },
    TestCase(name: "an AC record later in the forecast start second clears the saved baseline") {
        let current = historyCurrent(70)
        let history = PowerHistory(from: """
        2024-01-01 12:00:00 +0000 Wake Wake from sleep Using Batt(Charge: 80%)
        2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC
        2024-01-01 12:02:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 75%)
        """, before: current.date)
        for offset in [0.0, 0.4] {
            let saved = BatterySample(date: current.date.addingTimeInterval(-3600 + offset), percent: 80, onBattery: true)
            let forecast = history.recoverForecast(at: current, bootDate: nil, historyFloor: saved.date,
                                                   forecastFloor: nil, saved: saved)
            try expect(forecast.start == nil, "the following AC record must invalidate the wake baseline")
            let existing = DischargeSession(start: saved, origin: .observed)
            let recovered = history.recoverSession(at: current, since: saved.date, replacing: existing)
            try expect(recovered.interruption != nil, "the session must record the AC interruption too")
        }
    },
    TestCase(name: "assertion descriptions cannot assert a power source") {
        let log = """
        2024-01-01 11:00:00 +0000 Wake Wake from sleep Using Batt (Charge: 90%)
        2024-01-01 12:00:00 +0000 Assertions PID 42(Fixture) Created PreventUserIdleSystemSleep "Using AC" 00:00:00 id:0x0
        2024-01-01 12:30:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt (Charge: 70%)
        """
        let current = historyCurrent()
        let history = PowerHistory(from: log, before: current.date)
        try expect(history.recoverSession(at: current).session?.start.percent == 90, "keep the first battery observation")
        try expect(history.recoverForecast(at: current, bootDate: nil, historyFloor: nil, forecastFloor: nil,
                                           saved: nil).start?.percent == 90, "keep the wake baseline")
    },
    TestCase(name: "history uses the battery segment after the latest AC boundary") {
        let log = """
        2024-01-01 09:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 95)
        2024-01-01 11:00:00 +0000 Assertions Summary- [System: PrevIdle] Using AC(Charge: 70)
        2024-01-01 12:00:00 +0000 Assertions Summary- [System: PrevIdle] Using Batt(Charge: 80)
        2024-01-01 12:30:00 +0000 Sleep Using BATT (Charge:70%)
        """
        let session = PowerHistory.recover(from: log, current: historyCurrent())
        try expectNear(session?.start.date.timeIntervalSince1970, 1704110400, "must start at 12:00, after AC")
        try expect(session?.origin == .history, "historical start must be marked approximate")
        try expectNear(session?.estimate(at: historyCurrent())?.remaining, 10800, "must use the new 80 percent baseline")
    },
    TestCase(name: "truncated history is usable only as an approximate observation") {
        let log = "2024-01-01 12:00:00 +0000 Sleep Using Batt (Charge:80%)"
        let session = PowerHistory.recover(from: log, current: historyCurrent())
        try expect(session?.start.percent == 80, "known earlier discharge should be usable")
        try expect(session?.origin == .history, "must not claim an exact unplug time")
    },
    TestCase(name: "latest AC with no later battery entry cannot recover the old session") {
        let log = """
        2024-01-01 11:00:00 +0000 Sleep Using Batt(Charge: 80)
        2024-01-01 12:00:00 +0000 Sleep Using AC(Charge: 60)
        """
        try expect(PowerHistory.recover(from: log, current: historyCurrent()) == nil, "must not reuse discharge before AC")
    },
    TestCase(name: "malformed future and out-of-order records cannot corrupt the current segment") {
        let log = """
        invalid Using Batt(Charge: 100)
        2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)
        2024-01-01 11:00:00 +0000 Sleep Using AC(Charge: 90)
        2024-01-01 14:00:00 +0000 Sleep Using AC(Charge: 60)
        2024-01-01 12:30:00 +0000 Sleep Using Batt(Charge: 999)
        """
        try expect(PowerHistory.recover(from: log, current: historyCurrent())?.start.percent == 80, "invalid records must not reset valid history")
    },
    TestCase(name: "a battery charge increase invalidates the preceding historical baseline") {
        let log = """
        2024-01-01 10:00:00 +0000 Sleep Using Batt(Charge: 90)
        2024-01-01 11:00:00 +0000 Sleep Using Batt(Charge: 40)
        2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 80)
        """
        try expect(PowerHistory.recover(from: log, current: historyCurrent())?.start.percent == 80, "unobserved charging must not be included")
    },
    TestCase(name: "AC now or a current charge above the latest record rejects recovery") {
        let log = "2024-01-01 12:00:00 +0000 Sleep Using Batt(Charge: 40)"
        try expect(PowerHistory.recover(from: log, current: historyCurrent()) == nil, "stale history with increased charge must be rejected")
        try expect(PowerHistory.recover(from: log, current: historyCurrent(30, onBattery: false)) == nil, "AC has no active discharge session")
    }
]
