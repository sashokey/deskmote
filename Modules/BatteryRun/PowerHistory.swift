import Foundation

struct PowerHistory {
    private struct PowerObservation {
        let date: Date
        let onBattery: Bool
        let percent: Double?
        let isFullWake: Bool

        var sample: BatterySample? {
            percent.map { BatterySample(date: date, percent: $0, onBattery: onBattery) }
        }
    }

    private static let maximumStartupLoggingDelay: TimeInterval = 120
    private static let maximumUnplugUncertainty: TimeInterval = 60
    private var observations: [PowerObservation] = []
    private var unmeasuredFullWakeIndices: [Date: Int] = [:]
    private var lastWake: (date: Date, firstObservationAfterWake: Int, observationIndex: Int?)?
    private var lastSleepOrDarkWake: Date?
    private var startups: [(date: Date, observation: PowerObservation?)] = []
    private var firstRecordDate: Date?
    private var lastRecordDate: Date?
    private var journalEnd: Date?

    var hasRecords: Bool { !observations.isEmpty || lastWake != nil || lastSleepOrDarkWake != nil || !startups.isEmpty }

    func covers(from checkpoint: Date, through resumed: Date) -> Bool {
        guard let firstRecordDate, let journalEnd else { return false }
        return firstRecordDate <= Self.logSecond(containing: checkpoint) &&
            journalEnd > Self.logSecond(containing: resumed)
    }

    func awaitsFullWake(since bootDate: Date?) -> Bool {
        lastWake == nil && lastSleepOrDarkWake.map { $0 >= (bootDate ?? .distantPast) } == true
    }

    func hasRecords(atOrAfter date: Date) -> Bool {
        lastRecordDate.map { $0 >= date } == true
    }

    init(from text: String, before now: Date) {
        guard let expression = try? NSRegularExpression(
            pattern: #"\bUsing\s+(Batt|AC)\b(?:\s*\(Charge:\s*(\d{1,3})%?\))?"#,
            options: .caseInsensitive
        ) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.isLenient = false
        var lastDate = Date.distantPast
        for line in text.split(separator: "\n") {
            let line = String(line)
            guard line.count >= 25,
                  let date = formatter.date(from: String(line.prefix(25))) else { continue }
            let event = line.dropFirst(25).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let message = (event.dropFirst().first ?? "").drop(while: \.isWhitespace)
            let isStartup = event.first == "Start" && message.hasPrefix("powerd process is started")
            let isWake = event.first == "Wake" && (message.hasPrefix("Wake from ") || message.hasPrefix("DarkWake to FullWake "))
            let isSleep = event.first == "Sleep" &&
                (message.hasPrefix("Entering Sleep state") || message.hasPrefix("Entering DarkWake state"))
            let isSummary = event.first == "Assertions" && message.hasPrefix("Summary- ")
            let isDarkWake = event.first == "DarkWake" && message.hasPrefix("DarkWake from ")
            let isWakeRequest = event.first == "Wake" && message.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "Requests"
            let isJournalRecord = isStartup || isWake || isSleep || isSummary || isDarkWake || isWakeRequest
            if date < lastDate {
                guard isJournalRecord else { continue }
                observations.removeAll(keepingCapacity: true)
                unmeasuredFullWakeIndices.removeAll(keepingCapacity: true)
                startups.removeAll(keepingCapacity: true)
                lastWake = nil
                lastSleepOrDarkWake = nil
                firstRecordDate = nil
                lastRecordDate = nil
                journalEnd = nil
                lastDate = .distantPast
            }
            guard date <= now else {
                if isJournalRecord { lastDate = date }
                continue
            }
            if isWakeRequest {
                journalEnd = date
                lastDate = date
                continue
            }
            if isWake {
                lastWake = (date, observations.count, nil)
                lastDate = date
                recordDate(date)
            } else if isSleep || isDarkWake {
                lastSleepOrDarkWake = date
                lastWake = nil
                lastDate = date
                recordDate(date)
            } else if isStartup {
                startups.append((date, nil))
                lastDate = date
                recordDate(date)
            }
            switch event.first {
            case "Sleep", "Wake", "DarkWake": break
            case "Start" where isStartup: break
            case "Assertions" where isSummary: break
            default: continue
            }
            let powerMessage = String(message)
            guard let match = expression.firstMatch(in: powerMessage,
                range: NSRange(powerMessage.startIndex..., in: powerMessage)),
                let sourceRange = Range(match.range(at: 1), in: powerMessage) else {
                if isWake { recordUnmeasuredFullWake(at: date) }
                continue
            }
            let percent = Range(match.range(at: 2), in: powerMessage)
                .flatMap { Double(powerMessage[$0]) }
                .flatMap { (0...100).contains($0) ? $0 : nil }
            let observation = PowerObservation(date: date, onBattery: powerMessage[sourceRange].lowercased() == "batt",
                                               percent: percent, isFullWake: isWake)
            if isWake {
                if observation.onBattery && percent == nil { recordUnmeasuredFullWake(at: date) }
                lastWake = (date, observations.count, observations.count)
            }
            if let startup = startups.indices.last, startups[startup].date == date, startups[startup].observation == nil {
                startups[startup].observation = observation
            }
            observations.append(observation)
            lastDate = date
            recordDate(date)
        }
    }

