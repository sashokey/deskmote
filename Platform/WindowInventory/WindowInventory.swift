import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import Foundation
#if DEBUG
import os
#endif

struct AppEntry {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let activationPolicy: NSApplication.ActivationPolicy
    let executablePath: String?
    var windowsByID: [CGWindowID: WindowEntry]
    var windowOrder: [CGWindowID]
    var isHidden: Bool
    var shadowTabCgIDs: Set<CGWindowID> = []
    var applicationOrigin: ApplicationOrigin? = nil
    var processGeneration: ProcessGeneration? = nil

}

struct WindowEntry {
    var cgWindowID: CGWindowID
    let token: String
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
    var minAbsentSince: Date? = nil
    #if DEBUG
    var absenceEpisodeID: UUID? = nil
    #endif
    var everSeenVisible: Bool = false
    var priorTabWindowNumbers: Set<CGWindowID> = []
    var displayUUID: String? = nil
    var absentProbe: AbsentSeatProbeState? = nil
    var createdAt = Date()
    var confirmedCGDisplayBounds: CGRect? = nil
    var actionTarget: WindowActionTarget? = nil

    func matchesAXElement(_ element: AXUIElement) -> Bool {
        actionTarget?.element == AXElementKey(e: element)
    }
}

private enum InventoryWindowSelection {
    static func preferredByID(
        _ observations: [AXWindowSnapshot], matching seats: [CGWindowID: WindowEntry]
    ) -> [CGWindowID: AXWindowSnapshot] {
        var preferred: [CGWindowID: AXWindowSnapshot] = [:]
        preferred.reserveCapacity(observations.count)
        for observation in observations {
            guard let id = observation.cgWindowID else { continue }
            if let previous = preferred[id] {
                guard let seat = seats[id],
                      !seat.matchesAXElement(previous.element),
                      seat.matchesAXElement(observation.element) else { continue }
            }
            preferred[id] = observation
        }
        return preferred
    }

    static func inObservationOrder(
        _ observations: [AXWindowSnapshot], preferredByID: [CGWindowID: AXWindowSnapshot]
    ) -> [AXWindowSnapshot] {
        var seen = Set<CGWindowID>()
        return observations.compactMap { observation in
            guard let id = observation.cgWindowID else { return observation }
            guard let preferred = preferredByID[id], seen.insert(id).inserted else { return nil }
            return preferred
        }
    }
}

#if DEBUG
struct DiagnosticAdmissionRecord: Equatable {
    let verdict: String
    let source: String
    let at: Date
}
#endif

typealias ApplicationOwnerRead = (identity: ScanAdmissionDecision.ProcessIdentity, application: AppTrackerWindowEligibility.Application)

protocol AppTrackerProcessProviding: Sendable {
    func isAlive(pid: pid_t) -> Bool
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity
    func applicationOwner(pid: pid_t) -> ApplicationOwnerRead?
    func applicationOwners(for pids: Set<pid_t>, cancellation: OperationCancellation) -> [pid_t: ApplicationOwnerRead]
}

extension AppTrackerProcessProviding {
    func applicationOwner(pid: pid_t) -> ApplicationOwnerRead? { nil }
    func applicationOwners(for pids: Set<pid_t>, cancellation: OperationCancellation) -> [pid_t: ApplicationOwnerRead] {
        var result: [pid_t: ApplicationOwnerRead] = [:]
        for pid in pids {
            guard !cancellation.isCancelled else { break }
            result[pid] = applicationOwner(pid: pid)
        }
        return result
    }
}

struct LiveAppTrackerProcessProvider: AppTrackerProcessProviding {
    func applicationOwner(pid: pid_t) -> ApplicationOwnerRead? { ApplicationOwnership().owner(for: pid) }
    func applicationOwners(for pids: Set<pid_t>, cancellation: OperationCancellation) -> [pid_t: ApplicationOwnerRead] {
        ApplicationOwnership().owners(for: pids, cancellation: cancellation)
    }

    func isAlive(pid: pid_t) -> Bool {
        ProcessLiveness.isAlive(pid: pid)
    }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        let start = ProcessLiveness.startTime(pid: pid)
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: start.map { Int64($0.tv_sec) },
            startTimeUsec: start.map { $0.tv_usec },
            bundleID: bundleID
        )
    }
}

@MainActor
final class AppTracker: ObservableObject, WindowInventoryTracking, DisplayTopologyUpdating {
    var snapshots: AnyPublisher<DockSnapshot, Never> { $snapshot.eraseToAnyPublisher() }
    @Published private(set) var snapshot: DockSnapshot = .empty

    private var apps: [pid_t: AppEntry] = [:]
    private struct OwnerBinding {
        let process: ScanAdmissionDecision.ProcessIdentity
        let owner: ApplicationOwnerRead
        let origin: ApplicationOrigin
    }
    private struct ApplicationProbe {
        let identity: ScanAdmissionDecision.ProcessIdentity
        let result: AXWindowReadResult
        let owner: ApplicationOwnerRead?
        var pid: pid_t { identity.pid }
    }
    private var ownerBindings: [pid_t: OwnerBinding] = [:]
    private var unprojectedHelperPIDs: Set<pid_t> = []
    #if DEBUG
    private(set) var lastAdmissionVerdictByPID: [pid_t: DiagnosticAdmissionRecord] = [:]

    func diagnosticApps() -> [AppEntry] {
        appOrder.compactMap { apps[$0] }
    }

    func noteAdmissionVerdict(pid: pid_t, verdict: String, source: String) {
        lastAdmissionVerdictByPID[pid] = DiagnosticAdmissionRecord(verdict: verdict, source: source, at: Date())
    }
    #endif
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?
    private var frontmostPollTimer: Timer?
    private var isScanningCandidates = false
    private let work = AsyncWorkScope()
    private let elementCache = AXElementCache.shared
    private struct DestroyedWindow {
        let element: AXUIElement?
    }
    private var destroyedWindows: [pid_t: [CGWindowID: DestroyedWindow]] = [:]
    private static let phantomReapGrace: TimeInterval = 10.0
    private var retryCandidates: [WindowSubscriptionRetryCandidate<AXElementKey>] = []
    private var retryFlushScheduled = false
    #if DEBUG
    private var nextRetryFlushID: UInt64 = 0
    #endif

    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    private var nextSeatSerial: Int = 0

    #if DEBUG
    private struct ShadowPoolDiagnosticState {
        var initialized = false
        var updateWasSkipped = false
        var lastSuccessfulRoundID: UInt64?
    }
    #endif

    #if DEBUG
    private var nextInventoryRoundID: UInt64 = 0
    private var reconcileOrdinalsByPID: [pid_t: UInt64] = [:]
    private var lastReconcileAtByPID: [pid_t: Date] = [:]
    private var shadowPoolDiagnosticsByPID: [pid_t: ShadowPoolDiagnosticState] = [:]
    private var heldLogDeduplicator = InventoryPhantomHeldDeduplicator()
    #endif

    private struct PendingEventRead: Sendable {
        let token: UInt64
        let mutationGeneration: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
        let source: InventoryReconcileSource
        var absenceProbes: [AbsentSeatProbeRequest] = []
    }

    private struct QueuedPeriodicRead: Sendable {
        let token: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
    }

    private struct InventoryTimeout {
        let identity: ScanAdmissionDecision.ProcessIdentity
        let failures: Int
        let nextReadUptime: TimeInterval?
    }

    private struct FrontmostProbe: Sendable {
        let windowIDs: Set<CGWindowID>?
    }

    private static let reconcileInterval: TimeInterval = 5
    private static let inventoryRetryDelays: [TimeInterval] = [0.5, 1, 2]

    private var nextEventReadToken: UInt64 = 0
    private var pendingEventReads: [pid_t: PendingEventRead] = [:]
    private var queuedPeriodicReads: [pid_t: QueuedPeriodicRead] = [:]
    private var trailingEventSources: [pid_t: InventoryReconcileSource] = [:]
    private var inventoryTimeouts: [pid_t: InventoryTimeout] = [:]
    private var frontmostProbeIDs: [pid_t: Set<CGWindowID>] = [:]
    private var frontmostProbePending = false
    private var pendingPeriodicSnapshot: (token: UInt64, onScreenIDs: Set<CGWindowID>)?
    private struct PendingFocusRead {
        let id = UUID()
        let revision: UInt64
        let mutationGeneration: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
    }
    private struct ConfirmedFocus {
        let observedAt: TimeInterval
        let windowID: CGWindowID?
        let element: AXElementKey?
    }
    private var focusRevisions: [pid_t: UInt64] = [:]
    private var confirmedFocus: [pid_t: ConfirmedFocus] = [:]
    private var pendingFocusReads: [pid_t: PendingFocusRead] = [:]
    private var trailingFocusReads = Set<pid_t>()
    private struct PendingSystemFocusRead {
        let id = UUID()
        let revision: UInt64
        let frontmostPID: pid_t
        let identities: [pid_t: ScanAdmissionDecision.ProcessIdentity]
        let mutationGenerations: [pid_t: UInt64]
    }
    private struct ConfirmedSystemFocus {
        let frontmostPID: pid_t
        let identity: ScanAdmissionDecision.ProcessIdentity
        let windowID: CGWindowID
        let windowElement: AXElementKey?
        let mutationGeneration: UInt64
    }
    private var systemFocusRevision: UInt64 = 0
    private var pendingSystemFocusRead: PendingSystemFocusRead?
    private var trailingSystemFocusRead = false
    private var confirmedSystemFocus: ConfirmedSystemFocus?
    var mutationGenerations: [pid_t: UInt64] = [:]

    private let reader: any AppTrackerWindowReading
    private let processProvider: any AppTrackerProcessProviding
    private let cgSnapshotProvider: @Sendable () -> AppTrackerCGWindowSnapshot
    private var latestCGSnapshot: AppTrackerCGWindowSnapshot?
    private let onScreenWindowIDsProvider: @Sendable () -> Set<CGWindowID>?
    private let periodicReconcileTimeout: TimeInterval
    private let reconcileSkipEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private var displayTable: WindowDisplayAttribution.Table
    private var screenParametersObserver: NSObjectProtocol?

    private struct ReconcileGateState {
        var lastCGIDs: Set<CGWindowID>
        var lastFullReadUptime: TimeInterval
        var dirty: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        var lastSeatOnScreenIDs: Set<CGWindowID>
    }

    private var gateStates: [pid_t: ReconcileGateState] = [:]

    private let frontmostCacheEnabled: Bool
    private let frontmostPIDProvider: @MainActor () -> pid_t?
    private var cachedFrontmostPID: pid_t?

    private let cgSnapshotReuseEnabled: Bool
    private var cgEventGeneration: UInt64 = 0
    private var cachedCGSnapshot: AppTrackerCGWindowSnapshot?
    private var cachedCGProbeIDs: Set<CGWindowID>?
    private var cachedCGAtUptime: TimeInterval = -.infinity
    private var cachedCGGeneration: UInt64 = 0

