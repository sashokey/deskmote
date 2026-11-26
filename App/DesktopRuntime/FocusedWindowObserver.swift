import AppKit
@preconcurrency import ApplicationServices
import Foundation
#if DEBUG
import os

private let focusedGeometryLog = Logger(subsystem: "io.github.sashokey.deskmote", category: "window-height")
#endif

enum FocusedWindowRead: Sendable {
    case window(AXElementKey)
    case none
    case unavailable
    case temporarilyUnavailable
}

private final class FocusedGeometryBinding: @unchecked Sendable {
    typealias ApplicationRegistration = (complete: Bool, focusMessagingFailed: Bool)

    let session: any WindowObservationSession
    private let pid: pid_t
    private var window: AXElementKey?
    private var applicationRegistered = false
    private let names = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]

    init(session: any WindowObservationSession, pid: pid_t) {
        self.session = session
        self.pid = pid
    }

    func registerApplication(cancellation: OperationCancellation) -> ApplicationRegistration {
        if applicationRegistered { return (true, false) }
        var complete = true
        var focusMessagingFailed = false
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            guard !cancellation.isCancelled else { return (false, false) }
            let status = session.add(name, element: nil)
            #if DEBUG
            focusedGeometryLog.notice("subscription pid=\(self.pid) scope=application notification=\(name, privacy: .public) axError=\(status.rawValue)")
            #endif
            if name == kAXFocusedWindowChangedNotification { focusMessagingFailed = status == .cannotComplete }
            if !Self.accepted(status) { complete = false }
        }
        applicationRegistered = complete
        return (complete, focusMessagingFailed)
    }

    func replaceWindow(with next: AXElementKey?, cancellation: OperationCancellation) -> Bool {
        guard !cancellation.isCancelled else { return false }
        let appReady = registerApplication(cancellation: cancellation).complete
        if let window {
            var removed = true
            for name in names {
                guard !cancellation.isCancelled else { return false }
                let status = session.remove(name, element: window)
                switch status {
                case .success, .notificationNotRegistered, .notificationUnsupported, .invalidUIElement:
                    break
                default:
                    #if DEBUG
                    focusedGeometryLog.notice("unsubscribe-failed pid=\(self.pid) window=\(window.hashValue) notification=\(name, privacy: .public) axError=\(status.rawValue)")
                    #endif
                    removed = false
                }
            }
            guard removed else { return false }
            self.window = nil
        }
        guard !cancellation.isCancelled else { return false }
        guard let next else { return appReady }
        window = next
        var complete = appReady
        for name in names {
            guard !cancellation.isCancelled else { return false }
            let status = session.add(name, element: next)
            #if DEBUG
            focusedGeometryLog.notice("subscription pid=\(self.pid) scope=window window=\(next.hashValue) notification=\(name, privacy: .public) axError=\(status.rawValue)")
            #endif
            if !Self.accepted(status) { complete = false }
        }
        return complete
    }

    private static func accepted(_ error: AXError) -> Bool {
        error == .success || error == .notificationAlreadyRegistered || error == .notificationUnsupported
    }

}

@MainActor
final class FrontmostWindowGeometryObserver {
    enum NewWindowEvidence: String {
        case windowCreated
        case applicationLaunched
        case launchFocusRecovered
    }

    enum Event {
        case focusedWindowChanged
        case windowBindingChanged(AXElementKey?, ownerPID: pid_t?)
        case newFocusedWindow(AXElementKey, evidence: NewWindowEvidence)
        case geometryChanged(AXElementKey, notification: String, receivedAt: TimeInterval?)
        case windowDestroyed
    }

    private enum FirstFocus {
        case awaitingWindow
        case window(AXElementKey)
        case superseded

        mutating func observe(_ current: AXElementKey?) {
            switch self {
            case .awaitingWindow:
                if let current { self = .window(current) }
            case let .window(first) where first != current:
                self = .superseded
            default:
                break
            }
        }
    }

    private struct Launch {
        let generation: ProcessGeneration?
        var consumed = false
    }