    private mutating func recordDate(_ date: Date) {
        if firstRecordDate == nil { firstRecordDate = date }
        lastRecordDate = date
        journalEnd = date
    }

    private mutating func recordUnmeasuredFullWake(at date: Date) {
        if unmeasuredFullWakeIndices[date] == nil { unmeasuredFullWakeIndices[date] = observations.count }
    }

    private func firstObservationAfterFullWake(for anchor: BatterySample?, requiresFullWake: Bool) -> Int? {
        guard requiresFullWake, let anchor else { return nil }
        if let measured = observations.firstIndex(where: { $0.isFullWake && Self.matches($0.sample, anchor: anchor) }) {
            return measured + 1
        }
        return unmeasuredFullWakeIndices[Self.logSecond(containing: anchor.date)]
    }

    func recoverForecast(
        at current: BatterySample, bootDate: Date?, historyFloor: Date?, forecastFloor: Date?, saved: BatterySample?,
        savedRequiresFullWakeMatch: Bool = false
    ) -> (start: BatterySample?, floor: Date?) {
        let earliestBoot = bootDate ?? startups.last?.date ?? .distantPast
        let evidenceFloor = max(historyFloor.map(Self.logSecond(containing:)) ?? .distantPast, earliestBoot)
        var startFloor = max(historyFloor ?? .distantPast, earliestBoot, forecastFloor ?? .distantPast,
                             lastSleepOrDarkWake ?? .distantPast, lastWake?.date ?? .distantPast)
        var historicalStart = bootDate.flatMap(startupBaseline(at:))
        var previous: PowerObservation?
        var lastBatteryReading: BatterySample?
        var usableSaved = saved
        var sawSaved = false
        let afterFullWake = firstObservationAfterFullWake(for: saved, requiresFullWake: savedRequiresFullWakeMatch)
        for (index, observation) in observations.enumerated() where observation.date >= evidenceFloor {
            if let afterFullWake, index >= afterFullWake, !sawSaved {
                sawSaved = true
                lastBatteryReading = usableSaved
                previous = nil
            }
            let sample = observation.sample
            let increased = sample.flatMap { reading in lastBatteryReading.map { reading.hasMoreCharge(than: $0) } } == true
            if let saved = usableSaved, !savedRequiresFullWakeMatch,
               Self.matches(sample, anchor: saved) { sawSaved = true }
            if !observation.onBattery || increased {
                startFloor = max(startFloor, observation.date)
                historicalStart = nil
                if let saved = usableSaved, Self.follows(observation.date, anchor: saved, matched: sawSaved) {
                    usableSaved = nil
                }
            }
            let recordedUnplug = previous.map { preceding in
                let savedInInterval = usableSaved.map { $0.date >= preceding.date && $0.date < observation.date } == true
                return !preceding.onBattery && !savedInInterval &&
                    observation.date.timeIntervalSince(preceding.date) <= Self.maximumUnplugUncertainty
            } == true
            if observation.onBattery, observation.date >= startFloor,
               index >= (lastWake?.firstObservationAfterWake ?? 0),
               recordedUnplug || index == lastWake?.observationIndex {
                historicalStart = sample
            }
            if !observation.onBattery {
                lastBatteryReading = nil
            } else if let sample {
                lastBatteryReading = sample
            }
            previous = observation
        }
        if afterFullWake != nil, !sawSaved {
            lastBatteryReading = usableSaved
            previous = nil
        }
        let floor = startFloor == .distantPast ? nil : startFloor
        let contradiction = previous.flatMap { $0.onBattery ? nil : $0.date }
            ?? lastBatteryReading.flatMap { current.hasMoreCharge(than: $0) ? $0.date : nil }
        if awaitsFullWake(since: bootDate) {
            historicalStart = nil
        }
        if let contradiction {
            historicalStart = nil
            if let saved = usableSaved, saved.date <= contradiction { return (nil, floor) }
        }
        let start = [historicalStart, usableSaved].compactMap { $0 }.filter {
            $0.isValid && $0.onBattery && $0.date >= startFloor && $0.date <= current.date && !current.hasMoreCharge(than: $0)
        }.max { $0.date < $1.date }
        return (start, floor)
    }

