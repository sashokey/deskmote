import ApplicationServices
import Foundation
#if DEBUG
import os
#endif

#if DEBUG
private let restorationLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "WindowLiftAvoidance")
#endif

struct WindowLiftWriteFrames: Sendable {
    var acknowledged: CGRect?
    var attempted: CGRect?

    var candidates: [CGRect] { [acknowledged, attempted].compactMap { $0 } }
    var isEmpty: Bool { acknowledged == nil && attempted == nil }

    func matches(_ frame: CGRect) -> Bool {
        candidates.contains { WindowLiftAvoidance.measuredFramesAgree(frame, $0) }
    }
}

struct WindowRestorationFrames: Sendable {
    let nativeAppKit: CGRect
    let targetAppKit: CGRect
    let nativeQuartz: CGRect
    let targetQuartz: CGRect
    let primaryDisplayHeight: CGFloat
    var processGeneration: ProcessGeneration? = nil
    var expectedElement: AXElementKey? = nil
    var restoresSettledTarget = true
    var settledQuartz: CGRect?
    var interruptedWriteFrames = WindowLiftWriteFrames()
    var partiallyRestoredQuartz: CGRect?

    func hasSameRestorationPlan(as other: Self) -> Bool {
        nativeQuartz == other.nativeQuartz &&
            targetQuartz == other.targetQuartz &&
            processGeneration == other.processGeneration &&
            expectedElement == other.expectedElement
    }
}

extension WindowRestorationFrames {
    init(nativeAppKit: CGRect, targetAppKit: CGRect, primaryDisplayHeight: CGFloat,
         processGeneration: ProcessGeneration? = nil, restoresSettledTarget: Bool = true) {
        self.init(
            nativeAppKit: nativeAppKit,
            targetAppKit: targetAppKit,
            nativeQuartz: WindowLiftAvoidance.windowServerFrame(
                fromAppKit: nativeAppKit, primaryDisplayHeight: primaryDisplayHeight
            ),
            targetQuartz: WindowLiftAvoidance.windowServerFrame(
                fromAppKit: targetAppKit, primaryDisplayHeight: primaryDisplayHeight
            ),
            primaryDisplayHeight: primaryDisplayHeight, processGeneration: processGeneration,
            restoresSettledTarget: restoresSettledTarget
        )
    }
}

enum WindowRestorationOutcome: Equatable, Sendable {
    case handled
    case retry
    case retryAfterPartialWrite(CGRect)
}

enum WindowRestorationCompletion: Equatable, Sendable {
    case complete
    case incomplete(remaining: Int)
}

enum WindowRestorationCaptureFailure: Error {
    case unavailable
    case windowGone
}

protocol WindowRestorationAccess: Sendable {
    associatedtype Handle: Sendable
    func processStartTime(pid: pid_t) -> timeval?
    func processIsAlive(pid: pid_t) -> Bool?
    func capture(_ key: WindowLiftAvoidance.WindowKey, expectedElement: AXElementKey?) -> Result<Handle, WindowRestorationCaptureFailure>
    func windowID(_ handle: Handle) -> CGWindowID?
    func frame(_ handle: Handle) -> CGRect?
    func write(_ frame: CGRect, to handle: Handle, matching current: CGRect,
               onAttempt: (CGRect) -> Void,
               checkWriteAdmission: () -> AXWindowFrameWriteFailure?) -> AXWindowFrameWriteResult
}

extension WindowRestorationAccess {
    func windowID(_ handle: Handle) -> CGWindowID? { nil }
    func processIsAlive(pid: pid_t) -> Bool? { nil }
}

struct AXWindowRestorationAccess: WindowRestorationAccess {
    struct Handle: Sendable {
        let element: AXElementKey
        let windowID: CGWindowID
    }

    private let reader: AXWindowReader
    private let startTime: @Sendable (pid_t) -> timeval?
    private let system: any WindowSystemAccess

    init(reader: AXWindowReader = AXWindowReader(),
         processStartTime: @escaping @Sendable (pid_t) -> timeval? = { ProcessLiveness.startTime(pid: $0) },
         system: any WindowSystemAccess = NativeWindowSystem()) {
        self.reader = reader
        self.startTime = processStartTime
        self.system = system
    }

