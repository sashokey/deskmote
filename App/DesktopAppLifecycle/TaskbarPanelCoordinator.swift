import AppKit
import Combine

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
    let taskbarVisibilityJournal = TaskbarVisibilityJournal.live()
    var panelVisibilityObserver: NSObjectProtocol?
    #endif
    var lastHideWasForFullscreen = false
    var visibilityState = PanelVisibilityState.unknown
    var panelsAreVisible = false
    var onAccessoryInteraction: ((PanelCoordinator, AccessoryKind) -> Bool)?

    enum AccessoryKind { case explicit, implicit, backgroundClick }


    let unitPlacement: TaskbarUnitPlacement
    let displayTopologyStore: DisplayTopologyStore
    let screenProvider: @MainActor () -> [NSScreen]
    let mainScreenProvider: @MainActor () -> NSScreen?
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         runtime: AppRuntime,
         stripOrderStore: StripOrderStore,
         displayTopologyStore: DisplayTopologyStore,
         spaceStore: TaskbarSpaceStore = TaskbarSpaceStore(),
         screenProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
         mainScreenProvider: @escaping @MainActor () -> NSScreen? = { NSScreen.main }) {
        self.unitPlacement = placement
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.displayTopologyStore = displayTopologyStore
        self.spaceStore = spaceStore
        self.screenProvider = screenProvider
        self.mainScreenProvider = mainScreenProvider
        super.init()
    }

    func start() -> Bool {
        guard !isSuspendedForPermissionLoss, dockPanel == nil else { return false }
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.panel.attach")
        defer { span?.finish() }
        #endif
        guard setupDockPanel() else { return false }
        presentInitialPanels()
        subscribeSettings()
        #if DEBUG
        startPanelVisibilityObservation()
        #endif
        return true
    }

    isolated deinit {
        #if DEBUG
        stopPanelVisibilityObservation()
        #endif
        taskbarView?.taskbarContent.prepareForHiding()
    }

    func tearDown(source: String = "teardown") {
        guard !isSuspendedForPermissionLoss else { return }
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.panel.release")
        defer { span?.finish() }
        #endif
        isSuspendedForPermissionLoss = true
        panelsAreVisible = false
        visibilityState = .unknown
        displayTopologySubscription?.cancel()
        displayTopologySubscription = nil
        taskbarPresenter?.setPanelVisible(false)
        #if DEBUG
        stopPanelVisibilityObservation()
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
    var visibleTaskbarFrame: CGRect? {
        guard panelsAreVisible, visibilityState.isVisible, let panel = dockPanel,
              panel.isVisible, panel.isOnActiveSpace, panel.occlusionState.contains(.visible) else { return nil }
        return panel.frame
    }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen? {
        let visualCenter = CGPoint(x: panel.frame.midX, y: panel.frame.minY + panelHeight / 2)
        let screens = screenProvider()
        return screens.first(where: { $0.frame.contains(visualCenter) })
            ?? screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? mainScreenProvider() ?? screens.first
    }

}
