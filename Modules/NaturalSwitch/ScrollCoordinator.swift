import Foundation

@MainActor
protocol DeviceMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start() throws
    func snapshot() throws -> [HIDDevice]
    func stop()
}

@MainActor
protocol ScrollControlling {
    func isNatural() throws -> Bool
    func setNatural(_ enabled: Bool) throws
}

@MainActor
final class ScrollCoordinator {
    private let monitor: any DeviceMonitoring
    private let scrolling: any ScrollControlling
    private let onFailure: (Error) -> Void
    private var enabled = false
    private var running = false
    private var sleeping = false
    private var sessionActive = true
    private var failed = false
    var isRunning: Bool { running }

    init(monitor: any DeviceMonitoring, scrolling: any ScrollControlling, onFailure: @escaping (Error) -> Void) {
        self.monitor = monitor
        self.scrolling = scrolling
        self.onFailure = onFailure
    }

    func start() {
        enabled = true
        updateLifecycle()
    }

    func stop() {
        enabled = false
        pause()
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        updateLifecycle()
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        updateLifecycle()
    }

    private func updateLifecycle() {
        guard enabled, !failed, !sleeping, sessionActive else {
            pause()
            return
        }
        guard !running else { return }
        do {
            monitor.onChange = { [weak self] in self?.refresh() }
            try monitor.start()
            running = true
            refresh()
        } catch { fail(error) }
    }

    private func refresh() {
        guard running else { return }
        do {
            let natural = try !monitor.snapshot().contains(where: \.isExternalMouse)
            if try scrolling.isNatural() != natural { try scrolling.setNatural(natural) }
        } catch { fail(error) }
    }

    private func pause() {
        running = false
        monitor.onChange = nil
        monitor.stop()
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        pause()
        onFailure(error)
    }
}
