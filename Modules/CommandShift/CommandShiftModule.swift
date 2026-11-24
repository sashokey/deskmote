import AppKit
import ApplicationServices

@MainActor
public final class CommandShiftModule {
    public enum StartResult {
        case running
        case permissionRequired
        case unavailable
    }

    public var onInterruption: ((Bool) -> Void)?
    private let notifications = NSWorkspace.shared.notificationCenter
    private let monitor = KeyboardMonitor(readInput: { ShortcutRecognizer.currentInput() }) {
        let status = SystemInputSources.selectNext()
        if status != 0 {
            Alerts.error("Couldn’t Switch Input Source",
                         "macOS returned error \(status). Check your enabled input sources in System Settings > Keyboard > Text Input.")
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var sessionInactive = false

    public init() {
        monitor.onInterruption = { [weak self] state in
            guard let self else { return }
            self.stop()
            self.onInterruption?(state == .permissionRequired)
        }
    }

    public func start(requestPermission: Bool) -> StartResult {
        var result = monitor.start()
        if result == .permissionRequired, requestPermission {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            result = monitor.start()
        }
        switch result {
        case .running:
            observeWorkspace()
            return .running
        case .permissionRequired:
            return .permissionRequired
        case .unavailable:
            if requestPermission {
                Alerts.error("Couldn’t Start Command Shift", "The keyboard event listener could not be started.")
            }
            return .unavailable
        }
    }

    public func stop() {
        observers.forEach(notifications.removeObserver)
        observers.removeAll()
        monitor.stop()
        sleeping = false
        sessionInactive = false
    }

    isolated deinit { stop() }

    private func observeWorkspace() {
        guard observers.isEmpty else { return }
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
        case NSWorkspace.willSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: return
        }
        monitor.stop()
        guard !sleeping && !sessionInactive else { return }
        let state = monitor.start()
        if state != .running {
            stop()
            onInterruption?(state == .permissionRequired)
        }
    }
}
