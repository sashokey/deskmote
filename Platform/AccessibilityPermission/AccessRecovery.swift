import Combine
import Foundation
import OSLog
import Synchronization

private extension PermissionPhase {
    var logName: String {
        switch self {
        case .idle: "idle"
        case .transientShell: "transient-shell"
        case .onboarding: "onboarding"
        case .running: "running"
        case .uncertain: "uncertain"
        case .suspended: "suspended"
        case .relaunching: "relaunching"
        case .relaunchFailed: "relaunch-failed"
        case .terminating: "terminating"
        }
    }
}

final class PermissionWatchdogGate: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var isRunning = false
        var isProbeInFlight = false
        var pendingDelivery: Bool?
    }

    private let state = Mutex(State())

    @discardableResult
    func start() -> UInt64 {
        state.withLock {
            $0 = State(generation: $0.generation &+ 1, isRunning: true)
            return $0.generation
        }
    }

    func stop() {
        state.withLock { $0 = State(generation: $0.generation &+ 1) }
    }

    func beginProbe(for expectedGeneration: UInt64? = nil) -> UInt64? {
        state.withLock {
            guard $0.isRunning, !$0.isProbeInFlight,
                  expectedGeneration == nil || expectedGeneration == $0.generation else { return nil }
            $0.isProbeInFlight = true
            return $0.generation
        }
    }

    func completeProbe(generation completedGeneration: UInt64, deliver trusted: Bool? = nil,
                       accept: () -> Bool = { true }) -> Bool {
        state.withLock {
            guard completedGeneration == $0.generation, $0.isProbeInFlight else { return false }
            $0.isProbeInFlight = false
            guard accept() else { return false }
            guard let trusted else { return true }
            let needsDispatch = $0.pendingDelivery == nil
            $0.pendingDelivery = trusted && ($0.pendingDelivery ?? true)
            return needsDispatch
        }
    }

    func takeDelivery(generation expectedGeneration: UInt64) -> Bool? {
        state.withLock {
            guard $0.isRunning, $0.generation == expectedGeneration else { return nil }
            defer { $0.pendingDelivery = nil }
            return $0.pendingDelivery
        }
    }
}

@MainActor
protocol PermissionEffectHandler: AnyObject {
    func startApp()
    func setActivationPolicy(_ policy: PermissionActivationPolicy)
    func showGuideWindow()
    func updateGuideWindow()
    func closeGuideWindow()
    func openAccessibilitySettings()
    func openApplicationsFolder()
    func startWatchdog()
    func stopWatchdog()
    func suspendPanelsAndStores()

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error>
    func terminateSelf()
}

@MainActor
final class PermissionRecoveryCoordinator: ObservableObject {
    @Published private(set) var presentation: PermissionPresentation?

