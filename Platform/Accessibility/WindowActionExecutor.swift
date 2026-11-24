import AppKit
import ApplicationServices
import Foundation
#if DEBUG
import OSLog
#endif

struct WindowApplicationState: Sendable {
    let isActive: Bool
    let isHidden: Bool
    let isTerminated: Bool
    let activationPolicy: NSApplication.ActivationPolicy
    let bundleURL: URL?
    var origin: ApplicationOrigin? { ApplicationOrigin(bundleURL: bundleURL) }
}

protocol WindowSystemAccess: Sendable {
    func generation(_ pid: pid_t) -> ProcessGeneration?
    func app(_ pid: pid_t) -> WindowApplicationState?
    func activate(_ pid: pid_t) -> Bool
    func unhide(_ pid: pid_t)
    func terminate(_ pid: pid_t, generation: ProcessGeneration, origin: ApplicationOrigin?) -> Bool
    func windowInfo(_ options: CGWindowListOption, _ relative: CGWindowID) -> [[String: Any]]?
    func windowDescriptions(for ids: [CGWindowID]) -> [[String: Any]]?
}

struct NativeWindowSystem: WindowSystemAccess {
    func generation(_ pid: pid_t) -> ProcessGeneration? { ProcessLiveness.startTime(pid: pid).map(ProcessGeneration.init) }
    func app(_ pid: pid_t) -> WindowApplicationState? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return WindowApplicationState(isActive: app.isActive, isHidden: app.isHidden, isTerminated: app.isTerminated,
            activationPolicy: app.activationPolicy, bundleURL: app.bundleURL)
    }
    func activate(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false }
    func unhide(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.unhide() }
    func terminate(_ pid: pid_t, generation expected: ProcessGeneration, origin: ApplicationOrigin?) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              ApplicationOrigin(bundleURL: app.bundleURL) == origin, generation(pid) == expected else { return false }
        return app.terminate()
    }
    func windowInfo(_ options: CGWindowListOption, _ relative: CGWindowID) -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(options, relative) as? [[String: Any]]
    }
    func windowDescriptions(for ids: [CGWindowID]) -> [[String: Any]]? {
        guard !ids.isEmpty else { return [] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = values.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }) else { return nil }
        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    }
}

enum WindowCommandIdentity {
    static func permitsProcess(_ record: WindowRecord, currentGeneration: ProcessGeneration?) -> Bool {
        guard let expected = record.processGeneration else { return false }
        return expected == currentGeneration
    }

    static func permits(_ record: WindowRecord, currentGeneration: ProcessGeneration?, ownerPID: Int32?,
                        accessibilityOwnerPID: Int32? = nil, accessibilityWindowID: CGWindowID? = nil) -> Bool {
        guard permitsProcess(record, currentGeneration: currentGeneration) else { return false }
        guard let windowID = record.cgWindowID else { return true }
        if let ownerPID, ownerPID != record.pid { return false }
        if accessibilityOwnerPID != nil || accessibilityWindowID != nil {
            return accessibilityOwnerPID == record.pid && accessibilityWindowID == windowID
        }
        return ownerPID == record.pid
    }

    static func validateProcess(_ record: WindowRecord, system: any WindowSystemAccess = NativeWindowSystem()) -> Bool {
        permitsProcess(record, currentGeneration: system.generation(record.pid))
    }

    static func permitsElement(_ record: WindowRecord, element: AXUIElement?) -> Bool {
        guard let expected = record.actionTarget?.element else { return true }
        guard let element else { return false }
        return expected == AXElementKey(e: element)
    }

    static func validate(_ record: WindowRecord, element: AXUIElement? = nil,
                         reader: AXWindowReader = AXWindowReader(), system: any WindowSystemAccess = NativeWindowSystem(),
                         requiresCGOwner: Bool = false) -> Bool {
        let generation = system.generation(record.pid)
        guard permitsProcess(record, currentGeneration: generation),
              permitsElement(record, element: element) else { return false }
        var accessibilityPID: pid_t?
        if let element {
            accessibilityPID = reader.accessibility.pid(element)
            guard accessibilityPID == record.pid else { return false }
        }
        let owner = record.cgWindowID.flatMap { ownerPID(for: $0, in: system.windowDescriptions(for: [$0])) }
        guard !requiresCGOwner || owner == record.pid else { return false }
        let accessibilityWindowID = record.cgWindowID == nil ? nil : element.flatMap {
            reader.cgWindowID(for: $0, maxAttempts: 1, messagingTimeout: 0.05)
        }
        return permits(record, currentGeneration: generation, ownerPID: owner,
                       accessibilityOwnerPID: accessibilityPID, accessibilityWindowID: accessibilityWindowID)
    }

    fileprivate static func ownerPID(for windowID: CGWindowID, in descriptions: [[String: Any]]?) -> pid_t? {
        guard let value = descriptions?.first(where: { nativeWindowNumber(in: $0) == windowID }),
              let number = value[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        return pid_t(exactly: number.int64Value)
    }
}

struct AccessibilityWindowActionExecutor: Sendable {
    private let reader: AXWindowReader
    private let system: any WindowSystemAccess
    private let chipProbeEnabled: Bool
    private let focusBackend: any WindowFocusRequesting
    private let cancellation: OperationCancellation
    private let budget: OperationReadBudget?
    private let authorization: @Sendable (pid_t, CGWindowID?, AXUIElement?) -> Bool
    #if DEBUG
    private static let chipProbeLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "ChipProbe")
    #endif

