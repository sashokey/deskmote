import AppKit
import Combine
import CoreGraphics
import Foundation
import Synchronization
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
    var clickLatencyTrace = ClickLatencyTrace.live
    #endif
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:] {
        didSet {
            if let prediction = activeFocusPrediction,
               optimisticStatesByWindowID[prediction.windowID.rawValue]?.status != .active {
                activeFocusPrediction = nil
            }
        }
    }
    var effectiveActiveWindowID: WindowID? {
        OptimisticWindowState.activeWindowID(in: snapshot, states: optimisticStatesByWindowID)
    }

    private struct ActionToken: Sendable {
        let id = UUID()
        let activationTarget: WindowActionIdentity?
        let activationSequence: UInt64?
        let focusAttempt: NativeFocusAttempt?
    }

    private final class NativeFocusAttempt: Sendable {
        private enum Target: Sendable {
            case waiting
            case expected(WindowActionIdentity)
            case finished
            case rejected
        }

        private let target = Mutex<Target>(.waiting)

        func expect(_ identity: WindowActionIdentity) -> Bool {
            target.withLock {
                guard case .waiting = $0 else { return false }
                $0 = .expected(identity)
                return true
            }
        }

        func consume(matching identity: WindowActionIdentity) -> Bool {
            target.withLock {
                guard case let .expected(expected) = $0,
                      expected == identity || expected.representsSameTarget(as: identity) else { return false }
                $0 = .finished
                return true
            }
        }

        func invalidate() { target.withLock { $0 = .rejected } }

        var isRejected: Bool {
            target.withLock {
                if case .rejected = $0 { return true }
                return false
            }
        }

        var isPending: Bool {
            target.withLock {
                switch $0 {
                case .waiting, .expected: return true
                case .finished, .rejected: return false
                }
            }
        }
    }

    private struct ActiveFocusPrediction {
        let windowID: WindowID
        let source: ActionToken
        var earlierAttempts: [UUID: NativeFocusAttempt]
        var lastNativeFocus: WindowActionIdentity?
        var observedPredecessors: [UUID: NativeFocusAttempt]?

        mutating func consumeEarlierAttempts(matching identity: WindowActionIdentity) -> [UUID: NativeFocusAttempt] {
            var matched: [UUID: NativeFocusAttempt] = [:]
            earlierAttempts = earlierAttempts.filter { token, attempt in
                if attempt.consume(matching: identity) { matched[token] = attempt }
                return attempt.isPending
            }
            return matched
        }

        mutating func retainsPrediction(afterObserving identity: WindowActionIdentity) -> Bool {
            if lastNativeFocus.map({ $0 == identity || $0.representsSameTarget(as: identity) }) != true {
                lastNativeFocus = identity
                observedPredecessors = consumeEarlierAttempts(matching: identity)
            }
            return observedPredecessors?.values.contains(where: { !$0.isRejected }) ?? true
        }
    }

    private struct HandoffFocusPrediction {
        let source: WindowActionIdentity
        let target: WindowActionIdentity
        let action: ActionToken
        let precedingActivation: UInt64
        let state: OptimisticWindowState
    }

    private let tracker: any WindowInventoryTracking
    private let work = WindowActionQueue()
    private var actionTokens: [String: ActionToken] = [:]
    private var activationSequence: UInt64 = 0
    private var settledActivationSequence: UInt64 = 0
    private var activeFocusPrediction: ActiveFocusPrediction?
    private var handoffFocusPrediction: HandoffFocusPrediction?
    private var activatingTargets: [String: WindowActionIdentity] = [:]
    private var projectionInvalidationSubscriptions: [String: AnyCancellable] = [:]
    private let intentPipeline: IntentPipeline
    private let monotonicNow: () -> ContinuousClock.Instant
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
        monotonicNow: @escaping () -> ContinuousClock.Instant = { .now },
        activateUtilityApplication: @escaping @MainActor () -> Void = {
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate()
        }
    ) {
        self.monotonicNow = monotonicNow
        self.intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner(isAppFrontmost: isAppFrontmost),
                                             monotonicNow: monotonicNow)
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
        activationSequence = 0
        settledActivationSequence = 0
        handoffFocusPrediction = nil
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
        let replacedState = optimisticStatesByWindowID[key]
        retireAction(for: key)
        var planningStates = optimisticStatesByWindowID
        if let replacedState, !replacedState.systemPredicted { planningStates[key] = replacedState }
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: planningStates
        )

        #if DEBUG
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = planningStates[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }
        #endif

        let activationTarget = request.kind == .activateWindow ? current.actionIdentity : nil
        if activationTarget != nil { activationSequence &+= 1 }
        let focusAttempt = activationTarget != nil || Self.handoffActivePredictionEnabled ? NativeFocusAttempt() : nil
        let token = ActionToken(activationTarget: activationTarget,
                                activationSequence: activationTarget.map { _ in activationSequence }, focusAttempt: focusAttempt)
        #if DEBUG
        if let clickLatencyTrace, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            clickLatencyTrace.begin(
                windowID: wid,
                token: token.id,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }
        #endif
        actionTokens[key] = token
        projectionInvalidationSubscriptions[key] = projectionInvalidations?.sink { [weak self] in
            guard let self, self.actionTokens[key]?.id == token.id else { return }
            self.cancelAction(for: key)
        }
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            planningStates[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        let requestedAt = monotonicNow()
        applyOptimisticState(for: request, token: token, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized, at: requestedAt)
        reconcileHandoffPrediction(now: requestedAt)
        intentPipeline.registerPending(intent: intent, request: request, at: requestedAt)
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
        guard let action = actionTokens[key] else { return }
        let token = action.id
        #if DEBUG
        let clickLatencyTrace = clickLatencyTrace
        let traceWindowID = request.windowID?.rawValue
        #endif
        let onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?
        if request.kind != .activateWindow, let focusAttempt = action.focusAttempt,
           let sourceIdentity = capturedSnapshot.windows[intent.windowID]?.actionIdentity {
            let precedingActivation = activationSequence
            onHandoffActivePrediction = { @Sendable [weak self] (windowID: WindowID) in
                guard let planned = capturedSnapshot.windows[windowID],
                      focusAttempt.expect(planned.actionIdentity) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.work.isCurrent(generation),
                          self.actionTokens[key]?.id == token,
                          self.handoffFocusPrediction == nil else { return }
                    let reportedAt = self.monotonicNow()
                    let state = OptimisticWindowState(
                        status: .active, createdAt: reportedAt, focusHandoffGrace: true,
                        systemPredicted: true, sourceActionToken: token
                    )
                    self.handoffFocusPrediction = HandoffFocusPrediction(
                        source: sourceIdentity, target: planned.actionIdentity, action: action,
                        precedingActivation: precedingActivation, state: state
                    )
                    self.reconcileHandoffPrediction(now: reportedAt)
                }
            }
        } else {
            onHandoffActivePrediction = nil
        }
        let accepted = work.submit(key: key, kind: request.kind,
            maximumPendingKeys: max(32, snapshot.windows.count)) { [weak self] generation, cancellation in
            let admitted = await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key]?.id == token else { return false }
                if isProjectionCurrent?() == false {
                    self.cancelAction(for: key)
                    return false
                }
                if let target = action.activationTarget {
                    _ = action.focusAttempt?.expect(target)
                }
                if request.kind == .activateWindow, let record = capturedSnapshot.windows[intent.windowID],
                   record.actionTarget != nil {
                    self.activatingTargets[key] = record.actionIdentity
                }
                return true
            }
            guard admitted else { return }
            #if DEBUG
            if let traceWindowID {
                clickLatencyTrace?.mark(windowID: traceWindowID, token: token, stage: "execStart")
            }
            #endif
            let result: Bool?
            if let utilityRecord {
                result = await MainActor.run { [weak self] in
                    guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                          self.actionTokens[key]?.id == token else { return nil }
                    guard self.snapshot.windows[utilityRecord.id]?.actionIdentity == utilityRecord.actionIdentity,
                          isProjectionCurrent?() != false else {
                        self.cancelAction(for: key)
                        return nil
                    }
                    return self.utilityWindows.execute(request.kind, windowID: utilityRecord.id)
                }
            } else {
                result = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                    let execute = {
                        executor.execute(request, snapshot: capturedSnapshot,
                                         forcedMinimizedPrior: forcedMinimizedPrior,
                                         cancellation: cancellation,
                                         onHandoffActivePrediction: onHandoffActivePrediction)
                    }
                    #if DEBUG
                    if let clickLatencyTrace, let traceWindowID {
                        return clickLatencyTrace.withOperation(windowID: traceWindowID, token: token, execute)
                    }
                    #endif
                    return execute()
                }
            }
            guard let success = result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key]?.id == token else { return }
                #if DEBUG
                if let traceWindowID {
                    clickLatencyTrace?.end(windowID: traceWindowID, token: token, success: success)
                }
                #endif
                self.retireAction(for: key, preservingEffects: success)
                self.reconcileHandoffPrediction()
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                self.updateFeedbackTimer()
            }
        }
        if !accepted {
            retireAction(for: key)
            reconcileHandoffPrediction()
            intentPipeline.registerExecutionResult(intent: intent, request: request, success: false)
            publishFeedbackEntries()
            updateFeedbackTimer()
        }
    }

    private func cancelAction(for key: String) {
        work.cancel(key: key)
        #if DEBUG
        if let token = actionTokens[key]?.id {
            clickLatencyTrace?.end(windowID: key, token: token, success: false)
        }
        #endif
        retireAction(for: key)
        reconcileHandoffPrediction()
        intentPipeline.discardFeedback(for: [key])
        publishFeedbackEntries()
        updateFeedbackTimer()
    }

    private func retireAction(for key: String, preservingEffects: Bool = false, reconcileFocus: Bool = true) {
        projectionInvalidationSubscriptions.removeValue(forKey: key)
        activatingTargets.removeValue(forKey: key)
        guard let action = actionTokens.removeValue(forKey: key) else { return }
        if preservingEffects {
            markActivationSettled(action)
            return
        }
        action.focusAttempt?.invalidate()
        if handoffFocusPrediction?.action.id == action.id { handoffFocusPrediction = nil }
        activeFocusPrediction?.earlierAttempts.removeValue(forKey: action.id)
        let retainedStates = optimisticStatesByWindowID.filter { $0.value.sourceActionToken != action.id }
        if retainedStates.count != optimisticStatesByWindowID.count {
            optimisticStatesByWindowID = retainedStates
        }
        if reconcileFocus, activeFocusPrediction?.observedPredecessors?[action.id] != nil {
            reconcileOptimisticStates()
        }
    }

    private func markActivationSettled(_ action: ActionToken) {
        if let sequence = action.activationSequence {
            settledActivationSequence = max(settledActivationSequence, sequence)
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
            retireAction(for: key, preservingEffects: closed, reconcileFocus: false)
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
        let now = monotonicNow()
        intentPipeline.reconcile(with: newSnapshot, now: now)
        publishFeedbackEntries()
        reconcileOptimisticStates(now: now)
        updateFeedbackTimer()

    }

    private func tickFeedback() {
        guard isRunning else { return }
        let now = monotonicNow()
        intentPipeline.reconcile(with: snapshot, now: now)
        publishFeedbackEntries()
        reconcileOptimisticStates(now: now)
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

    private static let optimisticTimeout: Duration = .seconds(4)

    private var confirmedActiveWindow: WindowRecord? {
        OptimisticWindowState.confirmedActiveWindow(in: snapshot, states: optimisticStatesByWindowID)
    }

    private var nativeActiveWindow: WindowRecord? {
        OptimisticWindowState.confirmedActiveWindow(in: snapshot, states: [:])
    }

    private func applyOptimisticState(for request: PlatformActionRequest, token: ActionToken,
                                      wasMinimizedAtPlan: Bool, at requestedAt: ContinuousClock.Instant) {
        guard let windowID = request.windowID else { return }
        if request.kind != .activateWindow, handoffFocusPrediction?.target.windowID == windowID {
            handoffFocusPrediction = nil
        }
        switch request.kind {
        case .activateWindow:
            var earlierAttempts = activeFocusPrediction?.earlierAttempts ?? [:]
            if let previous = activeFocusPrediction?.source, let attempt = previous.focusAttempt, attempt.isPending {
                earlierAttempts[previous.id] = attempt
            }
            for action in actionTokens.values where action.id != token.id {
                guard let attempt = action.focusAttempt, attempt.isPending else { continue }
                earlierAttempts[action.id] = attempt
            }
            let nativeFocus = nativeActiveWindow?.actionIdentity
            var prediction = ActiveFocusPrediction(windowID: windowID, source: token, earlierAttempts: earlierAttempts,
                                                   lastNativeFocus: nativeFocus)
            if let nativeFocus { _ = prediction.consumeEarlierAttempts(matching: nativeFocus) }
            activeFocusPrediction = prediction
            var states = optimisticStatesByWindowID.filter { $0.value.status != .active }
            states[windowID.rawValue] = OptimisticWindowState(
                status: .active, createdAt: requestedAt, focusHandoffGrace: wasMinimizedAtPlan, sourceActionToken: token.id
            )
            optimisticStatesByWindowID = states
        case .minimizeWindow:
            optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                status: .minimized, createdAt: requestedAt, sourceActionToken: token.id
            )
        case .closeWindow:
            optimisticStatesByWindowID.removeValue(forKey: windowID.rawValue)
        }
    }

    private func reconcileHandoffPrediction(now instant: ContinuousClock.Instant? = nil) {
        guard let prediction = handoffFocusPrediction else { return }
        let now = instant ?? monotonicNow()
        let key = prediction.target.windowID.rawValue
        let visible = optimisticStatesByWindowID[key] == prediction.state
        let source = snapshot.windows[prediction.source.windowID]?.actionIdentity
        guard settledActivationSequence <= prediction.precedingActivation,
              prediction.state.createdAt.duration(to: now) <= Self.optimisticTimeout,
              source == nil || source == prediction.source,
              let target = snapshot.windows[prediction.target.windowID], target.actionIdentity == prediction.target,
              target.status != .active, target.status != .minimized, target.status != .hidden else {
            handoffFocusPrediction = nil
            if visible { optimisticStatesByWindowID.removeValue(forKey: key) }
            return
        }
        if visible { return }
        if let nativeFocus = nativeActiveWindow?.actionIdentity, nativeFocus != prediction.source {
            handoffFocusPrediction = nil
            return
        }
        if actionTokens.values.contains(where: { ($0.activationSequence ?? 0) > prediction.precedingActivation }) { return }
        guard optimisticStatesByWindowID[key] == nil,
              !optimisticStatesByWindowID.values.contains(where: { $0.status == .active }) else {
            handoffFocusPrediction = nil
            return
        }
        activeFocusPrediction = ActiveFocusPrediction(windowID: target.id, source: prediction.action, earlierAttempts: [:],
                                                      lastNativeFocus: prediction.source)
        optimisticStatesByWindowID[key] = prediction.state
    }

    private func reconcileOptimisticStates(now instant: ContinuousClock.Instant? = nil) {
        let now = instant ?? monotonicNow()
        defer { reconcileHandoffPrediction(now: now) }
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            let age = state.createdAt.duration(to: now)
            let cleared: String?
            if age > Self.optimisticTimeout {
                cleared = "timeout"
            } else if snapshot.windows[WindowID(rawValue: windowID)] == nil {
                cleared = "window-gone"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      Self.optimisticConfirmed(predicted: state.status, actual: record.status) {
                if let prediction = activeFocusPrediction, prediction.windowID == record.id,
                   prediction.source.focusAttempt?.consume(matching: record.actionIdentity) == true {
                    markActivationSettled(prediction.source)
                }
                cleared = "confirmed"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      OptimisticWindowState.systemPredictionFalsified(state: state, actual: record.status) {
                cleared = "prediction-falsified"
            } else if activePredictionSuperseded(windowID: windowID, state: state, now: now) {
                cleared = "superseded-by-native-focus"
            } else {
                cleared = nil
            }
            if cleared != nil, handoffFocusPrediction?.state == state { handoffFocusPrediction = nil }
            #if DEBUG
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(age / .milliseconds(1)), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            #endif
            return cleared == nil
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    private func activePredictionSuperseded(windowID: String, state: OptimisticWindowState, now: ContinuousClock.Instant) -> Bool {
        guard state.status == .active, let actual = confirmedActiveWindow,
              actual.id.rawValue != windowID,
              let predicted = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        if activeFocusPrediction?.windowID == predicted.id,
           activeFocusPrediction?.retainsPrediction(afterObserving: actual.actionIdentity) == true {
            return false
        }
        guard actual.sharesApplicationFocus(with: predicted) else { return true }
        return OptimisticWindowState.supersededByActiveSibling(
            windowID: windowID, state: state, now: now, optimisticStates: optimisticStatesByWindowID,
            snapshot: snapshot, handoffGraceEnabled: Self.handoffActiveGraceEnabled
        )
    }

    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}
