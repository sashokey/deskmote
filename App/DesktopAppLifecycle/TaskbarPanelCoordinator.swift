import AppKit
import Combine
#if DEBUG
import os
#endif

@MainActor
final class PanelCoordinator: NSObject {
    var panelHeight: CGFloat { TaskbarMetrics.height }
    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }
    let runtime: AppRuntime
    let stripOrderStore: StripOrderStore
    let spaceStore: TaskbarSpaceStore
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockContentHost: ManualPanelHost?
    var taskbarView: TaskbarView?
    var taskbarPresenter: TaskbarPresenter?
    var isSuspendedForPermissionLoss = false
    var displayTopologySubscription: AnyCancellable?
    #if DEBUG
    let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "dock-panel")
    let taskbarVisibilityJournal = TaskbarVisibilityJournal.live()
    var panelVisibilitySampler: Timer?
    var diagnosticFullscreenCandidate: CGWindowID?
    #endif
    var fullscreenProbeWorker: FullscreenProbeWorker?
    var fullscreenFrameProvider: (() -> CGRect?)?
    var fullscreenDisplayUUIDProvider: (() -> String?)?
    var fullscreenSpaceProvider: (@Sendable (String) -> Bool?)?
    var fullscreenCGWindowsProvider: (() -> [[String: Any]]?)?
    var fullscreenCGWindowObservationProvider: ((CGWindowID) -> (isOnscreen: Bool, bounds: CGRect?)?)?
    var fullscreenCGConfirmation: FullscreenCGConfirmation?
    var fullscreenProbeGeneration: UInt64 = 0
    var fullscreenSpaceHoldGeneration: UInt64 = 0
    var fullscreenSpaceHold: FullscreenSpaceHold?
    var fullscreenSpaceHoldTimer: Timer?
    static let overlayWindowWatchEnabled =
        DebugSwitch.overlayWindowWatch.isEnabled(in: ProcessInfo.processInfo.environment)
    var overlayWindowWatchTimer: Timer?
    var overlayWindowWatchID: CGWindowID?
    var lastHideWasForFullscreen = false
    static let spaceMembershipRepairEnabled =
        DebugSwitch.spaceMembershipRepair.isEnabled(in: ProcessInfo.processInfo.environment)
    var spaceMembershipRepairInFlight = false
    var lastActiveApplicationPID: pid_t?
    var visibilityState = PanelVisibilityState()
    var panelsAreVisible = true
    var onAccessoryInteraction: ((PanelCoordinator, AccessoryKind) -> Bool)?

    enum AccessoryKind { case explicit, implicit, backgroundClick }


    let unitPlacement: TaskbarUnitPlacement
    let overlaySpaceHost: OverlaySpaceHost?
    let fullscreenSLSVerdictEnabled: Bool
    let displayTopologyStore: DisplayTopologyStore
    let screenProvider: @MainActor () -> [NSScreen]
    let mainScreenProvider: @MainActor () -> NSScreen?
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
         stripOrderStore: StripOrderStore,
         displayTopologyStore: DisplayTopologyStore,
         spaceStore: TaskbarSpaceStore = TaskbarSpaceStore(),
         fullscreenSLSVerdictEnabled: Bool = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment),
         screenProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
         mainScreenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main }) {
        self.unitPlacement = placement
        self.overlaySpaceHost = overlaySpaceHost
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.displayTopologyStore = displayTopologyStore
        self.spaceStore = spaceStore
        self.fullscreenSLSVerdictEnabled = fullscreenSLSVerdictEnabled
        self.screenProvider = screenProvider
        self.mainScreenProvider = mainScreenProvider
        super.init()
    }

    func start() -> Bool {
        guard !isSuspendedForPermissionLoss, dockPanel == nil else { return false }
        guard setupDockPanel() else { return false }
        presentInitialPanels()
        pinResidentPanelsIfNeeded()
        subscribeSettings()
        setupFullscreenMonitor()
        #if DEBUG
        startPanelVisibilitySampling()
        #endif
        return true
    }

    isolated deinit {
        #if DEBUG
        panelVisibilitySampler?.invalidate()
        #endif
        fullscreenProbeWorker?.stop()
        fullscreenSpaceHoldTimer?.invalidate()
        overlayWindowWatchTimer?.invalidate()
        taskbarView?.taskbarContent.prepareForHiding()
    }

    func tearDown(source: String = "teardown") {
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        fullscreenProbeGeneration &+= 1
        fullscreenProbeWorker?.stop()
        fullscreenProbeWorker = nil
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
        fullscreenCGConfirmation = nil
        endOverlayWindowWatch()
        displayTopologySubscription?.cancel()
        displayTopologySubscription = nil
        taskbarPresenter?.setPanelVisible(false)
        #if DEBUG
        panelVisibilitySampler?.invalidate()
        panelVisibilitySampler = nil
        #endif
        orderDockSurfaceOut(source: source)
        taskbarPresenter = nil
        dockContentHost = nil
        taskbarView = nil
        dockPanel?.contentView = NSView()
        dockPanel?.close()
        dockPanel = nil
    }

    func dismissTaskbarPopups() {
        taskbarView?.taskbarContent.dismissPopups()
    }

    var currentScreen: NSScreen? { dockPanel.flatMap { panelCurrentScreen(panel: $0) } }
    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        guard let screen = panelCurrentScreen(panel: panel) else { return nil }
        let primaryDisplayHeight = Self.quartzPrimaryScreenHeight
        let visibleFrame = screen.visibleFrame
        let topReservedHeight = max(screen.safeAreaInsets.top,
            max(NSApplication.shared.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness))
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: visibleFrame,
            taskbarTopEdge: screen.frame.minY + TaskbarMetrics.height,
            topReservedHeight: topReservedHeight
        )
        return WindowLiftAvoidanceContext(
            geometry: geometry,
            displayWindowServerFrame: Self.toCGRect(screen),
            usableWindowServerFrame: WindowLiftAvoidance.windowServerFrame(
                fromAppKit: visibleFrame,
                primaryDisplayHeight: primaryDisplayHeight
            ),
            primaryDisplayHeight: primaryDisplayHeight
        )
    }


    var allSpacesPanels: [NSPanel] { [dockPanel].compactMap { $0 } }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen? {
        let visualCenter = CGPoint(x: panel.frame.midX, y: panel.frame.minY + panelHeight / 2)
        let screens = screenProvider()
        return screens.first(where: { $0.frame.contains(visualCenter) })
            ?? screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? mainScreenProvider() ?? screens.first
    }

    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.minX, y: quartzPrimaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .primary: return nil
        }
    }
}