    func processStartTime(pid: pid_t) -> timeval? { startTime(pid) }
    func processIsAlive(pid: pid_t) -> Bool? { pid > 0 ? ProcessLiveness.isAlive(pid: pid) : nil }

    func capture(_ key: WindowLiftAvoidance.WindowKey, expectedElement: AXElementKey?) -> Result<Handle, WindowRestorationCaptureFailure> {
        if let handle = reader.captureHandle(forPID: key.pid, cgWindowID: key.cgWindowID,
                                             messagingTimeout: 0.1, expectedElement: expectedElement) {
            return .success(Handle(element: AXElementKey(e: handle.element), windowID: key.cgWindowID))
        }
        guard let expectedElement else { return .failure(.unavailable) }
        if reader.accessibility.pid(expectedElement.e) == key.pid,
           let number = reader.cgWindowID(for: expectedElement.e, maxAttempts: 1, messagingTimeout: 0.1),
           number != kCGNullWindowID,
           let descriptions = system.windowDescriptions(for: number == key.cgWindowID ? [number] : [key.cgWindowID, number]) {
            let ownedNumbers = Set(descriptions.filter { $0[kCGWindowOwnerPID as String] as? pid_t == key.pid }
                .compactMap { nativeWindowNumber(in: $0) })
            if ownedNumbers.contains(number), number == key.cgWindowID || !ownedNumbers.contains(key.cgWindowID) {
                return .success(Handle(element: expectedElement, windowID: number))
            }
        }
        _ = reader.accessibility.setTimeout(expectedElement.e, 0.1)
        var role: CFTypeRef?
        let error = reader.copyAttributeValue(kAXRoleAttribute as CFString, from: expectedElement.e, into: &role, maxAttempts: 1)
        return .failure(error == .invalidUIElement ? .windowGone : .unavailable)
    }

    func windowID(_ handle: Handle) -> CGWindowID? { handle.windowID }

    func frame(_ handle: Handle) -> CGRect? { reader.frame(of: handle.element.e, messagingTimeout: 0.1) }

    func write(_ frame: CGRect, to handle: Handle, matching current: CGRect,
               onAttempt: (CGRect) -> Void,
               checkWriteAdmission: () -> AXWindowFrameWriteFailure?) -> AXWindowFrameWriteResult {
        reader.setFrame(frame, for: handle.element.e, messagingTimeout: 0.1,
                        frameVerificationTolerance: WindowLiftAvoidance.frameVerificationTolerance,
                        onlyIfCurrentMatches: current, restoreOnFailureTo: current,
                        expectedWindowID: handle.windowID, onAttempt: onAttempt,
                        checkWriteAdmission: checkWriteAdmission)
    }
}

struct WindowRestorer<Access: WindowRestorationAccess>: Sendable {
    let access: Access

