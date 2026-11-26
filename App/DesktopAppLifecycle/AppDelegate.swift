import AppKit
import Combine
import CoreGraphics
import OSLog
import QuartzCore
import SwiftUI

@MainActor
struct ApplicationEnvironment {
    var bundleURL = Bundle.main.bundleURL
    var permissionService = PermissionService()
    var permissionProbe: @Sendable () -> Bool = { PermissionService().hasRequiredPermissions() }
    var runtimeAccessibilityAccess = RuntimeAccessibilityAccess()
    var makeModules: @MainActor (@escaping UtilityWindowRegistration) -> [DeskMoteModule] = DeskMoteModuleRegistry.production
    var moduleSessionIsActive: @MainActor () -> Bool = {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
    }
    var moduleSessionNotifications = NSWorkspace.shared.notificationCenter
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    var launchInstance: @MainActor @Sendable (URL) async -> Result<Void, Error> = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(returning: .failure(error)) }
                else { continuation.resume(returning: .success(())) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var localizedDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "DeskMote"
    }

    private let inventoryLog = WindowInventoryAnomalyLog()
    private let environment: ApplicationEnvironment
    let displayTopologyStore: DisplayTopologyStore
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table }
    )
    lazy var stripOrderStore = StripOrderStore(inventoryLog: inventoryLog)
    private var panelCoordinator: TaskbarScreenOrchestrator?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        launchAtLoginService: launchAtLoginService
    )
    private var startupTask: Task<Void, Never>?
    #if DEBUG
    private var mainLoopStallProbe: Timer?
    #endif
    private var spaceCompatibilityAlert: NSAlert?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var permissionService: PermissionService { environment.permissionService }
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: DispatchSourceTimer?
    private let permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "io.github.sashokey.deskmote.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private lazy var modules = environment.makeModules { [weak self] window in
        self?.runtime.registerUtilityWindow(window)
    }
    private var moduleSessionObserver: NSObjectProtocol?
    private var needsModuleRestore = false
    private var moduleToggles: [DeskMoteModuleToggle] {
        modules.compactMap { module in
            guard case let .toggle(toggle) = module else { return nil }
            return toggle
        }
    }
    private let permissionLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        settingsCoordinator: settingsCoordinator,
        statusItem: environment.makeStatusItem(), modules: modules, quit: { [weak self] in
            self?.requestTermination(source: "status-menu")
        }
    )

    override convenience init() {
        self.init(environment: ApplicationEnvironment(runtimeAccessibilityAccess: .shared))
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
        setvbuf(stdout, nil, _IOLBF, 0)

        #if DEBUG
        let resources = ActionResourceLog.begin("app.launch")
        defer { resources?.finish() }
        startMainLoopStallProbeIfTracing()
        #endif

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
                self.requestTermination(source: "previous-instance")
            }
        }
    }

    private func finishLaunching(at location: AppInstallLocation) {
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        #if DEBUG
        logPermissionLaunch(installLocation: location, isTrusted: trusted)
        #endif

        if !location.isTransient {
            restoreModulesWhenSessionIsActive()
            _ = statusMenuController
        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location, now: environment.now
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
        if !installLocation.isTransient {
            if environment.moduleSessionIsActive() { restoreOrRetryModules() }
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    #if DEBUG
    private func logPermissionLaunch(installLocation: AppInstallLocation, isTrusted: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info("""
            permission launch version=\(version, privacy: .public) \
            build=\(build, privacy: .public) \
            location=\(installLocation.rawValue, privacy: .public) \
            trusted=\(isTrusted, privacy: .public) \
            bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))
            """)
    }
    #endif

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
        #if DEBUG
        let resources = ActionResourceLog.begin("app.terminate")
        defer { resources?.finish() }
        #endif
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            permissionLogger.notice("application-termination-requested apple-event-class=\(event.eventClass, privacy: .public) apple-event-id=\(event.eventID, privacy: .public)")
        } else {
            permissionLogger.notice("application-termination-requested")
        }
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        stopModules()
        if hasStartedApp { runtime.stop() }

        panelCoordinator?.stopWindowGeometryObservation()
        permissionLogger.notice("application-termination-ready")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionLogger.notice("application-will-terminate")
        startupTask?.cancel()
        startupTask = nil
        permissionCoordinator?.terminationRequested()
        stopModules()
        panelCoordinator?.stopWindowGeometryObservation()
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
        #if DEBUG
        let resources = ActionResourceLog.begin("app.startTaskbarRuntime")
        defer { resources?.finish() }
        #endif
        runtime.start()
        let coordinator = environment.makePanels(runtime, stripOrderStore, displayTopologyStore)
        panelCoordinator = coordinator
        coordinator.windowAdjustmentAllowed = { [weak self] in self?.permissionCoordinator?.phase == .running }
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
        let guidance = String(localized: "Some taskbars or window buttons may be unavailable. In Console, search for the error code in the taskbar-spaces category.")
        alert.informativeText = "\(guidance)\n\n\(code)\n\(details)\n\(macOS) · \(build)"
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

    #if DEBUG
    private func startMainLoopStallProbeIfTracing() {
        guard HoverTrace.isEnabled else { return }
        let clock = StallProbeClock(expected: CACurrentMediaTime() + 0.008)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = CACurrentMediaTime()
            HoverTrace.mainLoopStall(lateMs: (now - clock.expected) * 1000)
            clock.expected = now + 0.008
        }
        RunLoop.main.add(timer, forMode: .common)
        mainLoopStallProbe = timer
    }
    #endif

}

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
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
        requestTermination(source: "permission-flow")
    }

    private func requestTermination(source: String) {
        permissionLogger.notice("application-termination-trigger source=\(source, privacy: .public)")
        environment.terminate()
    }

    func startWatchdog() {
        stopWatchdog()
        let generation = permissionWatchdogGate.start()
        let timer = DispatchSource.makeTimerSource(queue: permissionProbeQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler(handler: makePermissionProbe(generation: generation))
        permissionWatchdogTimer = timer
        timer.activate()
    }

    func stopWatchdog() {
        permissionWatchdogGate.stop()
        permissionWatchdogTimer?.cancel()
        permissionWatchdogTimer = nil
    }

    func schedulePermissionProbe() {
        permissionProbeQueue.async(execute: makePermissionProbe(generation: nil))
    }

    private func makePermissionProbe(generation expectedGeneration: UInt64?) -> @Sendable () -> Void {
        let gate = permissionWatchdogGate
        let access = environment.runtimeAccessibilityAccess
        let probe = environment.permissionProbe
        let logger = permissionLogger
        return { [weak self] in
            guard let generation = gate.beginProbe(for: expectedGeneration) else { return }
            let trustGeneration = access.trustGeneration
            let trusted = probe()
            var changed = false
            let enqueue = gate.completeProbe(generation: generation, deliver: trusted) {
                guard let didChange = access.updateTrust(trusted, for: trustGeneration) else { return false }
                changed = didChange
                return true
            }
            if changed { logger.notice("permission-probe-transition trusted=\(trusted, privacy: .public)") }
            guard enqueue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let trusted = gate.takeDelivery(generation: generation) else { return }
                let changed = self.cachedAccessibilityTrusted != trusted
                self.cachedAccessibilityTrusted = trusted
                if changed {
                    self.permissionLogger.notice("permission-trust-changed trusted=\(trusted, privacy: .public)")
                }
                self.moduleToggles.forEach {
                    $0.accessibilityChanged(trusted: trusted, canResume: self.environment.moduleSessionIsActive)
                }
                if changed { self.permissionLogger.notice("permission-modules-notified trusted=\(trusted, privacy: .public)") }
                self.permissionCoordinator?.sampleTrust(trusted)
                if changed { self.permissionLogger.notice("permission-trust-delivered trusted=\(trusted, privacy: .public)") }
            }
        }
    }

    func suspendPanelsAndStores() {
        #if DEBUG
        let resources = ActionResourceLog.begin("permission.suspendRuntime")
        defer { resources?.finish() }
        #endif
        permissionLogger.notice("permission-loss-suspension-started")
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        permissionLogger.notice("permission-loss-panels-suspended")
        runtime.stop()
        permissionLogger.notice("permission-loss-suspension-completed")
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        await environment.launchInstance(environment.bundleURL)
    }
}

#if DEBUG
private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
#endif
