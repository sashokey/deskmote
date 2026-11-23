import AppKit

@MainActor
public final class NaturalSwitchModule {
    public var onInterruption: (() -> Void)?
    private let notifications = NSWorkspace.shared.notificationCenter
    private let makeScrolling: () throws -> any ScrollControlling
    private let presentFailure: (Error) -> Void
    private var coordinator: ScrollCoordinator?
    private var observers: [NSObjectProtocol] = []

    public convenience init() {
        self.init(makeScrolling: { try ScrollController() }, presentFailure: Self.present)
    }

    init(makeScrolling: @escaping () throws -> any ScrollControlling,
         presentFailure: @escaping (Error) -> Void) {
        self.makeScrolling = makeScrolling
        self.presentFailure = presentFailure
    }

    public func start(presentStartupError: Bool = true) -> Bool {
        if let coordinator { return coordinator.isRunning }
        var starting = true
        defer { starting = false }
        do {
            let coordinator = ScrollCoordinator(monitor: DeviceMonitor(), scrolling: try makeScrolling()) { [weak self] error in
                self?.stop()
                self?.onInterruption?()
                if !starting || presentStartupError { self?.presentFailure(error) }
            }
            self.coordinator = coordinator
            coordinator.start()
            guard coordinator.isRunning else { return false }
            observeWorkspace()
            return true
        } catch {
            if presentStartupError { presentFailure(error) }
            return false
        }
    }

    public func stop() {
        observers.forEach(notifications.removeObserver)
        observers.removeAll()
        coordinator?.stop()
        coordinator = nil
    }

    isolated deinit { stop() }

    private func observeWorkspace() {
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated { self?.workspaceChanged(name) }
            })
        }
    }

    private func workspaceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: coordinator?.setSleeping(true)
        case NSWorkspace.didWakeNotification: coordinator?.setSleeping(false)
        case NSWorkspace.sessionDidResignActiveNotification: coordinator?.setSessionActive(false)
        case NSWorkspace.sessionDidBecomeActiveNotification: coordinator?.setSessionActive(true)
        default: break
        }
    }

    private static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Run Natural Switch"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate()
        alert.runModal()
    }
}