    func restore(key: WindowLiftAvoidance.WindowKey, frames: WindowRestorationFrames,
                 expectedStartTime: timeval?, liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?,
                 cancellation: OperationCancellation = OperationCancellation(),
                 budget: OperationReadBudget? = nil) -> WindowRestorationOutcome {
        guard !cancellation.isCancelled, budget?.canContinue != false else { return .retry }
        guard frames.restoresSettledTarget || !frames.interruptedWriteFrames.isEmpty ||
              frames.partiallyRestoredQuartz != nil else { return .handled }
        if liveWindowKeys?.contains(key) == false, frames.expectedElement == nil {
            #if DEBUG
            logSkippedRestoration(key, reason: "windowGone")
            #endif
            return .handled
        }
        guard let expectedStartTime = expectedStartTime ?? frames.processGeneration.map({ timeval(tv_sec: Int($0.seconds), tv_usec: $0.microseconds) }) else { return .retry }
        guard let currentStart = access.processStartTime(pid: key.pid) else {
            return access.processIsAlive(pid: key.pid) == false ? .handled : .retry
        }
        guard currentStart.tv_sec == expectedStartTime.tv_sec, currentStart.tv_usec == expectedStartTime.tv_usec else {
            #if DEBUG
            logSkippedRestoration(key, reason: "processReplaced")
            #endif
            return .handled
        }
        let handle: Access.Handle
        switch access.capture(key, expectedElement: frames.expectedElement) {
        case let .success(captured):
            handle = captured
        case .failure(.windowGone):
            #if DEBUG
            logSkippedRestoration(key, reason: "windowGone")
            #endif
            return .handled
        case .failure(.unavailable):
            return .retry
        }
        if let number = access.windowID(handle), number != key.cgWindowID {
            guard frames.expectedElement != nil, let liveWindowKeys, !liveWindowKeys.contains(key),
                  liveWindowKeys.contains(.init(pid: key.pid, cgWindowID: number)) else { return .retry }
        } else if liveWindowKeys?.contains(key) == false {
            return .retry
        }
        guard let current = access.frame(handle) else { return .retry }
        let appKitFrame = WindowLiftAvoidance.appKitCoordinates(fromQuartz: current, primaryDisplayHeight: frames.primaryDisplayHeight)
        let classification = WindowLiftAvoidance.classifyObservedLiftFrame(of: appKitFrame, unadjustedWindowFrame: frames.nativeAppKit,
                                                                    intendedWindowFrame: frames.targetAppKit)
        let matchesSettledTarget = frames.restoresSettledTarget &&
            WindowLiftAvoidance.measuredFramesAgree(current, frames.settledQuartz ?? frames.targetQuartz)
        let matchesPartialRestoration = frames.partiallyRestoredQuartz.map { WindowLiftAvoidance.measuredFramesAgree(current, $0) } == true
        let matchesInterruptedWrite = !WindowLiftAvoidance.measuredFramesAgree(current, frames.nativeQuartz) &&
            (frames.interruptedWriteFrames.matches(current) || matchesPartialRestoration)
        guard matchesSettledTarget || matchesInterruptedWrite else {
            #if DEBUG
            logSkippedRestoration(key, reason: String(describing: classification), frame: current)
            #endif
            return .handled
        }
        func checkWriteAdmission() -> AXWindowFrameWriteFailure? {
            guard !cancellation.isCancelled, budget?.canContinue != false else { return .operationBudgetExhausted }
            guard let finalStart = access.processStartTime(pid: key.pid) else { return .initialFrameUnavailable }
            guard finalStart.tv_sec == expectedStartTime.tv_sec, finalStart.tv_usec == expectedStartTime.tv_usec else {
                return .windowIdentityChanged
            }
            return !cancellation.isCancelled && budget?.canContinue != false ? nil : .operationBudgetExhausted
        }

        guard !cancellation.isCancelled, budget?.canContinue != false else { return .retry }
        var partiallyRestoredQuartz: CGRect?
        let result = access.write(frames.nativeQuartz, to: handle, matching: current, onAttempt: { attempted in
            if !WindowLiftAvoidance.measuredFramesAgree(attempted, frames.nativeQuartz) {
                partiallyRestoredQuartz = attempted
            }
        }, checkWriteAdmission: checkWriteAdmission)
        switch result {
        case let .success(actual):
            #if DEBUG
            restorationLogger.notice("lift restored pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) axBefore=\(String(describing: current), privacy: .public) axAfter=\(String(describing: actual), privacy: .public)")
            #endif
            return .handled
        case let .failure(reason, rollback):
            #if DEBUG
            restorationLogger.error("lift restoration failed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason.diagnosticDescription, privacy: .public) rollback=\(rollback.diagnosticDescription, privacy: .public) axBefore=\(String(describing: current), privacy: .public) target=\(String(describing: frames.nativeQuartz), privacy: .public)")
            #endif
            if case .restored = rollback { return .retry }
            if let partiallyRestoredQuartz { return .retryAfterPartialWrite(partiallyRestoredQuartz) }
            return .retry
        }
    }

    #if DEBUG
    private func logSkippedRestoration(_ key: WindowLiftAvoidance.WindowKey, reason: String, frame: CGRect? = nil) {
        let observed = frame.map { String(describing: $0) } ?? "-"
        restorationLogger.notice("lift restoration skipped pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason, privacy: .public) ax=\(observed, privacy: .public)")
    }
    #endif
}
