import Foundation

struct JournalBatteryPoint: Equatable, Sendable {
    let date: Date
    let percent: Double
}

enum JournalBatteryMode: Equatable, Sendable {
    case battery
    case externalPower
    case charging
    case charged
    case unknown
}

struct JournalBatteryEstimate: Equatable, Sendable {
    let remainingSeconds: TimeInterval
    let fullRangeSeconds: TimeInterval?
    let percentagePointsPerHour: Double?
}

struct JournalBatteryReport: Equatable, Sendable {
    let mode: JournalBatteryMode
    let latest: JournalBatteryPoint?
    let sessionStart: JournalBatteryPoint?
    let sessionStartIsApproximate: Bool
    let forecastStart: JournalBatteryPoint?
    let estimate: JournalBatteryEstimate?
}

private struct JournalProjection {
    enum Event {
        case start
        case sleep
        case wake
        case summary

        init?(name: Substring, message: Substring) {
            switch name {
            case "Start" where message.hasPrefix("powerd process is started"):
                self = .start
            case "Sleep" where message.hasPrefix("Entering Sleep state") || message.hasPrefix("Entering DarkWake state"),
                 "DarkWake" where message.hasPrefix("DarkWake from "):
                self = .sleep
            case "Wake" where message.hasPrefix("Wake from ") || message.hasPrefix("DarkWake to FullWake "):
                self = .wake
            case "Assertions" where message.hasPrefix("Summary- [System:"):
                self = .summary
            default:
                return nil
            }
        }

        func powerPayload(in message: Substring) -> Substring {
            guard self == .summary else { return message }
            guard let bracket = message.firstIndex(of: "]") else { return "" }
            let payload = message[message.index(after: bracket)...].drop(while: \.isWhitespace)
            return payload.hasPrefix("Using ") ? payload : ""
        }
    }

    private var recordDate: Date?
    private var observedPercentages: Set<Double> = []
    private var onBattery: Bool?
    private var sourceChangedAt: Date?
    private var sessionStart: JournalBatteryPoint?
    private var sessionStartIsApproximate = false
    private var latest: JournalBatteryPoint?
    private var awaitingFullWake = false
    private var forecastStart: JournalBatteryPoint?
    private var forecastEnd: JournalBatteryPoint?
    private var priorDistinctPoint: JournalBatteryPoint?

    mutating func record(_ event: Event, at date: Date, onBattery source: Bool?, percent: Double?) {
        if event == .start || recordDate.map({ date < $0 }) == true { self = Self() }
        if recordDate != date { observedPercentages.removeAll(keepingCapacity: true) }
        recordDate = date
        switch event {
        case .sleep, .wake:
            awaitingFullWake = event == .sleep
            observedPercentages.removeAll(keepingCapacity: true)
            resetForecast()
        case .start, .summary:
            break
        }

        guard let source else { return }
        if onBattery != source {
            sourceChangedAt = onBattery == nil ? nil : date
            onBattery = source
            sessionStart = nil
            sessionStartIsApproximate = false
            latest = nil
            observedPercentages.removeAll(keepingCapacity: true)
            resetForecast()
        }

        guard let percent, observedPercentages.insert(percent).inserted else { return }
        let point = JournalBatteryPoint(date: date, percent: percent)
        if sessionStart == nil {
            sessionStart = point
            sessionStartIsApproximate = sourceChangedAt != date
        }
        latest = point
        guard !awaitingFullWake else { return }

        if let end = forecastEnd, source ? percent > end.percent : percent < end.percent {
            resetForecast()
        }
        if forecastStart == nil { forecastStart = point }
        if let end = forecastEnd, end.date < date { priorDistinctPoint = end }
        forecastEnd = point
    }

    private mutating func resetForecast() {
        forecastStart = nil
        forecastEnd = nil
        priorDistinctPoint = nil
    }

    var report: JournalBatteryReport {
        let mode: JournalBatteryMode
        switch onBattery {
        case true?:
            mode = .battery
        case false?:
            if forecastEnd?.percent == 100 {
                mode = .charged
            } else if isGainingCharge {
                mode = .charging
            } else {
                mode = .externalPower
            }
        case nil:
            mode = .unknown
        }
        return JournalBatteryReport(
            mode: mode, latest: latest, sessionStart: sessionStart,
            sessionStartIsApproximate: sessionStartIsApproximate,
            forecastStart: forecastStart, estimate: estimate(for: mode)
        )
    }

    private var isGainingCharge: Bool {
        guard let end = forecastEnd, let priorDistinctPoint else { return false }
        return end.percent > priorDistinctPoint.percent
    }

    private func estimate(for mode: JournalBatteryMode) -> JournalBatteryEstimate? {
        let completion = mode == .charged
            ? JournalBatteryEstimate(remainingSeconds: 0, fullRangeSeconds: nil, percentagePointsPerHour: nil)
            : nil
        guard mode == .battery || isGainingCharge,
              let start = forecastStart, let end = forecastEnd else { return completion }
        let elapsed = end.date.timeIntervalSince(start.date)
        let change = abs(end.percent - start.percent)
        guard elapsed >= 60, change >= 1 else { return completion }
        let secondsPerPoint = elapsed / change
        let remainingPoints = mode == .battery ? end.percent : 100 - end.percent
        return JournalBatteryEstimate(
            remainingSeconds: remainingPoints * secondsPerPoint,
            fullRangeSeconds: 100 * secondsPerPoint,
            percentagePointsPerHour: 3600 / secondsPerPoint
        )
    }
}

private func projectJournal(_ text: String, before now: Date) -> JournalBatteryReport {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    formatter.isLenient = false
    let power = (/\bUsing\s+(Batt|AC)\b(?:\s*\(Charge:\s*([0-9]{1,3})%?\))?/).ignoresCase()
    var projection = JournalProjection()
    for line in text.split(separator: "\n") {
        let fields = line.dropFirst(25).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { continue }
        let message = fields[1].drop(while: \.isWhitespace)
        guard let event = JournalProjection.Event(name: fields[0], message: message),
              let date = formatter.date(from: String(line.prefix(25))), date <= now else { continue }
        let reading = event.powerPayload(in: message).matches(of: power).last
        let onBattery = reading.map { $0.1.lowercased() == "batt" }
        let percent = reading?.2.flatMap { Double($0) }.flatMap { (0...100).contains($0) ? $0 : nil }
        projection.record(event, at: date, onBattery: onBattery, percent: percent)
    }
    return projection.report
}

struct PowerHistory {
    private let report: JournalBatteryReport

    func batteryReport() -> JournalBatteryReport { report }

    init(from text: String, before now: Date) {
        report = projectJournal(text, before: now)
    }
}
