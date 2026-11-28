import AppKit
import Combine
import CoreGraphics
import Darwin
import QuartzCore
import SwiftUI

@MainActor
struct ApplicationEnvironment {
    var bundleURL = Bundle.main.bundleURL
    var permissionService = PermissionService()
    var permissionProbe: @Sendable () -> Bool = { PermissionService().hasRequiredPermissions() }
    var runtimeAccessibilityAccess = RuntimeAccessibilityAccess()
    var makeModules: (@MainActor (@escaping UtilityWindowRegistration) -> [DeskMoteModule])?
    var permissionClock: @Sendable () -> DispatchTime = DispatchTime.now
    var schedulePermissionDeadline: RuntimePermissionWatchdog.Schedule?
    var forceExit: @Sendable () -> Void = {}
    var moduleSessionIsActive: @MainActor () -> Bool = {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
    }
    var moduleSessionNotifications = NSWorkspace.shared.notificationCenter
    var retirePreviousInstances: @MainActor @Sendable () -> (@MainActor @Sendable () async -> Bool)? = {
        AppDelegate.retirePreviousInstances()
    }
    var resetAppearance: @MainActor @Sendable () -> Void = { NSApp.appearance = nil }
    var setActivationPolicy: @MainActor @Sendable (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }
    var activateApplication: @MainActor @Sendable () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var terminate: @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    var makeStatusItem: @MainActor @Sendable () -> any StatusItemPresenting = { NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
    var makePermissionWindow: @MainActor @Sendable (NSRect, NSWindow.StyleMask) -> NSWindow = {
        NSWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: false)
    }
    var makePanels: @MainActor @Sendable (AppRuntime, StripOrderStore, DisplayTopologyStore) -> TaskbarScreenOrchestrator = {
        TaskbarScreenOrchestrator(runtime: $0, stripOrderStore: $1, displayTopologyStore: $2)
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var localizedDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "DeskMote"
    }

