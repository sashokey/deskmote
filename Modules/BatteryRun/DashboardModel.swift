import Foundation

struct DashboardModel {
    let snapshot: BatteryDisplaySnapshot?

    private var report: JournalBatteryReport? { snapshot?.report }
    private var mode: JournalBatteryMode { report?.mode ?? .unknown }
    var isCharging: Bool { mode == .charging || mode == .charged }
    var isOnBattery: Bool { mode == .battery }
    var isCompact: Bool { !isCharging && !isOnBattery }
    var recordedCharge: Double? { report?.latest?.percent }
    var powerHeading: String { mode == .externalPower ? "External Power" : "Power Readings" }
    var historyUnavailable: Bool { mode == .unknown }

    var sourceLabel: String {
        switch mode {
        case .battery: "On Battery"
        case .charging: "Recorded charging"
        case .charged: "Recorded full charge"
        case .externalPower, .unknown: ""
        }
    }

    var asOf: String? {
        report?.latest.map { "As of \(Self.formatDate($0.date))" }
    }

    var remaining: String { DurationText.string(report?.estimate?.remainingSeconds) }
    var fullDuration: String { DurationText.string(report?.estimate?.fullRangeSeconds) }
    var startLabel: String { isCharging ? "Charging started" : "Discharge started" }
    var startValue: String {
        guard let start = report?.sessionStart else { return "—" }
        let time = Self.formatDate(start.date)
        return report?.sessionStartIsApproximate == true ? "≈ \(time)" : time
    }
    var elapsed: String { elapsed(since: report?.sessionStart) }
    var startCharge: String { report?.sessionStart.map { Self.percent($0.percent) } ?? "—" }
    var forecastStartCharge: String { report?.forecastStart.map { Self.percent($0.percent) } ?? "—" }
    var forecastStartTime: String { report?.forecastStart.map { Self.formatDate($0.date) } ?? "—" }
    var forecastElapsed: String { elapsed(since: report?.forecastStart) }
    var chargeUsed: String {
        guard let start = report?.sessionStart, let recordedCharge else { return "—" }
        let delta = recordedCharge - start.percent
        return Self.percent(max(0, isCharging ? delta : -delta))
    }
    var rate: String {
        report?.estimate?.percentagePointsPerHour.map { Self.percent($0) + "/h" } ?? "—"
    }
    var batteryPower: String { Self.watts(snapshot?.watts.battery) }
    var inputPower: String { Self.watts(snapshot?.watts.input) }
    var explanation: String {
        if recordedCharge == nil { return "No charge is available in the latest journal interval." }
        if report?.estimate == nil { return "An estimate needs at least one minute and one percentage point of change in the journal." }
        return ""
    }
    var originNote: String? {
        guard report?.sessionStartIsApproximate == true else { return nil }
        return "Session start is the first available journal entry."
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(2))) + " W"
    }

    private func elapsed(since start: JournalBatteryPoint?) -> String {
        guard let latest = report?.latest, let start else { return "—" }
        return DurationText.string(latest.date.timeIntervalSince(start.date))
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

enum DurationText {
    static func string(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 60 else { return "—" }
        if seconds == 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
