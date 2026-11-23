import Foundation

struct DashboardModel {
    let sample: BatterySample?
    let session: DischargeSession?
    let forecastStart: BatterySample?
    var chargingSession: ChargingSession? = nil

    var mode: BatteryMode? { sample?.mode }
    var isCharging: Bool { mode == .charging }
    var isCompact: Bool { mode == .idle }
    var activeSession: DischargeSession? { sample?.onBattery == true ? session : nil }
    private var activeForecastStart: BatterySample? { activeSession == nil ? nil : forecastStart }
    private var chargingStart: BatterySample? { isCharging ? chargingSession?.start : nil }
    private var sessionStart: BatterySample? { chargingStart ?? activeSession?.start }
    private var forecastBaseline: BatterySample? { isCharging ? chargingStart : activeForecastStart }
    private var chargingSecondsPerPoint: TimeInterval? {
        guard isCharging, let sample else { return nil }
        return chargingSession?.secondsPerPoint(at: sample)
    }
    private var fullChargingDuration: TimeInterval? {
        guard let sample, let chargingStart, let seconds = chargingSecondsPerPoint else { return nil }
        let remaining = sample.timeToFull ?? ((100 - sample.percent) * seconds)
        return chargingStart.percent * seconds + sample.date.timeIntervalSince(chargingStart.date) + remaining
    }
    var estimate: DischargeEstimate? {
        guard let sample, let forecastStart else { return nil }
        return activeSession?.estimate(at: sample, since: forecastStart)
    }
    var remaining: String { DurationText.string(isCharging ? sample?.timeToFull : estimate?.remaining) }
    var fullDuration: String {
        guard isCharging else { return DurationText.string(estimate?.fullDuration) }
        let duration = DurationText.string(fullChargingDuration)
        return duration == "—" ? duration : "≈ " + duration
    }
    var fullChargingNote: String? {
        guard isCharging else { return nil }
        guard fullChargingDuration != nil else { return "Waiting for charging measurements." }
        if sample?.timeToFull != nil { return "Based on the measured rate and macOS estimate." }
        return "Based on the measured charging rate."
    }
    var startLabel: String {
        if isCharging {
            return chargingSession?.observedStart == true ? "Charging started" : "Monitoring since"
        }
        return activeSession?.origin == .monitoring ? "Monitoring since" : "Discharge started"
    }
    var startValue: String {
        guard let sessionStart else { return "—" }
        let date = Self.formatStartTime(sessionStart.date)
        return activeSession?.origin == .history ? "≈ \(date)" : date
    }
    var elapsed: String { elapsed(since: sessionStart) }
    var startCharge: String { sessionStart.map { Self.percent($0.percent) } ?? "—" }
    var forecastStartCharge: String { forecastBaseline.map { Self.percent($0.percent) } ?? "—" }
    var forecastStartTime: String { forecastBaseline.map { Self.formatStartTime($0.date) } ?? "—" }
    var forecastElapsed: String { elapsed(since: forecastBaseline) }
    var chargeUsed: String {
        guard let sessionStart, let sample else { return "—" }
        let delta = sample.percent - sessionStart.percent
        return Self.percent(max(0, isCharging ? delta : -delta))
    }
    var rate: String {
        let rate = isCharging ? chargingSecondsPerPoint.map { 3600 / $0 } : estimate?.ratePerHour
        return rate.map { Self.percent($0) + "/h" } ?? "—"
    }
    var batteryPower: String { Self.watts(sample?.batteryWatts) }
    var inputPower: String { Self.watts(sample?.inputWatts) }
    var explanation: String {
        guard let sample else { return "Battery data is temporarily unavailable." }
        if isCharging {
            return sample.timeToFull == nil ? "macOS has not provided a time to full." : ""
        }
        guard sample.onBattery else { return "The Mac is using external power. A new session starts when it switches to battery." }
        guard activeForecastStart != nil else { return "Waiting for a battery reading from a switch to battery power, wake, or Mac startup." }
        if estimate == nil { return "Collecting data. An estimate needs at least 1% of charge used and 1 minute of observation." }
        return "Based on average drain since the latest switch to battery power, wake, or Mac startup."
    }
    var originNote: String? {
        switch activeSession?.origin {
        case .history: "Start reconstructed from the first available battery entry. Discharge may have started earlier."
        case .monitoring: "The unplug time is unknown. Session totals use measurements since monitoring began."
        default: nil
        }
    }
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(2))) + " W"
    }

    private func elapsed(since start: BatterySample?) -> String {
        guard let sample, let start else { return "—" }
        return DurationText.string(sample.date.timeIntervalSince(start.date))
    }

    private static func formatStartTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
