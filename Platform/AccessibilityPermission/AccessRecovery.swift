import Combine
import Foundation
import Synchronization


final class RuntimePermissionWatchdog: Sendable {
    typealias Schedule = @Sendable (DispatchTime, @escaping @Sendable () -> Void) -> Void

    struct ProbeTicket: Equatable, Sendable {
        fileprivate let id: UInt64
        fileprivate let run: UInt64
        fileprivate let axGeneration: UInt64
    }

    private struct State {
        var sequence: UInt64 = 0
        var run: UInt64 = 0
        var running = false
        var ready = false
        var terminal = false
        var forcedExit = false
        var probe: ProbeTicket?
    }

    private let state = Mutex(State())
    private let access: RuntimeAccessibilityAccess
    private let now: @Sendable () -> DispatchTime
    private let schedule: Schedule
    private let requestQuit: @Sendable () -> Void
    private let forceExit: @Sendable () -> Void
    private let notifyReady: @Sendable () -> Void

    init(access: RuntimeAccessibilityAccess, now: @escaping @Sendable () -> DispatchTime = DispatchTime.now,
         schedule: @escaping Schedule, requestQuit: @escaping @Sendable () -> Void,
         forceExit: @escaping @Sendable () -> Void, notifyReady: @escaping @Sendable () -> Void = {}) {
        self.access = access
        self.now = now
        self.schedule = schedule
        self.requestQuit = requestQuit
        self.forceExit = forceExit
        self.notifyReady = notifyReady
    }

    @discardableResult
    func start() -> UInt64 {
        state.withLock {
            $0.run &+= 1
            $0.running = !$0.terminal
            $0.ready = false
            return $0.run
        }
    }

    func stop() {
        state.withLock {
            $0.run &+= 1
            $0.running = false
            $0.ready = false
        }
    }

    var isReady: Bool { state.withLock { $0.running && $0.ready && !$0.terminal && access.allowsCalls } }
    var canRequestStartupPrompt: Bool { state.withLock { !$0.terminal } }

    func beginProbe(for expectedRun: UInt64? = nil) -> ProbeTicket? {
        state.withLock {
            guard $0.running, !$0.terminal, $0.probe == nil,
                  expectedRun == nil || $0.run == expectedRun else { return nil }
            let generation = access.trustGeneration
            guard access.acceptsResult(for: generation) else { return nil }
            $0.sequence &+= 1
            let ticket = ProbeTicket(id: $0.sequence, run: $0.run, axGeneration: generation)
            $0.probe = ticket
            return ticket
        }
    }

    func completeProbe(_ ticket: ProbeTicket, verdict: Bool) {
        let deliver = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.probe == ticket else { return nil }
            state.probe = nil
            guard state.running, state.run == ticket.run, !state.terminal else { return nil }
            guard verdict else { return access.commitLoss(.negativeProbe, for: ticket.axGeneration) }
            guard !state.ready, access.acceptsResult(for: ticket.axGeneration) else { return nil }
            state.ready = true
            return notifyReady
        }
        deliver?()
    }

    func requiredPermissionLost() {
        let shouldQuit = state.withLock {
            guard !$0.terminal else { return false }
            $0.terminal = true
            $0.ready = false
            return true
        }
        guard shouldQuit else { return }
        schedule(now() + .seconds(3)) { [weak self] in self?.exitIfRequired() }
        requestQuit()
    }

    private func exitIfRequired() {
        let shouldExit = state.withLock {
            guard $0.terminal, !$0.forcedExit else { return false }
            $0.forcedExit = true
            return true
        }
        if shouldExit { forceExit() }
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
    func terminateSelf()
}

@MainActor
final class PermissionRecoveryCoordinator: ObservableObject {
    @Published private(set) var presentation: PermissionPresentation?

    private weak var handler: PermissionEffectHandler?
    private let installLocation: AppInstallLocation
    private let makeModel: (PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel

    private var machine = PermissionRecoveryMachine()
    private var model: AccessibilityPermissionModel?
    private var modelSubscription: AnyCancellable?
    private var onboardingState: PermissionOnboardingState = .waiting

    private var pendingEvents: [PermissionEvent] = []
    private var isDispatching = false

    var phase: PermissionPhase { machine.phase }

    init(
        handler: PermissionEffectHandler?,
        permissionService: PermissionService,
        installLocation: AppInstallLocation,
        makeModel: ((PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel)? = nil
    ) {
        self.handler = handler
        self.installLocation = installLocation
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

    func applicationDidBecomeActive() {
        model?.applicationDidBecomeActive()
    }

    func recheck() { dispatch(.recheckRequested) }
    func quit() {
        dispatch(.quitRequested)
    }
    func terminationRequested() { dispatch(.terminationRequested) }
    func openSettings() { handler?.openAccessibilitySettings() }
    func openApplications() { handler?.openApplicationsFolder() }

    private func dispatch(_ event: PermissionEvent) {
        pendingEvents.append(event)
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }
        while !pendingEvents.isEmpty {
            let effects = machine.handle(pendingEvents.removeFirst())
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
                refreshPresentation()
                handler?.showGuideWindow()
            case .closeGuide:
                refreshPresentation()
                handler?.closeGuideWindow()
            case let .startPermissionEpisode(purpose, episode):
                startEpisode(purpose: purpose, episode: episode)
            case .stopPermissionEpisode:
                stopEpisode()
            case .requestSystemPrompt:
                model?.requestSystemPromptIfNeeded()
            case .recheckNow:
                model?.checkNow()
            case .startWatchdog:
                handler?.startWatchdog()
            case .stopWatchdog:
                handler?.stopWatchdog()
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
}