    static func logSecond(containing date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func matches(_ sample: BatterySample?, anchor: BatterySample) -> Bool {
        guard let sample, sample.onBattery, sample.date == logSecond(containing: anchor.date) else { return false }
        return !sample.hasMoreCharge(than: anchor) && !anchor.hasMoreCharge(than: sample)
    }

    private static func follows(_ date: Date, anchor: BatterySample, matched: Bool) -> Bool {
        date > anchor.date || (matched && date == logSecond(containing: anchor.date))
    }

    private func startupBaseline(at bootDate: Date) -> BatterySample? {
        guard let startup = startups.first(where: { $0.date >= bootDate }),
              startup.date.timeIntervalSince(bootDate) <= Self.maximumStartupLoggingDelay,
              let sample = startup.observation?.sample, sample.onBattery else { return nil }
        return BatterySample(date: bootDate, percent: sample.percent, onBattery: true)
    }

    static func recover(from text: String, current: BatterySample) -> DischargeSession? {
        PowerHistory(from: text, before: current.date).recoverSession(at: current).session
    }

    func recoverSession(
        at current: BatterySample, since floor: Date? = nil, replacing existing: DischargeSession? = nil,
        forecast: BatterySample? = nil, forecastRequiresFullWakeMatch: Bool = false
    ) -> (session: DischargeSession?, interruption: Date?, forecastInterruption: Date?) {
        guard current.isValid, current.onBattery else { return (nil, nil, nil) }
        var start: BatterySample?
        var previous: BatterySample?
        var interruption: Date?
        var forecastInterruption: Date?
        var previousForecastReading: BatterySample?
        var sawExistingStart = false
        var sawForecast = false
        let evidenceFloor = floor.map(Self.logSecond(containing:)) ?? .distantPast
        let afterFullWake = firstObservationAfterFullWake(for: forecast, requiresFullWake: forecastRequiresFullWakeMatch)
        for (index, observation) in observations.enumerated() where observation.date >= evidenceFloor && observation.date <= current.date {
            if let afterFullWake, index >= afterFullWake, !sawForecast {
                sawForecast = true
                previousForecastReading = forecast
            }
            let sample = observation.sample
            let increased = sample.map { reading in previous.map { reading.hasMoreCharge(than: $0) } == true } == true
            let increasedSinceForecast = afterFullWake == nil ? increased :
                sample.flatMap { reading in previousForecastReading.map { reading.hasMoreCharge(than: $0) } } == true
            if let forecast, !observation.onBattery || increasedSinceForecast,
               Self.follows(observation.date, anchor: forecast, matched: sawForecast) {
                forecastInterruption = observation.date
            }
            if !observation.onBattery || increased {
                if let existing, Self.follows(observation.date, anchor: existing.start, matched: sawExistingStart) {
                    interruption = observation.date
                }
                start = nil
            }
            if !observation.onBattery {
                previous = nil
                previousForecastReading = nil
            } else if let sample {
                if let existing, Self.matches(sample, anchor: existing.start) { sawExistingStart = true }
                if let forecast, !forecastRequiresFullWakeMatch,
                   Self.matches(sample, anchor: forecast) { sawForecast = true }
                if afterFullWake != nil, sawForecast { previousForecastReading = sample }
                if start == nil, sample.date >= (interruption ?? floor ?? .distantPast) { start = sample }
                previous = sample
            }
        }
        if afterFullWake != nil {
            if !sawForecast { previousForecastReading = forecast }
            if let previousForecastReading, current.hasMoreCharge(than: previousForecastReading) {
                forecastInterruption = current.date
            }
        }
        if let previous, let existing, previous.date >= existing.start.date, current.hasMoreCharge(than: previous) {
            if afterFullWake == nil, let forecast, previous.date >= forecast.date || sawForecast {
                forecastInterruption = current.date
            }
            return (nil, current.date, forecastInterruption)
        }
        guard let start, let previous,
              !current.hasMoreCharge(than: previous), current.date > start.date else { return (nil, interruption, forecastInterruption) }
        return (DischargeSession(start: start, origin: .history), interruption, forecastInterruption)
    }
}