    private enum LaunchFocusAdmission: Equatable {
        case awaitingRead
        case reading
        case unavailable
        case closed
    }

    typealias Factory = AppWindowObserver.Factory
    var onEvent: ((Event) -> Void)?
    var isLaunchFocusCurrent: (WindowLaunchFocus) -> Bool = { _ in false }
    private let makeSession: Factory
    private let readFocused: @Sendable (pid_t) -> FocusedWindowRead
    private let processGeneration: (pid_t) -> ProcessGeneration?
    private let queue = DispatchQueue(label: "io.github.sashokey.deskmote.focused-geometry", qos: .utility)
    let work = AsyncWorkScope()
    private var binding: FocusedGeometryBinding?
    private var activePID: pid_t?
    private var focusedWindow: AXElementKey?
    private var confirmedWindow: AXElementKey?
    private var pendingCreatedWindow: AXElementKey?
    private var firstFocus = FirstFocus.awaitingWindow
    private var applicationLaunches: [pid_t: Launch] = [:]
    private var launchFocusAdmission = LaunchFocusAdmission.awaitingRead
    private var pendingLaunchFocus: WindowLaunchFocus?
    private var focusEvidenceFloor: TimeInterval = 0
    private var initialFocusSubscriptionUnavailable = false
    private var starting = false
    private var refreshing = false
    private var focusRevision: UInt64 = 0
    private var needsRefresh = false
    private var needsRetry = false
    private var bindingInFlight = false
    private var bindingAwaitingFreshFocus = false
    private var needsBinding = false
    private var needsBindingRetry = false
    private var bindingCancellation: OperationCancellation?

    init(makeSession: @escaping Factory = { AXWindowObservationSession(pid: $0, receive: $1) },
         readFocused: @escaping @Sendable (pid_t) -> FocusedWindowRead = {
             FrontmostWindowGeometryObserver.readFocusedWindow(pid: $0)
         },
         processGeneration: @escaping (pid_t) -> ProcessGeneration? = {
             ProcessLiveness.startTime(pid: $0).map(ProcessGeneration.init)
         }) {
        self.makeSession = makeSession
        self.readFocused = readFocused
        self.processGeneration = processGeneration
    }

    func start(pid: pid_t?) {
        #if DEBUG
        focusedGeometryLog.notice("observer-start initialPID=\(pid ?? 0)")
        #endif
        activate(pid: pid)
    }

    func applicationLaunched(pid: pid_t) {
        #if DEBUG
        focusedGeometryLog.notice("workspace-launch pid=\(pid) observerPID=\(self.activePID ?? 0) previouslySeen=\(self.applicationLaunches[pid] != nil)")
        #endif
        guard pid != ProcessInfo.processInfo.processIdentifier, applicationLaunches[pid] == nil else { return }
        applicationLaunches[pid] = Launch(generation: processGeneration(pid))
        guard activePID == pid else { return }
        if let window = confirmedWindow, consumeApplicationLaunch(for: window) {
            onEvent?(.newFocusedWindow(window, evidence: .applicationLaunched))
        } else {
            admitPendingLaunchFocus()
        }
    }

    func acceptLaunchFocus(_ focus: WindowLaunchFocus) {
        guard activePID == focus.pid, launchFocusAdmission != .closed, case .awaitingWindow = firstFocus,
              focus.observedAt >= focusEvidenceFloor,
              applicationLaunches[focus.pid]?.consumed != true else { return }
        pendingLaunchFocus = focus
        admitPendingLaunchFocus()
    }