    init(reader: AXWindowReader = AXWindowReader(), chipProbeEnabled: Bool = false,
         focusBackend: any WindowFocusRequesting = SkyLightWindowFocus(),
         system: any WindowSystemAccess = NativeWindowSystem(),
         cancellation: OperationCancellation = OperationCancellation(),
         budget: OperationReadBudget? = nil,
         authorization: @escaping @Sendable (pid_t, CGWindowID?, AXUIElement?) -> Bool = { _, _, _ in true }) {
        self.reader = budget.map { reader.withOperationBudget($0) } ?? reader
        self.system = system
        self.chipProbeEnabled = chipProbeEnabled
        self.focusBackend = focusBackend
        self.cancellation = cancellation
        self.budget = budget
        self.authorization = authorization
    }

    func withCancellation(_ cancellation: OperationCancellation, budget: OperationReadBudget? = nil,
                          authorization: @escaping @Sendable (pid_t, CGWindowID?, AXUIElement?) -> Bool) -> Self {
        Self(reader: reader, chipProbeEnabled: chipProbeEnabled, focusBackend: focusBackend, system: system,
             cancellation: cancellation, budget: budget, authorization: authorization)
    }

    private func withBudget(_ budget: OperationReadBudget) -> Self {
        Self(reader: reader, chipProbeEnabled: chipProbeEnabled, focusBackend: focusBackend, system: system,
             cancellation: cancellation, budget: budget, authorization: authorization)
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        let remaining = budget?.remaining ?? 0.1
        guard !cancellation.isCancelled, remaining > 0,
              reader.accessibility.setTimeout(element, Float(min(0.1, remaining))) == .success else { return false }
        return !cancellation.isCancelled && budget?.canContinue != false
    }

    private func canAct(pid: pid_t, windowID: CGWindowID? = nil, element: AXUIElement? = nil) -> Bool {
        !cancellation.isCancelled && budget?.canContinue != false
            && authorization(pid, windowID, element)
            && !cancellation.isCancelled && budget?.canContinue != false
    }

    fileprivate func canAct(on handle: WindowHandle) -> Bool {
        canAct(pid: handle.pid, windowID: handle.cgWindowID ?? reader.cgWindowID(for: handle.element),
               element: handle.element)
    }

    @discardableResult
    func activateApplication(pid: pid_t, windowID: CGWindowID? = nil, element: AXUIElement? = nil) -> Bool {
        guard canAct(pid: pid, windowID: windowID, element: element) else { return false }
        return system.activate(pid)
    }

    struct ActionExecution {
        let success: Bool
        let mechanism: String
        let verifiedMinimized: Bool?
    }

    struct WindowTarget {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        var cgWindowID: CGWindowID? = nil
        var expectedElement: AXElementKey? = nil
    }

    struct WindowHandle {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        fileprivate let element: AXUIElement
        var cgWindowID: CGWindowID? = nil

        var elementKey: AXElementKey { AXElementKey(e: element) }

        static func captured(from window: AXWindowSnapshot) -> Self {
            Self(pid: window.pid, title: window.title, bounds: window.bounds,
                 element: window.element, cgWindowID: window.cgWindowID)
        }
    }

    func captureHandleFromCache(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?,
        expectedElement: AXElementKey? = nil
    ) -> WindowHandle? {
        guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
        guard let element = AXElementCache.shared.element(pid: pid, cgWindowID: cgWindowID) else {
            return nil
        }
        if let expectedElement, AXElementKey(e: element) != expectedElement { return nil }
        let matches = reader.matchesCGWindowID(cgWindowID, element: element, messagingTimeout: 0.05)
        guard !cancellation.isCancelled else { return nil }
        switch matches {
        case .some(true):
            return WindowHandle(pid: pid, title: title, bounds: bounds, element: element, cgWindowID: cgWindowID)
        case .some(false):
            AXElementCache.shared.remove(pid: pid, cgWindowID: cgWindowID, matching: element)
            return nil
        case .none:
            return nil
        }
    }

    func captureHandleByCGWindowID(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?,
        expectedElement: AXElementKey? = nil
    ) -> WindowHandle? {
        guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
        let captureBudget = budget?.limited(to: 0.1)
            ?? OperationReadBudget(maximumDuration: 0.1, cancellation: cancellation)
        guard let handle = reader.withOperationBudget(captureBudget).captureHandle(
            forPID: pid,
            cgWindowID: cgWindowID,
            messagingTimeout: 0.1,
            expectedElement: expectedElement
        ) else { return nil }
        return Self.fastHandle(
            from: handle,
            target: WindowTarget(pid: pid, title: title, bounds: bounds, cgWindowID: cgWindowID)
        )
    }

    static func fastHandle(from handle: AXWindowHandle, target: WindowTarget) -> WindowHandle {
        return WindowHandle(
            pid: target.pid,
            title: target.title,
            bounds: target.bounds,
            element: handle.element,
            cgWindowID: target.cgWindowID
        )
    }

    func activateAppWithWindowRecovery(pid: Int32) -> Bool {
        let liveWindows: [AXWindowSnapshot]
        switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.3) {
        case .success(let windows): liveWindows = windows
        case .unread: liveWindows = []
        }
        let visibleWindows = liveWindows.filter { !$0.isMinimized }

        if let window = visibleWindows.first, canAct(pid: pid, windowID: window.cgWindowID, element: window.element) {
            _ = reader.accessibility.perform(visibleWindows[0].element, kAXRaiseAction as CFString)
            return activateApplication(pid: pid)
        }

