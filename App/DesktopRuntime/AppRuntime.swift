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

    func hasNativeFocus(_ id: WindowID) -> Bool {
        isAppFrontmost(pid) && entries.first(where: { $0.id == id })?.window?.isKeyWindow == true
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
    var effectiveActiveWindowID: WindowID? {
        snapshot.orderedWindowIDs.first { snapshot.windows[$0]?.status == .active }
    }

    struct PendingMinimization {
        let requestedAt: ContinuousClock.Instant
        let token: UUID
    }

    private(set) var pendingMinimizations: [String: PendingMinimization] = [:]

    private let tracker: any WindowInventoryTracking
    private let work = WindowActionQueue()
    private var actionTokens: [String: UUID] = [:]
    private var activatingTargets: [String: WindowActionIdentity] = [:]
    private var projectionInvalidationSubscriptions: [String: AnyCancellable] = [:]
    private let intentPipeline: IntentPipeline
    private let monotonicNow: () -> ContinuousClock.Instant
    private let actionExecutor: any WindowActionExecuting
    private let utilityWindows: UtilityWindowRegistry
    private var externalSnapshot: DockSnapshot = .empty
    private var snapshotSubscription: AnyCancellable?

    #if DEBUG
    private let chipProbeLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "ChipProbe")
    private static let chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    private struct WindowRestoreInventoryState: Equatable {
        let status: WindowStatus?
        let isOnDesktop: Bool?
        let windowNumber: CGWindowID?
    }
    private var windowRestore: (trace: WindowRestoreTrace, inventory: WindowRestoreInventoryState, onScreen: Bool?)?
    #endif
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
    }

    private var isRunning: Bool { snapshotSubscription != nil }

    func stop() {
        #if DEBUG
        clearWindowRestore()
        #endif
        work.stop()
        actionTokens.removeAll()
        activatingTargets.removeAll()
        projectionInvalidationSubscriptions.removeAll()
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        pendingMinimizations.removeAll()
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

    var windowSpaceInvalidations: AnyPublisher<CGWindowID, Never> { tracker.windowSpaceInvalidations }
    var launchWindowFocus: AnyPublisher<WindowLaunchFocus, Never> { tracker.launchWindowFocus }

    func isLaunchWindowFocusCurrent(_ focus: WindowLaunchFocus) -> Bool {
        tracker.isLaunchWindowFocusCurrent(focus)
    }

    func refreshFrontmostWindow() { tracker.refreshFrontmostWindow() }

    func registerUtilityWindow(_ window: NSWindow) { utilityWindows.register(window) }

    func utilityWindowOnActiveSpace(_ id: WindowID) -> Bool? { utilityWindows.onActiveSpace(id) }
    func utilityWindowPhysicalDisplayID(_ id: WindowID) -> CGDirectDisplayID? { utilityWindows.physicalDisplayID(id) }

    private func publishSnapshot() {
        guard isRunning else { return }
        #if DEBUG
        let resources = ActionResourceLog.begin("runtime.publishSnapshot")
        defer { resources?.finish() }
        #endif
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
        let token = UUID()
        #if DEBUG
        let resources = ActionResourceLog.begin("window.\(intent.action.rawValue).dispatch", correlation: token.uuidString)
        defer { resources?.finish() }
        #endif
        let requestedAt = monotonicNow()
        if intent.action == .close {
            guard !work.contains(key: key, kind: .closeWindow) else { return }
            if !intentPipeline.canBegin(intent: intent) {
                intentPipeline.reconcile(with: snapshot, now: requestedAt)
                guard intentPipeline.canBegin(intent: intent) else { return }
            }
        }
        for (oldKey, target) in activatingTargets where oldKey != key && target.representsSameTarget(as: current.actionIdentity) {
            cancelAction(for: oldKey)
        }
        reconcilePendingMinimizations(now: requestedAt)
        let pendingMinimize = pendingMinimizations[key] != nil
        retireAction(for: key)
        let request = intentPipeline.plan(intent: intent, snapshot: snapshot, pendingMinimize: pendingMinimize)

        #if DEBUG
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) pendingMinimize=\(pendingMinimize, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }
        #endif

        #if DEBUG
        if windowRestore?.trace.identity.windowID == current.id { clearWindowRestore() }
        if request.kind == .activateWindow, case .external = current.source,
           current.status == .hidden || current.status == .minimized || pendingMinimize {
            let trace = WindowRestoreTrace(token: token, identity: current.actionIdentity)
            windowRestore = (trace, .init(status: current.status, isOnDesktop: current.isOnDesktop,
                                          windowNumber: current.cgWindowID), nil)
            (tracker as? AppTracker)?.onWindowRestoreOnScreenSample = { [weak self] onScreenIDs, source in
                self?.observeWindowRestoreOnScreen(onScreenIDs, source: source)
            }
            trace.mark("click", detail: "intent=\(intent.action.rawValue) inventory=\(current.status.rawValue) pending-minimize=\(pendingMinimize) on-desktop=\(current.isOnDesktop)")
        }
        if let clickLatencyTrace, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            clickLatencyTrace.begin(
                windowID: wid,
                token: token,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }
        #endif
        actionTokens[key] = token
        projectionInvalidationSubscriptions[key] = projectionInvalidations?.sink { [weak self] in
            guard let self, self.actionTokens[key] == token else { return }
            self.cancelAction(for: key)
        }
        if request.kind == .minimizeWindow {
            pendingMinimizations[key] = PendingMinimization(requestedAt: requestedAt, token: token)
        } else if pendingMinimize {
            pendingMinimizations.removeValue(forKey: key)
        }
        intentPipeline.registerPending(intent: intent, request: request, at: requestedAt)
        publishFeedbackEntries()

        dispatchToExecutor(intent: intent, request: request, forcedMinimizedPrior: pendingMinimize || current.status == .minimized,
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
        #if DEBUG
        let clickLatencyTrace = clickLatencyTrace
        let traceWindowID = request.windowID?.rawValue
        let restoreTrace = windowRestore.flatMap { $0.trace.token == token ? $0.trace : nil }
        #endif
        let accepted = work.submit(key: key, kind: request.kind,
            maximumPendingKeys: max(32, snapshot.windows.count)) { [weak self] generation, cancellation in
            #if DEBUG
            let resources = ActionResourceLog.begin("window.\(request.kind.rawValue).lifecycle", correlation: token.uuidString)
            defer { resources?.finish() }
            #endif
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
            restoreTrace?.mark("execution-admitted")
            if let traceWindowID {
                clickLatencyTrace?.mark(windowID: traceWindowID, token: token, stage: "execStart")
            }
            #endif
            let result: (request: PlatformActionRequest, outcome: WindowActionResult)?
            if let utilityRecord {
                result = await MainActor.run { [weak self] in
                    guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                          self.actionTokens[key] == token else { return nil }
                    guard self.snapshot.windows[utilityRecord.id]?.actionIdentity == utilityRecord.actionIdentity,
                          isProjectionCurrent?() != false else {
                        self.cancelAction(for: key)
                        return nil
                    }
                    let resolved = Self.resolve(request, hasFocus: self.utilityWindows.hasNativeFocus(utilityRecord.id))
                    return (resolved, WindowActionResult(success:
                        self.utilityWindows.execute(resolved.kind, windowID: utilityRecord.id)))
                }
            } else {
                result = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                    let resolved = Self.resolve(request, hasFocus: capturedSnapshot.windows[intent.windowID].map {
                        executor.hasNativeFocus($0, cancellation: cancellation)
                    } ?? false)
                    let execute = {
                        executor.executeWithFocusConfirmation(resolved, snapshot: capturedSnapshot,
                            forcedMinimizedPrior: forcedMinimizedPrior, cancellation: cancellation, onHandoffTarget: nil)
                    }
                    #if DEBUG
                    func executeWithClickTrace() -> WindowActionResult {
                        if let clickLatencyTrace, let traceWindowID {
                            return clickLatencyTrace.withOperation(windowID: traceWindowID, token: token, execute)
                        }
                        return execute()
                    }
                    if let restoreTrace {
                        return (resolved, WindowRestoreTrace.$current.withValue(restoreTrace, operation: executeWithClickTrace))
                    }
                    return (resolved, executeWithClickTrace())
                    #else
                    return (resolved, execute())
                    #endif
                }
            }
            guard let (resolved, outcome) = result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), !cancellation.isCancelled,
                      self.actionTokens[key] == token else { return }
                let success = outcome.success
                if success, let focus = outcome.focus, let target = capturedSnapshot.windows[intent.windowID]?.actionIdentity {
                    self.tracker.acceptRestoredWindowFocus(focus, target: target)
                }
                #if DEBUG
                if let traceWindowID {
                    clickLatencyTrace?.end(windowID: traceWindowID, token: token, success: success)
                }
                restoreTrace?.mark("execution-finished", detail: "success=\(success)")
                self.chipProbeLogger.notice("command-finished windowID=\(key, privacy: .public) planned=\(request.kind.rawValue, privacy: .public) executed=\(resolved.kind.rawValue, privacy: .public) success=\(success, privacy: .public)")
                #endif
                let focusChanged = resolved.kind != request.kind
                self.retireAction(for: key, preservingEffects: success && !focusChanged)
                if focusChanged {
                    self.intentPipeline.registerPending(intent: intent, request: resolved)
                    self.tracker.refreshFrontmostWindow()
                }
                self.intentPipeline.registerExecutionResult(intent: intent, request: resolved, success: success)
                self.publishFeedbackEntries()
            }
        }
        if !accepted {
            #if DEBUG
            restoreTrace?.mark("queue-rejected")
            #endif
            retireAction(for: key)
            intentPipeline.registerExecutionResult(intent: intent, request: request, success: false)
            publishFeedbackEntries()
        }
    }

    nonisolated private static func resolve(_ request: PlatformActionRequest, hasFocus: @autoclosure () -> Bool)
        -> PlatformActionRequest {
        guard request.kind == .minimizeWindow, !hasFocus() else { return request }
        return PlatformActionRequest(kind: .activateWindow, windowID: request.windowID)
    }

    private func cancelAction(for key: String) {
        work.cancel(key: key)
        #if DEBUG
        if let token = actionTokens[key] {
            if windowRestore?.trace.token == token { windowRestore?.trace.mark("execution-cancelled") }
            clickLatencyTrace?.end(windowID: key, token: token, success: false)
        }
        #endif
        retireAction(for: key)
        intentPipeline.discardFeedback(for: [key])
        publishFeedbackEntries()
    }

    private func retireAction(for key: String, preservingEffects: Bool = false) {
        projectionInvalidationSubscriptions.removeValue(forKey: key)
        activatingTargets.removeValue(forKey: key)
        guard let token = actionTokens.removeValue(forKey: key), !preservingEffects else { return }
        if pendingMinimizations[key]?.token == token { pendingMinimizations.removeValue(forKey: key) }
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        #if DEBUG
        observeWindowRestoreInventory(newSnapshot)
        #endif
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
            retireAction(for: key, preservingEffects: closed)
        }
        work.retain(windowIDs: retainedActionIDs)
        if !replacedIDs.isEmpty {
            intentPipeline.discardFeedback(for: replacedIDs)
            for key in replacedIDs { pendingMinimizations.removeValue(forKey: key) }
        }
        if snapshot != newSnapshot { snapshot = newSnapshot }
        let now = monotonicNow()
        intentPipeline.reconcile(with: newSnapshot, now: now)
        publishFeedbackEntries()
        reconcilePendingMinimizations(now: now)
    }

    private func publishFeedbackEntries() {
        #if DEBUG
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
        #endif
    }

    #if DEBUG
    private func clearWindowRestore() {
        windowRestore = nil
        (tracker as? AppTracker)?.onWindowRestoreOnScreenSample = nil
    }

    private func observeWindowRestoreOnScreen(_ ids: Set<CGWindowID>, source: String) {
        guard let observation = windowRestore else { return }
        guard observation.trace.isRecent else { clearWindowRestore(); return }
        guard let window = observation.inventory.windowNumber ?? observation.trace.identity.cgWindowID else { return }
        let onScreen = ids.contains(window)
        guard observation.onScreen != onScreen else { return }
        windowRestore?.onScreen = onScreen
        observation.trace.mark("windowserver-onscreen", detail: "source=\(source) resolved-window=\(window) on-screen=\(onScreen)")
    }

    private func observeWindowRestoreInventory(_ snapshot: DockSnapshot) {
        guard let observation = windowRestore else { return }
        guard observation.trace.isRecent else { clearWindowRestore(); return }
        let identity = observation.trace.identity
        let record = snapshot.windows[identity.windowID].flatMap {
            $0.actionIdentity == identity || identity.representsSameTarget(as: $0.actionIdentity) ? $0 : nil
        } ?? snapshot.windows.values.first { identity.representsSameTarget(as: $0.actionIdentity) }
        let next = WindowRestoreInventoryState(status: record?.status, isOnDesktop: record?.isOnDesktop,
                                                windowNumber: record?.cgWindowID)
        guard next != observation.inventory else { return }
        windowRestore?.inventory = next
        if next.windowNumber != observation.inventory.windowNumber { windowRestore?.onScreen = nil }
        observation.trace.mark("inventory-transition", detail: "from=\(observation.inventory.status?.rawValue ?? "missing") to=\(next.status?.rawValue ?? "missing") on-desktop=\(String(describing: next.isOnDesktop)) resolved-window=\(next.windowNumber ?? 0)")
    }

    var pendingActionsForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    private func reconcilePendingMinimizations(now: ContinuousClock.Instant) {
        guard !pendingMinimizations.isEmpty else { return }
        pendingMinimizations = pendingMinimizations.filter { id, request in
            guard let record = snapshot.windows[WindowID(rawValue: id)] else { return false }
            return record.status != .minimized && record.status != .hidden && record.status != .disappeared
                && request.requestedAt.duration(to: now) <= .seconds(4)
        }
    }
}
