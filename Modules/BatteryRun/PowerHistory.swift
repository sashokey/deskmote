import Foundation

struct PowerHistory {
    private struct PowerObservation {
        let date: Date
        let onBattery: Bool
        let percent: Double?

        var sample: BatterySample? {
            percent.map { BatterySample(date: date, percent: $0, onBattery: onBattery) }
        }
    }

    private static let maximumStartupLoggingDelay: TimeInterval = 120
    private static let maximumUnplugUncertainty: TimeInterval = 60
    private var observations: [PowerObservation] = []
    private var lastWake: (date: Date, firstObservationAfterWake: Int, observationIndex: Int?)?
    private var lastSleep: Date?
    private var startups: [(date: Date, observation: PowerObservation?)] = []
    private var firstRecordDate: Date?
    private var lastRecordDate: Date?

    var hasRecords: Bool { !observations.isEmpty || lastWake != nil || lastSleep != nil || !startups.isEmpty }

    func covers(_ date: Date) -> Bool {
        guard let firstRecordDate, let lastRecordDate else { return false }
        return firstRecordDate <= date && lastRecordDate > date
    }

    func hasRecords(after date: Date) -> Bool {
        lastRecordDate.map { $0 > date } == true
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
            let isJournalRecord = isStartup || isWake || isSleep || isSummary || isDarkWake
            if date < lastDate {
                guard isJournalRecord else { continue }
                observations.removeAll(keepingCapacity: true)
                startups.removeAll(keepingCapacity: true)
                lastWake = nil
                lastSleep = nil
                firstRecordDate = nil
                lastRecordDate = nil
                lastDate = .distantPast
            }
            guard date <= now else {
                if isJournalRecord { lastDate = date }
                continue
            }
            if isWake {
                lastWake = (date, observations.count, nil)
                lastDate = date
                recordDate(date)
            } else if isSleep {
                lastSleep = date
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
                let sourceRange = Range(match.range(at: 1), in: powerMessage) else { continue }
            let percent = Range(match.range(at: 2), in: powerMessage)
                .flatMap { Double(powerMessage[$0]) }
                .flatMap { (0...100).contains($0) ? $0 : nil }
            let observation = PowerObservation(date: date, onBattery: powerMessage[sourceRange].lowercased() == "batt",
                                               percent: percent)
            if isWake { lastWake = (date, observations.count, observations.count) }
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
    }

    func recoverForecast(
        at current: BatterySample, bootDate: Date?, historyFloor: Date?, forecastFloor: Date?, saved: BatterySample?
    ) -> (start: BatterySample?, floor: Date?) {
        let earliestBoot = bootDate ?? startups.last?.date ?? .distantPast
        let evidenceFloor = max(historyFloor.map(Self.logSecond(containing:)) ?? .distantPast, earliestBoot)
        var startFloor = max(historyFloor ?? .distantPast, earliestBoot, forecastFloor ?? .distantPast,
                             lastSleep ?? .distantPast, lastWake?.date ?? .distantPast)
        var historicalStart = bootDate.flatMap(startupBaseline(at:))
        var previous: PowerObservation?
        var lastBatteryReading: BatterySample?
        var usableSaved = saved
        var sawSaved = false
        for (index, observation) in observations.enumerated() where observation.date >= evidenceFloor {
            let sample = observation.sample
            let increased = sample.flatMap { reading in lastBatteryReading.map { reading.hasMoreCharge(than: $0) } } == true
            let savedSecond = usableSaved.map { PowerHistory.logSecond(containing: $0.date) }
            if let sample, let saved = usableSaved, sample.onBattery, sample.date == savedSecond,
               !sample.hasMoreCharge(than: saved), !saved.hasMoreCharge(than: sample) { sawSaved = true }
            if !observation.onBattery || increased {
                startFloor = max(startFloor, observation.date)
                historicalStart = nil
                if let saved = usableSaved, observation.date > saved.date || (observation.date == savedSecond && sawSaved) {
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
        let floor = startFloor == .distantPast ? nil : startFloor
        let contradiction = previous.flatMap { $0.onBattery ? nil : $0.date }
            ?? lastBatteryReading.flatMap { current.hasMoreCharge(than: $0) ? $0.date : nil }
        if lastWake == nil, let lastSleep, lastSleep >= (bootDate ?? .distantPast) {
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

    private func startupBaseline(at bootDate: Date) -> BatterySample? {
        guard let startup = startups.first(where: { $0.date >= bootDate }),
              startup.date.timeIntervalSince(bootDate) <= Self.maximumStartupLoggingDelay,
              let sample = startup.observation?.sample, sample.onBattery else { return nil }
        return BatterySample(date: bootDate, percent: sample.percent, onBattery: true)
    }

    static func recover(from text: String, current: BatterySample) -> DischargeSession? {
        PowerHistory(from: text, before: current.date).recoverSession(at: current).session
    }

    func recoverSession(at current: BatterySample, since floor: Date? = nil, replacing existing: DischargeSession? = nil)
        -> (session: DischargeSession?, interruption: Date?) {
        guard current.isValid, current.onBattery else { return (nil, nil) }
        var start: BatterySample?
        var previous: BatterySample?
        var interruption: Date?
        var sawExistingStart = false
        let evidenceFloor = floor.map(Self.logSecond(containing:)) ?? .distantPast
        for observation in observations where observation.date >= evidenceFloor && observation.date <= current.date {
            let sample = observation.sample
            let increased = sample.map { reading in previous.map { reading.hasMoreCharge(than: $0) } == true } == true
            if !observation.onBattery || increased {
                if let existing, observation.date > existing.start.date || sawExistingStart {
                    interruption = observation.date
                }
                start = nil
            }
            if !observation.onBattery {
                previous = nil
            } else if let sample {
                if let existing, sample.date == Self.logSecond(containing: existing.start.date),
                   !sample.hasMoreCharge(than: existing.start), !existing.start.hasMoreCharge(than: sample) {
                    sawExistingStart = true
                }
                if start == nil, sample.date >= (interruption ?? floor ?? .distantPast) { start = sample }
                previous = sample
            }
        }
        if let previous, let existing, previous.date >= existing.start.date, current.hasMoreCharge(than: previous) {
            return (nil, current.date)
        }
        guard let start, let previous,
              !current.hasMoreCharge(than: previous), current.date > start.date else { return (nil, interruption) }
        return (DischargeSession(start: start, origin: .history), interruption)
    }
}