    private let environment: ApplicationEnvironment
    let displayTopologyStore: DisplayTopologyStore
    private(set) lazy var runtime = AppRuntime(
        accessibilityAccess: environment.runtimeAccessibilityAccess,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table }
    )
    lazy var stripOrderStore = StripOrderStore()
    private var panelCoordinator: TaskbarScreenOrchestrator?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        launchAtLoginService: launchAtLoginService
    )
    private var startupTask: Task<Void, Never>?
    private var spaceCompatibilityAlert: NSAlert?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var permissionService: PermissionService { environment.permissionService }
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: DispatchSourceTimer?
    private let permissionProbeQueue = DispatchQueue(label: "io.github.sashokey.deskmote.permission-probe", qos: .utility)
    private let permissionProtectionQueue = DispatchQueue(label: "io.github.sashokey.deskmote.permission-protection",
                                                          qos: .userInitiated)
    private var permissionSleepObservers: [NSObjectProtocol] = []
    private var permissionSleeping = false
    private var permissionStopping = false
    private(set) lazy var permissionWatchdog: RuntimePermissionWatchdog = makePermissionWatchdog()

    private func makePermissionWatchdog() -> RuntimePermissionWatchdog {
        RuntimePermissionWatchdog(
            access: environment.runtimeAccessibilityAccess,
            now: environment.permissionClock,
            schedule: environment.schedulePermissionDeadline ?? { [permissionProtectionQueue] time, work in
                permissionProtectionQueue.asyncAfter(deadline: time, execute: work)
            },
            requestQuit: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.permissionCoordinator?.terminationRequested()
                    self?.requestTermination()
                }
            },
            forceExit: environment.forceExit,
            notifyReady: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.restoreReadyAccessibilityModules() }
            }
        )
    }
    private func restoreReadyAccessibilityModules() {
        guard permissionWatchdog.isReady, environment.moduleSessionIsActive() else { return }
        moduleToggles.forEach { $0.accessibilityChanged(trusted: true) }
    }

    private var hasStartedApp = false
    private lazy var modules: [DeskMoteModule] = {
        let register: UtilityWindowRegistration = { [weak self] window in self?.runtime.registerUtilityWindow(window) }
        let result = environment.makeModules?(register) ?? DeskMoteModuleRegistry.production(
            registerWindow: register, watchdog: permissionWatchdog)
        for case let .toggle(toggle) in result {
            toggle.mayStartWithAccessibility = { [weak self] in self?.permissionWatchdog.isReady == true }
            toggle.requestStartupPermission = { [weak self] in
                guard let self, self.permissionCoordinator?.phase != .running,
                      self.permissionWatchdog.canRequestStartupPrompt else { return }
                _ = self.permissionService.requestAccessibilityPermission()
            }
        }
        return result
    }()
    private var moduleSessionObserver: NSObjectProtocol?
    private var needsModuleRestore = false
    private var moduleToggles: [DeskMoteModuleToggle] {
        modules.compactMap { module in
            guard case let .toggle(toggle) = module else { return nil }
            return toggle
        }
    }
    private lazy var statusMenuController = StatusMenuController(
        settingsCoordinator: settingsCoordinator,
        statusItem: environment.makeStatusItem(), modules: modules, quit: { [weak self] in
            self?.requestTermination()
        }
    )

    override convenience init() {
        let access = RuntimeAccessibilityAccess.shared
        _ = access.updateTrust(false)
        var environment = ApplicationEnvironment(runtimeAccessibilityAccess: access)
        environment.forceExit = { Darwin._exit(EXIT_FAILURE) }
        self.init(environment: environment)
    }

    init(environment: ApplicationEnvironment, runtime: AppRuntime? = nil,
         displayTopologyStore: DisplayTopologyStore? = nil,
         stripOrderStore: StripOrderStore? = nil) {
        self.environment = environment
        self.displayTopologyStore = displayTopologyStore ?? DisplayTopologyStore(initialSnapshot: DisplayIdentity.topologySnapshot())
        super.init()
        if let runtime { self.runtime = runtime }
        if let stripOrderStore { self.stripOrderStore = stripOrderStore }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {


        environment.resetAppearance()

        let location = AppInstallLocation(
            bundleURL: environment.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        guard !location.isTransient, let waitForExit = environment.retirePreviousInstances() else {
            finishLaunching(at: location)
            return
        }
        startupTask = Task { @MainActor [weak self] in
            let ready = await waitForExit()
            guard !Task.isCancelled, let self else { return }
            self.startupTask = nil
            if ready {
                self.finishLaunching(at: location)
            } else {
                self.requestTermination()
            }
        }
    }

    private func finishLaunching(at location: AppInstallLocation) {
        let trusted = permissionService.hasRequiredPermissions()

        if !location.isTransient {
            restoreModulesWhenSessionIsActive()
            _ = statusMenuController
        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    private func restoreModulesWhenSessionIsActive() {
        guard !moduleToggles.isEmpty else { return }
        needsModuleRestore = true
        moduleSessionObserver = environment.moduleSessionNotifications.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.moduleSessionObserver != nil else { return }
                self.restoreOrRetryModules()
            }
        }
        if environment.moduleSessionIsActive() { restoreOrRetryModules() }
    }

    private func restoreOrRetryModules() {
        if needsModuleRestore {
            needsModuleRestore = false
            moduleToggles.forEach { $0.restore() }
        } else {
            moduleToggles.forEach { $0.retryWaiting() }
        }
    }

    private func stopModules() {
        needsModuleRestore = false
        if let moduleSessionObserver {
            environment.moduleSessionNotifications.removeObserver(moduleSessionObserver)
            self.moduleSessionObserver = nil
        }
        if !installLocation.isTransient { moduleToggles.forEach { $0.stop() } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard permissionCoordinator != nil else { return false }
        guard !installLocation.isTransient else { return true }
        statusMenuController.showStatusBarIcon()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let permissionCoordinator else { return }
        permissionCoordinator.applicationDidBecomeActive()
        schedulePermissionProbe()
        if !installLocation.isTransient {
            if environment.moduleSessionIsActive() { restoreOrRetryModules() }
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }


    fileprivate static func retirePreviousInstances() -> (@MainActor @Sendable () async -> Bool)? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let origin = ApplicationOrigin(bundleURL: Bundle.main.bundleURL) else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated
                && ApplicationOrigin(bundleURL: $0.bundleURL) == origin }
        guard !others.isEmpty else { return nil }
        guard let myStart = ProcessLiveness.startTime(pid: myPID) else { return { false } }

        let myRank = (myStart.tv_sec, myStart.tv_usec, myPID)
        var earlier: [(NSRunningApplication, ProcessGeneration)] = []
        for app in others {
            let pid = app.processIdentifier
            guard let start = ProcessLiveness.startTime(pid: pid) else {
                if ProcessLiveness.isAlive(pid: pid) { return { false } }
                continue
            }
            if (start.tv_sec, start.tv_usec, pid) < myRank {
                earlier.append((app, ProcessGeneration(start)))
            }
        }
        guard !earlier.isEmpty else { return nil }

        let predecessors = earlier
        return {
            guard !Task.isCancelled else { return false }
            let deadline = ContinuousClock.now + .seconds(10)
            for (app, expected) in predecessors {
                guard !app.isTerminated,
                      ProcessLiveness.startTime(pid: app.processIdentifier).map(ProcessGeneration.init) == expected,
                      ApplicationOrigin(bundleURL: app.bundleURL) == origin else { continue }
                _ = app.terminate()
            }

            while predecessors.contains(where: { app, expected in
                guard !app.isTerminated else { return false }
                let pid = app.processIdentifier
                guard let current = ProcessLiveness.startTime(pid: pid) else {
                    return ProcessLiveness.isAlive(pid: pid)
                }
                return ProcessGeneration(current) == expected
            }) {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !Task.isCancelled
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        stopModules()
        panelCoordinator?.stopWindowHeightPolling()
        if hasStartedApp { runtime.stop() }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        stopModules()
        panelCoordinator?.stopWindowHeightPolling()
        if hasStartedApp { runtime.stop() }
    }

    private func showPermissionWindow() {
        guard let coordinator = permissionCoordinator else { return }
        if let permissionWindow {
            resizePermissionWindowToFit()
            permissionWindow.makeKeyAndOrderFront(nil)
            environment.activateApplication()
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = environment.makePermissionWindow(
            NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260), [.titled, .miniaturizable]
        )
        window.title = Self.localizedDisplayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        environment.activateApplication()
    }

    private func resizePermissionWindowToFit() {
        guard let window = permissionWindow, let coordinator = permissionCoordinator else { return }

        let probe = NSHostingView(rootView: PermissionOnboardingView(coordinator: coordinator))
        probe.setFrameSize(NSSize(width: PermissionOnboardingView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(200, min(natural, available - 80))
        let size = NSSize(width: PermissionOnboardingView.contentWidth, height: height)
        guard window.contentView?.frame.size != size else { return }

        let before = window.frame
        window.setContentSize(size)
        let after = window.frame
        window.setFrameOrigin(NSPoint(
            x: before.midX - after.width / 2,
            y: before.midY - after.height / 2
        ))
    }

    private func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        permissionHostingView = nil
    }

    private func startTaskbarRuntime() {
        runtime.start()
        guard environment.runtimeAccessibilityAccess.allowsCalls else { return }
        let coordinator = environment.makePanels(runtime, stripOrderStore, displayTopologyStore)
        coordinator.leadingSlotFactory = DeskMoteModuleRegistry.makeLeadingSlotFactory()
        panelCoordinator = coordinator
        coordinator.windowAdjustmentAllowed = { [weak self] in
            guard let self else { return false }
            return self.permissionCoordinator?.phase == .running && self.environment.runtimeAccessibilityAccess.allowsCalls
        }
        coordinator.onSpaceCompatibilityFailure = { [weak self] code, details in
            self?.showSpaceCompatibilityNotice(code: code, details: details)
        }
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
    }

    private func showSpaceCompatibilityNotice(code: String, details: String) {
        let alert = spaceCompatibilityAlert ?? NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "DeskMote Couldn’t Read Spaces")
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let build = Bundle.main.object(forInfoDictionaryKey: "DeskMoteSourceRevision") as? String ?? "-"
        let diagnostic = "\(code)\n\(details)\n\(macOS) · \(build)"
        alert.informativeText = diagnostic
        let button = alert.buttons.first ?? alert.addButton(withTitle: String(localized: "OK"))
        let window = alert.window
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.closable)
        window.level = .floating
        button.target = window
        button.action = #selector(NSWindow.performClose(_:))
        spaceCompatibilityAlert = alert
        alert.layout()
        window.center()
        window.orderFrontRegardless()
    }


}

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
        let watchdog = permissionWatchdog
        let queue = permissionProtectionQueue
        environment.runtimeAccessibilityAccess.activateRuntime { [weak watchdog] _ in
            queue.async { [weak watchdog] in watchdog?.requiredPermissionLost() }
        }
        hasStartedApp = true
        if environment.moduleSessionIsActive() { restoreOrRetryModules() }
        startTaskbarRuntime()
    }

    func setActivationPolicy(_ policy: PermissionActivationPolicy) {
        switch policy {
        case .accessory:
            environment.setActivationPolicy(.accessory)
        case .regular:
            environment.setActivationPolicy(.regular)
        }
    }

    func showGuideWindow() { showPermissionWindow() }
    func updateGuideWindow() { resizePermissionWindowToFit() }
    func closeGuideWindow() { closePermissionWindow() }

    func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func terminateSelf() {
        requestTermination()
    }

    private func requestTermination() {
        environment.terminate()
    }

    func startWatchdog() {
        guard !permissionStopping, !permissionSleeping, permissionWatchdogTimer == nil,
              environment.runtimeAccessibilityAccess.allowsCalls else { return }
        installPermissionSleepObservers()
        let watchdog = permissionWatchdog
        let generation = watchdog.start()
        let timer = DispatchSource.makeTimerSource(queue: permissionProtectionQueue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .milliseconds(100))
        let submit = makePermissionProbe()
        let tick: @Sendable () -> Void = { submit(generation) }
        timer.setEventHandler(handler: tick)
        permissionWatchdogTimer = timer
        timer.activate()
        submit(generation)
    }

    func stopWatchdog() {
        permissionStopping = true
        permissionWatchdog.stop()
        permissionWatchdogTimer?.cancel()
        permissionWatchdogTimer = nil
        permissionSleepObservers.forEach(environment.moduleSessionNotifications.removeObserver)
        permissionSleepObservers.removeAll()
    }

    func schedulePermissionProbe() {
        guard permissionWatchdogTimer != nil else { return }
        makePermissionProbe()(nil)
    }

    private func makePermissionProbe() -> @Sendable (UInt64?) -> Void {
        let watchdog = permissionWatchdog
        let queue = permissionProbeQueue
        let probe = environment.permissionProbe
        return { expectedRun in
            guard let reservation = watchdog.beginProbe(for: expectedRun) else { return }
            queue.async {
                let trusted = probe()
                watchdog.completeProbe(reservation, verdict: trusted)
            }
        }
    }

    private func installPermissionSleepObservers() {
        guard permissionSleepObservers.isEmpty else { return }
        let notifications = environment.moduleSessionNotifications
        permissionSleepObservers = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.permissionStopping else { return }
                    if name == NSWorkspace.willSleepNotification {
                        self.permissionSleeping = true
                        self.permissionWatchdog.stop()
                        self.permissionWatchdogTimer?.cancel()
                        self.permissionWatchdogTimer = nil
                    } else {
                        self.permissionSleeping = false
                        self.startWatchdog()
                    }
                }
            }
        }
    }


}

