import AppKit
import Combine
#if DESKMOTE_QA_JOURNAL
import os
#endif

@MainActor
public final class BatteryRunModule {
    private let windowPresented: @MainActor (NSWindow) -> Void
    private var controller: BatteryWindowController?
    private var pendingPresentation: UUID?
    private var activationObservation: AnyCancellable?
    #if DESKMOTE_QA_JOURNAL
    private var latestRequest: UUID?
    #endif

    public init(windowPresented: @escaping @MainActor (NSWindow) -> Void = { _ in }) {
        self.windowPresented = windowPresented
    }

    public func showWindow() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.requestPresentation() }
        }
    }

    private func requestPresentation() {
        let request = UUID()
        let application = NSApplication.shared
        pendingPresentation = request
        activationObservation = nil
        #if DESKMOTE_QA_JOURNAL
        latestRequest = request
        logPresentation("requested", request: request)
        #endif

        if application.isActive {
            presentWindow(request, reason: "already-active")
            return
        }

        activationObservation = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification, object: application
        ).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePresentation(request, reason: "activation-notification") }
        }
        #if DESKMOTE_QA_JOURNAL
        logPresentation("activating", request: request)
        #endif
        application.activate()
        if application.isActive {
            presentWindow(request, reason: "activation-immediate")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.schedulePresentation(request, reason: "activation-timeout")
        }
    }

    private func schedulePresentation(_ request: UUID, reason: String) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.presentWindow(request, reason: reason) }
        }
    }

    private func presentWindow(_ request: UUID, reason: String) {
        guard pendingPresentation == request else { return }
        pendingPresentation = nil
        activationObservation = nil

        if controller == nil {
            let monitor = BatteryMonitor()
            monitor.start()
            controller = BatteryWindowController(monitor: monitor)
            controller?.window?.tabbingMode = .disallowed
        }
        guard let window = controller?.window else { return }

        let active = NSApplication.shared.isActive
        if window.isMiniaturized { window.deminiaturize(nil) }
        if active {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        windowPresented(window)
        #if DESKMOTE_QA_JOURNAL
        logPresentation(reason, request: request)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, self.latestRequest == request else { return }
            self.logPresentation("settled", request: request)
        }
        #endif
    }

    #if DESKMOTE_QA_JOURNAL
    private static let logger = Logger(subsystem: "io.github.sashokey.deskmote.batteryrun", category: "QA")

    private func logPresentation(_ event: String, request: UUID) {
        let window = controller?.window
        Self.logger.notice("""
            battery event=\(event, privacy: .public) request=\(request.uuidString, privacy: .public) \
            active=\(NSApplication.shared.isActive, privacy: .public) hasWindow=\(window != nil, privacy: .public) \
            visible=\(window?.isVisible == true, privacy: .public) key=\(window?.isKeyWindow == true, privacy: .public) \
            minimized=\(window?.isMiniaturized == true, privacy: .public) onSpace=\(window?.isOnActiveSpace == true, privacy: .public) \
            onscreen=\(window?.occlusionState.contains(.visible) == true, privacy: .public)
            """)
    }
    #endif
}
