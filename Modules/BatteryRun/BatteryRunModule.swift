import AppKit
import Combine

@MainActor
public final class BatteryRunModule {
    private let windowPresented: @MainActor (NSWindow) -> Void
    private var controller: BatteryWindowController?
    private var pendingPresentation: UUID?
    private var activationObservation: AnyCancellable?

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

        if application.isActive {
            presentWindow(request, reason: "already-active")
            return
        }

        activationObservation = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification, object: application
        ).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePresentation(request, reason: "activation-notification") }
        }
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
            controller = BatteryWindowController(monitor: BatteryMonitor())
            controller?.window?.tabbingMode = .disallowed
        }
        guard let controller, let window = controller.window else { return }

        let active = NSApplication.shared.isActive
        if window.isMiniaturized { window.deminiaturize(nil) }
        if active {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        windowPresented(window)
        controller.monitor.refresh()
    }

}