        return false
    }

    func captureHandle(
        for target: WindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            for: AXWindowTarget(pid: target.pid, title: target.title, bounds: target.bounds,
                                cgWindowID: target.cgWindowID, expectedElement: target.expectedElement),
            attempts: attempts,
            retryIntervalMicroseconds: retryIntervalMicroseconds,
            messagingTimeout: 0.5,
            cancellation: cancellation
        ) else {
            return nil
        }
        return WindowHandle(
            pid: target.pid,
            title: handle.title,
            bounds: handle.bounds,
            element: handle.element,
            cgWindowID: target.cgWindowID
        )
    }

    private func minimizeButton(for handle: WindowHandle) -> AXUIElement? {
        for _ in 0..<2 {
            guard canAct(on: handle), prepare(handle.element) else { return nil }
            let (result, value) = reader.accessibility.copy(handle.element, kAXMinimizeButtonAttribute as CFString)
            guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
            if result == .success {
                return AXWindowReader.validatedElement(value)
            }
            guard result == .cannotComplete else { return nil }
            let wait = min(0.02, budget?.remaining ?? 0.02)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        return nil
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        guard budget != nil else {
            return withBudget(OperationReadBudget(maximumDuration: 3, cancellation: cancellation)).minimize(handle)
        }
        guard canAct(on: handle) else {
            return ActionExecution(success: false, mechanism: "stale-target", verifiedMinimized: nil)
        }
        #if DEBUG
        if chipProbeEnabled {
            let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let subrole = reader.stringAttribute(kAXSubroleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let hasMinimizeButton = minimizeButton(for: handle) != nil
            let currentMinimized = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element, maxAttempts: 1)
            let (_, minimizedSettable) = reader.accessibility.isSettable(handle.element, kAXMinimizedAttribute as CFString)
            let probeApp = NSRunningApplication(processIdentifier: handle.pid)
            let probePolicyStr: String
            switch probeApp?.activationPolicy {
            case .regular: probePolicyStr = "regular"
            case .accessory: probePolicyStr = "accessory"
            case .prohibited: probePolicyStr = "prohibited"
            default: probePolicyStr = "nil"
            }
            Self.chipProbeLogger.info("minimize-ax-probe app=\(probeApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(probeApp?.bundleIdentifier ?? "(none)", privacy: .public) activationPolicy=\(probePolicyStr, privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) hasMinimizeButton=\(hasMinimizeButton, privacy: .public) currentMinimized=\(String(describing: currentMinimized), privacy: .public) minimizedSettable=\(minimizedSettable, privacy: .public)")
        }
        #endif

        if setMinimized(true, for: handle) {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if verified == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: verified
                )
            }
        }

        guard let button = minimizeButton(for: handle) else {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == true,
                mechanism: "missing-minimize-button",
                verifiedMinimized: verified
            )
        }

        guard canAct(on: handle), prepare(button), canAct(on: handle),
              reader.accessibility.perform(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
        return ActionExecution(
            success: verified == true,
            mechanism: "press-minimize-button",
            verifiedMinimized: verified
        )
    }

    func activate(
        _ handle: WindowHandle,
        confirmationTimeout: TimeInterval = 0.6,
        pollIntervalMicroseconds: useconds_t = 10_000,
        knownCGWindowID: CGWindowID? = nil,
        knownMinimized: Bool = false,
        preActivateForRestore: Bool = false,
        awaitOnScreenBeforeFocus: Bool = false,
        owningApplication: ApplicationIdentity? = nil,
        rebindAfterRestore: Bool = false
    ) -> Bool {
        var handle = handle
        guard canAct(on: handle) else { return false }
        let wasMinimized = knownMinimized || reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element) == true
        var canRebind = false
        var restoredNumber = knownCGWindowID
        var rebindDeadline: TimeInterval = 0

        func revalidateHandle() -> Bool {
            if canAct(on: handle) { return true }
            guard canRebind, !cancellation.isCancelled else { return false }
            let readBudget = OperationReadBudget(maximumDuration: 0.05, cancellation: cancellation)
            guard let number = reader.withOperationBudget(readBudget).cgWindowID(
                for: handle.element, maxAttempts: 1, messagingTimeout: 0.05
            ), number != handle.cgWindowID, readBudget.canContinue else { return false }
            var rebound = handle
            rebound.cgWindowID = number
            guard canAct(on: rebound) else { return false }
            handle = rebound
            restoredNumber = number
            postSkyLightWindowFocus(pid: handle.pid, windowID: number, element: handle.element)
            return true
        }

        func waitsForCurrentHandle() -> Bool {
            while !revalidateHandle() {
                guard canRebind, !cancellation.isCancelled,
                      ProcessInfo.processInfo.systemUptime < rebindDeadline else { return false }
                usleep(2_000)
            }
            return true
        }

        if wasMinimized {
            if preActivateForRestore, let wid = knownCGWindowID {
                postSkyLightFrontSwitchOnly(pid: handle.pid, windowID: wid, element: handle.element)
            }
            let restored = setMinimized(false, for: handle)
            if rebindAfterRestore, !cancellation.isCancelled {
                let readBudget = OperationReadBudget(maximumDuration: 0.05, cancellation: cancellation)
                canRebind = restored || reader.withOperationBudget(readBudget)
                    .boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element, maxAttempts: 1) == false
                rebindDeadline = ProcessInfo.processInfo.systemUptime + min(0.9, max(0, confirmationTimeout))
            }
            if (awaitOnScreenBeforeFocus && !preActivateForRestore) || (canRebind && !revalidateHandle()) {
                waitForWindowOnScreen { revalidateHandle() ? restoredNumber : nil }
            }
            if revalidateHandle(), let wid = restoredNumber {
                postSkyLightWindowFocus(pid: handle.pid, windowID: wid, element: handle.element)
            }
            if revalidateHandle() { _ = reader.accessibility.set(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue) }
        }

        return WindowActivationAttempt.run(
            requestPrivateFocus: { requestWindowFocusViaSkyLight(handle) },
            raise: { if canAct(on: handle) { _ = reader.accessibility.perform(handle.element, kAXRaiseAction as CFString) } },
            activateApplication: {
                _ = activateApplication(pid: handle.pid, windowID: handle.cgWindowID, element: handle.element)
            },
            confirm: { timeout in
                confirmFocused(pid: handle.pid, windowID: handle.cgWindowID, element: handle.element,
                               timeout: timeout, pollIntervalMicroseconds: pollIntervalMicroseconds,
                               requiresRestored: wasMinimized, owningApplication: owningApplication,
                               restoredWindowNumber: canRebind ? { revalidateHandle() ? handle.cgWindowID : nil } : nil)
            },
            timeout: confirmationTimeout,
            isCancelled: { !waitsForCurrentHandle() }
        )
    }

    @discardableResult
    private func waitForWindowOnScreen(windowNumber: () -> CGWindowID?, cap: TimeInterval = 0.9) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + cap
        repeat {
            guard !cancellation.isCancelled else { return false }
            if let windowID = windowNumber(), let list = system.windowDescriptions(for: [windowID]),
               let info = list.first,
               (info[kCGWindowIsOnscreen as String] as? Bool) == true,
               (info[kCGWindowLayer as String] as? Int) == 0 {
                return true
            }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func close(_ handle: WindowHandle) -> Bool {
        let localBudget = budget?.limited(to: 0.6)
            ?? OperationReadBudget(maximumDuration: 0.6, cancellation: cancellation)
        return withBudget(localBudget).closeWithinBudget(handle)
    }

    private func closeWithinBudget(_ handle: WindowHandle) -> Bool {
        guard let budget else { return false }
        var attempts = 0
        repeat {
            guard canAct(on: handle), prepare(handle.element) else { return false }
            attempts += 1
            var raw: CFTypeRef?
            let readError: AXError
            (readError, raw) = reader.accessibility.copy(handle.element, kAXCloseButtonAttribute as CFString)
            if readError == .success, let button = AXWindowReader.validatedElement(raw) {
                guard canAct(on: handle), prepare(button), canAct(on: handle) else { return false }
                let pressError = reader.accessibility.perform(button, kAXPressAction as CFString)
                #if DEBUG
                Self.chipProbeLogger.info("close-press pid=\(handle.pid, privacy: .public) error=\(pressError.rawValue, privacy: .public) attempt=\(attempts, privacy: .public)")
                #endif
                if pressError == .success { return true }
                if pressError != .cannotComplete { return false }
            } else if readError != .cannotComplete {
                #if DEBUG
                Self.chipProbeLogger.info("close-button-read failed pid=\(handle.pid, privacy: .public) error=\(readError.rawValue, privacy: .public)")
                #endif
                return false
            }
            let wait = min(0.05, budget.remaining)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        } while budget.canContinue
        #if DEBUG
        Self.chipProbeLogger.info("close gave up pid=\(handle.pid, privacy: .public) attempts=\(attempts, privacy: .public)")
        #endif
        return false
    }

    private func isCurrentActiveOwner(_ owner: ApplicationIdentity?) -> Bool {
        guard let owner, system.generation(owner.pid) == owner.generation,
              let application = system.app(owner.pid), !application.isTerminated, !application.isHidden,
              application.origin == owner.origin else { return false }
        return application.isActive
    }

    private func confirmFocused(
        pid: pid_t, windowID: CGWindowID?, element: AXUIElement? = nil,
        timeout: TimeInterval, pollIntervalMicroseconds: useconds_t = 10_000, requiresRestored: Bool = false,
        owningApplication: ApplicationIdentity? = nil,
        restoredWindowNumber: (() -> CGWindowID?)? = nil
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            guard !cancellation.isCancelled else { return false }
            let windowID = restoredWindowNumber.map { $0() } ?? windowID
            let remaining = max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
            let focused: AXUIElement?
            if restoredWindowNumber != nil, windowID == nil {
                focused = nil
            } else if system.app(pid)?.isActive == true {
                focused = reader.focusedWindow(forPID: pid, messagingTimeout: min(remaining, 0.025))
            } else if isCurrentActiveOwner(owningApplication), let windowID {
                let observation = reader.systemFocusedWindowRead(
                    messagingTimeout: min(remaining, 0.025), cancellation: cancellation)
                if case let .window(focusedPID, focusedID) = observation.result,
                   focusedPID == pid, focusedID == windowID {
                    focused = observation.windowElement?.e
                } else { focused = nil }
            } else { focused = nil }
            if let focused, reader.accessibility.pid(focused) == pid {
                let matches: Bool
                if let element, CFEqual(focused, element) { matches = true }
                else if let windowID {
                    matches = reader.matchesCGWindowID(windowID, element: focused,
                        messagingTimeout: min(max(0.001, deadline - ProcessInfo.processInfo.systemUptime), 0.025)) == true
                } else { matches = false }
                if matches {
                    var restored = !requiresRestored
                    if requiresRestored {
                        _ = reader.accessibility.setTimeout(focused, Float(min(remaining, 0.025)))
                        restored = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: focused, maxAttempts: 1) == false
                    }
                    if restored, canAct(pid: pid, windowID: windowID, element: focused),
                       system.app(pid)?.isActive == true || isCurrentActiveOwner(owningApplication) { return true }
                }
            }
            let wait = min(Double(pollIntervalMicroseconds) / 1_000_000,
                           deadline - ProcessInfo.processInfo.systemUptime)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func findBackgroundActivationTarget(
        for handle: WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        focusedReadBudget: TimeInterval = 0
    ) -> MinimizeHandoffTarget.Verdict {
        guard canAct(on: handle), system.app(handle.pid)?.isActive == true else { return .none }

        let appElement = reader.accessibility.application(handle.pid)
        _ = reader.accessibility.setTimeout(appElement, 0.2)
        let deadline = Date().addingTimeInterval(focusedReadBudget)
        var focused: AXUIElement?
        var readError = AXError.success
        repeat {
            guard !cancellation.isCancelled else { return .none }
            var raw: CFTypeRef?
            (readError, raw) = reader.accessibility.copy(appElement, kAXFocusedWindowAttribute as CFString)
            if readError == .success {
                focused = AXWindowReader.validatedElement(raw)
            }
            guard readError == .cannotComplete, Date() < deadline else { break }
            usleep(20_000)
        } while true
        guard let focused, CFEqual(focused, handle.element) else {
            #if DEBUG
            Self.chipProbeLogger.info("postactivate-target focused-gate failed pid=\(handle.pid, privacy: .public) readError=\(readError.rawValue, privacy: .public)")
            #endif
            return .none
        }

        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = system.windowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return .none }

        var zOrder: [MinimizeHandoffTarget.ZOrderedWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID else { continue }
            guard let wid = nativeWindowNumber(in: info) else { continue }
            zOrder.append(.init(pid: ownerPID, cgWindowID: CGWindowID(wid)))
        }

        let verdict = MinimizeHandoffTarget.select(zOrder: zOrder, target: record, snapshot: snapshot)
        #if DEBUG
        switch verdict {
        case .switchTo(let pid, let wid, let windowID):
            Self.chipProbeLogger.info(
                "postactivate-target candidate=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "(unknown)", privacy: .public) pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)"
            )
        case .siblingTakesOver(let windowID):
            Self.chipProbeLogger.info("postactivate-target sibling-takes-over pid=\(handle.pid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)")
        case .none:
            Self.chipProbeLogger.info("postactivate-target no-eligible-candidate pid=\(handle.pid, privacy: .public)")
        }
        #endif
        return verdict
    }

    func switchFrontmostForHandoff(to candidate: WindowRecord, windowID: CGWindowID, element: AXUIElement?,
                                   from source: WindowHandle, original: WindowRecord,
                                   deactivationCap: TimeInterval = 0.1) -> Bool {
        let pid = candidate.pid
        func authorizeHandoff() -> Bool {
            canSwitchForHandoff(to: candidate, windowID: windowID, element: element, from: source, original: original)
        }
        #if DEBUG
        let route: String
        #endif
        if Self.skyLightFocusEnabled, authorizeHandoff(),
           focusBackend.setFrontmost(pid: pid, windowID: windowID, mode: Self.kCPSNoWindows) {
            #if DEBUG
            route = "skylight"
            #endif
        } else if activateApplicationViaAccessibility(pid: pid, authorized: authorizeHandoff) {
            #if DEBUG
            route = "ax-frontmost"
            #endif
        } else {
            #if DEBUG
            Self.chipProbeLogger.info("switch-frontmost-handoff unavailable pid=\(pid, privacy: .public)")
            #endif
            return false
        }
        let targetApp = reader.accessibility.application(source.pid)
        _ = reader.accessibility.setTimeout(targetApp, 0.05)
        let deadline = Date().addingTimeInterval(deactivationCap)
        var stillFrontmost: Bool? = true
        #if DEBUG
        var lastAXError: Int32 = 0
        let waitStart = Date()
        #endif
        repeat {
            guard !cancellation.isCancelled else { return false }
            var raw: CFTypeRef?
            let axError: AXError
            (axError, raw) = reader.accessibility.copy(targetApp, kAXFrontmostAttribute as CFString)
            if axError == .success {
                stillFrontmost = (raw as? NSNumber)?.boolValue
            } else {
                stillFrontmost = nil
                #if DEBUG
                lastAXError = axError.rawValue
                #endif
            }
            if stillFrontmost == false { break }
            usleep(2_000)
        } while Date() < deadline
        #if DEBUG
        Self.chipProbeLogger.info("switch-frontmost-handoff pid=\(pid, privacy: .public) route=\(route, privacy: .public) targetStillFrontmost=\(String(describing: stillFrontmost), privacy: .public) axError=\(lastAXError, privacy: .public) waitMs=\(Int(Date().timeIntervalSince(waitStart) * 1000), privacy: .public)")
        #endif
        return stillFrontmost == false && system.app(pid)?.isActive == true
    }

    private func canSwitchForHandoff(to candidate: WindowRecord, windowID: CGWindowID, element: AXUIElement?,
                                     from source: WindowHandle, original: WindowRecord) -> Bool {
        guard canAct(pid: candidate.pid, windowID: windowID, element: element), canAct(on: source) else { return false }
        let originalAXID = original.cgWindowID
        if let originalAXID {
            guard reader.matchesCGWindowID(originalAXID, element: source.element, messagingTimeout: 0.05) == true else { return false }
        }
        if let element {
            guard reader.accessibility.pid(element) == candidate.pid,
                  reader.matchesCGWindowID(windowID, element: element, messagingTimeout: 0.05) == true else { return false }
        }
        guard !cancellation.isCancelled, budget?.canContinue != false else { return false }
        let descriptions = system.windowDescriptions(for: [candidate.cgWindowID, originalAXID].compactMap { $0 })
        guard reader.accessibility.pid(source.element) == original.pid else { return false }
        let candidateOwner = WindowCommandIdentity.ownerPID(for: windowID, in: descriptions)
        let originalOwner = originalAXID.flatMap { WindowCommandIdentity.ownerPID(for: $0, in: descriptions) }
        return WindowCommandIdentity.permits(candidate, currentGeneration: system.generation(candidate.pid), ownerPID: candidateOwner,
                    accessibilityOwnerPID: element.flatMap { reader.accessibility.pid($0) }, accessibilityWindowID: element == nil ? nil : windowID)
            && WindowCommandIdentity.permits(original, currentGeneration: system.generation(original.pid), ownerPID: originalOwner,
                    accessibilityOwnerPID: original.pid, accessibilityWindowID: originalAXID)
            && !cancellation.isCancelled && budget?.canContinue != false
    }

    private func activateApplicationViaAccessibility(pid: pid_t, authorized: () -> Bool) -> Bool {
        let app = reader.accessibility.application(pid)
        _ = reader.accessibility.setTimeout(app, 0.2)
        guard authorized() else { return false }
        return reader.accessibility.set(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static let skyLightFocusEnabled =
        DebugSwitch.skylightFocus.isEnabled(in: ProcessInfo.processInfo.environment)

    fileprivate static let kCPSUserGenerated: UInt32 = 0x200
    fileprivate static let kCPSNoWindows: UInt32 = 0x400

    @discardableResult
    fileprivate func postSkyLightFrontSwitchOnly(
        pid: pid_t, windowID: CGWindowID,
        mode: UInt32 = AccessibilityWindowActionExecutor.kCPSUserGenerated,
        element: AXUIElement?
    ) -> Bool {
        guard Self.skyLightFocusEnabled, canAct(pid: pid, windowID: windowID, element: element) else { return false }
        return focusBackend.setFrontmost(pid: pid, windowID: windowID, mode: mode)
    }

    @discardableResult
    fileprivate func postSkyLightWindowFocus(pid: pid_t, windowID: CGWindowID, element: AXUIElement) -> Bool {
        guard postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, element: element) else { return false }
        return postSkyLightMakeKeyDown(pid: pid, windowID: windowID, element: element)
    }

    @discardableResult
    fileprivate func postSkyLightMakeKeyDown(pid: pid_t, windowID: CGWindowID, element: AXUIElement?) -> Bool {
        guard Self.skyLightFocusEnabled, canAct(pid: pid, windowID: windowID, element: element) else { return false }
        return focusBackend.makeKey(pid: pid, windowID: windowID)
    }

    func makeKeyAfterHandoff(pid: pid_t, windowID: CGWindowID, element: AXUIElement?) -> Bool {
        guard postSkyLightMakeKeyDown(pid: pid, windowID: windowID, element: element) else { return false }
        return confirmFocused(pid: pid, windowID: windowID, element: element, timeout: 0.1)
    }

    @discardableResult
    func requestWindowFocusViaSkyLight(_ handle: WindowHandle) -> Bool {
        guard let windowID = handle.cgWindowID ?? reader.cgWindowID(for: handle.element) else { return false }
        return postSkyLightWindowFocus(pid: handle.pid, windowID: windowID, element: handle.element)
    }

    private func setMinimized(_ minimized: Bool, for handle: WindowHandle) -> Bool {
        guard canAct(on: handle) else { return false }
        if budget != nil, !prepare(handle.element) { return false }
        guard canAct(on: handle) else { return false }
        return reader.setMinimized(
            minimized,
            for: AXWindowHandle(pid: handle.pid, title: handle.title, bounds: handle.bounds, element: handle.element)
        )
    }

}