    private func admitPendingLaunchFocus() {
        guard launchFocusAdmission == .unavailable, initialFocusSubscriptionUnavailable, !refreshing,
              let focus = pendingLaunchFocus, case .awaitingWindow = firstFocus,
              let launch = applicationLaunches[focus.pid], !launch.consumed else { return }
        pendingLaunchFocus = nil
        launchFocusAdmission = .closed
        guard launch.generation == focus.processGeneration, processGeneration(focus.pid) == focus.processGeneration,
              isLaunchFocusCurrent(focus) else {
            #if DEBUG
            focusedGeometryLog.notice("launch-focus-discarded pid=\(focus.pid) window=\(focus.windowID) reason=focus-generation-foreground-or-permission")
            #endif
            return
        }
        firstFocus.observe(focus.element)
        publishConfirmedWindow(focus.element)
        guard consumeApplicationLaunch(for: focus.element) else { return }
        #if DEBUG
        focusedGeometryLog.notice("launch-focus-recovered pid=\(focus.pid) window=\(focus.windowID) element=\(focus.element.hashValue)")
        #endif
        onEvent?(.newFocusedWindow(focus.element, evidence: .launchFocusRecovered))
    }

    func applicationTerminated(pid: pid_t) {
        applicationLaunches.removeValue(forKey: pid)
        if activePID == pid { stopObservation() }
    }