    private let scanGateEnabled: Bool
    private var scanMemos: [pid_t: ScanProbeGateDecision.Memo] = [:]
    private var scanDirtyPIDs: Set<pid_t> = []
    private var lastFullScanUptime: TimeInterval?
    private var scanCandidateCache: [(pid: pid_t, bundleID: String?)]?
    #if DEBUG
    private var observerActiveOverridesForTesting: [pid_t: Bool] = [:]
    #endif
    private let absentSeatReleaseEnabled: Bool
    private let absentSeatProber: any AbsentSeatProbing
    private var absenceProbeTimers: [pid_t: DispatchWorkItem] = [:]
    #if DEBUG
    private var subscribedElementOverridesForTesting: [pid_t: [CGWindowID: (element: AXUIElement, instanceID: UInt64)]] = [:]
    #endif
    private let windowEligibility = AppTrackerWindowEligibility()
    #if DEBUG
    private let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "app-tracker")
    #endif
    #if DEBUG
    private let inventoryLog: WindowInventoryAnomalyLog
    #endif
    #if DEBUG
    private var admissionAppsForTesting: [NSRunningApplication]?
    private var admissionApplicationForTesting: AppTrackerWindowEligibility.Application?
    #endif

    private var runningApplications: [NSRunningApplication] {
        #if DEBUG
        if let admissionAppsForTesting { return admissionAppsForTesting }
        #endif
        return NSWorkspace.shared.runningApplications
    }

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        reader: any AppTrackerWindowReading = AXWindowReader(),
        processProvider: any AppTrackerProcessProviding = LiveAppTrackerProcessProvider(),
        cgSnapshotProvider: @escaping @Sendable () -> AppTrackerCGWindowSnapshot = {
            AppTrackerCGWindowSnapshot.capture()
        },
        onScreenWindowIDsProvider: @escaping @Sendable () -> Set<CGWindowID>? = {
            AppTrackerCGWindowSnapshot.captureOnScreenWindowIDs()
        },
        periodicAXTimeoutMS: Int = Int(DebugSwitch.reconcileAxTimeoutMs.value(in: ProcessInfo.processInfo.environment) ?? "") ?? 100,
        reconcileSkipEnabled: Bool = DebugSwitch.reconcileSkip.isEnabled(in: ProcessInfo.processInfo.environment),
        scanGateEnabled: Bool = DebugSwitch.scanGate.isEnabled(in: ProcessInfo.processInfo.environment),
        frontmostCacheEnabled: Bool = DebugSwitch.frontmostCache.isEnabled(in: ProcessInfo.processInfo.environment),
        cgSnapshotReuseEnabled: Bool = DebugSwitch.cgSnapshotReuse.isEnabled(in: ProcessInfo.processInfo.environment),
        absentSeatReleaseEnabled: Bool = DebugSwitch.absentSeatRelease.isEnabled(in: ProcessInfo.processInfo.environment),
        absentSeatProber: any AbsentSeatProbing = LiveAbsentSeatProber(),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        frontmostPIDProvider: @escaping @MainActor () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = { .empty }
    ) {
        #if DEBUG
        self.inventoryLog = inventoryLog
        #endif
        self.displayTableProvider = displayTableProvider
        self.displayTable = displayTableProvider()
        self.reader = reader
        self.processProvider = processProvider
        self.cgSnapshotProvider = { AppTrackerCGWindowSnapshot.timedCapture(cgSnapshotProvider) }
        self.onScreenWindowIDsProvider = onScreenWindowIDsProvider
        self.periodicReconcileTimeout = TimeInterval(max(1, periodicAXTimeoutMS)) / 1000.0
        self.reconcileSkipEnabled = reconcileSkipEnabled
        self.scanGateEnabled = scanGateEnabled
        self.frontmostCacheEnabled = frontmostCacheEnabled
        self.frontmostPIDProvider = frontmostPIDProvider
        self.cgSnapshotReuseEnabled = cgSnapshotReuseEnabled
        self.absentSeatReleaseEnabled = absentSeatReleaseEnabled
        self.absentSeatProber = absentSeatProber
        self.uptimeProvider = uptimeProvider
    }

    isolated deinit { stop() }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        work.restart()
        #if DEBUG
        let info = Bundle.main.infoDictionary
        inventoryLog.record(.sessionStart(InventorySessionStartPayload(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            processID: ProcessInfo.processInfo.processIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )))
        #endif
        subscribeWorkspaceNotifications()
        let generation = work.generation
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleScreenParametersChanged()
            }
        }
        displayTable = displayTableProvider()
        seedRunningApps()
        startReconcileTimer()
        startFrontmostPollTimer()
        for delay in [0.5, 1.0, 2.0, 4.0] {
            work.launch(after: delay) { [weak self] generation in
                await MainActor.run {
                    guard let self, self.work.isCurrent(generation) else { return }
                    self.scanNonAdmittedApps()
                }
            }
        }
    }

    func stop() {
        work.stop()
        isScanningCandidates = false
        for item in absenceProbeTimers.values { item.cancel() }
        absenceProbeTimers.removeAll()
        retryCandidates.removeAll()
        retryFlushScheduled = false
        cgEventGeneration &+= 1
        cachedCGSnapshot = nil
        latestCGSnapshot = nil
        pendingCGDisplayKeys.removeAll()
        for pid in appOrder { AXElementCache.shared.removeAll(pid: pid) }
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        frontmostPollTimer?.invalidate()
        frontmostPollTimer = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        #if DEBUG
        lastAdmissionVerdictByPID.removeAll()
        #endif
        appOrder.removeAll()
        destroyedWindows.removeAll()
        #if DEBUG
        reconcileOrdinalsByPID.removeAll()
        lastReconcileAtByPID.removeAll()
        shadowPoolDiagnosticsByPID.removeAll()
        heldLogDeduplicator.removeAll()
        #endif
        ownerBindings.removeAll()
        unprojectedHelperPIDs.removeAll()
        pendingEventReads.removeAll()
        queuedPeriodicReads.removeAll()
        trailingEventSources.removeAll()
        inventoryTimeouts.removeAll()
        frontmostProbeIDs.removeAll()
        frontmostProbePending = false
        pendingPeriodicSnapshot = nil
        focusRevisions.removeAll()
        confirmedFocus.removeAll()
        pendingFocusReads.removeAll()
        trailingFocusReads.removeAll()
        systemFocusRevision &+= 1
        pendingSystemFocusRead = nil
        trailingSystemFocusRead = false
        confirmedSystemFocus = nil
        mutationGenerations.removeAll()
        gateStates.removeAll()
        scanMemos.removeAll()
        scanDirtyPIDs.removeAll()
        lastFullScanUptime = nil
        scanCandidateCache = nil
        cachedFrontmostPID = nil
        snapshot = .empty
    }


    private func purgeFromSeatHistories(_ cgID: CGWindowID) {
        for pid in appOrder {
            guard var app = apps[pid] else { continue }
            var touched = false
            if app.shadowTabCgIDs.remove(cgID) != nil { touched = true }
            for wid in app.windowOrder where app.windowsByID[wid]?.priorTabWindowNumbers.contains(cgID) == true {
                app.windowsByID[wid]?.priorTabWindowNumbers.remove(cgID)
                touched = true
            }
            if touched { apps[pid] = app }
        }
    }

    @discardableResult
    private func retireCGIDs(_ ids: Set<CGWindowID>, from app: inout AppEntry,
                             keepingSubscriptionsIn cgIDs: Set<CGWindowID>) -> Bool {
        guard !ids.isEmpty else { return false }
        var removedSeat = false
        for id in ids {
            if let seat = app.windowsByID.removeValue(forKey: id) {
                removedSeat = true
                #if DEBUG
                if let episode = seat.absenceEpisodeID {
                    heldLogDeduplicator.clear(pid: app.pid, seatToken: seat.token, episodeID: episode)
                }
                #endif
                pendingCGDisplayKeys.removeValue(forKey: id)
            }
            elementCache.remove(pid: app.pid, cgWindowID: id)
        }
        app.windowOrder.removeAll { ids.contains($0) }
        app.shadowTabCgIDs.subtract(ids)
        for id in app.windowOrder { app.windowsByID[id]?.priorTabWindowNumbers.subtract(ids) }
        _ = observers[app.pid]?.retainSubscriptions(keep: cgIDs.union(app.windowOrder).subtracting(ids))
        return removedSeat
    }

    private func retireConflictingOwners(
        claimedIDs: Set<CGWindowID>, ownerPID: pid_t, cgIDs: Set<CGWindowID>
    ) -> Bool {
        guard !claimedIDs.isEmpty else { return false }
        var changed = false
        for pid in appOrder where pid != ownerPID {
            guard var app = apps[pid] else { continue }
            let conflicts = claimedIDs.filter { id in
                app.windowsByID[id] != nil || app.shadowTabCgIDs.contains(id)
                    || app.windowsByID.values.contains { $0.priorTabWindowNumbers.contains(id) }
                    || subscribedElement(pid: pid, cgWindowID: id) != nil
            }
            guard !conflicts.isEmpty else { continue }
            if retireCGIDs(conflicts, from: &app, keepingSubscriptionsIn: cgIDs) { changed = true }
            apps[pid] = app
            for id in conflicts { destroyedWindows[pid]?.removeValue(forKey: id) }
            if destroyedWindows[pid]?.isEmpty == true { destroyedWindows[pid] = nil }
            invalidateEventReads(pid: pid)
            queuedPeriodicReads.removeValue(forKey: pid)
        }
        return changed
    }

    private func frameKey(_ pid: pid_t, _ bounds: CGRect?) -> String? {
        guard let bounds, WindowFrameMatchPolicy.isValid(bounds) else { return nil }
        return "\(pid)|\(WindowFrameMatchPolicy.signature(for: bounds))"
    }

    @discardableResult
    private func reconcileSeats(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        source: InventoryReconcileSource,
        preloadedEligible: [AXWindowSnapshot],
        preloadedReadOutcome: InventoryAXReadOutcome? = nil,
        preloadedReadMode: InventoryReconcileReadMode? = nil,
        rawAXCgIDs: Set<CGWindowID>? = nil,
        rawAXWindows: [AXWindowSnapshot]? = nil,
        absenceEvidence: [CGWindowID: AbsentSeatProbeEvidence] = [:]
    ) -> Bool {
        guard var app = apps[pid] else { return false }
        let onScreenCGIDs = cgSnapshot.onScreenWindowIDs
        let cgPidIDs = cgSnapshot.windowIDsByPID[pid] ?? []
        let before = seatSignature(app)
        let observedWindows = (rawAXWindows ?? preloadedEligible).filter { $0.pid == pid }
        let observedByID = InventoryWindowSelection.preferredByID(observedWindows, matching: app.windowsByID)
        let rawAXCgIDs = rawAXWindows.map { _ in Set(observedByID.keys) } ?? rawAXCgIDs
        let foreignIDs = cgSnapshot.captureFailed ? [] : Set(cgSnapshot.ownerPIDByWindowID.compactMap { id, owner in
            owner == pid ? nil : id
        })
        let cgIDs = cgSnapshot.allWindowIDs.subtracting(foreignIDs)
        let nativeChildren = cgSnapshot.captureFailed ? [] : Set(cgPidIDs.filter {
            cgSnapshot.parentWindowIDs[$0].map { $0 != 0 } ?? false
        })
        let ineligibleIDs = nativeChildren.union(foreignIDs)
        let axWindowIDs = Set(preloadedEligible.compactMap(\.cgWindowID))
        let contestedAXIDs = axWindowIDs.union(observedByID.keys).filter { id in
            guard cgSnapshot.captureFailed || cgSnapshot.ownerPIDByWindowID[id] == nil else { return false }
            return appOrder.contains { $0 != pid && apps[$0]?.windowsByID[id] != nil }
        }
        let trackedIDs = app.windowsByID.values.reduce(into: app.shadowTabCgIDs.union(app.windowOrder)) {
            $0.formUnion($1.priorTabWindowNumbers)
        }
        let retiredIDs = ineligibleIDs.intersection(trackedIDs)
        let destroyed = destroyedWindows[pid] ?? [:]
        let replacements = Set(destroyed.compactMap { id, record -> CGWindowID? in
            guard axWindowIDs.contains(id), let old = record.element, let observed = observedByID[id],
                  !CFEqual(old, observed.element) else { return nil }
            return id
        })
        let retainedDestroyedIDs = Set(destroyed.keys).subtracting(replacements).subtracting(foreignIDs)
        retireCGIDs(retiredIDs.union(replacements), from: &app, keepingSubscriptionsIn: cgIDs.union(axWindowIDs))
        apps[pid] = app
        if destroyed.count != retainedDestroyedIDs.count {
            let retained = destroyed.filter { retainedDestroyedIDs.contains($0.key) }
            destroyedWindows[pid] = retained.isEmpty ? nil : retained
        }
        let nativeRoots = Set(cgPidIDs.filter {
            cgSnapshot.isNormalRoot(windowID: $0, pid: pid) && cgSnapshot.alphaByWindowID[$0] != 0
        })
        let shadowPool = app.shadowTabCgIDs
        let excludedIDs = ineligibleIDs.union(retainedDestroyedIDs)
        let eligibleCandidates = preloadedEligible.filter {
            $0.pid == pid && ($0.cgWindowID.map { !excludedIDs.contains($0) && !contestedAXIDs.contains($0) } ?? true)
        }
        let confirmedClaims: Set<CGWindowID> = cgSnapshot.captureFailed ? [] : cgPidIDs.filter {
            cgSnapshot.ownerPIDByWindowID[$0] == pid
        }
        let movedOwnership = retireConflictingOwners(claimedIDs: confirmedClaims, ownerPID: pid,
                                                     cgIDs: cgSnapshot.allWindowIDs)
        let axReadOutcome = preloadedReadOutcome ?? .success(count: preloadedEligible.count)

        if axReadOutcome.kind == .unread {
            #if DEBUG
            inventoryLog.record(.reconcileUnread(InventoryReconcileUnreadPayload(
                pid: pid,
                bundleID: app.bundleIdentifier,
                source: source,
                readMode: preloadedReadMode ?? .timed,
                usedPreloadedAX: true,
                errorCode: axReadOutcome.errorCode ?? AXError.failure.rawValue
            )))
            #endif
            gateStates[pid]?.lastReadWasUnread = true
            let visibleDestroyedSeat = retainedDestroyedIDs.contains {
                snapshot.windows[WindowID(rawValue: "cgw-\($0)")]?.pid == pid
            }
            return visibleDestroyedSeat || movedOwnership || seatSignature(app) != before
        }
        #if DEBUG
        let reconcileContext = inventoryLog.isEnabled
            ? inventoryReconcileContext(
                pid: pid,
                source: source,
                now: now,
                usedPreloadedAX: true,
                axReadOutcome: axReadOutcome
            )
            : nil
        #else
        let reconcileContext: InventoryReconcileContext? = nil
        #endif
        func fk(_ b: CGRect?) -> String? { frameKey(pid, b) }

        var eligibleByCgID = InventoryWindowSelection.preferredByID(eligibleCandidates, matching: app.windowsByID)
        let heldMinimized = observedByID.filter { id, observation in
            guard let seat = app.windowsByID[id], seat.matchesAXElement(observation.element),
                  observation.isMinimizedRead == true,
                  observation.role == nil || observation.role == kAXWindowRole as String,
                  observation.isTopLevel != false,
                  !excludedIDs.contains(id), !contestedAXIDs.contains(id),
                  !cgSnapshot.belowNormalLayerWindowIDs.contains(id),
                  cgSnapshot.parentWindowIDs[id].map({ $0 != 0 }) != true else { return false }
            return eligibleByCgID[id].map { seat.matchesAXElement($0.element) } != true
        }
        for id in heldMinimized.keys { eligibleByCgID.removeValue(forKey: id) }
        let seatsByElement = Dictionary(grouping: app.windowsByID.values.compactMap { seat in
            seat.actionTarget.map { (element: $0.element, cgWindowID: seat.cgWindowID) }
        }, by: \.element)
        var reboundWindowIDs: [CGWindowID: CGWindowID] = [:]
        var pendingRebindSourceIDs = Set<CGWindowID>()
        var pendingRebindDestinationIDs = Set<CGWindowID>()
        for (id, candidate) in eligibleByCgID {
            guard app.windowsByID[id] == nil,
                  let seats = seatsByElement[AXElementKey(e: candidate.element)], seats.count == 1,
                  let previousID = seats.first?.cgWindowID, rawAXCgIDs?.contains(previousID) == false,
                  app.windowsByID[previousID]?.priorTabWindowNumbers.contains(id) == false,
                  !retainedDestroyedIDs.contains(previousID),
                  observedWindows.allSatisfy({ observation in
                      let sameElement = CFEqual(observation.element, candidate.element)
                      return sameElement == (observation.cgWindowID == id)
                  }) else { continue }
            let confirmedParked = !cgSnapshot.captureFailed && !cgSnapshot.allWindowIDs.contains(previousID)
                && (candidate.isMinimized || app.isHidden)
            if (onScreenCGIDs.contains(id) || confirmedParked), !onScreenCGIDs.contains(previousID),
               cgSnapshot.ownerPIDByWindowID[id] == pid {
                reboundWindowIDs[previousID] = id
            } else {
                pendingRebindSourceIDs.insert(previousID)
                pendingRebindDestinationIDs.insert(id)
            }
        }
        for id in pendingRebindDestinationIDs { eligibleByCgID.removeValue(forKey: id) }
        let eligible = InventoryWindowSelection.inObservationOrder(eligibleCandidates, preferredByID: eligibleByCgID)
        if !reboundWindowIDs.isEmpty {
            for (oldID, newID) in reboundWindowIDs {
                guard var seat = app.windowsByID.removeValue(forKey: oldID) else { continue }
                seat.cgWindowID = newID
                app.windowsByID[newID] = seat
                elementCache.remove(pid: pid, cgWindowID: oldID)
                pendingCGDisplayKeys.removeValue(forKey: oldID)
            }
            app.windowOrder = app.windowOrder.map { reboundWindowIDs[$0] ?? $0 }
            for id in app.windowOrder { app.windowsByID[id]?.priorTabWindowNumbers.subtract(reboundWindowIDs.keys) }
        }

        var eligibleByFrame: [String: [AXWindowSnapshot]] = [:]
        for snapshot in eligible {
            if let key = fk(snapshot.bounds) { eligibleByFrame[key, default: []].append(snapshot) }
        }

        if AXElementCache.isEnabled {
            for (c, s) in eligibleByCgID { elementCache.store(pid: pid, cgWindowID: c, element: s.element) }
            for (c, s) in heldMinimized { elementCache.store(pid: pid, cgWindowID: c, element: s.element) }
            if !cgSnapshot.captureFailed {
                elementCache.retain(pid: pid, liveCGWindowIDs: cgIDs.union(eligibleByCgID.keys).union(heldMinimized.keys))
            }
        }

        var usedEligible: Set<CGWindowID> = []
        var newOrder: [CGWindowID] = []
        var newByID: [CGWindowID: WindowEntry] = [:]
        var actionTargetChanged = false
        let createdAtByToken = Dictionary(app.windowsByID.values.map { ($0.token, $0.createdAt) },
                                         uniquingKeysWith: { first, _ in first })
        func place(_ e: WindowEntry) { newOrder.append(e.cgWindowID); newByID[e.cgWindowID] = e }
        func clearAbsenceEpisode(_ seat: inout WindowEntry) {
            #if DEBUG
            if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
            }
            InventoryAbsenceEpisode.clear(absentSince: &seat.minAbsentSince, episodeID: &seat.absenceEpisodeID)
            #else
            seat.minAbsentSince = nil
            #endif
        }
        func make(token: String, _ s: AXWindowSnapshot, previousTitle: String? = nil,
                  history: Set<CGWindowID> = [], wasEverVisible: Bool = false,
                  previousDisplayUUID: String? = nil, retainedMinimized: Bool? = nil,
                  confirmedCGDisplayBounds: CGRect? = nil,
                  previousActionTarget: WindowActionTarget? = nil) -> WindowEntry {
            let isMinimized = retainedMinimized ?? s.isMinimized
            let visible = !isMinimized && !app.isHidden
            let fresh = visible && confirmedCGDisplayBounds == nil
                ? WindowDisplayAttribution.displayUUID(for: s.bounds, table: displayTable) : nil
            let displayUUID = fresh ?? previousDisplayUUID
            let former = history.subtracting([s.cgWindowID!])
            return WindowEntry(cgWindowID: s.cgWindowID!, token: token,
                               title: s.titleRead.resolvedTitle(previousTitle: previousTitle),
                               bounds: s.bounds, isMinimized: isMinimized, isFocused: s.isFocusedWindow,
                               everSeenVisible: wasEverVisible || !isMinimized,
                               priorTabWindowNumbers: cgSnapshot.captureFailed ? former : former.intersection(cgIDs),
                               displayUUID: displayUUID,
                               createdAt: createdAtByToken[token] ?? now,
                               confirmedCGDisplayBounds: confirmedCGDisplayBounds,
                               actionTarget: previousActionTarget ?? WindowActionTarget(element: AXElementKey(e: s.element)))
        }
        let seatCountByFrame = app.windowOrder.reduce(into: [String: Int]()) { counts, id in
            if let key = fk(app.windowsByID[id]?.bounds) { counts[key, default: 0] += 1 }
        }
        func seatsAtFrame(_ key: String) -> Int { seatCountByFrame[key] ?? 0 }

        func uniqueWindow(_ candidates: [AXWindowSnapshot]) -> AXWindowSnapshot? {
            guard let first = candidates.first, let id = first.cgWindowID,
                  candidates.allSatisfy({ $0.cgWindowID == id }) else { return nil }
            return first
        }

        let axPresentSeatCount = app.windowOrder.filter { eligibleByCgID[$0] != nil }.count
        var healedSeats: [CGWindowID] = []
        #if DEBUG
        var healedDiagnosticContext: [CGWindowID: (token: String, episodeID: UUID)] = [:]
        #endif
        #if DEBUG
        var releasedSeats: [(seat: WindowEntry, reason: InventorySeatReleasedReason)] = []
        #endif
        var tearOutCgIDs: Set<CGWindowID> = []
        var mergedIntoOwner: [(cgID: CGWindowID, ownerActiveCgID: CGWindowID)] = []
        func axPresentSeatsForMerge(excluding candidate: CGWindowID) -> [TabMergeDecision.AXPresentSeat] {
            app.windowOrder.compactMap { id in
                guard id != candidate, let snap = eligibleByCgID[id] else { return nil }
                return TabMergeDecision.AXPresentSeat(seatActiveWindowNumber: id, bounds: snap.bounds, isMinimized: snap.isMinimized)
            }
        }

        func allowsTentativeReplacement(_ seat: WindowEntry) -> Bool {
            guard let handle = subscribedElement(pid: pid, cgWindowID: seat.cgWindowID) else { return false }
            guard let evidence = absenceEvidence[seat.cgWindowID] else { return true }
            guard evidence.request.seatToken == seat.token,
                  evidence.request.cgWindowID == seat.cgWindowID,
                  evidence.request.instanceID == handle.instanceID,
                  CFEqual(evidence.request.element.e, handle.element),
                  evidence.spaces != .includesNonCurrent else { return false }
            if case .alive(let minimized) = evidence.element {
                if minimized == true { return false }
                if minimized == false, evidence.spaces == .onlyCurrent { return false }
            }
            return true
        }

        var delayedReplacements: [CGWindowID: AXWindowSnapshot] = [:]
        var tentativeCandidates: [CGWindowID: AXWindowSnapshot] = [:]
        let tentativeUptime = uptimeProvider()
        for id in app.windowOrder {
            guard let seat = app.windowsByID[id],
                  let tentative = seat.absentProbe?.tentativeTabReplacement else { continue }
            let handle = subscribedElement(pid: pid, cgWindowID: id)
            let target = eligibleByCgID[tentative.cgWindowID]
            let targetSeat = app.windowsByID[tentative.cgWindowID]
            let cgContradicts = !cgSnapshot.captureFailed && (
                !cgPidIDs.contains(id) || !cgPidIDs.contains(tentative.cgWindowID)
                || cgSnapshot.boundsByWindowID[id].map { fk($0) != tentative.frameKey } == true
                || cgSnapshot.boundsByWindowID[tentative.cgWindowID].map { fk($0) != tentative.frameKey } == true
            )
            guard tentativeUptime < tentative.expiresAt, !retainedDestroyedIDs.contains(id), !seat.isMinimized, !app.isHidden,
                  rawAXCgIDs?.contains(id) == false, !onScreenCGIDs.contains(id),
                  fk(seat.bounds) == tentative.frameKey,
                  let target, !target.isMinimized, fk(target.bounds) == tentative.frameKey,
                  targetSeat?.token == tentative.seatToken,
                  CFEqual(target.element, tentative.element.e),
                  handle?.instanceID == tentative.sourceInstanceID,
                  handle.map({ CFEqual($0.element, tentative.sourceElement.e) }) == true,
                  !cgContradicts, allowsTentativeReplacement(seat) else {
                app.windowsByID[id]?.absentProbe?.tentativeTabReplacement = nil
                continue
            }
            if cgSnapshot.isNormalRoot(windowID: tentative.cgWindowID, pid: pid),
               fk(cgSnapshot.boundsByWindowID[id]) == tentative.frameKey,
               hasConfirmedDormantEvidence(seat: seat, pid: pid, cgSnapshot: cgSnapshot,
                   rawAXCgIDs: rawAXCgIDs, evidence: absenceEvidence[id]) {
                delayedReplacements[id] = target
            }
        }
        let supersededSeats = Set(delayedReplacements.values.compactMap(\.cgWindowID))
        for id in supersededSeats {
            #if DEBUG
            if let seat = app.windowsByID[id] { releasedSeats.append((seat, .mergedIntoTabbedWindow)) }
            #endif
        }

        for cgID in app.windowOrder {
            guard !supersededSeats.contains(cgID) else { continue }
            guard var seat = app.windowsByID[cgID] else { continue }
            if pendingRebindSourceIDs.contains(cgID) {
                seat.isFocused = false
                place(seat)
                continue
            }
            let X = seat.cgWindowID
            let seatKey = fk(seat.bounds)
            if let snapX = eligibleByCgID[X], !usedEligible.contains(X) {
                let sameElement = seat.matchesAXElement(snapX.element)
                let isMinimized = snapX.isMinimizedRead ?? (snapX.isMinimized || (sameElement && seat.isMinimized))
                clearAbsenceEpisode(&seat)
                if !isMinimized, !reboundWindowIDs.values.contains(X),
                   let seatKey, seatsAtFrame(seatKey) == 1, fk(snapX.bounds) != seatKey,
                   let Y = eligibleByFrame[seatKey].flatMap({ candidates in
                       uniqueWindow(candidates.filter { s in
                           guard let c = s.cgWindowID else { return false }
                           return c != X && !s.isMinimized && seat.priorTabWindowNumbers.contains(c)
                               && !usedEligible.contains(c) && app.windowsByID[c] == nil
                       })
                   }), let yc = Y.cgWindowID {
                    place(make(token: seat.token, Y, history: seat.priorTabWindowNumbers,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID))
                    usedEligible.insert(yc)
                    subscribeWindow(pid: pid, element: Y.element, cgWindowID: yc, context: reconcileContext)
                    tearOutCgIDs.insert(X)
                } else {
                    if seat.actionTarget != nil, !sameElement { actionTargetChanged = true }
                    let previousTitle = sameElement ? seat.title : nil
                    #if DEBUG
                    if case .unread(let error) = snapX.titleRead,
                       let previousTitle, !previousTitle.isEmpty, let reconcileContext {
                        inventoryLog.record(.titleHeld(InventoryTitleHeldPayload(
                            context: reconcileContext,
                            pid: pid,
                            bundleID: app.bundleIdentifier,
                            seatToken: seat.token,
                            seatActiveWindowNumber: X,
                            errorCode: error.rawValue
                        )))
                    }
                    #endif
                    let displayBounds = retainedCGDisplayBounds(
                        for: seat, after: snapX, cgSnapshot: cgSnapshot, isVisible: !isMinimized && !app.isHidden
                    )
                    var continuation = make(token: seat.token, snapX, previousTitle: previousTitle,
                                            history: seat.priorTabWindowNumbers,
                                            wasEverVisible: seat.everSeenVisible,
                                            previousDisplayUUID: seat.displayUUID,
                                            retainedMinimized: isMinimized,
                                            confirmedCGDisplayBounds: displayBounds,
                                            previousActionTarget: sameElement ? seat.actionTarget : nil)
                    if sameElement, snapX.isMinimizedRead == true, snapX.bounds == nil {
                        continuation.bounds = seat.bounds
                    }
                    place(continuation)
                    usedEligible.insert(X)
                    subscribeWindow(pid: pid, element: snapX.element, cgWindowID: X, context: reconcileContext)
                }
            } else if let observation = heldMinimized[X] {
                clearAbsenceEpisode(&seat)
                seat.absentProbe = nil
                seat.isMinimized = true
                seat.isFocused = false
                seat.title = observation.titleRead.resolvedTitle(previousTitle: seat.title)
                if !cgSnapshot.captureFailed { seat.priorTabWindowNumbers.formIntersection(cgIDs) }
                place(seat)
                subscribeWindow(pid: pid, element: observation.element, cgWindowID: X, context: reconcileContext)
            } else {
                if observedByID[X]?.titleRead == .empty { seat.title = "" }
                if seat.absentProbe?.tentativeTabReplacement == nil,
                   !cgSnapshot.captureFailed, !seat.isMinimized, !app.isHidden,
                   rawAXCgIDs?.contains(X) == false, !onScreenCGIDs.contains(X),
                   !retainedDestroyedIDs.contains(X), allowsTentativeReplacement(seat),
                   let seatKey, seatsAtFrame(seatKey) == 1 {
                    let candidates = eligibleByFrame[seatKey]?.filter {
                        guard let id = $0.cgWindowID else { return false }
                        return app.windowsByID[id] == nil && !$0.isMinimized && onScreenCGIDs.contains(id)
                    } ?? []
                    if candidates.count == 1 { tentativeCandidates[X] = candidates[0] }
                }
                let replacements = delayedReplacements[X].map { [$0] } ?? seatKey.flatMap { eligibleByFrame[$0] }?.filter { s in
                       guard let c = s.cgWindowID, !usedEligible.contains(c), app.windowsByID[c] == nil else { return false }
                       guard seat.priorTabWindowNumbers.contains(c) || (!retainedDestroyedIDs.contains(X) && hasConfirmedDormantEvidence(
                           seat: seat, pid: pid, cgSnapshot: cgSnapshot,
                           rawAXCgIDs: rawAXCgIDs, evidence: absenceEvidence[X]
                       )) else { return false }
                       guard seat.priorTabWindowNumbers.contains(c) || (!seat.isMinimized && !app.isHidden && !s.isMinimized) else { return false }
                       return !cgSnapshot.captureFailed || (!s.isMinimized && seat.priorTabWindowNumbers.contains(c))
                } ?? []
                let knownReplacements = replacements.filter {
                    $0.cgWindowID.map(seat.priorTabWindowNumbers.contains) == true
                }
                if let seatKey, seatsAtFrame(seatKey) == 1 || delayedReplacements[X] != nil,
                   let Y = uniqueWindow(knownReplacements.isEmpty ? replacements : knownReplacements),
                   let yc = Y.cgWindowID {
                    clearAbsenceEpisode(&seat)
                    var history = seat.priorTabWindowNumbers
                    if let target = delayedReplacements[X]?.cgWindowID {
                        history.formUnion(app.windowsByID[target]?.priorTabWindowNumbers ?? [])
                    }
                    if !retainedDestroyedIDs.contains(X) { history.insert(X) }
                    place(make(token: seat.token, Y, history: history,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID))
                    usedEligible.insert(yc)
                    subscribeWindow(pid: pid, element: Y.element, cgWindowID: yc, context: reconcileContext)
                } else if cgSnapshot.captureFailed && !retainedDestroyedIDs.contains(X) {
                    seat.isFocused = false
                    place(seat)
                } else if cgIDs.contains(X) && !retainedDestroyedIDs.contains(X) {
                    seat.priorTabWindowNumbers.formIntersection(cgIDs)
                    if seat.isMinimized || app.isHidden {
                        #if DEBUG
                        InventoryAbsenceEpisode.beginIfNeeded(
                            absentSince: &seat.minAbsentSince,
                            episodeID: &seat.absenceEpisodeID,
                            now: now
                        )
                        #else
                        if seat.minAbsentSince == nil { seat.minAbsentSince = now }
                        #endif
                        let absentFor = now.timeIntervalSince(seat.minAbsentSince ?? now)
                        let evaluation = PhantomSeatDecision.evaluate(
                            everSeenVisible: seat.everSeenVisible,
                            axAbsentFor: absentFor,
                            threshold: Self.phantomReapGrace,
                            cgStillPresent: true,
                            axReadSawWindows: !eligible.isEmpty,
                            axPresentSiblingCount: axPresentSeatCount,
                            confirmedDormantWindow: !app.isHidden && hasConfirmedDormantEvidence(
                                seat: seat, pid: pid, cgSnapshot: cgSnapshot,
                                rawAXCgIDs: rawAXCgIDs, evidence: absenceEvidence[X]
                            ),
                            hasCoframedAXSibling: fk(cgSnapshot.boundsByWindowID[X]).map { key in
                                axPresentSeatsForMerge(excluding: X).contains { fk($0.bounds) == key }
                            } ?? false
                        )
                        if evaluation.permitsSeatRelease {
                            healedSeats.append(X)
                            #if DEBUG
                            releasedSeats.append((seat, .phantomHealed))
                            if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                                healedDiagnosticContext[X] = (seat.token, episodeID)
                                heldLogDeduplicator.clear(
                                    pid: pid, seatToken: seat.token, episodeID: episodeID
                                )
                            }
                            #endif
                        } else {
                            #if DEBUG
                            if let reconcileContext,
                               absentFor >= Self.phantomReapGrace,
                               let episodeID = seat.absenceEpisodeID,
                               heldLogDeduplicator.shouldRecord(
                                   pid: pid,
                                   seatToken: seat.token,
                                   episodeID: episodeID,
                                   reasons: evaluation.retentionReasons
                               ) {
                                inventoryLog.record(.phantomHeld(InventoryPhantomHeldPayload(
                                    context: reconcileContext,
                                    pid: pid,
                                    bundleID: app.bundleIdentifier,
                                    seatToken: seat.token,
                                    seatActiveWindowNumber: X,
                                    absenceEpisodeID: episodeID,
                                    retentionReasons: evaluation.retentionReasons.map(\.rawValue).sorted(),
                                    appHidden: app.isHidden,
                                    everSeenVisible: seat.everSeenVisible,
                                    absentForMs: Int((absentFor * 1_000).rounded()),
                                    thresholdMs: Int((Self.phantomReapGrace * 1_000).rounded()),
                                    eligibleWindowCount: eligible.count,
                                    axPresentSiblingCount: axPresentSeatCount,
                                    bounds: seat.bounds.map(InventoryLogRect.init)
                                )))
                            }
                            #endif
                            seat.isFocused = false
                            if !seat.everSeenVisible, !app.isHidden {
                                prepareAbsenceProbe(seat: &seat, pid: pid,
                                    isOnScreen: onScreenCGIDs.contains(X), rawAXCgIDs: rawAXCgIDs)
                            } else {
                                seat.absentProbe = nil
                            }
                            place(seat)
                        }
                    } else {
                        let mergeVerdict = TabMergeDecision.decisionFromEvidence(
                            candidateIsConfirmedDormant: hasConfirmedDormantEvidence(
                                seat: seat, pid: pid, cgSnapshot: cgSnapshot,
                                rawAXCgIDs: rawAXCgIDs, evidence: absenceEvidence[X]
                            ),
                            candidateIsOnScreen: onScreenCGIDs.contains(X),
                            candidateCGBounds: cgSnapshot.boundsByWindowID[X],
                            candidateSeatBounds: seat.bounds,
                            axPresentSeats: axPresentSeatsForMerge(excluding: X),
                            frameKey: fk
                        )
                        if case .release(let owner) = mergeVerdict {
                            #if DEBUG
                            releasedSeats.append((seat, .mergedIntoTabbedWindow))
                            #endif
                            if let owner { mergedIntoOwner.append((cgID: X, ownerActiveCgID: owner)) }
                        } else {
                            seat.isFocused = false
                            if applyAbsentSeatProbe(
                                seat: &seat, pid: pid, bundleID: app.bundleIdentifier,
                                isOnScreen: onScreenCGIDs.contains(X), rawAXCgIDs: rawAXCgIDs,
                                evidence: absenceEvidence[X], context: reconcileContext
                            ) {
                                #if DEBUG
                                releasedSeats.append((seat, .hiddenWithoutDestroy))
                                #endif
                            } else {
                                place(seat)
                            }
                        }
                    }
                } else {
                    #if DEBUG
                    releasedSeats.append((seat, .leftCGList))
                    #endif
                }
            }
        }

        for merged in mergedIntoOwner {
            newByID[merged.ownerActiveCgID]?.priorTabWindowNumbers.insert(merged.cgID)
        }
        var placedForFold: [TabFoldDecision.PlacedSeat] = newOrder.compactMap { id in
            guard let e = newByID[id] else { return nil }
            return TabFoldDecision.PlacedSeat(seatActiveWindowNumber: e.cgWindowID, priorTabWindowNumbers: e.priorTabWindowNumbers)
        }
        for s in eligible {
            guard let c = s.cgWindowID, !usedEligible.contains(c), newByID[c] == nil else { continue }
            let verdict = TabFoldDecision.decisionFromEvidence(
                candidateCgID: c,
                candidateIsMinimized: s.isMinimized,
                placedSeats: placedForFold
            )
            switch verdict {
            case .fold(let owner, _):
                usedEligible.insert(c)
                if let owner { newByID[owner]?.priorTabWindowNumbers.insert(c) }
            case .newSeat:
                #if DEBUG
                let hadPlacedSeat = !placedForFold.isEmpty
                #endif
                nextSeatSerial += 1
                let entry = make(token: "tabgrp-\(pid)-s\(nextSeatSerial)", s)
                #if DEBUG
                if let reconcileContext {
                    let isOnScreen = onScreenCGIDs.contains(c)
                    let creationReason = InventorySeatCreationReason.classify(
                        hasPlacedSeat: hadPlacedSeat,
                        isTearOut: tearOutCgIDs.contains(c),
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen
                    )
                    let relations: [InventorySeatRelation] = newOrder.compactMap { id in
                        guard let existing = newByID[id] else { return nil }
                        let exactFrame = fk(existing.bounds) != nil && fk(existing.bounds) == fk(s.bounds)
                        let nearbyFrame: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            nearbyFrame = WindowFrameMatchPolicy.areClose(lhs, rhs)
                        } else {
                            nearbyFrame = false
                        }
                        let sizeMatches: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            sizeMatches = abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
                        } else {
                            sizeMatches = false
                        }
                        return InventorySeatRelation(
                            seatToken: existing.token,
                            seatActiveWindowNumber: existing.cgWindowID,
                            isMinimized: existing.isMinimized,
                            everSeenVisible: existing.everSeenVisible,
                            bounds: existing.bounds.map(InventoryLogRect.init),
                            priorTabWindowNumbers: existing.priorTabWindowNumbers.sorted(),
                            formerContainsCandidate: existing.priorTabWindowNumbers.contains(c),
                            normalizedTitleMatches: WindowInventoryDiagnosticRelations.normalizedTitlesMatch(
                                existing.title, s.title
                            ),
                            exactFrameMatches: exactFrame,
                            nearbyFrameMatches: nearbyFrame,
                            sizeMatches: sizeMatches
                        )
                    }
                    inventoryLog.record(.seatCreated(InventorySeatCreatedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        seatToken: entry.token,
                        seatActiveWindowNumber: c,
                        creationReason: creationReason,
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen,
                        isFocused: s.isFocusedWindow,
                        appHidden: app.isHidden,
                        bounds: s.bounds.map(InventoryLogRect.init),
                        candidateKnownShadow: shadowPool.contains(c) && !nativeRoots.contains(c),
                        eligibleWindowCount: eligible.count,
                        minimizedEligibleCount: eligible.filter(\.isMinimized).count,
                        onScreenEligibleCount: eligible.compactMap(\.cgWindowID).filter {
                            onScreenCGIDs.contains($0)
                        }.count,
                        cgWindowCount: cgPidIDs.count,
                        eligibleCgIDs: eligible.compactMap(\.cgWindowID).sorted(),
                        cgWindowIDs: cgPidIDs.sorted(),
                        shadowPool: shadowPool.sorted(),
                        existingSeats: relations
                    )))
                }
                #endif
                place(entry)
                subscribeWindow(pid: pid, element: s.element, cgWindowID: c, context: reconcileContext)
                placedForFold.append(TabFoldDecision.PlacedSeat(seatActiveWindowNumber: entry.cgWindowID, priorTabWindowNumbers: entry.priorTabWindowNumbers))
            }
        }

        for (id, candidate) in tentativeCandidates {
            guard let targetID = candidate.cgWindowID, let targetSeat = newByID[targetID],
                  let sourceSeat = newByID[id], sourceSeat.token != targetSeat.token,
                  sourceSeat.absentProbe != nil, let key = fk(sourceSeat.bounds),
                  let handle = subscribedElement(pid: pid, cgWindowID: id) else { continue }
            newByID[id]?.absentProbe?.tentativeTabReplacement = AbsentSeatProbeState.TentativeTabReplacement(
                cgWindowID: targetID, seatToken: targetSeat.token, element: AXElementKey(e: candidate.element),
                sourceElement: AXElementKey(e: handle.element), sourceInstanceID: handle.instanceID,
                frameKey: key, expiresAt: tentativeUptime + AbsentSeatReleaseDecision.confirmMaxInterval
            )
        }

        if !healedSeats.isEmpty {
            let axPresentPlaced = newOrder.filter { eligibleByCgID[$0] != nil }
            let ownerCandidates = axPresentPlaced.compactMap { cgID -> InventoryPhantomOwner? in
                #if DEBUG
                guard let token = newByID[cgID]?.token else { return nil }
                return InventoryPhantomOwner(seatToken: token, seatActiveWindowNumber: cgID)
                #else
                guard newByID[cgID] != nil else { return nil }
                return InventoryPhantomOwner(seatActiveWindowNumber: cgID)
                #endif
            }
            let owner = InventoryPhantomOwnerResolution.uniqueOwner(from: ownerCandidates)
            for cgID in healedSeats {
                if let owner {
                    newByID[owner.seatActiveWindowNumber]?.priorTabWindowNumbers.insert(cgID)
                }
                #if DEBUG
                if let reconcileContext, let healed = healedDiagnosticContext[cgID] {
                    inventoryLog.record(.phantomHealed(InventoryPhantomHealedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        releasedSeatToken: healed.token,
                        releasedActiveCgID: cgID,
                        absenceEpisodeID: healed.episodeID,
                        ownerSeatToken: owner?.seatToken,
                        ownerActiveCgID: owner?.seatActiveWindowNumber,
                        ownerCandidateCount: ownerCandidates.count
                    )))
                }
                #endif
            }
        }

        #if DEBUG
        for released in releasedSeats {
            if inventoryLog.isEnabled, let episodeID = released.seat.absenceEpisodeID {
                heldLogDeduplicator.clear(pid: pid, seatToken: released.seat.token, episodeID: episodeID)
            }
            let snapshot = inventorySeatReleaseSnapshot(app: app, seats: [released.seat])
            for payload in InventorySeatReleasePlan.payloads(
                for: snapshot,
                reason: released.reason,
                context: reconcileContext
            ) {
                inventoryLog.record(.seatReleased(payload))
            }
        }
        #endif

        let observedAXIDs = rawAXCgIDs ?? Set(eligibleByCgID.keys)
        let shouldUpdateShadowPool = !cgSnapshot.captureFailed && (!observedAXIDs.isEmpty || cgPidIDs.isEmpty)
        if shouldUpdateShadowPool {
            var pool = app.shadowTabCgIDs
            pool.formIntersection(cgPidIDs)
            for (id, window) in observedByID where !window.isMinimized { pool.remove(id) }
            pool.formUnion(cgPidIDs.subtracting(observedAXIDs).subtracting(newOrder))
            pool.subtract(nativeRoots)
            pool.subtract(excludedIDs)
            pool.subtract(reboundWindowIDs.keys)
            app.shadowTabCgIDs = pool

            #if DEBUG
            if let reconcileContext {
                var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
                func recordShadowPool(_ status: InventoryShadowPoolStatus) {
                    inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        status: status,
                        previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                        before: shadowPool.sorted(),
                        after: pool.sorted(),
                        added: pool.subtracting(shadowPool).sorted(),
                        removed: shadowPool.subtracting(pool).sorted(),
                        eligibleWindowCount: eligible.count,
                        cgWindowCount: cgPidIDs.count
                    )))
                }
                if !diagnostic.initialized {
                    recordShadowPool(.initialized)
                }
                if diagnostic.updateWasSkipped {
                    recordShadowPool(.resumed)
                } else if diagnostic.initialized, pool != shadowPool {
                    recordShadowPool(.changed)
                }
                diagnostic.initialized = true
                diagnostic.updateWasSkipped = false
                diagnostic.lastSuccessfulRoundID = reconcileContext.roundID
                shadowPoolDiagnosticsByPID[pid] = diagnostic
            }
            #endif
        } else {
            #if DEBUG
            if let reconcileContext {
                var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
                if !diagnostic.updateWasSkipped {
                    inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        status: .updateSkipped,
                        previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                        before: shadowPool.sorted(),
                        after: shadowPool.sorted(),
                        added: [],
                        removed: [],
                        eligibleWindowCount: eligible.count,
                        cgWindowCount: cgPidIDs.count
                    )))
                }
                diagnostic.updateWasSkipped = true
                shadowPoolDiagnosticsByPID[pid] = diagnostic
            }
            #endif
        }

        if !cgSnapshot.captureFailed, let observer = observers[pid] {
            let dropped = observer.retainSubscriptions(
                keep: cgIDs.union(newOrder).union(eligibleByCgID.keys).subtracting(excludedIDs)
                    .subtracting(reboundWindowIDs.keys)
            )
            #if DEBUG
            if inventoryLog.isEnabled {
                for entry in dropped {
                    recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
                        event: .leftCG, context: reconcileContext, flushID: nil, pid: pid,
                        bundleID: app.bundleIdentifier, cgWindowID: entry.cgWindowID,
                        instanceID: entry.instanceID
                    ))
                }
            }
            #endif
        }

        if !cgSnapshot.captureFailed, let destroyed = destroyedWindows[pid] {
            let retained = destroyed.filter { cgIDs.contains($0.key) || observedByID[$0.key] != nil }
            destroyedWindows[pid] = retained.isEmpty ? nil : retained
        }
        let previousWindows = app.windowsByID
        for id in app.windowOrder where pendingCGDisplayKeys[id]?.pid == pid {
            if newByID[id]?.isMinimized != false || newByID[id]?.actionTarget?.id != previousWindows[id]?.actionTarget?.id {
                pendingCGDisplayKeys.removeValue(forKey: id)
            }
        }
        app.windowOrder = newOrder
        app.windowsByID = newByID
        apps[pid] = app
        refreshSystemFocusAfterReplacingWindows(pid: pid, previous: previousWindows, current: newByID)
        let changed = actionTargetChanged || movedOwnership || seatSignature(app) != before
        gateStates[pid] = ReconcileGateState(
            lastCGIDs: cgPidIDs,
            lastFullReadUptime: uptimeProvider(),
            dirty: false,
            lastReadWasUnread: false,
            lastRoundChanged: changed || app.shadowTabCgIDs != shadowPool,
            lastSeatOnScreenIDs: Set(newOrder).intersection(onScreenCGIDs)
        )
        return changed
    }

    private func hasConfirmedDormantEvidence(
        seat: WindowEntry,
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        rawAXCgIDs: Set<CGWindowID>?,
        evidence: AbsentSeatProbeEvidence?
    ) -> Bool {
        guard cgSnapshot.isNormalRoot(windowID: seat.cgWindowID, pid: pid),
              !cgSnapshot.onScreenWindowIDs.contains(seat.cgWindowID),
              rawAXCgIDs?.contains(seat.cgWindowID) == false,
              let evidence, let handle = subscribedElement(pid: pid, cgWindowID: seat.cgWindowID),
              evidence.request.seatToken == seat.token,
              evidence.request.cgWindowID == seat.cgWindowID,
              evidence.request.instanceID == handle.instanceID,
              CFEqual(evidence.request.element.e, handle.element) else { return false }
        switch (evidence.element, evidence.spaces) {
        case (.dead, .none), (.dead, .onlyCurrent):
            return true
        case (.alive(let minimized), .none):
            return minimized == false
        default:
            return false
        }
    }

    private func prepareAbsenceProbe(
        seat: inout WindowEntry,
        pid: pid_t,
        isOnScreen: Bool,
        rawAXCgIDs: Set<CGWindowID>?
    ) {
        guard absentSeatReleaseEnabled, let rawAXCgIDs,
              !isOnScreen, !rawAXCgIDs.contains(seat.cgWindowID),
              subscribedElement(pid: pid, cgWindowID: seat.cgWindowID) != nil else {
            seat.absentProbe = nil
            return
        }
        if seat.absentProbe == nil {
            seat.absentProbe = AbsentSeatProbeState(nextProbeUptime: uptimeProvider())
        }
    }

    private func applyAbsentSeatProbe(
        seat: inout WindowEntry,
        pid: pid_t,
        bundleID: String?,
        isOnScreen: Bool,
        rawAXCgIDs: Set<CGWindowID>?,
        evidence: AbsentSeatProbeEvidence?,
        context: InventoryReconcileContext?
    ) -> Bool {
        guard absentSeatReleaseEnabled, let rawAXCgIDs else { return false }
        let cgID = seat.cgWindowID
        guard !isOnScreen, !rawAXCgIDs.contains(cgID),
              let handle = subscribedElement(pid: pid, cgWindowID: cgID) else {
            seat.absentProbe = nil
            return false
        }
        let now = uptimeProvider()
        var probe = seat.absentProbe ?? AbsentSeatProbeState(nextProbeUptime: now)
        defer { seat.absentProbe = seat.isMinimized ? nil : probe }
        guard let evidence else { return false }

        #if DEBUG
        let firstHiddenAgeMs = probe.firstHidden.map { Int(((now - $0.uptime) * 1_000).rounded()) }
        #endif
        let verdict = AbsentSeatReleaseDecision.decisionFromEvidence(AbsentSeatReleaseDecision.Input(
            evidenceMatchesSeat: evidence.request.seatToken == seat.token
                && evidence.request.cgWindowID == cgID
                && evidence.request.instanceID == handle.instanceID
                && CFEqual(evidence.request.element.e, handle.element),
            element: evidence.element,
            spaces: evidence.spaces,
            firstHidden: probe.firstHidden,
            cgWindowID: cgID,
            instanceID: evidence.request.instanceID,
            now: now
        ))
        switch verdict {
        case .release:
            break
        case .markFirst:
            probe.firstHidden = AbsentSeatProbeState.FirstHiddenMark(
                uptime: now, cgWindowID: cgID, instanceID: evidence.request.instanceID
            )
            probe.nextProbeUptime = now + AbsentSeatReleaseDecision.confirmMinInterval
        case .holdMark:
            if let first = probe.firstHidden {
                probe.nextProbeUptime = first.uptime + AbsentSeatReleaseDecision.confirmMinInterval
            }
        case .notHidden(.elementAlive):
            probe.firstHidden = nil
            if evidence.element == .alive(minimized: true) { seat.isMinimized = true }
        case .notHidden:
            probe.firstHidden = nil
        }
        #if DEBUG
        recordAbsenceProbe(
            evidence: evidence, verdict: verdict, pid: pid, bundleID: bundleID,
            context: context, firstHiddenAgeMs: firstHiddenAgeMs
        )
        #endif
        return verdict == .release
    }

    #if DEBUG
    private func recordAbsenceProbe(
        evidence: AbsentSeatProbeEvidence,
        verdict: AbsentSeatReleaseDecision.Verdict?,
        discardReason: String? = nil,
        pid: pid_t,
        bundleID: String?,
        context: InventoryReconcileContext?,
        firstHiddenAgeMs: Int?
    ) {
        guard inventoryLog.isEnabled else { return }
        let element: String
        var minimized: Bool?
        var errorCode: Int32?
        switch evidence.element {
        case .dead: element = "dead"; errorCode = AXError.invalidUIElement.rawValue
        case .alive(let value): element = "alive"; minimized = value
        case .unknown(let code): element = "unknown"; errorCode = code
        }
        let verdictName: String
        switch verdict {
        case .release: verdictName = "release"
        case .markFirst: verdictName = "markFirst"
        case .holdMark: verdictName = "holdMark"
        case .notHidden(let reason): verdictName = "notHidden:\(reason.rawValue)"
        case nil: verdictName = "discarded:\(discardReason ?? "unknown")"
        }
        inventoryLog.record(.absenceProbe(InventoryAbsenceProbePayload(
            context: context,
            pid: pid,
            bundleID: bundleID,
            seatToken: evidence.request.seatToken,
            cgWindowID: evidence.request.cgWindowID,
            instanceID: evidence.request.instanceID,
            element: element,
            elementMinimized: minimized,
            elementErrorCode: errorCode,
            windowSpaceIDs: evidence.windowSpaceIDs,
            currentSpaceIDs: evidence.currentSpaceIDs.map { $0.sorted() },
            spaceClass: evidence.spaces.rawValue,
            verdict: verdictName,
            probeCount: evidence.request.probeCount,
            firstHiddenAgeMs: firstHiddenAgeMs
        )))
    }
    #endif

    private func subscribedElement(pid: pid_t, cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        #if DEBUG
        if let overrides = subscribedElementOverridesForTesting[pid] { return overrides[cgWindowID] }
        #endif
        return observers[pid]?.subscribedElement(cgWindowID: cgWindowID)
    }

    private func takeDueAbsenceProbes(pid: pid_t) -> [AbsentSeatProbeRequest] {
        guard absentSeatReleaseEnabled, var app = apps[pid] else { return [] }
        let now = uptimeProvider()
        let due = app.windowOrder
            .compactMap { id -> (CGWindowID, AbsentSeatProbeState)? in
                guard let probe = app.windowsByID[id]?.absentProbe, probe.nextProbeUptime <= now else { return nil }
                return (id, probe)
            }
            .sorted { $0.1.nextProbeUptime < $1.1.nextProbeUptime }
            .prefix(AbsentSeatReleaseDecision.maxProbesPerRead)
        guard !due.isEmpty else { return [] }
        var requests: [AbsentSeatProbeRequest] = []
        for (cgID, state) in due {
            guard let token = app.windowsByID[cgID]?.token,
                  let handle = subscribedElement(pid: pid, cgWindowID: cgID) else {
                app.windowsByID[cgID]?.absentProbe = nil
                continue
            }
            var probe = state
            probe.probeCount += 1
            probe.nextProbeUptime = now + AbsentSeatReleaseDecision.backoff(afterDispatch: probe.probeCount)
            app.windowsByID[cgID]?.absentProbe = probe
            requests.append(AbsentSeatProbeRequest(
                cgWindowID: cgID, seatToken: token, element: AXElementKey(e: handle.element),
                instanceID: handle.instanceID, probeCount: probe.probeCount
            ))
        }
        apps[pid] = app
        return requests
    }

    private func hasDueAbsenceProbe(pid: pid_t) -> Bool {
        guard absentSeatReleaseEnabled, let app = apps[pid] else { return false }
        let now = uptimeProvider()
        return app.windowOrder.contains { (app.windowsByID[$0]?.absentProbe?.nextProbeUptime ?? .infinity) <= now }
    }

    private func armAbsenceProbes(pid: pid_t) {
        cancelAbsenceProbeTimer(pid: pid)
        guard absentSeatReleaseEnabled, let app = apps[pid] else { return }
        guard let next = app.windowOrder.compactMap({ app.windowsByID[$0]?.absentProbe?.nextProbeUptime }).min() else {
            return
        }
        let delay = next - uptimeProvider()
        if delay <= 0 {
            scheduleEventRead(pid: pid, source: .absenceProbe)
            return
        }
        guard delay < 5 else { return }
        let generation = work.generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.work.isCurrent(generation) else { return }
                self.absenceProbeTimers.removeValue(forKey: pid)
                self.armAbsenceProbes(pid: pid)
            }
        }
        absenceProbeTimers[pid] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAbsenceProbeTimer(pid: pid_t) {
        absenceProbeTimers.removeValue(forKey: pid)?.cancel()
    }

    private func clearFirstHiddenMarks(pid: pid_t) {
        guard var app = apps[pid] else { return }
        var touched = false
        for id in app.windowOrder where app.windowsByID[id]?.absentProbe?.firstHidden != nil
            || app.windowsByID[id]?.absentProbe?.tentativeTabReplacement != nil {
            app.windowsByID[id]?.absentProbe?.firstHidden = nil
            app.windowsByID[id]?.absentProbe?.tentativeTabReplacement = nil
            touched = true
        }
        if touched { apps[pid] = app }
    }

    #if DEBUG
    private func inventoryReconcileContext(
        pid: pid_t,
        source: InventoryReconcileSource,
        now: Date,
        usedPreloadedAX: Bool,
        axReadOutcome: InventoryAXReadOutcome
    ) -> InventoryReconcileContext {
        nextInventoryRoundID += 1
        let ordinal = (reconcileOrdinalsByPID[pid] ?? 0) + 1
        let gapMs = lastReconcileAtByPID[pid].map {
            max(0, Int((now.timeIntervalSince($0) * 1_000).rounded()))
        }
        reconcileOrdinalsByPID[pid] = ordinal
        lastReconcileAtByPID[pid] = now
        return InventoryReconcileContext(
            roundID: nextInventoryRoundID,
            appReconcileOrdinal: ordinal,
            source: source,
            gapMs: gapMs,
            usedPreloadedAX: usedPreloadedAX,
            axReadOutcome: axReadOutcome
        )
    }
    #endif

    #if DEBUG
    private func clearInventoryDiagnostics(pid: pid_t) {
        lastAdmissionVerdictByPID.removeValue(forKey: pid)
        reconcileOrdinalsByPID.removeValue(forKey: pid)
        lastReconcileAtByPID.removeValue(forKey: pid)
        shadowPoolDiagnosticsByPID.removeValue(forKey: pid)
        heldLogDeduplicator.removeAll(pid: pid)
    }
    #endif

    #if DEBUG
    private func inventorySeatReleaseSnapshot(
        app: AppEntry,
        seats: [WindowEntry]? = nil
    ) -> InventorySeatReleaseSnapshot {
        let selected = seats ?? app.windowOrder.compactMap { app.windowsByID[$0] }
        return InventorySeatReleaseSnapshot(
            pid: app.pid,
            bundleID: app.bundleIdentifier,
            appHidden: app.isHidden,
            seats: selected.map { entry in
                InventorySeatReleaseSnapshot.Seat(
                    seatToken: entry.token,
                    seatActiveWindowNumber: entry.cgWindowID,
                    isMinimized: entry.isMinimized,
                    isFocused: entry.isFocused,
                    everSeenVisible: entry.everSeenVisible,
                    bounds: entry.bounds
                )
            }
        )
    }
    #endif

    #if DEBUG
    private func recordProcessGoneSeats(app: AppEntry) {
        let snapshot = inventorySeatReleaseSnapshot(app: app)
        for payload in InventorySeatReleasePlan.processGonePayloads(for: snapshot) {
            inventoryLog.record(.seatReleased(payload))
        }
    }
    #endif

    private func seatSignature(_ app: AppEntry) -> String {
        app.windowOrder.map { id -> String in
            let e = app.windowsByID[id]
            return "\(id):\(e?.token ?? ""):\(e?.title ?? ""):\(e?.isMinimized == true ? 1 : 0):\(e?.isFocused == true ? 1 : 0):\(e?.displayUUID ?? "")"
        }.joined(separator: "|")
    }


    private struct CGDisplayEvidence: Equatable {
        let pid: pid_t
        let seatCreatedAt: Date
        let actionTargetID: UUID?
        let key: String
    }

    private var pendingCGDisplayKeys: [CGWindowID: CGDisplayEvidence] = [:]

    private func clearPendingCGDisplayKeys(pid: pid_t) {
        for id in apps[pid]?.windowOrder ?? [] where pendingCGDisplayKeys[id]?.pid == pid {
            pendingCGDisplayKeys.removeValue(forKey: id)
        }
    }

    private func retainedCGDisplayBounds(
        for seat: WindowEntry,
        after window: AXWindowSnapshot,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        isVisible: Bool
    ) -> CGRect? {
        guard let confirmedBounds = seat.confirmedCGDisplayBounds else { return nil }
        if seat.actionTarget != nil, !seat.matchesAXElement(window.element) { return nil }
        guard isVisible, let axBounds = window.bounds,
              let axDisplay = WindowDisplayAttribution.displayUUID(for: axBounds, table: displayTable) else {
            return confirmedBounds
        }
        if WindowFrameMatchPolicy.areClose(axBounds, confirmedBounds),
           WindowDisplayAttribution.displayUUID(for: confirmedBounds, table: displayTable) == axDisplay {
            return nil
        }
        if !cgSnapshot.captureFailed, cgSnapshot.ownerPIDByWindowID[seat.cgWindowID] == window.pid,
           let cgBounds = cgSnapshot.boundsByWindowID[seat.cgWindowID], WindowFrameMatchPolicy.isValid(cgBounds) {
            let agrees = WindowFrameMatchPolicy.areClose(axBounds, cgBounds)
                && WindowDisplayAttribution.displayUUID(for: cgBounds, table: displayTable) == axDisplay
            return agrees ? nil : confirmedBounds
        }
        let axBoundsChanged = seat.bounds.map { !WindowFrameMatchPolicy.areClose(axBounds, $0) } ?? true
        return axBoundsChanged && axDisplay != seat.displayUUID ? nil : confirmedBounds
    }

    private func refreshDisplayAttributionFromCG(_ cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        guard !cgSnapshot.captureFailed, !cgSnapshot.boundsByWindowID.isEmpty, !displayTable.displays.isEmpty else {
            pendingCGDisplayKeys.removeAll()
            return false
        }
        var changed = false
        var pending: [CGWindowID: CGDisplayEvidence] = [:]
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      cgSnapshot.ownerPIDByWindowID[cgID] == pid,
                      let rect = cgSnapshot.boundsByWindowID[cgID],
                      let key = WindowDisplayAttribution.displayUUID(for: rect, table: displayTable) else { continue }
                if key == seat.displayUUID {
                    if seat.confirmedCGDisplayBounds != nil {
                        apps[pid]?.windowsByID[cgID]?.confirmedCGDisplayBounds = rect
                    }
                    continue
                }
                let evidence = CGDisplayEvidence(pid: pid, seatCreatedAt: seat.createdAt,
                                                 actionTargetID: seat.actionTarget?.id, key: key)
                guard pendingCGDisplayKeys[cgID] == evidence else {
                    pending[cgID] = evidence
                    continue
                }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                apps[pid]?.windowsByID[cgID]?.confirmedCGDisplayBounds = rect
                changed = true
            }
        }
        pendingCGDisplayKeys = pending
        return changed
    }

    private func handleScreenParametersChanged() {
        updateDisplayTopology(displayTableProvider())
    }

    func updateDisplayTopology(_ table: WindowDisplayAttribution.Table) {
        guard displayTable != table else { return }
        displayTable = table
        pendingCGDisplayKeys.removeAll()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized else { continue }
                let bounds = seat.confirmedCGDisplayBounds ?? seat.bounds
                guard let key = WindowDisplayAttribution.displayUUID(for: bounds, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }


    private func seedRunningApps() {
        guard work.isActive else { return }
        #if DEBUG
        let seedStart: Date? = Date()
        #else
        let seedStart: Date? = nil
        #endif
        let configured = Int(DebugSwitch.seedAxTimeoutMs.value() ?? "") ?? 100
        let messagingTimeout: TimeInterval? = configured == 0 ? nil : max(0.001, Double(configured) / 1_000)
        let candidates = runningApplications.filter(isWindowCandidate).map {
            (identity: processIdentity(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier),
             requiresOwner: !eligibilityApplication(for: $0).canOwnTaskbarWindows)
        }
        let reader = reader
        let processProvider = processProvider
        let embeddedPIDs = Set(candidates.filter(\.requiresOwner).map { $0.identity.pid })
        work.launch { [weak self] generation in
            let ownerCancellation = OperationCancellation()
            guard let owners = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: ownerCancellation, operation: {
                processProvider.applicationOwners(for: embeddedPIDs, cancellation: ownerCancellation)
            }) else { return }
            var results: [ApplicationProbe] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let cancellation = OperationCancellation()
                guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation, operation: {
                    Self.probeApplication(candidate.identity, requiresOwner: candidate.requiresOwner,
                        owner: owners[candidate.identity.pid], reader: reader, timeout: messagingTimeout, cancellation: cancellation)
                }) else { return }
                results.append(result)
            }
            let probed = results
            await MainActor.run {
                guard let self, self.work.isCurrent(generation) else { return }
                self.completeSeed(probed, messagingTimeout: messagingTimeout, startedAt: seedStart)
            }
        }
    }

    private func completeSeed(
        _ probed: [ApplicationProbe],
        messagingTimeout: TimeInterval?, startedAt: Date?
    ) {
        let useTimeout = messagingTimeout != nil
        let messagingTimeout = messagingTimeout ?? 0
        #if DEBUG
        var admittedCount = 0
        var unreadList: [String] = []
        #endif
        let cgSnapshot = currentCGSnapshot(cgSnapshotProvider())
        for entry in probed {
            let pid = entry.identity.pid
            defer { if apps[pid] == nil { ownerBindings.removeValue(forKey: pid) } }
            rememberOwner(entry)
            guard apps[pid] == nil, let app = applicationForAdmission(pid: pid),
                  isWindowApplication(app), !isTerminatedForAdmission(app),
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: entry.identity,
                    current: processIdentity(pid: pid, bundleID: app.bundleIdentifier)) else { continue }
            let bid = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)
            let result = entry.result
            let probedEligible: [AXWindowSnapshot]
            let inventoryReadOutcome: InventoryAXReadOutcome
            switch result {
            case .success(let snaps):
                probedEligible = snaps.filter {
                    isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                inventoryReadOutcome = .success(count: snaps.count)
            case .unread(let error):
                probedEligible = []
                inventoryReadOutcome = .unread(errorCode: error.rawValue)
                #if DEBUG
                unreadList.append(app.localizedName ?? bid ?? "\(pid)")
                #endif
            }

            #if DEBUG
            let seedVerdict: InventoryAdmissionProbeVerdict
            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                seedVerdict = .admitFinderPersistent
            } else if case .unread = result {
                seedVerdict = .skipUnread
            } else if probedEligible.isEmpty {
                seedVerdict = .skipNoEligible
            } else {
                seedVerdict = .admit
            }
            noteAdmissionVerdict(pid: pid, verdict: seedVerdict.rawValue, source: "seed")
            if inventoryLog.isEnabled {
                recordAdmissionProbe(
                    source: .seed,
                    identity: entry.identity,
                    readMode: useTimeout ? .timed : .untimed,
                    messagingTimeoutMs: useTimeout ? Int((messagingTimeout * 1_000).rounded()) : nil,
                    maxAttempts: useTimeout ? 1 : 2,
                    result: result,
                    eligibleWindowCount: result.isSuccess ? probedEligible.count : nil,
                    verdict: seedVerdict
                )
            }
            #endif

            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed,
                    rawAXWindows: result.isSuccess ? result.windowsOrEmpty : nil
                )
                #if DEBUG
                admittedCount += 1
                #endif
                continue
            }

            if !probedEligible.isEmpty {
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed,
                    rawAXWindows: result.isSuccess ? result.windowsOrEmpty : nil
                )
                #if DEBUG
                admittedCount += 1
                #endif
            }
        }

        rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
        #if DEBUG
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        logger.info("seed done: \(admittedCount) admitted, \(unreadList.count) unread, elapsed=\(String(format: "%.2f", elapsed))s")
        #endif
    }


    private func subscribeWorkspaceNotifications() {
        let generation = work.generation
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleAppLaunched(app)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleAppTerminated(pid: pid)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleAppHidden(pid: pid)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.handleAppUnhidden(pid: pid)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.cachedFrontmostPID = pid
                self.handleAppActivated(app)
            }
        })
    }


    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard isWindowCandidate(app) else { return }
        scanDirtyPIDs.insert(app.processIdentifier)
        scanCandidateCache = nil
        if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
            if let stalePID = appOrder.first(where: {
                FinderWindowRules.isFinder(bundleIdentifier: apps[$0]?.bundleIdentifier)
            }), stalePID != app.processIdentifier {
                removeTrackedProcess(pid: stalePID)
            }
            addApp(app, enumerateImmediately: true)
            rebuildSnapshot()
            return
        }
        scheduleRetryAdmission(app: app, delays: [0.2, 0.5, 1.0, 2.0])
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        defer { rebuildSnapshot() }
        requestSystemFocusedWindowRead()
        guard isWindowCandidate(app) else { return }
        for (pid, binding) in ownerBindings where binding.owner.identity.pid == app.processIdentifier {
            if applicationOwner(for: pid) != nil { requestFocusedWindowRead(pid: pid) }
        }
        if !isWindowApplication(app) {
            scheduleRetryAdmission(app: app, delays: [0])
            return
        }
        guard apps[app.processIdentifier] == nil else {
            markReconcileGateDirty(pid: app.processIdentifier)
            requestFocusedWindowRead(pid: app.processIdentifier)
            return
        }
        addApp(app, enumerateImmediately: true)
    }

    func handleAppTerminated(pid: pid_t) {
        let helpers = ownerBindings.filter { $0.value.owner.identity.pid == pid }.map(\.key)
        for helper in helpers { removeTrackedProcess(pid: helper) }
        removeTrackedProcess(pid: pid)
        rebuildSnapshot()
    }

    private func removeTrackedProcess(pid: pid_t) {
        cgEventGeneration &+= 1
        clearPendingCGDisplayKeys(pid: pid)
        observers.removeValue(forKey: pid)?.stop()
        #if DEBUG
        if let app = apps[pid] { recordProcessGoneSeats(app: app) }
        #endif
        apps.removeValue(forKey: pid)
        destroyedWindows.removeValue(forKey: pid)
        ownerBindings.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        pendingEventReads.removeValue(forKey: pid)
        queuedPeriodicReads.removeValue(forKey: pid)
        trailingEventSources.removeValue(forKey: pid)
        inventoryTimeouts.removeValue(forKey: pid)
        frontmostProbeIDs.removeValue(forKey: pid)
        focusRevisions.removeValue(forKey: pid)
        confirmedFocus.removeValue(forKey: pid)
        pendingFocusReads.removeValue(forKey: pid)
        trailingFocusReads.remove(pid)
        mutationGenerations.removeValue(forKey: pid)
        #if DEBUG
        clearInventoryDiagnostics(pid: pid)
        #endif
        gateStates.removeValue(forKey: pid)
        cancelAbsenceProbeTimer(pid: pid)
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil
        elementCache.removeAll(pid: pid)
        #if DEBUG
        observerActiveOverridesForTesting.removeValue(forKey: pid)
        subscribedElementOverridesForTesting.removeValue(forKey: pid)
        #endif
    }

    private func handleAppHidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        clearPendingCGDisplayKeys(pid: pid)
        apps[pid]?.isHidden = true
        rebuildSnapshot()
    }

    private func handleAppUnhidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        apps[pid]?.isHidden = false
        rebuildSnapshot()
    }


    private func addApp(
        _ app: NSRunningApplication,
        enumerateImmediately: Bool,
        source: InventoryReconcileSource = .initialEnumeration
    ) {
        let pid = app.processIdentifier
        guard apps[pid] == nil, isWindowApplication(app) else { return }
        cgEventGeneration &+= 1
        let application = eligibilityApplication(for: app)

        guard let generation = processGeneration(processIdentity(pid: pid, bundleID: application.bundleIdentifier)) else { return }

        apps[pid] = AppEntry(
            pid: pid,
            bundleIdentifier: application.bundleIdentifier,
            appName: application.appName,
            activationPolicy: application.activationPolicy,
            executablePath: application.executablePath,
            windowsByID: [:],
            windowOrder: [],
            isHidden: app.isHidden,
            applicationOrigin: ApplicationOrigin(bundleURL: app.bundleURL),
            processGeneration: generation
        )
        appOrder.append(pid)
        mutationGenerations[pid, default: 0] &+= 1
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil
        requestSystemFocusedWindowRead()

        if AXIsProcessTrusted() {
            let obs = AppWindowObserver(pid: pid)
            #if DEBUG
            obs.onSubscriptionAttempt = { [weak self] report in
                self?.recordSubscriptionAttempt(report, context: nil, flushID: nil)
            }
            obs.onSubscriptionDestroyNotified = { [weak self] pid, cgID, removedInstanceID in
                self?.noteSubscriptionDestroyNotified(pid: pid, cgWindowID: cgID, removedInstanceID: removedInstanceID)
            }
            #endif
            obs.onWindowCreated = { [weak self] pid in self?.handleWindowCreated(pid: pid) }
            obs.onWindowDestroyed = { [weak self] pid, cgID, element in
                self?.handleWindowDestroyed(pid: pid, cgWindowID: cgID, element: element)
            }
            obs.onWindowMinimized = { [weak self] pid, cgID in self?.handleWindowMinimized(pid: pid, cgWindowID: cgID) }
            obs.onWindowDeminiaturized = { [weak self] pid, cgID in self?.handleWindowDeminiaturized(pid: pid, cgWindowID: cgID) }
            obs.onFocusedWindowChanged = { [weak self] pid in self?.handleFocusedWindowChanged(pid: pid) }
            obs.onTitleChanged = { [weak self] pid, cgID in self?.handleTitleChanged(pid: pid, cgWindowID: cgID) }
            obs.start()
            observers[pid] = obs
        }

        if enumerateImmediately {
            scheduleEventRead(pid: pid, source: source)
        }
    }

    private func scheduleRetryAdmission(app: NSRunningApplication, delays: [TimeInterval]) {
        let pid = app.processIdentifier
        let reader = reader
        let processProvider = processProvider
        let requiresOwner = !eligibilityApplication(for: app).canOwnTaskbarWindows
        for delay in delays {
            work.launch(after: delay) { [weak self] generation in
                let identity = await MainActor.run { () -> ScanAdmissionDecision.ProcessIdentity? in
                    guard let self, self.work.isCurrent(generation), self.processProvider.isAlive(pid: pid) else { return nil }
                    if self.apps[pid] != nil {
                        self.scheduleEventRead(pid: pid, source: .initialEnumeration)
                        return nil
                    }
                    guard let current = self.applicationForAdmission(pid: pid) else { return nil }
                    return self.processIdentity(pid: pid, bundleID: current.bundleIdentifier)
                }
                guard let identity, !Task.isCancelled else { return }
                let cancellation = OperationCancellation()
                guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation, operation: {
                    Self.probeApplication(identity, requiresOwner: requiresOwner,
                        owner: requiresOwner ? processProvider.applicationOwner(pid: pid) : nil, reader: reader,
                        timeout: 0.1, cancellation: cancellation)
                }) else { return }
                await MainActor.run {
                    guard let self, self.work.isCurrent(generation) else { return }
                    defer { if self.apps[pid] == nil { self.ownerBindings.removeValue(forKey: pid) } }
                    self.rememberOwner(result)
                    let result = result.result
                    guard self.apps[pid] == nil,
                          let current = self.applicationForAdmission(pid: pid),
                          self.isWindowApplication(current), !self.isTerminatedForAdmission(current),
                          ScanAdmissionDecision.ProcessIdentity.matches(probed: identity,
                            current: self.processIdentity(pid: pid, bundleID: current.bundleIdentifier)) else { return }
                    let rawWindows = result.windowsOrEmpty
                    guard !rawWindows.isEmpty else {
                        #if DEBUG
                        self.noteAdmissionVerdict(pid: pid,
                            verdict: result.isSuccess ? "skipNoEligible" : "skipUnread", source: "launchRetry")
                        #endif
                        return
                    }
                    let cgSnapshot = self.currentCGSnapshot(self.cgSnapshotProvider())
                    let application = self.eligibilityApplication(for: current)
                    let prepared = ScanAdmissionDecision.prepare(rawWindows: rawWindows) {
                        self.isEligible($0, application: application, cgSnapshot: cgSnapshot)
                    }
                    #if DEBUG
                    self.noteAdmissionVerdict(pid: pid,
                        verdict: prepared.eligible.isEmpty ? "skipNoEligible" : "admit", source: "launchRetry")
                    #endif
                    if !prepared.eligible.isEmpty {
                        self.admit(app: current, prepared: prepared,
                            readOutcome: .success(count: prepared.rawCount), cgSnapshot: cgSnapshot,
                            rawAXWindows: rawWindows)
                        self.rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
                    }
                }
            }
        }
    }


    private func isEligible(
        _ snap: AXWindowSnapshot,
        application: AppTrackerWindowEligibility.Application,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        if !cgSnapshot.captureFailed, let id = snap.cgWindowID,
           let owner = cgSnapshot.ownerPIDByWindowID[id], owner != snap.pid {
            return false
        }
        let alpha = snap.cgWindowID.flatMap { cgSnapshot.alphaByWindowID[$0] }
        let isNativeRoot = snap.cgWindowID.map { cgSnapshot.isNormalRoot(windowID: $0, pid: snap.pid) } ?? false
        let previousSeat = snap.cgWindowID.flatMap { apps[snap.pid]?.windowsByID[$0] }
            ?? (isNativeRoot ? apps[snap.pid]?.windowsByID.values.first { $0.matchesAXElement(snap.element) } : nil)
        let matchesPreviousElement = previousSeat?.matchesAXElement(snap.element) == true
        let eligibilityTitle: String?
        if case .unread = snap.titleRead, matchesPreviousElement {
            eligibilityTitle = previousSeat?.title
        } else {
            eligibilityTitle = snap.title
        }
        let retainsUntitledAccessoryWindow = application.activationPolicy == .accessory && snap.title == nil
            && matchesPreviousElement
        return windowEligibility.isEligible(
            title: eligibilityTitle,
            role: snap.role,
            subrole: snap.subrole,
            bounds: snap.bounds,
            alpha: alpha,
            isMinimized: snap.isMinimized,
            isBelowNormalLayer: snap.cgWindowID.map {
                cgSnapshot.belowNormalLayerWindowIDs.contains($0)
            } ?? false,
            application: application, isModal: snap.isModal, isTopLevel: snap.isTopLevel,
            isNativeRoot: isNativeRoot,
            isFocusedWindow: snap.isFocusedWindow,
            isKnownWindow: matchesPreviousElement,
            retainsUntitledAccessoryWindow: retainsUntitledAccessoryWindow
        )
    }

    private func eligibilityApplication(for app: AppEntry) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            activationPolicy: app.activationPolicy,
            executablePath: app.executablePath
        )
    }

    private func eligibilityApplication(for app: NSRunningApplication) -> AppTrackerWindowEligibility.Application {
        #if DEBUG
        if admissionAppsForTesting?.contains(where: { $0.processIdentifier == app.processIdentifier }) == true,
           let admissionApplicationForTesting {
            return admissionApplicationForTesting
        }
        #endif
        return AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path,
            bundleURL: app.bundleURL
        )
    }


    private func subscribeWindow(
        pid: pid_t,
        element: AXUIElement,
        cgWindowID: CGWindowID,
        context: InventoryReconcileContext?
    ) {
        guard let observer = observers[pid] else { return }
        switch observer.registerWindow(element, cgWindowID: cgWindowID) {
        case .none:
            return
        case .scheduled:
            return
        case .retryDue(let candidate):
            retryCandidates.append(candidate)
            guard !retryFlushScheduled else { return }
            retryFlushScheduled = true
            let generation = work.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.flushRetryCandidates()
            }
        }
    }

    private func flushRetryCandidates() {
        retryFlushScheduled = false
        let candidates = retryCandidates
        retryCandidates.removeAll()
        guard !candidates.isEmpty else { return }
        #if DEBUG
        nextRetryFlushID &+= 1
        let flushID = nextRetryFlushID
        #endif
        let observers = self.observers
        let choice = WindowSubscriptionRetryScheduler.pick(candidates) { candidate in
            observers[candidate.pid]?.isRetryValid(candidate) ?? false
        }
        guard let picked = choice.picked, let observer = observers[picked.pid] else { return }
        #if DEBUG
        observer.performRetry(picked) { [weak self] report in
            guard let self, self.work.isActive else { return }
            if self.inventoryLog.isEnabled {
                self.inventoryLog.record(.subscriptionRetryFlush(InventorySubscriptionRetryFlushPayload(
                    flushID: flushID,
                    candidates: candidates.map { InventorySubscriptionRetryCandidateEntry(pid: $0.pid, cgWindowID: $0.cgWindowID) },
                    skippedInvalid: choice.skippedInvalid, executedPID: report.pid,
                    executedCgWindowID: report.cgWindowID, durationMs: report.durationMs
                )))
                self.recordSubscriptionAttempt(report, context: nil, flushID: flushID)
            }
        }
        #else
        observer.performRetry(picked)
        #endif
    }

    #if DEBUG
    private func recordSubscriptionAttempt(
        _ report: WindowSubscriptionAttemptReport,
        context: InventoryReconcileContext?,
        flushID: UInt64?
    ) {
        guard inventoryLog.isEnabled else { return }
        recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
            event: .attempt, context: context, flushID: flushID, pid: report.pid,
            bundleID: apps[report.pid]?.bundleIdentifier, cgWindowID: report.cgWindowID,
            instanceID: report.instanceID, previousInstanceID: report.previousInstanceID,
            kind: report.kind,
            results: Dictionary(uniqueKeysWithValues: report.results.map { ($0.key.logName, $0.value.rawValue) }),
            stop: report.stop, covered: report.covered,
            durationMs: (report.durationMs * 10).rounded() / 10
        ))
    }
    #endif

    #if DEBUG
    private func noteSubscriptionDestroyNotified(pid: pid_t, cgWindowID: CGWindowID, removedInstanceID: UInt64?) {
        guard inventoryLog.isEnabled else { return }
        recordSubscriptionEvent(InventoryWindowSubscriptionPayload(
            event: .destroyNotified, context: nil, flushID: nil, pid: pid,
            bundleID: apps[pid]?.bundleIdentifier, cgWindowID: cgWindowID,
            instanceID: removedInstanceID, removedCurrent: removedInstanceID != nil
        ))
    }
    #endif

    #if DEBUG
    private func recordSubscriptionEvent(_ payload: InventoryWindowSubscriptionPayload) {
        inventoryLog.record(.windowSubscription(payload))
    }
    #endif


    private func handleWindowCreated(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        scheduleEventRead(pid: pid, source: .windowCreated)
    }

    private func handleWindowDestroyed(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement?) {
        guard apps[pid] != nil else { return }
        pendingCGDisplayKeys.removeValue(forKey: cgWindowID)
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        if let focus = confirmedFocus[pid], focus.windowID == cgWindowID,
           element == nil || focus.element == element.map(AXElementKey.init(e:)) {
            confirmedFocus.removeValue(forKey: pid)
            apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        }
        destroyedWindows[pid, default: [:]][cgWindowID] = DestroyedWindow(element: element)
        purgeFromSeatHistories(cgWindowID)
        elementCache.remove(pid: pid, cgWindowID: cgWindowID)
        scheduleEventRead(pid: pid, source: .windowDestroyed)
    }

    private func handleWindowMinimized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        pendingCGDisplayKeys.removeValue(forKey: cgWindowID)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = true
        apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        rebuildSnapshot()
    }

    private func handleWindowDeminiaturized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        clearFirstHiddenMarks(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = false
        rebuildSnapshot()
    }

    func handleFocusedWindowChanged(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        requestFocusedWindowRead(pid: pid)
        scheduleEventRead(pid: pid, source: .focusChanged)
    }

    private func requestFocusedWindowRead(pid: pid_t) {
        guard work.isActive, apps[pid] != nil else { return }
        requestSystemFocusedWindowRead()
        focusRevisions[pid, default: 0] &+= 1
        if pendingFocusReads[pid] != nil {
            trailingFocusReads.insert(pid)
            return
        }
        beginFocusedWindowRead(pid: pid)
    }

    private func beginFocusedWindowRead(pid: pid_t) {
        guard let app = apps[pid] else { return }
        let identity = processIdentity(pid: pid, bundleID: app.bundleIdentifier)
        guard canReadTrackedProcess(pid: pid, identity: identity) else { return }
        let request = PendingFocusRead(revision: focusRevisions[pid, default: 0],
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: identity)
        pendingFocusReads[pid] = request
        let reader = reader
        work.launch(priority: .userInitiated) { [weak self] generation in
            let cancellation = OperationCancellation()
            guard let result = await AsyncWorkScope.performBlocking(cancellation: cancellation, operation: {
                reader.focusedWindowRead(forPID: pid, messagingTimeout: 0.05, cancellation: cancellation)
            }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.pendingFocusReads[pid]?.id == request.id else { return }
                self.pendingFocusReads.removeValue(forKey: pid)
                if self.trailingFocusReads.remove(pid) != nil {
                    self.beginFocusedWindowRead(pid: pid)
                    return
                }
                guard self.focusRevisions[pid] == request.revision,
                      self.mutationGenerations[pid, default: 0] == request.mutationGeneration,
                      let app = self.apps[pid],
                      app.processGeneration != nil,
                      app.processGeneration == self.processGeneration(request.identity),
                      ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity,
                          current: self.processIdentity(pid: pid, bundleID: app.bundleIdentifier)) else { return }
                guard self.confirmedFocus[pid].map({ $0.observedAt <= result.observedAt }) ?? true else { return }
                let focused: CGWindowID?
                switch result.result {
                case let .window(id): focused = id
                case .none: focused = nil
                case .unread: return
                }
                let focusElement = result.windowElement ?? focused.flatMap { app.windowsByID[$0]?.actionTarget?.element }
                self.confirmedFocus[pid] = ConfirmedFocus(observedAt: result.observedAt, windowID: focused,
                                                          element: focusElement)
                for id in app.windowOrder {
                    self.apps[pid]?.windowsByID[id]?.isFocused = id == focused &&
                        (focusElement.map { app.windowsByID[id]?.actionTarget?.element == $0 } ?? true)
                }
                self.rebuildSnapshot(onScreenCGIDs: self.lastOnScreenCGIDs)
            }
        }
    }

    private func systemFocusFamily(frontmostPID: pid_t?) -> pid_t? {
        guard let frontmostPID else { return nil }
        if let binding = ownerBindings[frontmostPID] { return binding.owner.identity.pid }
        return ownerBindings.contains { apps[$0.key] != nil && $0.value.owner.identity.pid == frontmostPID } ? frontmostPID : nil
    }

    private func refreshSystemFocusAfterReplacingWindows(pid: pid_t, previous: [CGWindowID: WindowEntry],
                                                          current: [CGWindowID: WindowEntry]) {
        let confirmed = confirmedSystemFocus
        let hasPendingRead = pendingSystemFocusRead?.identities[pid] != nil
        guard confirmed?.identity.pid == pid || hasPendingRead else { return }

        func wasReplaced(_ id: CGWindowID) -> Bool {
            guard let old = previous[id]?.actionTarget?.element,
                  let new = current[id]?.actionTarget?.element else { return false }
            return old != new
        }

        if let confirmed, confirmed.identity.pid == pid, wasReplaced(confirmed.windowID),
           confirmed.windowElement != current[confirmed.windowID]?.actionTarget?.element {
            confirmedSystemFocus = nil
            requestSystemFocusedWindowRead(invalidate: false)
        } else if hasPendingRead && current.keys.contains(where: wasReplaced) {
            requestSystemFocusedWindowRead(invalidate: false)
        }
    }

    private func requestSystemFocusedWindowRead(invalidate: Bool = true) {
        guard work.isActive, systemFocusFamily(frontmostPID: currentFrontmostPID()) != nil else { return }
        systemFocusRevision &+= 1
        if invalidate {
            let hadFocus = confirmedSystemFocus != nil
            confirmedSystemFocus = nil
            if hadFocus { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
        }
        if pendingSystemFocusRead != nil {
            trailingSystemFocusRead = true
            return
        }
        beginSystemFocusedWindowRead()
    }

    private func beginSystemFocusedWindowRead() {
        guard let frontmostPID = currentFrontmostPID(), let family = systemFocusFamily(frontmostPID: frontmostPID) else { return }
        let identities = Dictionary(uniqueKeysWithValues: appOrder.compactMap { pid -> (pid_t, ScanAdmissionDecision.ProcessIdentity)? in
            guard let app = apps[pid], pid == family || applicationOwner(for: pid)?.pid == family else { return nil }
            let identity = processIdentity(pid: pid, bundleID: app.bundleIdentifier)
            guard app.processGeneration != nil, app.processGeneration == processGeneration(identity) else { return nil }
            return (pid, identity)
        })
        let request = PendingSystemFocusRead(revision: systemFocusRevision, frontmostPID: frontmostPID,
            identities: identities, mutationGenerations: mutationGenerations)
        pendingSystemFocusRead = request
        let reader = reader
        work.launch(priority: .userInitiated) { [weak self] generation in
            let cancellation = OperationCancellation()
            guard let result = await AsyncWorkScope.performBlocking(cancellation: cancellation, operation: {
                reader.systemFocusedWindowRead(messagingTimeout: 0.05, cancellation: cancellation)
            }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.pendingSystemFocusRead?.id == request.id else { return }
                self.pendingSystemFocusRead = nil
                if self.trailingSystemFocusRead {
                    self.trailingSystemFocusRead = false
                    self.beginSystemFocusedWindowRead()
                    return
                }
                guard self.systemFocusRevision == request.revision, self.currentFrontmostPID() == request.frontmostPID else { return }
                self.confirmedSystemFocus = nil
                if case let .window(pid, windowID) = result.result, let identity = request.identities[pid],
                   self.mutationGenerations[pid, default: 0] == request.mutationGenerations[pid, default: 0],
                   let app = self.apps[pid], app.processGeneration == self.processGeneration(identity),
                   ScanAdmissionDecision.ProcessIdentity.matches(probed: identity,
                       current: self.processIdentity(pid: pid, bundleID: app.bundleIdentifier)) {
                    self.confirmedSystemFocus = ConfirmedSystemFocus(frontmostPID: request.frontmostPID,
                        identity: identity, windowID: windowID, windowElement: result.windowElement,
                        mutationGeneration: request.mutationGenerations[pid, default: 0])
                }
                self.rebuildSnapshot(onScreenCGIDs: self.lastOnScreenCGIDs)
            }
        }
    }

    private func handleTitleChanged(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .titleChanged)
    }

    private func markReconcileGateDirty(pid: pid_t) {
        gateStates[pid]?.dirty = true
        cgEventGeneration &+= 1
    }

    private func invalidateEventReads(pid: pid_t) {
        guard apps[pid] != nil else { return }
        mutationGenerations[pid, default: 0] &+= 1
        if let inFlight = pendingEventReads[pid], trailingEventSources[pid] == nil {
            trailingEventSources[pid] = inFlight.source
        }
    }

    private func scheduleEventRead(
        pid: pid_t,
        source: InventoryReconcileSource,
        frontmostProbe: FrontmostProbe? = nil,
        isPeriodic: Bool = false
    ) {
        guard work.isActive, apps[pid] != nil else { return }
        if pendingEventReads[pid] != nil {
            trailingEventSources[pid] = source
            return
        }

        let identity = processIdentity(pid: pid, bundleID: apps[pid]?.bundleIdentifier)
        guard canReadTrackedProcess(pid: pid, identity: identity) else { return }
        guard canRetryInventory(identity: identity, isPeriodic: isPeriodic) else {
            if source != .frontmostPoll, source != .absenceProbe, source != .periodicReconcile {
                trailingEventSources[pid] = source
            }
            return
        }
        trailingEventSources.removeValue(forKey: pid)
        queuedPeriodicReads.removeValue(forKey: pid)

        nextEventReadToken &+= 1
        let request = PendingEventRead(
            token: nextEventReadToken,
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: identity,
            source: source,
            absenceProbes: takeDueAbsenceProbes(pid: pid)
        )
        pendingEventReads[pid] = request
        let reader = self.reader
        let cgSnapshotProvider = self.cgSnapshotProvider
        let probeProvider = self.onScreenWindowIDsProvider
        let prober = self.absentSeatProber
        let ticket = makeCGSnapshotReuseTicket(pid: pid)

        work.launch { [weak self] generation in
            let cancellation = OperationCancellation()
            guard let read = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation, operation: {
                let result = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1, cancellation: cancellation)
                var evidence: [AbsentSeatProbeEvidence] = []
                if !request.absenceProbes.isEmpty, case .success = result {
                    evidence = request.absenceProbes.map { prober.probe($0, messagingTimeout: 0.1) }
                }
                let acquisition: CGSnapshotAcquisition
                let verdict = request.absenceProbes.isEmpty && frontmostProbe == nil
                    ? CGSnapshotReuseDecision.decideBeforeProbe(ticket.input) : .captureWithoutProbe
                switch verdict {
                case .captureWithoutProbe:
                    let probe = frontmostProbe?.windowIDs == nil ? nil : probeProvider()
                    acquisition = CGSnapshotAcquisition(
                        snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                    )
                case .captureAndPrime:
                    let probe = probeProvider()
                    acquisition = CGSnapshotAcquisition(
                        snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                    )
                case .probeThenCompare:
                    guard let probe = probeProvider() else {
                        acquisition = CGSnapshotAcquisition(
                            snapshot: cgSnapshotProvider(), probeIDs: nil, fresh: true, ticket: ticket
                        )
                        break
                    }
                    switch CGSnapshotReuseDecision.decideAfterProbe(
                        probe: probe, cachedProbe: ticket.cachedProbeIDs ?? []
                    ) {
                    case .reuse:
                        if let cached = ticket.cachedSnapshot,
                           !CGSnapshotReuseDecision.cacheHasNonstandardLayer(
                               axWindowIDs: Set(result.windowsOrEmpty.compactMap(\.cgWindowID)),
                               cachedBelowNormalLayerIDs: cached.belowNormalLayerWindowIDs
                           ), !CGSnapshotReuseDecision.cachedParentVetoApplies(
                               windowIDs: ticket.seatedWindowIDs.union(result.windowsOrEmpty.compactMap(\.cgWindowID)),
                               cachedParentWindowIDs: cached.parentWindowIDs
                           ) {
                            acquisition = CGSnapshotAcquisition(
                                snapshot: cached, probeIDs: probe, fresh: false, ticket: ticket
                            )
                        } else {
                            acquisition = CGSnapshotAcquisition(
                                snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                            )
                        }
                    case .captureAndPrime:
                        acquisition = CGSnapshotAcquisition(
                            snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                        )
                    }
                }
                return (result, acquisition, evidence)
            }) else { return }
            let (result, acquisition, landedEvidence) = read
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.noteCGSnapshotAcquisition(acquisition)
                self.completeEventRead(
                    pid: pid,
                    request: request,
                    result: result,
                    cgSnapshot: self.currentCGSnapshot(acquisition.snapshot),
                    frontmostProbeIDs: acquisition.probeIDs,
                    absenceEvidence: landedEvidence
                )
            }
        }
    }

    private func canRetryInventory(identity: ScanAdmissionDecision.ProcessIdentity, isPeriodic: Bool) -> Bool {
        guard let timeout = inventoryTimeouts[identity.pid], timeout.identity == identity else { return true }
        guard let next = timeout.nextReadUptime else { return isPeriodic }
        return uptimeProvider() >= next
    }

    private func recordInventoryResult(_ result: AXWindowReadResult, identity: ScanAdmissionDecision.ProcessIdentity) {
        switch result {
        case .success:
            inventoryTimeouts.removeValue(forKey: identity.pid)
        case .unread:
            let failures = inventoryTimeouts[identity.pid].flatMap {
                $0.identity == identity ? $0.failures : nil
            } ?? 0
            let delay = Self.inventoryRetryDelays.indices.contains(failures) ? Self.inventoryRetryDelays[failures] : nil
            inventoryTimeouts[identity.pid] = InventoryTimeout(
                identity: identity,
                failures: min(failures + 1, Self.inventoryRetryDelays.count + 1),
                nextReadUptime: delay.map { uptimeProvider() + $0 }
            )
        }
    }

    private struct CGSnapshotAcquisition: Sendable {
        let snapshot: AppTrackerCGWindowSnapshot
        let probeIDs: Set<CGWindowID>?
        let fresh: Bool
        let ticket: CGSnapshotReuseTicket
    }

    private struct CGSnapshotReuseTicket: Sendable {
        let input: CGSnapshotReuseDecision.Input
        let cachedSnapshot: AppTrackerCGWindowSnapshot?
        let cachedProbeIDs: Set<CGWindowID>?
        let uptime: TimeInterval
        let generation: UInt64
        let seatedWindowIDs: Set<CGWindowID>
    }

    private func makeCGSnapshotReuseTicket(pid: pid_t) -> CGSnapshotReuseTicket {
        let now = uptimeProvider()
        let app = apps[pid]
        let input = CGSnapshotReuseDecision.Input(
            usesSnapshotCache: cgSnapshotReuseEnabled,
            hasCachedSnapshot: cachedCGSnapshot != nil && cachedCGProbeIDs != nil,
            didCacheReadFail: cachedCGSnapshot?.captureFailed ?? true,
            cachedSnapshotAge: now - cachedCGAtUptime,
            isSnapshotGenerationCurrent: cachedCGGeneration == cgEventGeneration,
            hasPendingAbsenceCheck: app?.windowOrder.contains {
                app?.windowsByID[$0]?.minAbsentSince != nil
            } ?? false,
            hasUnresolvedPhantomSeat: app?.windowOrder.contains {
                app?.windowsByID[$0]?.everSeenVisible == false
            } ?? false,
            hasActiveWindowObserver: observerActive(pid: pid)
        )
        return CGSnapshotReuseTicket(
            input: input,
            cachedSnapshot: cachedCGSnapshot,
            cachedProbeIDs: cachedCGProbeIDs,
            uptime: now,
            generation: cgEventGeneration,
            seatedWindowIDs: Set(app?.windowOrder ?? [])
        )
    }

    private func noteCGSnapshotAcquisition(_ acquisition: CGSnapshotAcquisition) {
        guard cgSnapshotReuseEnabled, acquisition.fresh, !acquisition.snapshot.captureFailed,
              let probe = acquisition.probeIDs,
              acquisition.ticket.uptime >= cachedCGAtUptime else { return }
        cachedCGSnapshot = acquisition.snapshot
        cachedCGProbeIDs = probe
        cachedCGAtUptime = acquisition.ticket.uptime
        cachedCGGeneration = acquisition.ticket.generation
    }

    private func currentCGSnapshot(_ snapshot: AppTrackerCGWindowSnapshot) -> AppTrackerCGWindowSnapshot {
        guard let capturedAt = snapshot.capturedAt else { return snapshot }
        if let latest = latestCGSnapshot, let latestCapturedAt = latest.capturedAt {
            if capturedAt <= latestCapturedAt { return latest }
        }
        latestCGSnapshot = snapshot
        return snapshot
    }

    private enum EventReadLanding {
        case staleToken
        case skipped
        case reconciled(seatsChanged: Bool)
    }

    private func landEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        absenceEvidence: [AbsentSeatProbeEvidence] = []
    ) -> EventReadLanding {
        guard pendingEventReads[pid]?.token == request.token else { return .staleToken }
        pendingEventReads.removeValue(forKey: pid)

        let currentIdentity = apps[pid].map {
            processIdentity(pid: pid, bundleID: $0.bundleIdentifier)
        }
        guard currentIdentity.map({
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity, current: $0)
              }) == true,
              let app = apps[pid], app.processGeneration != nil,
              app.processGeneration == processGeneration(request.identity) else { return .skipped }
        recordInventoryResult(result, identity: request.identity)
        guard mutationGenerations[pid, default: 0] == request.mutationGeneration else { return .skipped }

        let readOutcome: InventoryAXReadOutcome
        let eligible: [AXWindowSnapshot]
        let rawAXWindows: [AXWindowSnapshot]?
        switch result {
        case .success(let windows):
            readOutcome = .success(count: windows.count)
            let application = eligibilityApplication(for: app)
            let observed: [AXWindowSnapshot]
            let observedAt = windows.first?.focusReadUptime
            if let focus = confirmedFocus[pid], observedAt.map({ $0 < focus.observedAt }) ?? true {
                observed = windows.map { snapshot in
                    var snapshot = snapshot
                    snapshot.isFocusedWindow = snapshot.cgWindowID == focus.windowID &&
                        focus.element == AXElementKey(e: snapshot.element)
                    return snapshot
                }
            } else {
                observed = windows
                if let observedAt {
                    let focused = windows.first(where: \.isFocusedWindow)
                    confirmedFocus[pid] = ConfirmedFocus(observedAt: observedAt, windowID: focused?.cgWindowID,
                                                         element: focused.map { AXElementKey(e: $0.element) })
                }
            }
            rawAXWindows = observed
            eligible = observed.filter { isEligible($0, application: application, cgSnapshot: cgSnapshot) }
        case .unread(let error):
            readOutcome = .unread(errorCode: error.rawValue)
            eligible = []
            rawAXWindows = nil
        }
        var evidenceByCgID: [CGWindowID: AbsentSeatProbeEvidence] = [:]
        for item in absenceEvidence { evidenceByCgID[item.request.cgWindowID] = item }
        let seatsChanged = reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: request.source,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed,
            rawAXWindows: rawAXWindows,
            absenceEvidence: evidenceByCgID
        )
        return .reconciled(seatsChanged: seatsChanged)
    }

    private func completeEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        frontmostProbeIDs probeIDs: Set<CGWindowID>?,
        absenceEvidence: [AbsentSeatProbeEvidence] = []
    ) {
        let landing = landEventRead(
            pid: pid, request: request, result: result, cgSnapshot: cgSnapshot,
            absenceEvidence: absenceEvidence
        )
        #if DEBUG
        if case .reconciled = landing {} else {
            for item in absenceEvidence {
                recordAbsenceProbe(
                    evidence: item, verdict: nil,
                    discardReason: { if case .staleToken = landing { return "staleToken" }; return "skipped" }(),
                    pid: pid, bundleID: apps[pid]?.bundleIdentifier, context: nil, firstHiddenAgeMs: nil
                )
            }
        }
        #endif
        switch landing {
        case .staleToken:
            return
        case .skipped:
            break
        case .reconciled(let seatsChanged):
            if result.isSuccess, !cgSnapshot.captureFailed, let probeIDs {
                frontmostProbeIDs[pid] = probeIDs
            } else if request.source == .frontmostPoll {
                frontmostProbeIDs.removeValue(forKey: pid)
            }
            let onScreenChanged = request.source == .frontmostPoll && !cgSnapshot.captureFailed
                && cgSnapshot.onScreenWindowIDs != lastOnScreenCGIDs
            if seatsChanged || onScreenChanged {
                rebuildSnapshot(onScreenCGIDs: cgSnapshot.captureFailed ? lastOnScreenCGIDs : cgSnapshot.onScreenWindowIDs)
            }
        }
        consumeTrailingEventRead(pid: pid)
        armAbsenceProbes(pid: pid)
    }

    private func consumeTrailingEventRead(pid: pid_t, isPeriodic: Bool = false) {
        if let trailingSource = trailingEventSources.removeValue(forKey: pid), apps[pid] != nil {
            scheduleEventRead(pid: pid, source: trailingSource, isPeriodic: isPeriodic)
        }
    }

    private func resumeDeferredInventoryEvents(isPeriodic: Bool) {
        let now = uptimeProvider()
        for pid in Array(trailingEventSources.keys) where pendingEventReads[pid] == nil {
            if inventoryTimeouts[pid]?.nextReadUptime.map({ now >= $0 }) ?? isPeriodic {
                consumeTrailingEventRead(pid: pid, isPeriodic: isPeriodic)
            }
        }
    }


    private func startReconcileTimer() {
        let generation = work.generation
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.reconcile()
            }
        }
        reconcileTimer?.tolerance = 0.5
    }

    private func startFrontmostPollTimer() {
        let generation = work.generation
        frontmostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.pollFrontmostApp()
            }
        }
        frontmostPollTimer?.tolerance = 0.05
    }

    private func currentFrontmostPID() -> pid_t? {
        guard frontmostCacheEnabled else {
            return frontmostPIDProvider()
        }
        if let cached = cachedFrontmostPID { return cached }
        let live = frontmostPIDProvider()
        cachedFrontmostPID = live
        return live
    }

    private func refreshFrontmostCache() -> Bool {
        guard frontmostCacheEnabled, let live = frontmostPIDProvider(), live != cachedFrontmostPID else {
            return false
        }
        cachedFrontmostPID = live
        return true
    }

    private func pollFrontmostApp() {
        guard work.isActive, AXIsProcessTrusted() else { return }
        resumeDeferredInventoryEvents(isPeriodic: false)
        guard let pid = currentFrontmostPID() else { return }
        let hasHelperFamily = systemFocusFamily(frontmostPID: pid) != nil
        if hasHelperFamily { requestSystemFocusedWindowRead(invalidate: false) }
        guard !frontmostProbePending, apps[pid] != nil || hasHelperFamily else { return }
        frontmostProbePending = true
        let probeProvider = onScreenWindowIDsProvider
        work.launch(priority: .utility) { [weak self] generation in
            guard let probe = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), operation: {
                FrontmostProbe(windowIDs: probeProvider())
            }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.frontmostProbePending = false
                guard self.currentFrontmostPID() == pid else { return }
                self.scheduleFrontmostPoll(pid: pid, probe: probe)
            }
        }
    }

    private func trackedFrontmostPIDs(_ pid: pid_t) -> [pid_t] {
        var tracked = apps[pid] == nil ? [] : [pid]
        for (helper, binding) in ownerBindings
            where binding.owner.identity.pid == pid && apps[helper] != nil && applicationOwner(for: helper) != nil {
            tracked.append(helper)
        }
        return tracked
    }

    private func scheduleFrontmostPoll(pid: pid_t, probe: FrontmostProbe) {
        let now = uptimeProvider()
        for tracked in trackedFrontmostPIDs(pid) where pendingEventReads[tracked] == nil {
            let gate = gateStates[tracked]
            let changed = probe.windowIDs == nil || frontmostProbeIDs[tracked] != probe.windowIDs
            let refreshDue = now - (gate?.lastFullReadUptime ?? -.infinity) >= Self.reconcileInterval
            if changed || refreshDue || gate?.dirty == true || inventoryTimeouts[tracked] != nil
                || hasDueAbsenceProbe(pid: tracked) {
                scheduleEventRead(pid: tracked, source: .frontmostPoll, frontmostProbe: probe)
            }
        }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        reconcileTrustedInventory()
    }

    private func reconcileTrustedInventory() {
        let frontmostChanged = refreshFrontmostCache()
        var changed = frontmostChanged

        var deadPIDs: Set<pid_t> = []
        for pid in appOrder {
            if !processProvider.isAlive(pid: pid) {
                deadPIDs.insert(pid)
                #if DEBUG
                logger.info("reconcile: pid=\(pid) no longer exists (POSIX kill(0) == ESRCH), removing stale entry")
                #endif
            }
        }
        var hostStates: [pid_t: (alive: Bool, generation: ProcessGeneration?)] = [:]
        for (helper, binding) in ownerBindings where apps[helper] != nil && !deadPIDs.contains(helper) {
            let host = binding.owner.identity
            let state: (alive: Bool, generation: ProcessGeneration?)
            if let cached = hostStates[host.pid] {
                state = cached
            } else {
                let alive = !deadPIDs.contains(host.pid) && processProvider.isAlive(pid: host.pid)
                let current = alive ? processGeneration(processIdentity(pid: host.pid, bundleID: host.bundleID)) : nil
                state = (alive, current)
                hostStates[host.pid] = state
            }
            if !state.alive {
                deadPIDs.insert(helper)
            } else if let expected = processGeneration(host), let current = state.generation {
                if expected != current {
                    deadPIDs.insert(helper)
                } else if unprojectedHelperPIDs.contains(helper), applicationOwner(for: helper) != nil {
                    changed = true
                }
            }
        }
        for pid in appOrder where deadPIDs.contains(pid) {
            removeTrackedProcess(pid: pid)
            changed = true
        }

        let cgSnapshot = currentCGSnapshot(cgSnapshotProvider())
        if refreshDisplayAttributionFromCG(cgSnapshot) { changed = true }

        if frontmostChanged {
            confirmedSystemFocus = nil
        }
        requestSystemFocusedWindowRead(invalidate: false)
        if changed {
            rebuildSnapshot(onScreenCGIDs: cgSnapshot.captureFailed ? lastOnScreenCGIDs : cgSnapshot.onScreenWindowIDs)
        }
        for pid in appOrder where pendingEventReads[pid] == nil && hasDueAbsenceProbe(pid: pid) {
            scheduleEventRead(pid: pid, source: .absenceProbe, isPeriodic: true)
        }
        schedulePeriodicBatchRead(cgSnapshot: cgSnapshot, timeout: periodicReconcileTimeout)
        scanNonAdmittedApps(cgSnapshot: cgSnapshot)
    }

    private func schedulePeriodicBatchRead(cgSnapshot: AppTrackerCGWindowSnapshot, timeout: TimeInterval) {
        guard work.isActive else { return }
        resumeDeferredInventoryEvents(isPeriodic: true)
        for observer in observers.values { observer.start() }
        var batch: [(pid: pid_t, request: QueuedPeriodicRead)] = []
        for pid in appOrder {
            guard pendingEventReads[pid] == nil, queuedPeriodicReads[pid] == nil,
                  let app = apps[pid] else { continue }
            let identity = processIdentity(pid: pid, bundleID: app.bundleIdentifier)
            guard canReadTrackedProcess(pid: pid, identity: identity),
                  canRetryInventory(identity: identity, isPeriodic: true) else { continue }
            if reconcileSkipEnabled, shouldSkipPeriodicRead(pid: pid, app: app, cgSnapshot: cgSnapshot) {
                continue
            }
            nextEventReadToken &+= 1
            let request = QueuedPeriodicRead(
                token: nextEventReadToken,
                identity: identity
            )
            queuedPeriodicReads[pid] = request
            batch.append((pid, request))
        }
        guard !batch.isEmpty else { return }
        let reader = self.reader
        let pending = batch

        work.launch { [weak self] generation in
            for entry in pending {
                guard !Task.isCancelled else { return }
                guard let request = await self?.beginPeriodicRead(
                    pid: entry.pid, request: entry.request, generation: generation
                ) else { continue }
                let cancellation = OperationCancellation()
                guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation, operation: {
                    reader.inventoryWindows(forPID: entry.pid, messagingTimeout: timeout, cancellation: cancellation)
                }) else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.work.isCurrent(generation) else { return }
                    self.completePeriodicRead(pid: entry.pid, request: request, result: result,
                                              cgSnapshot: cgSnapshot, generation: generation)
                }
            }
        }
    }

    private func beginPeriodicRead(pid: pid_t, request: QueuedPeriodicRead, generation: UInt64) -> PendingEventRead? {
        guard work.isCurrent(generation), queuedPeriodicReads[pid]?.token == request.token else { return nil }
        queuedPeriodicReads.removeValue(forKey: pid)
        guard pendingEventReads[pid] == nil, let app = apps[pid],
              app.processGeneration == processGeneration(request.identity) else { return nil }
        let identity = processIdentity(pid: pid, bundleID: app.bundleIdentifier)
        guard ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity, current: identity),
              canRetryInventory(identity: identity, isPeriodic: true) else { return nil }
        let admitted = PendingEventRead(
            token: request.token,
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: identity,
            source: .periodicReconcile
        )
        pendingEventReads[pid] = admitted
        return admitted
    }

    private func shouldSkipPeriodicRead(
        pid: pid_t,
        app: AppEntry,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        if !cgSnapshot.captureFailed, app.windowOrder.contains(where: {
            guard let owner = cgSnapshot.ownerPIDByWindowID[$0] else { return false }
            return owner != pid || cgSnapshot.parentWindowIDs[$0].map { $0 != 0 } == true
        }) { return false }
        let gate = gateStates[pid]
        let input = PeriodicReconcileSkipDecision.Input(
            captureFailed: cgSnapshot.captureFailed,
            currentCGIDs: cgSnapshot.windowIDsByPID[pid] ?? [],
            lastObservedCGIDs: gate?.lastCGIDs,
            dirtySinceLastRead: gate?.dirty ?? true,
            hasPendingAbsenceCheck: app.windowOrder.contains { app.windowsByID[$0]?.minAbsentSince != nil },
            hasUnresolvedPhantomSeat: app.windowOrder.contains { app.windowsByID[$0]?.everSeenVisible == false },
            lastReadWasUnread: gate?.lastReadWasUnread ?? true,
            lastRoundChanged: gate?.lastRoundChanged ?? true,
            hasActiveWindowObserver: observerActive(pid: pid),
            allSeatsSubscribed: allSeatsSubscribed(pid: pid, app: app),
            uptimeSinceLastFullRead: gate.map { uptimeProvider() - $0.lastFullReadUptime } ?? .infinity,
            seatOnScreenChanged: absentSeatReleaseEnabled && gate.map {
                $0.lastSeatOnScreenIDs != Set(app.windowOrder).intersection(cgSnapshot.onScreenWindowIDs)
            } ?? false
        )
        return PeriodicReconcileSkipDecision.decisionFromEvidence(input) == .skip
    }

    private func allSeatsSubscribed(pid: pid_t, app: AppEntry) -> Bool {
        guard let observer = observers[pid], observer.isActive else { return true }
        return app.windowOrder.allSatisfy { observer.isCovered(cgWindowID: $0) }
    }

    private func observerActive(pid: pid_t) -> Bool {
        #if DEBUG
        if let override = observerActiveOverridesForTesting[pid] { return override }
        #endif
        return observers[pid]?.isActive ?? false
    }

    private func completePeriodicRead(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult,
                                      cgSnapshot: AppTrackerCGWindowSnapshot, generation: UInt64) {
        let cgSnapshot = currentCGSnapshot(cgSnapshot)
        switch landEventRead(pid: pid, request: request, result: result, cgSnapshot: cgSnapshot) {
        case .staleToken:
            return
        case .skipped:
            break
        case .reconciled(let changed):
            if changed { schedulePeriodicSnapshot(request: request, cgSnapshot: cgSnapshot, generation: generation) }
        }
        consumeTrailingEventRead(pid: pid)
        armAbsenceProbes(pid: pid)
    }

    private func schedulePeriodicSnapshot(request: PendingEventRead, cgSnapshot: AppTrackerCGWindowSnapshot,
                                           generation: UInt64) {
        if pendingPeriodicSnapshot != nil {
            pendingPeriodicSnapshot?.onScreenIDs = cgSnapshot.onScreenWindowIDs
            return
        }
        pendingPeriodicSnapshot = (request.token, cgSnapshot.onScreenWindowIDs)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.work.isCurrent(generation),
                  let pending = self.pendingPeriodicSnapshot, pending.token == request.token else { return }
            self.rebuildSnapshot(onScreenCGIDs: pending.onScreenIDs)
        }
    }

    private func scanNonAdmittedApps(cgSnapshot: AppTrackerCGWindowSnapshot? = nil) {
        guard work.isActive, !isScanningCandidates else { return }
        var slowFullScanDue = false
        if cgSnapshot != nil, scanGateEnabled {
            let uptime = uptimeProvider()
            slowFullScanDue = lastFullScanUptime.map {
                uptime - $0 >= ScanProbeGateDecision.defaultFullScanInterval
            } ?? true
            if slowFullScanDue {
                lastFullScanUptime = uptime
            }
        }
        let candidates: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity)]
        if let cgSnapshot, scanGateEnabled {
            if scanCandidateCache == nil || slowFullScanDue {
                scanCandidateCache = enumerateScanCandidates()
            }
            candidates = (scanCandidateCache ?? []).compactMap { entry in
                guard apps[entry.pid] == nil, processProvider.isAlive(pid: entry.pid) else { return nil }
                let identity = processIdentity(pid: entry.pid, bundleID: entry.bundleID)
                let verdict = ScanProbeGateDecision.decisionFromEvidence(.init(
                    captureFailed: cgSnapshot.captureFailed,
                    cgWindowIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    memo: scanMemos[entry.pid],
                    currentIdentity: identity,
                    workspaceDirty: scanDirtyPIDs.contains(entry.pid),
                    slowFullScanDue: slowFullScanDue
                ))
                guard case .probe = verdict else { return nil }
                scanDirtyPIDs.remove(entry.pid)
                return (entry.pid, identity)
            }
        } else {
            candidates = runningApplications.compactMap { app in
                let pid = app.processIdentifier
                guard isWindowCandidate(app), !isTerminatedForAdmission(app), apps[pid] == nil else { return nil }
                scanDirtyPIDs.remove(pid)
                return (pid, processIdentity(pid: pid, bundleID: app.bundleIdentifier))
            }
        }
        guard !candidates.isEmpty else { return }

        isScanningCandidates = true
        let reader = self.reader
        let processProvider = processProvider
        let embeddedPIDs = Set(candidates.compactMap { candidate -> pid_t? in
            guard let app = applicationForAdmission(pid: candidate.pid),
                  !eligibilityApplication(for: app).canOwnTaskbarWindows else { return nil }
            return candidate.pid
        })

        work.launch { [weak self] generation in
            let probeStart = DispatchTime.now().uptimeNanoseconds
            let ownerCancellation = OperationCancellation()
            guard let owners = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: ownerCancellation, operation: {
                processProvider.applicationOwners(for: embeddedPIDs, cancellation: ownerCancellation)
            }) else { return }
            var probed: [ApplicationProbe] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let cancellation = OperationCancellation()
                guard let result = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation, operation: {
                    Self.probeApplication(candidate.identity, requiresOwner: embeddedPIDs.contains(candidate.pid),
                        owner: owners[candidate.pid], reader: reader, timeout: 0.1, cancellation: cancellation)
                }) else { return }
                probed.append(result)
            }
            let results = probed
            let probeElapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - probeStart) / 1_000_000_000

            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.isScanningCandidates = false
                self.admitScannedApps(results, tickSnapshot: cgSnapshot, probeElapsed: probeElapsed)
            }
        }
    }

    private func enumerateScanCandidates() -> [(pid: pid_t, bundleID: String?)] {
        runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard isWindowCandidate(app), !app.isTerminated, apps[pid] == nil else { return nil }
            return (pid, app.bundleIdentifier)
        }
    }

    private func admitScannedApps(
        _ probed: [ApplicationProbe],
        tickSnapshot: AppTrackerCGWindowSnapshot? = nil,
        probeElapsed: TimeInterval = .infinity
    ) {
        guard !probed.isEmpty else { return }
        let cgSnapshot: AppTrackerCGWindowSnapshot
        if let tickSnapshot, probeElapsed <= 1.0 {
            cgSnapshot = currentCGSnapshot(tickSnapshot)
        } else {
            cgSnapshot = currentCGSnapshot(cgSnapshotProvider())
        }
        var admitted = false

        for entry in probed {
            defer { if apps[entry.pid] == nil { ownerBindings.removeValue(forKey: entry.pid) } }
            rememberOwner(entry)
            guard let app = applicationForAdmission(pid: entry.pid) else {
                scanMemos.removeValue(forKey: entry.pid)
                #if DEBUG
                noteAdmissionVerdict(pid: entry.pid, verdict: "skipProcessUnavailable", source: "scan")
                #endif
                #if DEBUG
                recordAdmissionProbe(
                    source: .scan,
                    identity: entry.identity,
                    readMode: .timed,
                    messagingTimeoutMs: 100,
                    maxAttempts: 1,
                    result: entry.result,
                    eligibleWindowCount: nil,
                    verdict: .skipProcessUnavailable
                )
                #endif
                continue
            }
            let bundleID = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)

            let rawWindows: [AXWindowSnapshot]?
            let readOutcome: InventoryAXReadOutcome
            switch entry.result {
            case .success(let snaps):
                rawWindows = snaps
                readOutcome = .success(count: snaps.count)
            case .unread(let error):
                rawWindows = nil
                readOutcome = .unread(errorCode: error.rawValue)
            }

            let prepared = ScanAdmissionDecision.prepare(rawWindows: rawWindows) {
                isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
            }
            let verdict = ScanAdmissionDecision.decisionFromEvidence(
                prepared,
                probedIdentity: entry.identity,
                currentIdentity: processIdentity(pid: entry.pid, bundleID: bundleID),
                isWindowApplication: isWindowApplication(app),
                isTerminated: isTerminatedForAdmission(app),
                alreadyTracked: apps[entry.pid] != nil
            )
            #if DEBUG
            noteAdmissionVerdict(pid: entry.pid, verdict: inventoryAdmissionVerdict(verdict).rawValue, source: "scan")
            #endif
            #if DEBUG
            recordAdmissionProbe(
                source: .scan,
                identity: entry.identity,
                readMode: .timed,
                messagingTimeoutMs: 100,
                maxAttempts: 1,
                result: entry.result,
                eligibleWindowCount: prepared.readFailed ? nil : prepared.eligible.count,
                verdict: inventoryAdmissionVerdict(verdict)
            )
            #endif
            if verdict == .skipNoEligible {
                scanMemos[entry.pid] = ScanProbeGateDecision.Memo(
                    identity: entry.identity,
                    lastCGIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    verdictWasNoEligible: true
                )
            } else {
                scanMemos.removeValue(forKey: entry.pid)
            }
            guard verdict == .admit else { continue }

            admit(app: app, prepared: prepared, readOutcome: readOutcome, cgSnapshot: cgSnapshot,
                  rawAXWindows: rawWindows ?? [])
            admitted = true
        }

        if admitted { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
    }

    private func admit(
        app: NSRunningApplication,
        prepared: ScanAdmissionDecision.Prepared<AXWindowSnapshot>,
        readOutcome: InventoryAXReadOutcome,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        rawAXWindows: [AXWindowSnapshot]
    ) {
        let pid = app.processIdentifier
        addApp(app, enumerateImmediately: false)
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: .initialEnumeration,
            preloadedEligible: prepared.eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed,
            rawAXWindows: rawAXWindows
        )
        #if DEBUG
        logger.info("scan: admitted pid=\(pid) (\(app.localizedName ?? app.bundleIdentifier ?? "?"))")
        #endif
    }

    private func processIdentity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        processProvider.identity(pid: pid, bundleID: bundleID)
    }

    private func processGeneration(_ identity: ScanAdmissionDecision.ProcessIdentity) -> ProcessGeneration? {
        guard let seconds = identity.startTimeSec, let microseconds = identity.startTimeUsec else { return nil }
        return ProcessGeneration(timeval(tv_sec: Int(seconds), tv_usec: microseconds))
    }

    private func canReadTrackedProcess(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity) -> Bool {
        guard let expected = apps[pid]?.processGeneration, let current = processGeneration(identity) else { return false }
        guard expected == current else {
            removeTrackedProcess(pid: pid)
            rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs)
            return false
        }
        return true
    }

    #if DEBUG
    private func recordAdmissionProbe(
        source: InventoryAdmissionProbeSource,
        identity: ScanAdmissionDecision.ProcessIdentity,
        readMode: InventoryAdmissionReadMode,
        messagingTimeoutMs: Int?,
        maxAttempts: Int,
        result: AXWindowReadResult,
        eligibleWindowCount: Int?,
        verdict: InventoryAdmissionProbeVerdict
    ) {
        guard inventoryLog.isEnabled else { return }
        let readResult: InventoryAdmissionProbeReadResult
        let errorCode: Int32?
        let rawWindowCount: Int?
        switch result {
        case .success(let windows):
            readResult = .success
            errorCode = nil
            rawWindowCount = windows.count
        case .unread(let error):
            readResult = .unread
            errorCode = error.rawValue
            rawWindowCount = nil
        }
        inventoryLog.record(.admissionProbe(InventoryAdmissionProbePayload(
            source: source,
            pid: identity.pid,
            bundleID: identity.bundleID,
            processStartTimeSec: identity.startTimeSec,
            processStartTimeUsec: identity.startTimeUsec,
            readMode: readMode,
            messagingTimeoutMs: messagingTimeoutMs,
            maxAttempts: maxAttempts,
            readResult: readResult,
            errorCode: errorCode,
            rawWindowCount: rawWindowCount,
            eligibleWindowCount: eligibleWindowCount,
            verdict: verdict
        )))
    }
    #endif

    #if DEBUG
    private func inventoryAdmissionVerdict(
        _ verdict: ScanAdmissionDecision.Verdict
    ) -> InventoryAdmissionProbeVerdict {
        switch verdict {
        case .admit: return .admit
        case .skipUnsupportedApplication: return .skipUnsupportedApplication
        case .skipTerminated: return .skipTerminated
        case .skipAlreadyTracked: return .skipAlreadyTracked
        case .skipIdentityMismatch: return .skipIdentityMismatch
        case .skipUnread: return .skipUnread
        case .skipNoEligible: return .skipNoEligible
        }
    }
    #endif


    private func rebuildSnapshot(onScreenCGIDs: Set<CGWindowID>? = nil) {
        pendingPeriodicSnapshot = nil
        let frontmostPID = currentFrontmostPID()
        let family = systemFocusFamily(frontmostPID: frontmostPID)
        let systemFocus = confirmedSystemFocus.flatMap { focus -> ConfirmedSystemFocus? in
            guard focus.frontmostPID == frontmostPID, let app = apps[focus.identity.pid],
                  focus.mutationGeneration == mutationGenerations[focus.identity.pid, default: 0],
                  focus.windowElement.map({ app.windowsByID[focus.windowID]?.actionTarget?.element == $0 }) ?? true,
                  app.processGeneration == processGeneration(focus.identity),
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: focus.identity,
                      current: processIdentity(pid: focus.identity.pid, bundleID: app.bundleIdentifier)) else { return nil }
            return focus
        }
        if let onScreenCGIDs { lastOnScreenCGIDs = onScreenCGIDs }
        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []
        unprojectedHelperPIDs.removeAll(keepingCapacity: true)
        for pid in appOrder {
            guard let app = apps[pid] else { continue }
            let owningApplication = applicationOwner(for: pid)
            if ownerBindings[pid] != nil && owningApplication == nil {
                unprojectedHelperPIDs.insert(pid)
                continue
            }
            for cgID in app.windowOrder {
                guard destroyedWindows[pid]?[cgID] == nil, let seat = app.windowsByID[cgID] else { continue }
                let id = WindowID(rawValue: "cgw-\(cgID)")
                if let existing = windows[id] {
                    guard snapshot.windows[id]?.pid == pid, existing.pid != pid else { continue }
                } else {
                    orderedWindowIDs.append(id)
                }
                windows[id] = WindowRecord(
                    id: id, appID: AppID(rawValue: app.bundleIdentifier ?? app.appName), pid: pid,
                    bundleIdentifier: app.bundleIdentifier, title: seat.title, bounds: seat.bounds,
                    status: windowStatus(isHidden: app.isHidden, isMinimized: seat.isMinimized,
                                         isFocused: seat.isFocused, pid: pid, frontmostPID: frontmostPID,
                                         family: family, cgWindowID: cgID, systemFocus: systemFocus),
                    cgWindowID: cgID, isOnDesktop: !seat.isMinimized && !app.isHidden,
                    groupID: seat.token, displayUUID: seat.displayUUID,
                    applicationOrigin: app.applicationOrigin, processGeneration: app.processGeneration,
                    owningApplication: owningApplication, actionTarget: seat.actionTarget
                )
            }
        }
        let next = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
        guard next != snapshot else { return }
        snapshot = next
    }

    private func windowStatus(isHidden: Bool, isMinimized: Bool, isFocused: Bool, pid: pid_t, frontmostPID: pid_t?,
                              family: pid_t?, cgWindowID: CGWindowID, systemFocus: ConfirmedSystemFocus?) -> WindowStatus {
        if isHidden { return .hidden }
        if isMinimized { return .minimized }
        if family != nil {
            return systemFocus?.identity.pid == pid && systemFocus?.windowID == cgWindowID ? .active : .inactive
        }
        if isFocused && pid == frontmostPID { return .active }
        return .inactive
    }

    private func applicationForAdmission(pid: pid_t) -> NSRunningApplication? {
        #if DEBUG
        if let fixture = admissionAppsForTesting?.first(where: { $0.processIdentifier == pid }) {
            return fixture
        }
        #endif
        return NSRunningApplication(processIdentifier: pid)
    }

    private func isTerminatedForAdmission(_ app: NSRunningApplication) -> Bool {
        #if DEBUG
        if admissionAppsForTesting?.contains(where: { $0.processIdentifier == app.processIdentifier }) == true {
            return !processProvider.isAlive(pid: app.processIdentifier)
        }
        #endif
        return app.isTerminated
    }

    private func isWindowCandidate(_ app: NSRunningApplication) -> Bool {
        let application = eligibilityApplication(for: app)
        return application.canOwnTaskbarWindows || application.isEmbeddedHelper
    }

    private func isWindowApplication(_ app: NSRunningApplication) -> Bool {
        let application = eligibilityApplication(for: app)
        return application.canOwnTaskbarWindows || application.isEmbeddedHelper && applicationOwner(for: app.processIdentifier) != nil
    }

    nonisolated private static func probeApplication(
        _ identity: ScanAdmissionDecision.ProcessIdentity, requiresOwner: Bool,
        owner: ApplicationOwnerRead?, reader: any AppTrackerWindowReading,
        timeout: TimeInterval?, cancellation: OperationCancellation
    ) -> ApplicationProbe {
        guard !cancellation.isCancelled else { return .init(identity: identity, result: .unread(.cannotComplete), owner: nil) }
        guard !requiresOwner || owner != nil else { return .init(identity: identity, result: .success([]), owner: nil) }
        guard !cancellation.isCancelled else { return .init(identity: identity, result: .unread(.cannotComplete), owner: nil) }
        let result = timeout.map { reader.inventoryWindows(forPID: identity.pid, messagingTimeout: $0, cancellation: cancellation) }
            ?? reader.windowReadResult(forPID: identity.pid)
        return .init(identity: identity, result: result, owner: owner)
    }

    private func rememberOwner(_ probe: ApplicationProbe) {
        guard apps[probe.pid] == nil else { return }
        if let owner = probe.owner, let origin = ApplicationOrigin(bundleURL: owner.application.bundleURL) {
            ownerBindings[probe.pid] = OwnerBinding(process: probe.identity, owner: owner, origin: origin)
        }
    }

    private func applicationOwner(for pid: pid_t) -> ApplicationIdentity? {
        guard let binding = ownerBindings[pid],
              ScanAdmissionDecision.ProcessIdentity.matches(probed: binding.process,
                  current: processIdentity(pid: pid, bundleID: binding.process.bundleID)),
              ScanAdmissionDecision.ProcessIdentity.matches(probed: binding.owner.identity,
                  current: processIdentity(pid: binding.owner.identity.pid, bundleID: binding.owner.identity.bundleID)),
              let seconds = binding.owner.identity.startTimeSec, let microseconds = binding.owner.identity.startTimeUsec,
              let bundleID = binding.owner.application.bundleIdentifier else { return nil }
        return ApplicationIdentity(pid: binding.owner.identity.pid, bundleIdentifier: bundleID,
            origin: binding.origin,
            generation: ProcessGeneration(timeval(tv_sec: Int(seconds), tv_usec: microseconds)))
    }

    #if DEBUG
    func runAdmissionForTesting(source: String, app: NSRunningApplication = .current, retryDelays: [TimeInterval] = [0],
                                application: AppTrackerWindowEligibility.Application = .init(
                                    bundleIdentifier: "test.diagnostics", appName: "Diagnostics",
                                    activationPolicy: .regular, executablePath: nil)) {
        admissionAppsForTesting = [app]
        admissionApplicationForTesting = application
        if !work.isActive { work.restart() }
        switch source {
        case "seed": seedRunningApps()
        case "scan": scanNonAdmittedApps()
        case "launchRetry": scheduleRetryAdmission(app: app, delays: retryDelays)
        default: preconditionFailure("Unknown admission fixture source")
        }
    }

    var pendingInventoryWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }


    func installFixtureForTesting(_ app: AppEntry) {
        var admitted = app
        if admitted.processGeneration == nil {
            admitted.processGeneration = processGeneration(processIdentity(pid: app.pid, bundleID: app.bundleIdentifier))
        }
        apps[app.pid] = admitted
        if !appOrder.contains(app.pid) { appOrder.append(app.pid) }
        mutationGenerations[app.pid, default: 0] &+= 1
    }

    func fixtureAppForTesting(pid: pid_t) -> AppEntry? {
        apps[pid]
    }

    @discardableResult
    func reconcileFixtureForTesting(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        eligible: [AXWindowSnapshot],
        readOutcome: InventoryAXReadOutcome,
        readMode: InventoryReconcileReadMode = .timed,
        rawAXCgIDs: Set<CGWindowID>? = nil,
        absenceEvidence: [CGWindowID: AbsentSeatProbeEvidence] = [:]
    ) -> Bool {
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: now,
            source: .periodicReconcile,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: readMode,
            rawAXCgIDs: rawAXCgIDs,
            absenceEvidence: absenceEvidence
        )
    }

    func setSubscribedElementForTesting(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement?, instanceID: UInt64) {
        var overrides = subscribedElementOverridesForTesting[pid] ?? [:]
        overrides[cgWindowID] = element.map { ($0, instanceID) }
        subscribedElementOverridesForTesting[pid] = overrides
    }

    func takeDueAbsenceProbesForTesting(pid: pid_t) -> [AbsentSeatProbeRequest] {
        takeDueAbsenceProbes(pid: pid)
    }

    func clearFirstHiddenMarksViaHideForTesting(pid: pid_t) {
        handleAppHidden(pid: pid)
    }

    var absenceProbeTimerPIDsForTesting: Set<pid_t> { Set(absenceProbeTimers.keys) }

    func scheduleEventReadForTesting(pid: pid_t, source: InventoryReconcileSource) {
        scheduleEventRead(pid: pid, source: source)
    }

    func scheduleFrontmostPollForTesting(pid: pid_t) {
        resumeDeferredInventoryEvents(isPeriodic: false)
        requestSystemFocusedWindowRead(invalidate: false)
        scheduleFrontmostPoll(pid: pid, probe: FrontmostProbe(windowIDs: onScreenWindowIDsProvider()))
    }

    func minimizeForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowMinimized(pid: pid, cgWindowID: cgWindowID)
    }

    func destroyForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowDestroyed(pid: pid, cgWindowID: cgWindowID,
            element: subscribedElement(pid: pid, cgWindowID: cgWindowID)?.element
                ?? elementCache.element(pid: pid, cgWindowID: cgWindowID))
    }

    func rebuildSnapshotForTesting(onScreenCGIDs: Set<CGWindowID> = []) {
        rebuildSnapshot(onScreenCGIDs: onScreenCGIDs)
    }

    @discardableResult
    func refreshDisplayAttributionFromCGForTesting(cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        refreshDisplayAttributionFromCG(cgSnapshot)
    }

    func screenParametersChangedForTesting() {
        handleScreenParametersChanged()
    }

    func hasPendingEventReadForTesting(pid: pid_t) -> Bool {
        pendingEventReads[pid] != nil || queuedPeriodicReads[pid] != nil || trailingEventSources[pid] != nil
    }

    func setFrontmostPIDForTesting(_ pid: pid_t?) {
        cachedFrontmostPID = pid
    }

    func cgSnapshotCacheForTesting() -> (probeIDs: Set<CGWindowID>, atUptime: TimeInterval)? {
        guard cachedCGSnapshot != nil, let probe = cachedCGProbeIDs else { return nil }
        return (probe, cachedCGAtUptime)
    }

    func bumpCGEventGenerationForTesting() {
        cgEventGeneration &+= 1
    }

    func setObserverActiveForTesting(pid: pid_t, active: Bool) {
        observerActiveOverridesForTesting[pid] = active
    }

    func runPeriodicReconcileForTesting() {
        reconcileTrustedInventory()
    }

    func runPeriodicBatchForTesting(
        cgSnapshot: AppTrackerCGWindowSnapshot,
        timeoutOverride: TimeInterval? = nil
    ) {
        schedulePeriodicBatchRead(
            cgSnapshot: currentCGSnapshot(AppTrackerCGWindowSnapshot.timedCapture { cgSnapshot }),
            timeout: timeoutOverride ?? periodicReconcileTimeout
        )
    }
    #endif
}