struct ActionExecutionSwitches: Equatable {
    let fastWindowHandleEnabled: Bool
    let axElementCacheEnabled: Bool
    let chipProbeEnabled: Bool
    #if DEBUG
    let clickTraceEnabled: Bool
    #endif

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fastWindowHandleEnabled = DebugSwitch.fastWindowHandle.isEnabled(in: environment)
        axElementCacheEnabled = DebugSwitch.axElementCache.isEnabled(in: environment)
        #if DEBUG
        chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: environment)
        clickTraceEnabled = DebugSwitch.clickTrace.isEnabled(in: environment)
        #else
        chipProbeEnabled = false
        #endif
    }
}

enum WindowHandleCapturePlan {
    static func capture<Handle>(
        cachedEnabled: Bool,
        fastEnabled: Bool,
        cgWindowID: CGWindowID?,
        justUnhid: Bool,
        cached: (CGWindowID) -> Handle?,
        fast: (CGWindowID) -> Handle?,
        fallback: (CGWindowID?) -> Handle?
    ) -> Handle? {
        if let cgWindowID, !justUnhid {
            if cachedEnabled, let handle = cached(cgWindowID) { return handle }
            if fastEnabled, let handle = fast(cgWindowID) { return handle }
        }
        return fallback(cgWindowID)
    }