    private let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "permissions")
    private weak var handler: PermissionEffectHandler?
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let makeModel: (PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel

    private var machine = PermissionRecoveryMachine()
    private var detector = PermissionLossDetector()
    private var model: AccessibilityPermissionModel?
    private var modelSubscription: AnyCancellable?
    private var recoveryTask: Task<Void, Never>?
    private var onboardingState: PermissionOnboardingState = .waiting

    private var pendingEvents: [PermissionEvent] = []
    private var isDispatching = false

    var phase: PermissionPhase { machine.phase }

    init(
        handler: PermissionEffectHandler?,
        permissionService: PermissionService,
        installLocation: AppInstallLocation,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeModel: ((PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel)? = nil
    ) {
        self.handler = handler
        self.installLocation = installLocation
        self.now = now
        self.makeModel = makeModel ?? { _, _ in
            AccessibilityPermissionModel(
                permissionService: permissionService,
                installLocation: installLocation
            )
        }
    }

    func launched(trusted: Bool) {
        dispatch(.launched(location: installLocation, trusted: trusted))
    }

    func sampleTrust(_ trusted: Bool) {
        dispatch(.trustVerdict(detector.record(trusted: trusted, at: now())))
    }

    func applicationDidBecomeActive() {
        model?.applicationDidBecomeActive()
    }

    func recheck() { dispatch(.recheckRequested) }
    func retryRelaunch() { dispatch(.retryRequested) }
    func quit() {
        logger.notice("permission-guide-quit-requested")
        dispatch(.quitRequested)
    }
    func terminationRequested() { dispatch(.terminationRequested) }
    func openSettings() { handler?.openAccessibilitySettings() }
    func openApplications() { handler?.openApplicationsFolder() }

    private func dispatch(_ event: PermissionEvent) {
        pendingEvents.append(event)
        guard !isDispatching else { return }
        #if DEBUG
        let resources = ActionResourceLog.begin("permission.dispatch")
        defer { resources?.finish() }
        #endif
        isDispatching = true
        defer { isDispatching = false }
        while !pendingEvents.isEmpty {
            let before = machine.phase
            let effects = machine.handle(pendingEvents.removeFirst())
            if before != machine.phase {
                logger.notice("permission-phase from=\(before.logName, privacy: .public) to=\(self.machine.phase.logName, privacy: .public)")
            }
            run(effects)
        }
    }

    private func run(_ effects: [PermissionEffect]) {
        for effect in effects {
            switch effect {
            case .startApp:
                handler?.startApp()
            case let .setActivationPolicy(policy):
                handler?.setActivationPolicy(policy)
            case .showGuide:
                logger.notice("permission-guide-opening")
                refreshPresentation()
                handler?.showGuideWindow()
                logger.notice("permission-guide-opened")
            case .updateGuide:
                refreshPresentation()
                handler?.updateGuideWindow()
            case .closeGuide:
                refreshPresentation()
                handler?.closeGuideWindow()
            case let .startPermissionEpisode(purpose, episode):
                startEpisode(purpose: purpose, episode: episode)
            case .stopPermissionEpisode:
                stopEpisode()
            case .requestSystemPrompt:
                logger.notice("permission-system-prompt-check-started")
                model?.requestSystemPromptIfNeeded()
                logger.notice("permission-system-prompt-check-completed")
            case .recheckNow:
                model?.checkNow()
            case .startWatchdog:
                detector = PermissionLossDetector()
                handler?.startWatchdog()
            case .stopWatchdog:
                handler?.stopWatchdog()
            case .suspendPanelsAndStores:
                handler?.suspendPanelsAndStores()

            case let .launchNewInstance(episode):
                startLaunch(episode: episode)
            case .cancelRecoveryTask:
                recoveryTask?.cancel()
                recoveryTask = nil
            case .terminateSelf:
                handler?.terminateSelf()
            }
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        let next = PermissionRecoveryMachine.presentation(
            phase: machine.phase,
            onboarding: onboardingState
        )
        if presentation != next { presentation = next }
    }

    private func startEpisode(purpose: PermissionEpisodePurpose, episode: UInt64) {
        stopEpisode()
        let model = makeModel(purpose, episode)
        self.model = model
        onboardingState = model.state
        modelSubscription = model.$state.sink { [weak self] state in
            guard let self else { return }
            let previous = self.presentation
            self.onboardingState = state
            self.refreshPresentation()
            if state != .granted, let previous, self.presentation != previous {
                self.handler?.updateGuideWindow()
            }
        }
        model.onGranted = { [weak self] in
            self?.dispatch(.grantObserved(episode: episode))
        }
        model.startPolling()
    }

    private func stopEpisode() {
        modelSubscription?.cancel()
        modelSubscription = nil
        model?.onGranted = nil
        model?.stop()
        model = nil
    }

    private func startLaunch(episode: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, let handler = self.handler else { return }
            let result = await handler.launchNewInstance(episode: episode)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                self.dispatch(.relaunchSucceeded(episode: episode))
            case let .failure(error):
                self.dispatch(.relaunchFailed(episode: episode, message: error.localizedDescription))
            }
        }
    }
}
