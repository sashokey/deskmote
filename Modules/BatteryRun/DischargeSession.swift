import Foundation

enum PowerReadingSource: String, Codable, Sendable {
    case direct
    case partial
}

struct BatterySample: Codable, Equatable, Sendable {
    let date: Date
    let percent: Double
    let onBattery: Bool
    var isCharging: Bool? = nil
    var timeToFull: TimeInterval? = nil
    var batteryWatts: Double? = nil
    var inputWatts: Double? = nil
    var powerSampleCount: UInt64? = nil
    var powerReadingSource: PowerReadingSource? = nil

    var mode: BatteryMode {
        if onBattery { return .discharging }
        return isCharging == true ? .charging : .idle
    }

    var isValid: Bool {
        percent.isFinite && (0...100).contains(percent) && date.timeIntervalSince1970.isFinite
    }

    func hasMoreCharge(than other: BatterySample) -> Bool {
        percent - other.percent > 100.0.ulp
    }
}

enum BatteryMode {
    case discharging
    case charging
    case idle
}

enum SessionOrigin: String, Codable, Sendable {
    case observed
    case history
    case monitoring
}

struct DischargeEstimate: Sendable {
    let remaining: TimeInterval
    let fullDuration: TimeInterval
    let ratePerHour: Double
}

struct DischargeSession: Codable, Equatable, Sendable {
    let start: BatterySample
    let origin: SessionOrigin

    func estimate(at current: BatterySample, since forecastStart: BatterySample? = nil) -> DischargeEstimate? {
        let start = forecastStart ?? self.start
        let elapsed = current.date.timeIntervalSince(start.date)
        let consumed = start.percent - current.percent
        let minimumLoss = 1 - 100.0.ulp
        guard start.isValid, current.isValid, start.onBattery, current.onBattery,
              elapsed.isFinite, elapsed >= 60, consumed >= minimumLoss else { return nil }
        let secondsPerPoint = elapsed / consumed
        return DischargeEstimate(
            remaining: secondsPerPoint * current.percent,
            fullDuration: secondsPerPoint * 100,
            ratePerHour: consumed / elapsed * 3600
        )
    }
}

struct SessionTracker: Codable, Sendable {
    var session: DischargeSession?
    var lastSample: BatterySample?
    var historyFloor: Date?
    private(set) var forecastStart: BatterySample?
    private(set) var wakeHistoryFloor: Date?
    private(set) var wakeAfterClockRollback: Bool?
    var needsWakeHistory: Bool { wakeHistoryFloor != nil }
    private var forecastFloor: Date?
    private var hasContinuousObservation = false

    private enum CodingKeys: String, CodingKey {
        case session, lastSample, historyFloor, forecastStart, forecastFloor, wakeHistoryFloor, wakeAfterClockRollback
    }

    init(session: DischargeSession? = nil, lastSample: BatterySample? = nil, historyFloor: Date? = nil) {
        self.session = session
        self.lastSample = lastSample
        self.historyFloor = historyFloor
    }

    mutating func markObservationGap() {
        hasContinuousObservation = false
    }

    mutating func discardForecast(through date: Date) {
        forecastStart = nil
        let next = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
        forecastFloor = max(forecastFloor ?? .distantPast, next)
    }

    mutating func markWake(at date: Date) {
        markObservationGap()
        forecastStart = nil
        let logSecond = PowerHistory.logSecond(containing: date)
        let rollback = lastSample.map { date < $0.date } == true || wakeHistoryFloor.map { logSecond < $0 } == true
        wakeAfterClockRollback = rollback ? true : nil
        if rollback {
            forecastFloor = logSecond
        } else {
            forecastFloor = max(forecastFloor ?? .distantPast, logSecond)
        }
        wakeHistoryFloor = logSecond
    }

    mutating func reconcile(history: String, current: BatterySample, bootDate: Date? = nil) {
        reconcile(history: PowerHistory(from: history, before: current.date), current: current, bootDate: bootDate)
    }

    mutating func reconcile(history: PowerHistory, current: BatterySample, bootDate: Date? = nil) {
        update(current, bootDate: bootDate)
        guard current.isValid, current.onBattery else { return }
        let forecast = history.recoverForecast(
            at: current, bootDate: bootDate, historyFloor: historyFloor, forecastFloor: forecastFloor, saved: forecastStart
        )
        forecastStart = forecast.start
        forecastFloor = forecast.floor
        if forecastStart != nil {
            wakeHistoryFloor = nil
            wakeAfterClockRollback = nil
        }
        let (recovered, interruption) = history.recoverSession(at: current, since: historyFloor, replacing: session)
        if let interruption {
            historyFloor = interruption
            session = recovered ?? DischargeSession(start: current, origin: .monitoring)
        } else if let recovered, session?.origin != .observed,
                  session.map({ recovered.start.date < $0.start.date }) ?? true {
            session = recovered
        }
    }

    mutating func update(_ sample: BatterySample, bootDate: Date? = nil, wakeDate: Date? = nil) {
        if let wakeDate { markWake(at: wakeDate) }
        guard sample.isValid else { return }
        if let lastSample, sample.date < lastSample.date { return }
        if let bootDate, let forecastStart, forecastStart.date < bootDate {
            self.forecastStart = nil
        }
        defer {
            lastSample = sample
            hasContinuousObservation = true
        }
        guard sample.onBattery else {
            session = nil
            historyFloor = sample.date
            forecastStart = nil
            return
        }
        let increased = lastSample.map { sample.hasMoreCharge(than: $0) } ?? false
        let observed = hasContinuousObservation && lastSample?.onBattery == false
        if increased { forecastStart = nil }
        if let wakeDate, wakeDate <= sample.date {
            forecastStart = BatterySample(date: wakeDate, percent: sample.percent, onBattery: true)
        } else if observed {
            forecastStart = sample
            wakeHistoryFloor = nil
            wakeAfterClockRollback = nil
        }
        if session == nil || increased {
            let origin: SessionOrigin = observed ? .observed : .monitoring
            if observed || (increased && hasContinuousObservation) {
                historyFloor = sample.date
            } else if let lastSample {
                historyFloor = max(historyFloor ?? .distantPast, lastSample.date)
            }
            session = DischargeSession(start: sample, origin: origin)
        }
    }
}