    static func usesAppFallbackAfterCaptureFailure(
        requestKind: PlatformActionRequest.ActionKind,
        isFinderWindow: Bool,
        knownMinimized: Bool,
        expectedCGWindowID: CGWindowID? = nil
    ) -> Bool {
        expectedCGWindowID == nil && requestKind == .activateWindow && !isFinderWindow && !knownMinimized
    }
}

enum MinimizedRestorePreActivation {
    static func canPreActivate(snapshot: DockSnapshot, target: WindowRecord) -> Bool {
        !snapshot.windows.values.contains {
            $0.pid == target.pid && $0.id != target.id && $0.status != .minimized
        }
    }
}

struct PlatformActionExecutor: WindowActionExecuting {
    private let windowExecutor: AccessibilityWindowActionExecutor
    private let switches: ActionExecutionSwitches
    #if DEBUG
    private static let chipProbeLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "ChipProbe")
    #endif
    private static let postMinimizeActivateDelayMicroseconds: useconds_t = 50_000

    private let reader: AXWindowReader
    private let system: any WindowSystemAccess

    init(switches: ActionExecutionSwitches = ActionExecutionSwitches(), reader: AXWindowReader = AXWindowReader(),
         system: any WindowSystemAccess = NativeWindowSystem(), focusBackend: any WindowFocusRequesting = SkyLightWindowFocus()) {
        self.switches = switches
        self.reader = reader
        self.system = system
        windowExecutor = AccessibilityWindowActionExecutor(reader: reader, chipProbeEnabled: switches.chipProbeEnabled,
            focusBackend: focusBackend, system: system)
    }

    @discardableResult
    func execute(
        _ request: PlatformActionRequest,
        snapshot: DockSnapshot,
        forcedMinimizedPrior: Bool,
        cancellation: OperationCancellation,
        onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?
    ) -> Bool {
        let commandBudget: OperationReadBudget? = request.kind == .activateWindow ? nil
            : OperationReadBudget(maximumDuration: 3, cancellation: cancellation)
        guard !cancellation.isCancelled, let windowID = request.windowID,
              let record = snapshot.windows[windowID], WindowCommandIdentity.validateProcess(record, system: system) else {
            return false
        }
        let windowExecutor = windowExecutor.withCancellation(cancellation, budget: commandBudget) { pid, windowID, element in
            let authorizationRecord: WindowRecord
            if pid == record.pid {
                var selected = record
                if let windowID {
                    if let expected = record.cgWindowID {
                        if expected != windowID {
                            guard request.kind == .activateWindow, let element,
                                  record.actionTarget?.element == AXElementKey(e: element),
                                  !snapshot.windows.values.contains(where: { $0.id != record.id && $0.cgWindowID == windowID })
                            else { return false }
                            selected.cgWindowID = windowID
                        }
                    } else if snapshot.windows.values.contains(where: {
                        $0.id != record.id && $0.pid == pid && $0.cgWindowID == windowID
                    }) {
                        return false
                    }
                }
                authorizationRecord = selected
            } else {
                guard let windowID, let candidate = snapshot.windows.values.first(where: {
                    $0.pid == pid && $0.cgWindowID == windowID
                }) else { return false }
                authorizationRecord = candidate
            }
            if windowID == nil, element == nil {
                return WindowCommandIdentity.validateProcess(authorizationRecord, system: system)
            }
            let identityBudget = commandBudget?.limited(to: 0.05)
                ?? OperationReadBudget(maximumDuration: 0.05, cancellation: cancellation)
            return WindowCommandIdentity.validate(authorizationRecord, element: element,
                reader: reader.withOperationBudget(identityBudget), system: system,
                requiresCGOwner: pid == record.pid && authorizationRecord.cgWindowID != record.cgWindowID)
        }
        let effectiveKnownMinimized = forcedMinimizedPrior || record.status == .minimized

        let isFinderWindow = FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier)

        let hiddenFinder = isFinderWindow && system.app(record.pid)?.isHidden == true

        let target = AccessibilityWindowActionExecutor.WindowTarget(
            pid: record.pid, title: record.title, bounds: record.bounds, cgWindowID: record.cgWindowID,
            expectedElement: record.actionTarget?.element)
        var captureTier = "none"
        let handle = WindowHandleCapturePlan.capture(
            cachedEnabled: switches.axElementCacheEnabled,
            fastEnabled: switches.fastWindowHandleEnabled,
            cgWindowID: record.cgWindowID,
            justUnhid: hiddenFinder,
            cached: {
                let h = windowExecutor.captureHandleFromCache(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds,
                    expectedElement: target.expectedElement
                )
                if h != nil { captureTier = "cached" }
                return h
            },
            fast: {
                let h = windowExecutor.captureHandleByCGWindowID(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds,
                    expectedElement: target.expectedElement
                )
                if h != nil { captureTier = "fast" }
                return h
            },
            fallback: { expectedCGWindowID in
                let h = windowExecutor.captureHandle(
                    for: AccessibilityWindowActionExecutor.WindowTarget(pid: target.pid, title: target.title,
                                                                         bounds: target.bounds, cgWindowID: expectedCGWindowID,
                                                                         expectedElement: target.expectedElement),
                    attempts: isFinderWindow ? 3 : 1,
                    retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
                )
                if h != nil { captureTier = "fallback" }
                return h
            }
        )
        #if DEBUG
        if switches.clickTraceEnabled { ClickLatencyTrace.markCurrent("handle", detail: captureTier) }
        #endif

        guard !cancellation.isCancelled else { return false }
        guard let handle else {
            guard !hiddenFinder, target.expectedElement == nil, WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                requestKind: request.kind,
                isFinderWindow: isFinderWindow,

                knownMinimized: effectiveKnownMinimized,
                expectedCGWindowID: record.cgWindowID
            ) else {
                return false
            }
            return executeAppFallback(request: request, record: record, executor: windowExecutor)
        }
        guard WindowCommandIdentity.permitsElement(record, element: handle.element) else { return false }
        if hiddenFinder {
            let identityBudget = commandBudget?.limited(to: 0.05)
                ?? OperationReadBudget(maximumDuration: 0.05, cancellation: cancellation)
            guard WindowCommandIdentity.validate(record, element: handle.element,
                reader: reader.withOperationBudget(identityBudget), system: system),
                !cancellation.isCancelled else { return false }
            system.unhide(record.pid)
            let deadline = ContinuousClock.now + .milliseconds(200)
            while !cancellation.isCancelled, system.app(record.pid)?.isHidden == true, ContinuousClock.now < deadline {
                usleep(20_000)
            }
        }

        switch request.kind {
        case .activateWindow:
            if !forcedMinimizedPrior, record.cgWindowID != nil,
               record.status == .active || record.status == .inactive,
               system.app(record.pid)?.isActive != true {
                windowExecutor.requestWindowFocusViaSkyLight(handle)
                #if DEBUG
                if switches.clickTraceEnabled { ClickLatencyTrace.markCurrent("earlyFocus") }
                #endif
            }
            return windowExecutor.activate(
                handle,
                confirmationTimeout: effectiveKnownMinimized ? 0.9 : (isFinderWindow ? 0.6 : 0.2),
                knownCGWindowID: record.cgWindowID,
                knownMinimized: effectiveKnownMinimized,
                preActivateForRestore: effectiveKnownMinimized
                    && MinimizedRestorePreActivation.canPreActivate(snapshot: snapshot, target: record),
                awaitOnScreenBeforeFocus: forcedMinimizedPrior,
                owningApplication: record.owningApplication,
                rebindAfterRestore: record.actionTarget != nil
            )
        case .minimizeWindow:
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, executor: windowExecutor, patience: .minimize)
            let preSwitched = handoff?.preSwitched == true

            func finishSuccessfulMinimize(_ exec: AccessibilityWindowActionExecutor.ActionExecution) -> Bool {
                finishHandoff(handoff, executor: windowExecutor)
                #if DEBUG
                if switches.chipProbeEnabled {
                    Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(exec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(exec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: exec.verifiedMinimized), privacy: .public)")
                }
                #endif
                return true
            }

            let minExec = windowExecutor.minimize(handle)
            if minExec.success {
                return finishSuccessfulMinimize(minExec)
            }
            if hiddenFinder {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    let retryExec = windowExecutor.minimize(h)
                    #if DEBUG
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    #endif
                    return retryExec.success
                }
            }
            if minExec.verifiedMinimized != true {
                for attempt in 1...8 {
                    guard !cancellation.isCancelled, commandBudget?.canContinue != false else { return false }
                    let wait = min(0.12, commandBudget?.remaining ?? 0.12)
                    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                    guard !cancellation.isCancelled, commandBudget?.canContinue != false else { return false }
                    let retryExec = windowExecutor.minimize(handle)
                    #if DEBUG
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-retry attempt=\(attempt, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    #endif
                    if retryExec.success {
                        return finishSuccessfulMinimize(retryExec)
                    }
                }
            }
            #if DEBUG
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
            }
            #endif
            return false
        case .closeWindow:
            let handoff = beginHandoff(handle: handle, record: record, snapshot: snapshot,
                                       onHandoffActivePrediction: onHandoffActivePrediction, executor: windowExecutor, patience: .close)
            if windowExecutor.close(handle) {
                finishHandoff(handoff, executor: windowExecutor)
                return true
            }
            if hiddenFinder {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    return windowExecutor.close(h)
                }
            }
            return false
        }
    }

    private struct Handoff {
        let pid: pid_t
        let windowID: CGWindowID
        let element: AXUIElement?
        let preSwitched: Bool
    }

    struct HandoffPatience {
        let focusedReadBudget: TimeInterval
        let deactivationCap: TimeInterval
        static let minimize = HandoffPatience(focusedReadBudget: 0, deactivationCap: 0.1)
        static let close = HandoffPatience(focusedReadBudget: 0.5, deactivationCap: 0.5)
    }

    private func beginHandoff(
        handle: AccessibilityWindowActionExecutor.WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot,
        onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?,
        executor windowExecutor: AccessibilityWindowActionExecutor,
        patience: HandoffPatience
    ) -> Handoff? {
        let verdict = windowExecutor.findBackgroundActivationTarget(
            for: handle, record: record, snapshot: snapshot, focusedReadBudget: patience.focusedReadBudget
        )
        switch verdict {
        case .siblingTakesOver(let windowID):
            guard windowExecutor.canAct(on: handle) else { return nil }
            onHandoffActivePrediction?(windowID)
            return nil
        case .none:
            return nil
        case .switchTo(let pid, let wid, let windowID):
            guard let candidate = snapshot.windows[windowID], candidate.pid == pid, candidate.cgWindowID == wid else { return nil }
            let element: AXUIElement?
            if let expectedElement = candidate.actionTarget?.element {
                guard let candidateHandle = windowExecutor.captureHandleByCGWindowID(wid, pid: pid, title: candidate.title,
                    bounds: candidate.bounds, expectedElement: expectedElement) else { return nil }
                element = candidateHandle.element
            } else {
                element = nil
            }
            guard windowExecutor.canAct(on: handle) else { return nil }
            onHandoffActivePrediction?(windowID)
            let preSwitched = windowExecutor.switchFrontmostForHandoff(
                to: candidate, windowID: wid, element: element, from: handle, original: record,
                deactivationCap: patience.deactivationCap
            )
            return Handoff(pid: pid, windowID: wid, element: element, preSwitched: preSwitched)
        }
    }

    private func finishHandoff(_ handoff: Handoff?, executor windowExecutor: AccessibilityWindowActionExecutor) {
        guard let handoff else { return }
        if handoff.preSwitched, windowExecutor.makeKeyAfterHandoff(pid: handoff.pid, windowID: handoff.windowID,
            element: handoff.element) { return }
        usleep(Self.postMinimizeActivateDelayMicroseconds)
        _ = windowExecutor.activateApplication(pid: handoff.pid, windowID: handoff.windowID, element: handoff.element)
    }

    private func executeAppFallback(request: PlatformActionRequest, record: WindowRecord, executor windowExecutor: AccessibilityWindowActionExecutor) -> Bool {
        guard request.kind == .activateWindow else { return false }
        return windowExecutor.activateAppWithWindowRecovery(pid: record.pid)
    }

}