    func activate(pid: pid_t?) {
        #if DEBUG
        focusedGeometryLog.notice("activation-request pid=\(pid ?? 0) priorPID=\(self.activePID ?? 0) starting=\(self.starting)")
        #endif
        if activePID == pid, binding != nil || starting {
            requestFocusedRefresh()
            return
        }
        stopObservation()
        guard let pid else { return }
        activePID = pid
        focusEvidenceFloor = ProcessInfo.processInfo.systemUptime
        starting = true
        work.restart()
        let generation = work.generation
        let deliver: @MainActor @Sendable (AXElementKey, String, TimeInterval?) -> Void = { [weak self] element, name, receivedAt in
            guard let self, self.work.isCurrent(generation) else { return }
            self.handleNotification(element, name: name, receivedAt: receivedAt)
        }
        let receive: @Sendable (AXElementKey, String) -> Void = { element, name in
            #if DEBUG
            let receivedAt: TimeInterval? = ProcessInfo.processInfo.systemUptime
            #else
            let receivedAt: TimeInterval? = nil
            #endif
            if Thread.isMainThread, name == kAXFocusedWindowChangedNotification || name == kAXUIElementDestroyedNotification {
                MainActor.assumeIsolated { deliver(element, name, receivedAt) }
            } else {
                Task { @MainActor in deliver(element, name, receivedAt) }
            }
        }
        let makeSession = makeSession
        let queue = queue
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let created = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                guard let session = makeSession(pid, receive), !cancellation.isCancelled else {
                    return nil as (FocusedGeometryBinding, FocusedGeometryBinding.ApplicationRegistration)?
                }
                let binding = FocusedGeometryBinding(session: session, pid: pid)
                return (binding, binding.registerApplication(cancellation: cancellation))
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.starting = false
                guard let (binding, registration) = created ?? nil else {
                    #if DEBUG
                    focusedGeometryLog.notice("observer-unavailable pid=\(pid) generation=\(generation)")
                    #endif
                    return
                }
                #if DEBUG
                focusedGeometryLog.notice("observer-attached pid=\(pid) generation=\(generation) applicationRegistered=\(registration.complete)")
                #endif
                self.binding = binding
                self.needsBindingRetry = !registration.complete
                self.initialFocusSubscriptionUnavailable = registration.focusMessagingFailed
                if !registration.focusMessagingFailed { self.closeLaunchFocusAdmission() }
                binding.session.attach()
                self.requestFocusedRefresh()
            }
        }
    }

    func stop() {
        stopObservation()
        applicationLaunches.removeAll()
        onEvent = nil
    }

    private func stopObservation() {
        bindingCancellation?.cancel()
        work.stop()
        binding?.session.detach()
        binding = nil
        bindingCancellation = nil
        activePID = nil
        focusedWindow = nil
        pendingCreatedWindow = nil
        firstFocus = .awaitingWindow
        launchFocusAdmission = .awaitingRead
        pendingLaunchFocus = nil
        initialFocusSubscriptionUnavailable = false
        publishConfirmedWindow(nil)
        starting = false
        refreshing = false
        needsRefresh = false
        needsRetry = false
        bindingInFlight = false
        bindingAwaitingFreshFocus = false
        needsBinding = false
        needsBindingRetry = false
    }

    private func requestFocusedRefresh() {
        guard let pid = activePID, binding != nil else { return }
        guard !refreshing else { needsRefresh = true; return }
        refreshing = true
        let firstRead = launchFocusAdmission == .awaitingRead
        if firstRead { launchFocusAdmission = .reading }
        let focusRevision = focusRevision
        let created = pendingCreatedWindow
        #if DEBUG
        focusedGeometryLog.notice("focus-read-start pid=\(pid) revision=\(focusRevision) creationPending=\(created != nil)")
        #endif
        let readFocused = readFocused
        let queue = queue
        work.launch { [weak self] generation in
            guard let result = await AsyncWorkScope.performBlocking(on: queue, operation: { readFocused(pid) }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.refreshing = false
                if self.focusRevision == focusRevision {
                    self.needsRetry = false
                    if self.pendingCreatedWindow == created { self.pendingCreatedWindow = nil }
                    switch result {
                    case let .window(element):
                        self.closeLaunchFocusAdmission()
                        self.firstFocus.observe(element)
                        self.updateFocusedWindow(element)
                        let launched = self.consumeApplicationLaunch(for: element)
                        #if DEBUG
                        focusedGeometryLog.notice("focus-resolved pid=\(pid) revision=\(focusRevision) window=\(element.hashValue) creationMatched=\(element == created) launchEvidence=\(launched)")
                        #endif
                        if element == created {
                            self.onEvent?(.newFocusedWindow(element, evidence: .windowCreated))
                        } else if launched {
                            self.onEvent?(.newFocusedWindow(element, evidence: .applicationLaunched))
                        }
                        self.onEvent?(.focusedWindowChanged)
                    case .none:
                        self.closeLaunchFocusAdmission()
                        #if DEBUG
                        focusedGeometryLog.notice("focus-resolved pid=\(pid) revision=\(focusRevision) outcome=no-window")
                        #endif
                        self.firstFocus.observe(nil)
                        self.updateFocusedWindow(nil)
                    case .unavailable, .temporarilyUnavailable:
                        #if DEBUG
                        focusedGeometryLog.notice("focus-resolved pid=\(pid) revision=\(focusRevision) outcome=unavailable")
                        #endif
                        self.needsRetry = true
                        if case .temporarilyUnavailable = result {
                            if firstRead { self.launchFocusAdmission = .unavailable }
                        } else {
                            self.closeLaunchFocusAdmission()
                        }
                    }
                } else {
                    if firstRead { self.closeLaunchFocusAdmission() }
                    #if DEBUG
                    focusedGeometryLog.notice("focus-discarded pid=\(pid) readRevision=\(focusRevision) currentRevision=\(self.focusRevision)")
                    #endif
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.requestFocusedRefresh()
                } else {
                    self.admitPendingLaunchFocus()
                }
            }
        }
    }

    private func consumeApplicationLaunch(for current: AXElementKey) -> Bool {
        guard let activePID, applicationLaunches[activePID]?.consumed == false else { return false }
        applicationLaunches[activePID]?.consumed = true
        guard case let .window(first) = firstFocus else { return false }
        return first == current
    }

    private func closeLaunchFocusAdmission() {
        launchFocusAdmission = .closed
        pendingLaunchFocus = nil
    }

    func retryUnavailableObservation() {
        if binding == nil, !starting, let activePID { activate(pid: activePID); return }
        if needsRetry, !refreshing { requestFocusedRefresh() }
        if needsBindingRetry, !bindingInFlight, !bindingAwaitingFreshFocus { beginBinding() }
    }

    private func publishConfirmedWindow(_ window: AXElementKey?) {
        guard confirmedWindow != window else { return }
        confirmedWindow = window
        onEvent?(.windowBindingChanged(window, ownerPID: activePID))
    }

    private func updateFocusedWindow(_ next: AXElementKey?) {
        publishConfirmedWindow(next)
        guard next != focusedWindow || bindingAwaitingFreshFocus else { return }
        bindingAwaitingFreshFocus = false
        focusedWindow = next
        bindingCancellation?.cancel()
        if bindingInFlight { needsBinding = true }
        else { beginBinding() }
    }

    private func beginBinding() {
        guard let binding else { return }
        bindingInFlight = true
        let next = focusedWindow
        let cancellation = OperationCancellation()
        bindingCancellation = cancellation
        let queue = queue
        work.launch { [weak self] generation in
            let registered = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                binding.replaceWindow(with: next, cancellation: cancellation)
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.bindingInFlight = false
                self.bindingCancellation = nil
                self.needsBindingRetry = registered != true
                if self.needsBinding {
                    self.needsBinding = false
                    self.beginBinding()
                }
            }
        }
    }

    private func handleNotification(_ element: AXElementKey, name: String, receivedAt: TimeInterval?) {
        if name == kAXFocusedWindowChangedNotification {
            focusRevision &+= 1
            focusEvidenceFloor = ProcessInfo.processInfo.systemUptime
            pendingLaunchFocus = nil
            #if DEBUG
            focusedGeometryLog.notice("ax-event pid=\(self.activePID ?? 0) revision=\(self.focusRevision) notification=AXFocusedWindowChanged")
            #endif
            publishConfirmedWindow(nil)
            if bindingInFlight || needsBindingRetry {
                bindingCancellation?.cancel()
                needsBinding = false
                bindingAwaitingFreshFocus = true
            }
            onEvent?(.focusedWindowChanged)
            requestFocusedRefresh()
        } else if name == kAXWindowCreatedNotification {
            #if DEBUG
            focusedGeometryLog.notice("ax-event pid=\(self.activePID ?? 0) revision=\(self.focusRevision) notification=AXWindowCreated window=\(element.hashValue) alreadyFocused=\(element == self.confirmedWindow)")
            #endif
            if element == confirmedWindow {
                onEvent?(.newFocusedWindow(element, evidence: .windowCreated))
            } else {
                pendingCreatedWindow = element
                requestFocusedRefresh()
            }
        } else if element == focusedWindow {
            if name == kAXWindowMovedNotification || name == kAXWindowResizedNotification {
                #if DEBUG
                focusedGeometryLog.debug("ax-event pid=\(self.activePID ?? 0) notification=\(name, privacy: .public) window=\(element.hashValue)")
                #endif
                onEvent?(.geometryChanged(element, notification: name, receivedAt: receivedAt))
            } else if name == kAXUIElementDestroyedNotification {
                focusRevision &+= 1
                closeLaunchFocusAdmission()
                firstFocus.observe(nil)
                if pendingCreatedWindow == element { pendingCreatedWindow = nil }
                onEvent?(.windowDestroyed)
                updateFocusedWindow(nil)
                requestFocusedRefresh()
            }
        }
    }

    nonisolated static func readFocusedWindow(
        pid: pid_t, accessibility: any AccessibilityOperations = NativeAccessibilityOperations()
    ) -> FocusedWindowRead {
        let app = accessibility.application(pid)
        _ = accessibility.setTimeout(app, 0.1)
        let (error, value) = accessibility.copy(app, kAXFocusedWindowAttribute as CFString)
        if error == .noValue { return .none }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            #if DEBUG
            let type = value.map { CFGetTypeID($0) } ?? 0
            focusedGeometryLog.notice("focus-attribute pid=\(pid) attribute=AXFocusedWindow axError=\(error.rawValue) valueType=\(type)")
            #endif
            return error == .cannotComplete ? .temporarilyUnavailable : .unavailable
        }
        let element = value as! AXUIElement
        let owner = accessibility.pid(element)
        guard owner == pid else {
            #if DEBUG
            focusedGeometryLog.notice("focus-attribute pid=\(pid) attribute=AXFocusedWindow outcome=owner-mismatch owner=\(owner ?? 0)")
            #endif
            return .unavailable
        }
        return .window(AXElementKey(e: element))
    }


    isolated deinit {
        bindingCancellation?.cancel()
        binding?.session.detach()
        work.stop()
    }
}
