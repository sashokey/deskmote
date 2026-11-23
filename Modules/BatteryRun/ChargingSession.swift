import Foundation

struct ChargingSession {
    let start: BatterySample
    let observedStart: Bool

    func secondsPerPoint(at current: BatterySample) -> TimeInterval? {
        let elapsed = current.date.timeIntervalSince(start.date)
        let added = current.percent - start.percent
        let minimumGain = 1 - 100.0.ulp
        guard start.isValid, current.isValid, start.mode == .charging, current.mode == .charging,
              elapsed.isFinite, elapsed >= 60, added >= minimumGain else { return nil }
        return elapsed / added
    }
}
