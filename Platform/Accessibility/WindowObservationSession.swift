import ApplicationServices
import Foundation
#if DEBUG
import os
#endif

protocol WindowObservationSession: Sendable {
    func add(_ notification: String, element: AXElementKey?) -> AXError
    @discardableResult
    func remove(_ notification: String, element: AXElementKey) -> AXError
    @MainActor func attach()
    @MainActor func detach()
}

final class AXWindowObservationSession: WindowObservationSession, @unchecked Sendable {
    private final class Callback: Sendable {
        let receive: @Sendable (AXElementKey, String) -> Void
        init(_ receive: @escaping @Sendable (AXElementKey, String) -> Void) { self.receive = receive }
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "window-height")
    #endif
    private let observer: AXObserver
    private let application: AXUIElement
    private let callback: Callback
    private let access = RuntimeAccessibilityAccess.shared

    init?(pid: pid_t, receive: @escaping @Sendable (AXElementKey, String) -> Void) {
        guard access.checkTrust(AXIsProcessTrusted) else {
            #if DEBUG
            Self.logger.notice("AXObserverCreate pid=\(pid) outcome=permission-unavailable")
            #endif
            return nil
        }
        var observer: AXObserver?
        let result = access.call {
            AXObserverCreate(pid, { _, element, notification, refcon in
                guard let refcon else { return }
                let callback = Unmanaged<Callback>.fromOpaque(refcon).takeUnretainedValue()
                callback.receive(AXElementKey(e: element), notification as String)
            }, &observer)
        }
        guard result == .success, let observer else {
            #if DEBUG
            Self.logger.notice("AXObserverCreate pid=\(pid) axError=\(result.rawValue) observerReturned=\(observer != nil)")
            #endif
            return nil
        }
        self.observer = observer
        application = AXUIElementCreateApplication(pid)
        callback = Callback(receive)
    }

    func add(_ notification: String, element: AXElementKey?) -> AXError {
        let target = element?.e ?? application
        _ = access.call { AXUIElementSetMessagingTimeout(target, 0.05) }
        return access.call {
            AXObserverAddNotification(observer, target, notification as CFString,
                                      Unmanaged.passUnretained(callback).toOpaque())
        }
    }

    @discardableResult
    func remove(_ notification: String, element: AXElementKey) -> AXError {
        _ = access.call { AXUIElementSetMessagingTimeout(element.e, 0.05) }
        return access.call { AXObserverRemoveNotification(observer, element.e, notification as CFString) }
    }

    @MainActor func attach() {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @MainActor func detach() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
