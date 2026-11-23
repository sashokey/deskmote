import AppKit
import Combine
import CoreGraphics
import Foundation
#if DEBUG || DESKMOTE_QA_JOURNAL
import os
#endif

@MainActor
protocol DisplayTopologyUpdating: AnyObject {
    func updateDisplayTopology(_ table: WindowDisplayAttribution.Table)
}

#if DEBUG
@MainActor
final class DebugRuntimeState: ObservableObject {
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]

    func setFeedbackEntries(_ entries: [String: IntentFeedbackState.Entry]) {
        guard entries != feedbackEntriesByWindowID else { return }
        feedbackEntriesByWindowID = entries
    }


}
#endif

@MainActor
private final class UtilityWindowRegistry {
    #if DESKMOTE_QA_JOURNAL
    private static let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "QA")
    #endif

    private final class Entry {
        let id = WindowID(rawValue: "utility-\(UUID().uuidString)")
        weak var window: NSWindow?
        var titleObservation: NSKeyValueObservation?
        var displayUUID: String?
        var physicalDisplayID: CGDirectDisplayID?
        var spaceWindowNumber: UInt32?

        init(window: NSWindow) { self.window = window }
    }

    private var entries: [Entry] = []
    private var observations = Set<AnyCancellable>()
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let bundleIdentifier = Bundle.main.bundleIdentifier
    private let origin = ApplicationOrigin(bundleURL: Bundle.main.bundleURL)
    private let isAppFrontmost: (pid_t) -> Bool
    private let activateApplication: @MainActor () -> Void
    var changed: (() -> Void)?

    init(isAppFrontmost: @escaping (pid_t) -> Bool, activateApplication: @escaping @MainActor () -> Void) {
        self.isAppFrontmost = isAppFrontmost
        self.activateApplication = activateApplication
    }

    func register(_ window: NSWindow) {
        if entries.allSatisfy({ $0.window !== window }) {
            let entry = Entry(window: window)
            entry.titleObservation = window.observe(\.title) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.changed?() }
            }
            entries.append(entry)
            if observations.isEmpty { observeLifecycle() }
            #if DESKMOTE_QA_JOURNAL
            Self.logger.notice("utility event=registered count=\(self.entries.count, privacy: .public)")
            #endif
        }
        changed?()
    }

    func records() -> [WindowRecord] {
        entries.removeAll { $0.window == nil }
        guard !entries.isEmpty else { return [] }
        let appIsHidden = NSApp?.isHidden == true
        let appIsActive = isAppFrontmost(pid)
        return entries.compactMap { entry in
            guard let window = entry.window else { return nil }
            let status: WindowStatus
            if window.isMiniaturized {
                status = .minimized
            } else if appIsHidden && window.canHide {
                status = .hidden
            } else {
                status = window.isKeyWindow && appIsActive ? .active : .inactive
            }
            let parked = status == .minimized || status == .hidden
            if (!parked || entry.physicalDisplayID == nil), let screen = window.screen {
                entry.displayUUID = DisplayIdentity.uuidString(for: screen)
                entry.physicalDisplayID = DisplayIdentity.displayID(for: screen)
            }
            if !parked || entry.spaceWindowNumber == nil,
               let number = UInt32(exactly: window.windowNumber), number > 0 {
                entry.spaceWindowNumber = number
            }
            return WindowRecord(id: entry.id, appID: AppID(rawValue: bundleIdentifier ?? "\(pid)"),
                pid: pid, bundleIdentifier: bundleIdentifier, title: window.title, bounds: nil, status: status,
                isOnDesktop: !parked && window.isVisible && window.isOnActiveSpace,
                displayUUID: entry.displayUUID, applicationOrigin: origin,
                source: .utility(spaceWindowNumber: entry.spaceWindowNumber), utilityDisplayID: entry.physicalDisplayID)
        }
    }

    func onActiveSpace(_ id: WindowID) -> Bool? {
        guard let window = entries.first(where: { $0.id == id })?.window,
              window.isVisible, !window.isMiniaturized,
              NSApp?.isHidden != true || !window.canHide else { return nil }
        return window.isOnActiveSpace
    }

    func physicalDisplayID(_ id: WindowID) -> CGDirectDisplayID? {
        guard let entry = entries.first(where: { $0.id == id }), let window = entry.window else { return nil }
        let parked = window.isMiniaturized || (NSApp?.isHidden == true && window.canHide)
        let liveDisplayID = window.screen.flatMap { DisplayIdentity.displayID(for: $0) }
        guard parked else { return liveDisplayID }
        let connected = NSScreen.screens.compactMap { DisplayIdentity.displayID(for: $0) }
        if let last = entry.physicalDisplayID {
            if connected.contains(last) { return last }
            if connected.count == 1 { return connected.first }
        }
        return liveDisplayID
    }

    func execute(_ kind: PlatformActionRequest.ActionKind, windowID: WindowID) -> Bool {
        let performed = perform(kind, windowID: windowID)
        #if DESKMOTE_QA_JOURNAL
        Self.logger.notice("utility event=action kind=\(kind.rawValue, privacy: .public) performed=\(performed, privacy: .public) count=\(self.entries.count, privacy: .public)")
        #endif
        return performed
    }

    private func perform(_ kind: PlatformActionRequest.ActionKind, windowID: WindowID) -> Bool {
        guard let window = entries.first(where: { $0.id == windowID })?.window else { return false }
        switch kind {
        case .activateWindow:
            if !isAppFrontmost(pid) { activateApplication() }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        case .minimizeWindow:
            guard window.styleMask.contains(.miniaturizable) else { return false }
            window.miniaturize(nil)
        case .closeWindow:
            guard window.styleMask.contains(.closable) else { return false }
            window.performClose(nil)
            return !entries.contains { $0.id == windowID }
        }
        changed?()
        return true
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.publisher(for: name).sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow,
                          let entry = self.entries.first(where: { $0.window === window }) else { return }
                    if name == NSWindow.willCloseNotification {
                        self.entries.removeAll { $0 === entry }
                        #if DESKMOTE_QA_JOURNAL
                        Self.logger.notice("utility event=removed count=\(self.entries.count, privacy: .public)")
                        #endif
                    }
                    self.changed?()
                }
            }.store(in: &observations)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.publisher(for: name).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.entries.isEmpty else { return }
                    self.changed?()
                }
            }.store(in: &observations)
        }
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    #if DEBUG
    let debugState = DebugRuntimeState()
    #endif
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    private let tracker: any WindowInventoryTracking
    private let work = WindowActionQueue()
    private var actionTokens: [String: UUID] = [:]
    private var activatingTargets: [String: WindowActionIdentity] = [:]
    private var projectionInvalidationSubscriptions: [String: AnyCancellable] = [:]
    private let intentPipeline: IntentPipeline
    private let actionExecutor: any WindowActionExecuting
    private let utilityWindows: UtilityWindowRegistry
    private var externalSnapshot: DockSnapshot = .empty
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?

    #if DEBUG
    private let chipProbeLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "ChipProbe")
    private static let chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    #endif
    private static let handoffActiveGraceEnabled = DebugSwitch.handoffActiveGrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let handoffActivePredictionEnabled = DebugSwitch.handoffActivePrediction.isEnabled(in: ProcessInfo.processInfo.environment)

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        tracker: (any WindowInventoryTracking)? = nil,
        actionExecutor: any WindowActionExecuting = PlatformActionExecutor(),
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = {
            DisplayIdentity.attributionTable()
        },
        isAppFrontmost: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isActive == true },
        activateUtilityApplication: @escaping @MainActor () -> Void = {
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate()
        }
    ) {
        self.intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner(isAppFrontmost: isAppFrontmost))
        self.tracker = tracker ?? AppTracker(inventoryLog: inventoryLog, displayTableProvider: displayTableProvider)
        self.actionExecutor = actionExecutor
        self.utilityWindows = UtilityWindowRegistry(isAppFrontmost: isAppFrontmost, activateApplication: activateUtilityApplication)
        utilityWindows.changed = { [weak self] in self?.publishSnapshot() }
    }

    func start() {
        guard snapshotSubscription == nil else { return }
        work.restart()
        let generation = work.generation
        snapshotSubscription = tracker.snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSnapshot in
                guard let self, self.work.isCurrent(generation) else { return }
                self.externalSnapshot = newSnapshot
                self.publishSnapshot()
            }
        tracker.start()
        publishSnapshot()
        updateFeedbackTimer()
    }

    private var isRunning: Bool { snapshotSubscription != nil }

    func stop() {
        work.stop()
        actionTokens.removeAll()
        activatingTargets.removeAll()
        projectionInvalidationSubscriptions.removeAll()
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        optimisticStatesByWindowID.removeAll()
        intentPipeline.reset()
        publishFeedbackEntries()
        externalSnapshot = .empty
        snapshot = .empty
    }

    isolated deinit { stop() }

    func updateDisplayTopology(_ table: WindowDisplayAttribution.Table) {
        (tracker as? any DisplayTopologyUpdating)?.updateDisplayTopology(table)
        publishSnapshot()
    }

    func registerUtilityWindow(_ window: NSWindow) { utilityWindows.register(window) }

    func utilityWindowOnActiveSpace(_ id: WindowID) -> Bool? { utilityWindows.onActiveSpace(id) }
    func utilityWindowPhysicalDisplayID(_ id: WindowID) -> CGDirectDisplayID? { utilityWindows.physicalDisplayID(id) }

    private func publishSnapshot() {
        guard isRunning else { return }
        var combined = externalSnapshot
        for record in utilityWindows.records() {
            combined.windows[record.id] = record
            combined.orderedWindowIDs.append(record.id)
        }
        handleSnapshotUpdate(combined)
    }

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }

    func trigger(_ intent: UserIntent, expected: WindowActionIdentity,
                 projectionInvalidations: AnyPublisher<Void, Never>,
                 isProjectionCurrent: @escaping @MainActor @Sendable () -> Bool) {
        guard snapshot.windows[intent.windowID]?.actionIdentity == expected, isProjectionCurrent() else { return }
        trigger(intent, projectionInvalidations: projectionInvalidations, isProjectionCurrent: isProjectionCurrent)
    }

    private func trigger(_ intent: UserIntent, projectionInvalidations: AnyPublisher<Void, Never>? = nil,
                         isProjectionCurrent: (@MainActor @Sendable () -> Bool)? = nil) {
        guard isRunning, let current = snapshot.windows[intent.windowID] else { return }
        #if DEBUG
        HoverTrace.action("\(intent.action)", phase: "begin")
        defer { HoverTrace.action("\(intent.action)", phase: "dispatched") }
        #endif
        let key = intent.windowID.rawValue
        switch intent.action {
        case .close:
            guard !work.contains(key: key, kind: .closeWindow),
                  intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        for (oldKey, target) in activatingTargets where oldKey != key && target.representsSameTarget(as: current.actionIdentity) {
            cancelAction(for: oldKey)
        }
        retireAction(for: key)
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

        #if DEBUG
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = optimisticStatesByWindowID[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }
        #endif

        #if DEBUG
        if ClickLatencyTrace.isEnabled, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            ClickLatencyTrace.begin(
                windowID: wid,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }
        #endif

        let token = UUID()
        actionTokens[key] = token
        projectionInvalidationSubscriptions[key] = projectionInvalidations?.sink { [weak self] in
            guard let self, self.actionTokens[key] == token else { return }
            self.cancelAction(for: key)
        }
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            optimisticStatesByWindowID[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        applyOptimisticState(for: request, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        dispatchToExecutor(intent: intent, request: request, forcedMinimizedPrior: effectiveStatusAtPlan == .minimized,
                           isProjectionCurrent: isProjectionCurrent)
    }

    private func dispatchToExecutor(intent: UserIntent, request: PlatformActionRequest, forcedMinimizedPrior: Bool,
                                    isProjectionCurrent: (@MainActor @Sendable () -> Bool)?) {
        let executor = actionExecutor
        let capturedSnapshot = externalSnapshot
        let utilityRecord: WindowRecord?
        if let record = snapshot.windows[intent.windowID], case .utility = record.source {
            utilityRecord = record
        } else {
            utilityRecord = nil
        }
        let generation = work.generation
        let key = intent.windowID.rawValue
        guard let token = actionTokens[key] else { return }
        let onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?
        if (request.kind == .minimizeWindow || request.kind == .closeWindow) && Self.handoffActivePredictionEnabled {
            onHandoffActivePrediction = { @Sendable [weak self] (windowID: WindowID) in
                Task { @MainActor [weak self] in
                    guard let self, self.work.isCurrent(generation),
                          self.actionTokens[key] == token else { return }
                    guard self.optimisticStatesByWindowID[windowID.rawValue] == nil else { return }
                    guard let planned = capturedSnapshot.windows[windowID],
                          let current = self.snapshot.windows[windowID],
                          current.actionIdentity == planned.actionIdentity,
                          current.status != .minimized, current.status != .hidden else { return }
                    self.optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                        status: .active, createdAt: Date(), focusHandoffGrace: true,
                        systemPredicted: true, handoffSourceToken: token
                    )
                }
            }
        } else {
            onHandoffActivePrediction = nil
        }
        let accepted = work.submit(key: key, kind: request.kind,
            maximumPendingKeys: max(32, snapshot.windows.count)) { [weak self] generation, cancellation in
            let admitted = await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key] == token else { return false }
                if isProjectionCurrent?() == false {
                    self.cancelAction(for: key)
                    return false
                }
                if request.kind == .activateWindow, let record = capturedSnapshot.windows[intent.windowID],
                   record.actionTarget != nil {
                    self.activatingTargets[key] = record.actionIdentity
                }
                return true
            }
            guard admitted else { return }
            #if DEBUG
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            #endif
            let result: Bool?
            if let utilityRecord {
                result = await MainActor.run { [weak self] in
                    guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                          self.actionTokens[key] == token else { return nil }
                    guard self.snapshot.windows[utilityRecord.id]?.actionIdentity == utilityRecord.actionIdentity,
                          isProjectionCurrent?() != false else {
                        self.cancelAction(for: key)
                        return nil
                    }
                    return self.utilityWindows.execute(request.kind, windowID: utilityRecord.id)
                }
            } else {
                result = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                    executor.execute(request, snapshot: capturedSnapshot,
                                     forcedMinimizedPrior: forcedMinimizedPrior,
                                     cancellation: cancellation,
                                     onHandoffActivePrediction: onHandoffActivePrediction)
                }
            }
            guard let success = result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key] == token else { return }
                #if DEBUG
                ClickLatencyTrace.end(windowID: request.windowID?.rawValue, success: success)
                #endif
                self.retireAction(for: key, preservingHandoff: success)
                if !success { self.optimisticStatesByWindowID.removeValue(forKey: key) }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                self.updateFeedbackTimer()
            }
        }
        if !accepted {
            retireAction(for: key)
            optimisticStatesByWindowID.removeValue(forKey: key)
            intentPipeline.registerExecutionResult(intent: intent, request: request, success: false)
            publishFeedbackEntries()
            updateFeedbackTimer()
        }
    }

    private func cancelAction(for key: String) {
        work.cancel(key: key)
        #if DEBUG
        ClickLatencyTrace.end(windowID: key, success: false)
        #endif
        retireAction(for: key)
        optimisticStatesByWindowID.removeValue(forKey: key)
        intentPipeline.discardFeedback(for: [key])
        publishFeedbackEntries()
        updateFeedbackTimer()
    }

    private func retireAction(for key: String, preservingHandoff: Bool = false) {
        projectionInvalidationSubscriptions.removeValue(forKey: key)
        activatingTargets.removeValue(forKey: key)
        guard let token = actionTokens.removeValue(forKey: key), !preservingHandoff else { return }
        let retainedStates = optimisticStatesByWindowID.filter { $0.value.handoffSourceToken != token }
        if retainedStates.count != optimisticStatesByWindowID.count {
            optimisticStatesByWindowID = retainedStates
        }
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        var retainedActionIDs = Set<String>()
        var replacedIDs = Set<String>()
        for (id, window) in newSnapshot.windows {
            if let previous = snapshot.windows[id], previous.actionIdentity != window.actionIdentity {
                replacedIDs.insert(id.rawValue)
            } else {
                retainedActionIDs.insert(id.rawValue)
            }
        }
        for (key, target) in activatingTargets {
            if let atOriginalKey = newSnapshot.windows[target.windowID] {
                if !target.representsSameTarget(as: atOriginalKey.actionIdentity) {
                    retainedActionIDs.remove(key)
                    replacedIDs.insert(key)
                }
            } else if newSnapshot.windows.values.contains(where: { target.representsSameTarget(as: $0.actionIdentity) }) {
                retainedActionIDs.insert(key)
            }
        }
        for key in actionTokens.keys where !retainedActionIDs.contains(key) {
            let closed = !replacedIDs.contains(key) && work.contains(key: key, kind: .closeWindow)
            retireAction(for: key, preservingHandoff: closed)
        }
        work.retain(windowIDs: retainedActionIDs)
        if !replacedIDs.isEmpty {
            intentPipeline.discardFeedback(for: replacedIDs)
            let retainedStates = optimisticStatesByWindowID.filter { !replacedIDs.contains($0.key) }
            if retainedStates != optimisticStatesByWindowID {
                optimisticStatesByWindowID = retainedStates
            }
        }
        if snapshot != newSnapshot { snapshot = newSnapshot }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        updateFeedbackTimer()

    }

    private func tickFeedback() {
        guard isRunning else { return }
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        updateFeedbackTimer()
    }

    private func publishFeedbackEntries() {
        #if DEBUG
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
        #endif
    }

    private func updateFeedbackTimer() {
        let shouldTick = FeedbackTickPolicy.shouldTick(
            isRunning: isRunning,
            hasFeedbackEntries: !intentPipeline.feedbackState.entriesByWindowID.isEmpty,
            hasOptimisticStates: !optimisticStatesByWindowID.isEmpty
        )
        guard shouldTick else {
            feedbackTimer?.invalidate()
            feedbackTimer = nil
            return
        }
        guard feedbackTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFeedback() }
        }
        timer.tolerance = 0.05
        feedbackTimer = timer
    }

    #if DEBUG
    var pendingActionsForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    private static let optimisticTimeout: TimeInterval = 4.0

    private func applyOptimisticState(for request: PlatformActionRequest, wasMinimizedAtPlan: Bool) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, createdAt: Date(), focusHandoffGrace: wasMinimizedAtPlan)
        case .minimizeWindow:
            state = OptimisticWindowState(status: .minimized, createdAt: Date())
        case .closeWindow:
            state = nil
        }
        guard let state, let windowID = request.windowID else { return }
        optimisticStatesByWindowID[windowID.rawValue] = state
    }

    private func reconcileOptimisticStates(now: Date = Date()) {
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            let cleared: String?
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout {
                cleared = "timeout"
            } else if snapshot.windows[WindowID(rawValue: windowID)] == nil {
                cleared = "window-gone"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      Self.optimisticConfirmed(predicted: state.status, actual: record.status) {
                cleared = "confirmed"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      OptimisticWindowState.systemPredictionFalsified(state: state, actual: record.status) {
                cleared = "prediction-falsified"
            } else if OptimisticWindowState.supersededByActiveSibling(
                windowID: windowID, state: state, now: now,
                optimisticStates: optimisticStatesByWindowID,
                snapshot: snapshot, handoffGraceEnabled: Self.handoffActiveGraceEnabled
            ) {
                cleared = "superseded-by-active-sibling"
            } else {
                cleared = nil
            }
            #if DEBUG
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(now.timeIntervalSince(state.createdAt) * 1000), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            #endif
            return cleared == nil
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}
