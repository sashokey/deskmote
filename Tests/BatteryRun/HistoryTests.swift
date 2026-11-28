import Foundation

private let journalStart = Date(timeIntervalSince1970: 1_704_067_200)

func journalReading(_ seconds: Int, _ source: String, _ percent: Int? = nil) -> String {
    let hour = seconds / 3600
    let minute = seconds / 60 % 60
    let second = seconds % 60
    let time = String(format: "%02d:%02d:%02d", hour, minute, second)
    let charge = percent.map { " (Charge: \($0)%)" } ?? ""
    return "2024-01-01 \(time) +0000 Assertions Summary- [System: kCPU] Using \(source)\(charge)"
}

private func project(_ lines: [String], cutoff: Int = 10_800) -> JournalBatteryReport {
    PowerHistory(from: lines.joined(separator: "\n"), before: journalStart.addingTimeInterval(Double(cutoff))).batteryReport()
}

let journalProjectionTests = [
    TestCase(name: "Journal projection does not replay duplicate points within a second") {
        let report = project([
            journalReading(0, "Batt", 80),
            journalReading(60, "Batt", 79),
            journalReading(60, "Batt", 78),
            journalReading(60, "Batt", 79),
        ])
        try expect(report.latest?.percent == 78, "the duplicate must not overwrite the last distinct observation")
        try expectNear(report.estimate?.remainingSeconds, 2340, "a duplicate must not reset the discharge interval")
    },
    TestCase(name: "Journal projection admits a matching full-wake point in the same second") {
        let report = project([
            "2024-01-01 00:00:00 +0000 DarkWake DarkWake from sleep Using Batt (Charge: 80%)",
            "2024-01-01 00:00:00 +0000 Wake DarkWake to FullWake from sleep Using Batt (Charge: 80%)",
            journalReading(60, "Batt", 79),
        ])
        try expect(report.forecastStart?.percent == 80 && report.estimate != nil, "the wake owns a new interval even at the same charge")
    },
    TestCase(name: "Journal projection reads column-padded pmset wake and assertion lines") {
        let report = project([
            "2024-01-01 00:00:00 +0000 Assertions           Summary- [System: PrevIdle] Using Batt(Charge: 92)",
            "2024-01-01 00:01:00 +0000 Sleep                Entering Sleep state Using Batt (Charge: 90%)",
            "2024-01-01 00:10:00 +0000 DarkWake             DarkWake from sleep Using Batt (Charge: 85%)",
            "2024-01-01 00:11:00 +0000 Wake                 DarkWake to FullWake from sleep Using Batt (Charge: 80%)",
            "2024-01-01 00:31:00 +0000 Assertions           Summary- [System: PrevIdle] Using Batt(Charge: 70)",
        ])
        try expect(report.mode == .battery && report.sessionStart?.percent == 92, "column padding does not hide source evidence")
        try expect(report.forecastStart?.percent == 80, "full wake supplies the awake baseline")
        try expectNear(report.estimate?.remainingSeconds, 8400, "the real row layout yields a dated estimate")
    },
    TestCase(name: "Journal projection uses first and last logged points for both directions") {
        let discharge = project([journalReading(0, "Batt", 80), journalReading(60, "Batt", 79), journalReading(1200, "Batt", 70)])
        let charge = project([journalReading(0, "AC", 70), journalReading(60, "AC", 71), journalReading(1200, "AC", 80)])
        try expect(discharge.mode == .battery && charge.mode == .charging, "directions come from the journal")
        try expectNear(discharge.estimate?.remainingSeconds, 8400, "time to empty")
        try expectNear(charge.estimate?.remainingSeconds, 2400, "time to full")
        for report in [discharge, charge] {
            try expectNear(report.estimate?.fullRangeSeconds, 12000, "full-range duration")
            try expectNear(report.estimate?.percentagePointsPerHour, 30, "hourly rate")
            try expect(report.forecastStart?.date == journalStart, "start is the first point")
            try expect(report.latest?.date == journalStart.addingTimeInterval(1200), "end is the last point")
        }
    },
    TestCase(name: "Journal projection has a minimum of one point and sixty seconds") {
        for (source, end) in [("Batt", 69), ("AC", 71)] {
            try expect(project([journalReading(0, source, 70), journalReading(59, source, end)]).estimate == nil, "59 seconds is insufficient")
            try expect(project([journalReading(0, source, 70), journalReading(60, source, end)]).estimate != nil, "60 seconds and one point qualify")
            try expect(project([journalReading(0, source, 70), journalReading(60, source, 70)]).estimate == nil, "flat charge supplies no forecast")
        }
    },
    TestCase(name: "Journal projection remains dated when the window opens hours later") {
        let log = [journalReading(0, "Batt", 80), journalReading(1200, "Batt", 70)]
        try expect(project(log, cutoff: 1200) == project(log), "only advancing the cutoff must leave journal values fixed")
    },
    TestCase(name: "Journal projection clears charge and session on source-only transitions") {
        let lines = [journalReading(0, "Batt", 90), journalReading(600, "Batt", 80), journalReading(600, "AC")]
        let ac = project(lines)
        try expect(ac.mode == .externalPower && ac.latest == nil && ac.sessionStart == nil && ac.estimate == nil, "same-second AC follows the battery reading")
        let resumed = project(lines + [journalReading(700, "Batt", 79), journalReading(760, "Batt", 78)])
        try expect(resumed.sessionStart?.percent == 79 && !resumed.sessionStartIsApproximate, "the source switch dates the session")
        let incomplete = project(lines + [journalReading(700, "Batt"), journalReading(760, "Batt", 78)])
        try expect(incomplete.sessionStartIsApproximate && incomplete.estimate == nil, "source-only start dates no charge")
    },
    TestCase(name: "Journal projection separates daemon starts and accepted clock rollbacks") {
        let earlier = [journalReading(0, "Batt", 90), journalReading(1200, "Batt", 80)]
        let rollback = project(earlier + [journalReading(600, "Batt", 75)])
        try expect(rollback.sessionStart?.percent == 75 && rollback.estimate == nil, "clock rollback starts a fresh session")
        let restart = project(earlier + ["2024-01-01 00:21:00 +0000 Start powerd process is started", journalReading(1320, "Batt", 75)])
        try expect(restart.sessionStart?.percent == 75 && restart.estimate == nil, "daemon start clears past evidence")
    },
    TestCase(name: "Journal projection ignores future and unrelated records before updating chronology") {
        let lines = [journalReading(0, "Batt", 80), journalReading(7200, "AC", 100),
                     "2024-01-01 01:00:00 +0000 Wake Requests Using AC",
                     "2024-01-01 01:00:00 +0000 Sleep Unrecognized event Using AC (Charge: 99%)",
                     "2024-01-01 01:00:00 +0000 Assertions Created description Using AC (Charge: 99%)",
                     journalReading(1200, "Batt", 70)]
        try expectNear(project(lines, cutoff: 4000).estimate?.remainingSeconds, 8400, "irrelevant chronology cannot break an awake interval")
        try expect(project(["unparseable journal"]).mode == .unknown, "no supported observation yields an unknown source")
        let badCharge = project([journalReading(0, "AC", 101)])
        try expect(badCharge.mode == .externalPower && badCharge.latest == nil, "out-of-range charge is unavailable")
    },
    TestCase(name: "Journal projection starts the forecast after full wake in file order") {
        let older = [journalReading(0, "Batt", 90), journalReading(600, "Batt", 80)]
        let sleep = "2024-01-01 00:11:00 +0000 Sleep Entering Sleep state Using Batt (Charge: 79%)"
        let darkWake = "2024-01-01 00:20:00 +0000 DarkWake DarkWake from Normal Sleep Using Batt (Charge: 78%)"
        let wake = "2024-01-01 00:20:00 +0000 Wake DarkWake to FullWake from Normal Sleep"
        let waiting = project(older + [sleep, darkWake, wake])
        try expect(waiting.sessionStart?.percent == 90 && waiting.latest?.percent == 78, "same-source wake keeps dated history")
        try expect(waiting.forecastStart == nil && waiting.estimate == nil, "dark wake is not an awake forecast point")
        let awake = project(older + [sleep, darkWake, wake, journalReading(1200, "Batt", 77), journalReading(1260, "Batt", 76)])
        try expect(awake.forecastStart?.percent == 77 && awake.estimate != nil, "post-wake event in the same second can anchor")
        let asleep = project(older + [sleep, journalReading(720, "Batt", 78), journalReading(780, "Batt", 77)])
        try expect(asleep.estimate == nil, "even summaries cannot forecast before full wake")
    },
    TestCase(name: "Journal projection resets after a direction reversal and suppresses paused AC") {
        let gain = [journalReading(0, "AC", 70), journalReading(600, "AC", 80)]
        try expect(project(gain + [journalReading(600, "AC", 80)]).estimate != nil, "same-second duplicate is not a plateau")
        let paused = project(gain + [journalReading(660, "AC", 80)])
        try expect(paused.mode == .externalPower && paused.estimate == nil, "flat distinct-time AC readings imply no future gain")
        let decline = project(gain + [journalReading(660, "AC", 79), journalReading(720, "AC", 80)])
        try expect(decline.forecastStart?.percent == 79, "AC decline resets directional start")
        let riseOnBattery = project([journalReading(0, "Batt", 90), journalReading(60, "Batt", 89), journalReading(120, "Batt", 90)])
        try expect(riseOnBattery.forecastStart?.date == journalStart.addingTimeInterval(120) && riseOnBattery.estimate == nil, "battery rise resets directional start")
    },
    TestCase(name: "Journal projection shows zero at awake full charge and ends extrapolation on a plateau") {
        let gain = [journalReading(0, "AC", 90), journalReading(600, "AC", 100)]
        let full = project(gain)
        try expect(full.mode == .charged && full.estimate?.remainingSeconds == 0, "full charge has zero remaining")
        try expectNear(full.estimate?.fullRangeSeconds, 6000, "first rise retains full-range evidence")
        let steady = project(gain + [journalReading(660, "AC", 100)])
        try expect(steady.estimate?.remainingSeconds == 0 && steady.estimate?.fullRangeSeconds == nil, "full plateau retains only the reported completion")
        let asleep = project(gain + ["2024-01-01 00:11:00 +0000 Sleep Entering Sleep state Using AC (Charge: 100%)"])
        try expect(asleep.estimate == nil, "sleep invalidates an awake estimate even at 100%")
    },
]
