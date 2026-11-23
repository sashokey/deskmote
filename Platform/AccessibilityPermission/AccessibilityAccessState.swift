import Combine
import Foundation

@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    nonisolated static let pollInterval: TimeInterval = 1
    nonisolated static let defaultStallInterval: TimeInterval = 8

    @Published private(set) var state: PermissionOnboardingState

    var onGranted: (() -> Void)?

    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let stallAfter: TimeInterval
    private var pollingStartedAt: TimeInterval?
    private var timer: Timer?
    private var didRequestPrompt = false
    private var didNotifyGranted = false

    init(
        permissionService: PermissionService = PermissionService(),
        installLocation: AppInstallLocation,
        initialTrusted: Bool? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        stallAfter: TimeInterval = AccessibilityPermissionModel.defaultStallInterval
    ) {
        let trusted = initialTrusted ?? permissionService.hasRequiredPermissions()
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.stallAfter = stallAfter
        self.state = .initial(installLocation: installLocation, isTrusted: trusted)
    }

    func startPolling() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }
        checkNow()
        guard state != .granted, timer == nil else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func requestSystemPromptIfNeeded() {
        guard installLocation.allowsAccessibilityPrompt,
              state != .granted,
              !didRequestPrompt else { return }
        didRequestPrompt = true
        permissionService.requestAccessibilityPermission()
    }

    func applicationDidBecomeActive() {
        checkNow()
    }

    func checkNow() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }

        let trusted = permissionService.hasRequiredPermissions()
        let elapsed = max(0, now() - (pollingStartedAt ?? now()))
        state = state.updated(isTrusted: trusted, elapsed: elapsed, stallAfter: stallAfter)
        guard state == .granted else { return }

        didNotifyGranted = true
        stop()
        let callback = onGranted
        onGranted = nil
        callback?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
