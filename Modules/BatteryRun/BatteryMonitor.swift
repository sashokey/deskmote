import AppKit
import Combine
import Darwin
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var sample: BatterySample?
    @Published private(set) var tracker = SessionTracker()
    @Published private(set) var isReadingHistory = false
    @Published private(set) var notice: String?
    private(set) var chargingSession: ChargingSession?
    var forecastStart: BatterySample? { tracker.forecastHistoryCheckpoint == nil ? tracker.forecastStart : nil }

    let stateURL: URL
    private let readSample: (Date) -> BatterySample?
    private var bootDate: Date?
    private let loadHistory: @Sendable () -> PowerHistory?
    private let readClock: () -> (wall: Date, continuous: ContinuousClock.Instant)
    private var clockAnchor: (wall: Date, continuous: ContinuousClock.Instant)?
    private var powerSource: CFRunLoopSource?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var isSleeping = false
    private var started = false
    private var needsHistory = false
    private var historyGeneration = 0
    private var nextHistoryRetry: ContinuousClock.Instant?
    private var historyRetryInterval: Duration = .seconds(30)
    private var observedSleepDate: Date?
    private var latestGapCheckpoint: Date?
    private var firstReadingAfterGap: Date?

    static var defaultStateURL: URL {
        URL.applicationSupportDirectory.appending(path: "DeskMote/BatteryRun/session.json")
    }

    init(
        stateURL: URL = BatteryMonitor.defaultStateURL,
        readSample: @escaping (Date) -> BatterySample? = BatteryReader.read(at:),
        bootDate: Date? = BatteryMonitor.systemBootDate(),
        loadHistory: @escaping @Sendable () -> PowerHistory? = {
            PowerHistoryLoader.run().map { PowerHistory(from: $0, before: Date()) }
        },
        readClock: @escaping () -> (wall: Date, continuous: ContinuousClock.Instant) = { (Date(), .now) }
    ) {
        self.stateURL = stateURL
        self.readSample = readSample
        self.bootDate = bootDate
        self.loadHistory = loadHistory
        self.readClock = readClock
        tracker = SessionStore.load(from: stateURL) ?? SessionTracker()
    }

    nonisolated static func systemBootDate() -> Date? {
        let uptime = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let wallTime = clock_gettime_nsec_np(CLOCK_REALTIME)
        guard uptime > 0, wallTime > uptime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval((wallTime - uptime) / 1_000_000_000))
    }

    func refresh(wakeDate: Date? = nil) {
        guard !isSleeping else { return }
        if wakeDate != nil {
            nextHistoryRetry = nil
            historyRetryInterval = .seconds(30)
            historyGeneration &+= 1
            needsHistory = true
        }
        let clock = readClock()
        guard let current = readSample(clock.wall) else {
            if sample != nil {
                historyGeneration &+= 1
                needsHistory = true
            }
            chargingSession = nil
            sample = nil
            scheduleRefresh(isCompact: false)
            if let wakeDate {
                let earliestWake = min(observedSleepDate ?? wakeDate, wakeDate)
                tracker.markWake(at: earliestWake)
                clearObservationGap()
                persist()
            } else {
                let checkpoint = tracker.forecastHistoryCheckpoint
                markObservationGap()
                if tracker.forecastHistoryCheckpoint != checkpoint { persist() }
            }
            return
        }
        let previous = tracker.lastSample
        let previousSession = tracker.session
        let previousForecastStart = tracker.forecastStart
        let previousCheckpoint = tracker.forecastHistoryCheckpoint
        let clockMovedBackward = current.isValid && (
            previous.map { current.date < $0.date } == true ||
            tracker.wakeHistoryFloor.map { current.date < $0 } == true)
        let clockMovedForward = current.isValid && wallClockMovedForward(to: clock)
        let clockAdjusted = clockMovedBackward || clockMovedForward
        if clockAdjusted {
            let pendingWake = tracker.wakeAfterClockRollback == true
                ? tracker.wakeHistoryFloor.flatMap { $0 <= current.date ? $0 : nil } : nil
            let liveWake = wakeDate.flatMap { $0 <= current.date ? $0 : nil }
            let wake = liveWake ?? pendingWake
            tracker = SessionTracker(historyFloor: wake.map(PowerHistory.logSecond(containing:)) ?? current.date)
            if let pendingWake, liveWake == nil { tracker.markWake(at: pendingWake) }
            if let bootDate, current.date < bootDate { self.bootDate = nil }
            chargingSession = nil
            historyGeneration &+= 1
            needsHistory = wake != nil
        }
        if current.mode != .charging {
            chargingSession = nil
        } else if chargingSession == nil || wakeDate != nil || sample.map({ $0.hasMoreCharge(than: current) }) == true {
            let observedStart = !clockAdjusted && wakeDate == nil && sample.map { $0.mode != .charging } == true
            chargingSession = ChargingSession(start: current, observedStart: observedStart)
        }
        sample = current
        scheduleRefresh(isCompact: current.mode == .idle)
        tracker.update(current, bootDate: bootDate, wakeDate: wakeDate)
        let newObservedForecast = tracker.forecastStart != nil && tracker.forecastStart != previousForecastStart
        if clockAdjusted || wakeDate != nil || !current.onBattery || newObservedForecast {
            clearObservationGap()
        } else if latestGapCheckpoint != nil, current.isValid, firstReadingAfterGap == nil {
            firstReadingAfterGap = current.date
        }
        let pendingGapAdvanced = latestGapCheckpoint != nil && previous?.date != tracker.lastSample?.date
        if notice != nil || clockAdjusted || wakeDate != nil || previous?.percent != current.percent || previous?.onBattery != current.onBattery ||
            previousSession != tracker.session || previousForecastStart != tracker.forecastStart ||
            previousCheckpoint != tracker.forecastHistoryCheckpoint || pendingGapAdvanced {
            persist()
        }
        if started, needsHistory { recoverHistory(automatic: true) }
    }

    private func wallClockMovedForward(to now: (wall: Date, continuous: ContinuousClock.Instant)) -> Bool {
        defer { clockAnchor = now }
        guard let clockAnchor else { return false }
        let elapsed = now.wall.timeIntervalSince(clockAnchor.wall)
        return elapsed.isFinite && .seconds(elapsed) > clockAnchor.continuous.duration(to: now.continuous) + .seconds(1)
    }

    private func markObservationGap() {
        tracker.markObservationGap()
        latestGapCheckpoint = tracker.lastSample?.date
        firstReadingAfterGap = nil
    }

    private func clearObservationGap() {
        latestGapCheckpoint = nil
        firstReadingAfterGap = nil
    }

    func start() {
        guard !started else { return }
        started = true
        markObservationGap()
        needsHistory = true
        refresh()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = true
                self?.observedSleepDate = Date()
                self?.markObservationGap()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let wakeDate = Date()
            Task { @MainActor in
                guard let self else { return }
                self.isSleeping = false
                self.refresh(wakeDate: wakeDate)
                self.observedSleepDate = nil
            }
        }
    }

    private func scheduleRefresh(isCompact: Bool) {
        let interval: TimeInterval = isCompact ? 5 : 30
        guard started, timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = isCompact ? 1 : 5
    }

    func recoverHistory(automatic: Bool = false) {
        guard !isSleeping, !isReadingHistory, sample?.onBattery == true else { return }
        if automatic, let nextHistoryRetry, readClock().continuous < nextHistoryRetry { return }
        isReadingHistory = true
        needsHistory = false
        let generation = historyGeneration
        let loadHistory = loadHistory
        Task { [weak self] in
            let history = await PowerHistoryLoader.load(using: loadHistory)
            guard let self else { return }
            self.refresh()
            if generation == self.historyGeneration {
                if self.applyHistory(history), !self.tracker.needsWakeHistory {
                    self.nextHistoryRetry = nil
                    self.historyRetryInterval = .seconds(30)
                } else {
                    self.deferHistoryRetry()
                }
            }
            self.isReadingHistory = false
            if self.needsHistory, generation != self.historyGeneration { self.recoverHistory(automatic: true) }
        }
    }

    private func applyHistory(_ history: PowerHistory?) -> Bool {
        guard !isSleeping, let history, history.hasRecords, let current = sample, current.onBattery else { return false }
        let forecastReady = !history.awaitsFullWake(since: bootDate) &&
            (tracker.wakeHistoryFloor.map(history.hasRecords(atOrAfter:)) ?? true)
        var reconciled = tracker
        let unchecked = tracker.forecastHistoryCheckpoint
        let covered = (unchecked ?? latestGapCheckpoint).map { checkpoint in
            firstReadingAfterGap.map { history.covers(from: checkpoint, through: $0) } ?? false
        } ?? true
        if forecastReady, !covered, let checkpoint = latestGapCheckpoint ?? unchecked {
            reconciled.discardForecast(through: checkpoint)
        }
        let interruption = reconciled.reconcile(
            history: history, current: current, bootDate: bootDate, allowsForecastRecovery: forecastReady
        )
        let forecastResolved = forecastReady && (covered || reconciled.forecastStart != nil)
        guard forecastResolved || interruption != nil else { return false }
        if forecastResolved {
            reconciled.forecastHistoryCheckpoint = nil
            clearObservationGap()
        }
        tracker = reconciled
        persist()
        return forecastResolved
    }

    private func deferHistoryRetry() {
        needsHistory = true
        nextHistoryRetry = readClock().continuous.advanced(by: historyRetryInterval)
        historyRetryInterval = min(historyRetryInterval * 2, .seconds(300))
    }

    private func persist() {
        do {
            try SessionStore.save(tracker, to: stateURL)
            notice = nil
        } catch {
            notice = "This session could not be saved. Monitoring will continue while the app is open."
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        let notifications = NSWorkspace.shared.notificationCenter
        if let wakeObserver { notifications.removeObserver(wakeObserver) }
        if let sleepObserver { notifications.removeObserver(sleepObserver) }
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
