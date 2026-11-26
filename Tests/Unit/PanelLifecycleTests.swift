import AppKit
import Combine
import Synchronization
import XCTest

@MainActor
private final class PanelInventory: WindowInventoryTracking {
    let initial: DockSnapshot
    var snapshots: AnyPublisher<DockSnapshot, Never> { Just(initial).eraseToAnyPublisher() }
    private(set) var frontmostRefreshes = 0

    init(_ initial: DockSnapshot = .empty) { self.initial = initial }
    func start() {}
    func stop() {}
    func refreshFrontmostWindow() { frontmostRefreshes += 1 }
}

@MainActor
final class PanelLifecycleTests: XCTestCase {
    private final class DetachedDockPanel: NSPanel {
        var onOrderOut: (() -> Void)?
        var onOrderFront: (() -> Void)?
        var ordered = false
        var activeSpace = true
        var fullyOccluded = false

        override var isVisible: Bool { ordered }
        override var isOnActiveSpace: Bool { activeSpace }
        override var occlusionState: NSWindow.OcclusionState { ordered && !fullyOccluded ? [.visible] : [] }

        override func orderOut(_ sender: Any?) {
            ordered = false
            onOrderOut?()
        }

        override func orderFrontRegardless() {
            ordered = true
            onOrderFront?()
        }

        override func close() {}
    }

    #if DEBUG
    func testVisibilityJournalRecordsNativeLossEvenWhenThePanelIsStillRequested() throws {
        let lines = Mutex<[Data]>([])
        let journal = TaskbarVisibilityJournal { line in lines.withLock { $0.append(line) } }
        let visible = TaskbarVisibilitySample(windowNumber: 25, primaryDisplay: true,
                                              requestedVisible: true, spaceState: "desktop", appKitVisible: true,
                                              onActiveSpace: true, occlusionVisible: true, alpha: "opaque")
        let lost = TaskbarVisibilitySample(windowNumber: 25, primaryDisplay: true,
                                           requestedVisible: true, spaceState: "desktop", appKitVisible: true,
                                           onActiveSpace: false, occlusionVisible: false, alpha: "opaque")
        journal.capture(visible)
        journal.capture(visible)
        journal.capture(lost, source: "appkit-occlusion")
        journal.capture(visible, event: "order-front", source: "managed-space")
        journal.flush()

        let values = try lines.withLock { $0 }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(values.map { $0["event"] as? String }, ["observed", "observed", "order-front"])
        let changed = try XCTUnwrap(values.dropFirst().first)
        let interrupted = try XCTUnwrap(changed["state"] as? [String: Any])
        XCTAssertEqual(interrupted["primaryDisplay"] as? Bool, true)
        XCTAssertEqual(interrupted["requestedVisible"] as? Bool, true)
        XCTAssertEqual(interrupted["onActiveSpace"] as? Bool, false)
        XCTAssertEqual(interrupted["spaceState"] as? String, "desktop")
        XCTAssertNotNil(changed["timestamp"] as? String)
        XCTAssertEqual(values.last?["source"] as? String, "managed-space")
    }
    #endif

    func testInitialPresentationWaitsForConfirmedDesktop() {
        let coordinator = coordinator()
        defer { coordinator.tearDown() }
        let panel = DetachedDockPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        coordinator.dockPanel = panel
        var frontOrders = 0
        panel.onOrderFront = { frontOrders += 1 }

        coordinator.presentInitialPanels()

        XCTAssertEqual(frontOrders, 0)
        XCTAssertFalse(coordinator.panelsAreVisible)
        XCTAssertEqual(coordinator.visibilityState, .unknown)
    }

    func testConfirmedDesktopRestoresOnlyItsPanelWhileMembershipReadIsBlocked() async throws {
        let initial = [
            "left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [2], currentSpaceID: 2),
            "right": SpaceLayoutSnapshot(orderedSpaceIDs: [3, 4], fullscreenSpaceIDs: [4], currentSpaceID: 4),
        ]
        let layouts = Mutex(initial)
        let shouldBlock = Mutex(false)
        let blocked = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let layoutReadOnMain = Mutex(false)
        let notifications = NotificationCenter()
        let store = TaskbarSpaceStore(read: { requests in
            if !requests.isEmpty, shouldBlock.withLock({ $0 }) {
                blocked.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 3)
            }
            return .init(layouts: layouts.withLock { $0 },
                         memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, [1]) }))
        }, notifications: notifications, readLayouts: {
            if Thread.isMainThread { layoutReadOnMain.withLock { $0 = true } }
            return .success(layouts.withLock { $0 })
        })
        let topology = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"],
                                              attributionTable: .empty)
        let window = WindowRecord(id: WindowID(rawValue: "left-window"), appID: AppID(rawValue: "test.editor"), pid: 42,
                                  bundleIdentifier: nil, title: "Document", bounds: nil, status: .inactive,
                                  cgWindowID: 10, isOnDesktop: true, groupID: "tabgrp-left", displayUUID: "left")
        let inventory = PanelInventory(.init(windows: [window.id: window], orderedWindowIDs: [window.id]))
        let runtime = AppRuntime(tracker: inventory)
        let orchestrator = TaskbarScreenOrchestrator(
            runtime: runtime, stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology), spaceStore: store,
            topologySnapshotProvider: { topology }, startCoordinator: { _ in true },
            workspaceNotifications: notifications, frontmostApplicationPID: { nil }, makeGeometryObserver: { nil }
        )
        defer {
            shouldBlock.withLock { $0 = false }
            release.signal()
            orchestrator.suspendAndRelease()
            runtime.stop()
        }
        runtime.start()
        orchestrator.start()
        let left = try XCTUnwrap(orchestrator.units.first { $0.key == "left" }?.coordinator)
        let right = try XCTUnwrap(orchestrator.units.first { $0.key == "right" }?.coordinator)
        await waitUntil { left.visibilityState == .fullscreen && right.visibilityState == .fullscreen }
        XCTAssertEqual(left.visibilityState, .fullscreen)
        XCTAssertEqual(right.visibilityState, .fullscreen)
        XCTAssertFalse(layoutReadOnMain.withLock { $0 })

        shouldBlock.withLock { $0 = true }
        layouts.withLock { $0["left"] = .init(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1) }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { left.visibilityState == .desktop && blocked.withLock { $0 } }

        XCTAssertTrue(blocked.withLock { $0 })
        XCTAssertEqual(left.visibilityState, .desktop)
        XCTAssertEqual(right.visibilityState, .fullscreen)
        XCTAssertEqual(inventory.frontmostRefreshes, 1)
        XCTAssertFalse(layoutReadOnMain.withLock { $0 })
    }

    func testSuspendedPanelRejectsLaterSpaceVerdict() {
        let coordinator = coordinator()
        coordinator.applySpaceFullscreen(true, source: "managed-space")
        XCTAssertEqual(coordinator.visibilityState, .fullscreen)

        coordinator.tearDown()
        coordinator.applySpaceFullscreen(false, source: "late-event")

        XCTAssertEqual(coordinator.visibilityState, .unknown)
        XCTAssertFalse(coordinator.panelsAreVisible)
    }

    func testUnavailableSpaceCannotShowPanelAndFreshDesktopRestoresDecision() {
        let coordinator = coordinator()
        coordinator.applySpaceFullscreen(false, source: "managed-space")
        XCTAssertEqual(coordinator.visibilityState, .desktop)

        coordinator.applySpaceUnavailable(source: "layout-unavailable")
        XCTAssertEqual(coordinator.visibilityState, .unknown)
        XCTAssertFalse(coordinator.visibilityState.isVisible)

        coordinator.applySpaceFullscreen(false, source: "managed-space")
        XCTAssertEqual(coordinator.visibilityState, .desktop)
    }

    func testVisibilityHideCancelsInteractionsOnceBeforeOrderingOut() {
        let coordinator = coordinator()
        defer { coordinator.tearDown() }
        let panel = DetachedDockPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let popup = BehaviorPopup()
        coordinator.dockPanel = panel
        coordinator.taskbarView = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        coordinator.panelsAreVisible = true
        var effects: [String] = []
        popup.onDismiss = { effects.append("cancel interaction") }
        panel.onOrderOut = { effects.append("order out") }

        coordinator.applySpaceFullscreen(true, source: "managed-space")
        coordinator.applySpaceFullscreen(true, source: "duplicate")

        XCTAssertEqual(effects, ["cancel interaction", "order out"])
    }

    func testRelayoutWithoutAScreenCancelsInteractionsBeforeOrderingOut() {
        let coordinator = coordinator()
        defer { coordinator.tearDown() }
        let panel = DetachedDockPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let popup = BehaviorPopup()
        coordinator.dockPanel = panel
        coordinator.taskbarView = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        var effects: [String] = []
        popup.onDismiss = { effects.append("cancel interaction") }
        panel.onOrderOut = { effects.append("order out") }

        coordinator.relayout()

        XCTAssertEqual(effects, ["cancel interaction", "order out"])
    }

    func testPanelCreationAndPlacementWaitForAnAvailableScreen() {
        let coordinator = coordinator()
        XCTAssertFalse(coordinator.start())
        XCTAssertNil(coordinator.dockPanel)
        XCTAssertNil(coordinator.currentScreen)
        let panel = DetachedDockPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        XCTAssertNil(coordinator.panelCurrentScreen(panel: panel))
        coordinator.dockPanel = panel
        coordinator.relayout()
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
    }

    func testFixedPanelDoesNotShowOnTheFallbackDisplay() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("NSScreen is unavailable") }
        let coordinator = coordinator(placement: .fixed(displayUUID: UUID().uuidString),
                                      screens: { [screen] }, mainScreen: { screen })
        defer { coordinator.tearDown() }
        let panel = DetachedDockPanel(contentRect: TaskbarMetrics.panelFrame(on: screen.frame),
                                      styleMask: .borderless, backing: .buffered, defer: true)
        coordinator.dockPanel = panel
        coordinator.relayout()
        XCTAssertEqual(coordinator.currentScreen, screen)

        coordinator.applySpaceFullscreen(false, source: "managed-space")

        XCTAssertEqual(coordinator.visibilityState, .desktop)
        XCTAssertFalse(panel.ordered)
        XCTAssertFalse(coordinator.panelsAreVisible)
    }

    func testResidentPanelUsesNativeMissionControlHidingWithoutDesktopPresentation() {
        let coordinator = coordinator()
        let panel = NonConstrainingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        coordinator.configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)

        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
    }

    func testDesktopSpaceChangeDismissesAnOpenPopupSynchronously() {
        let coordinator = coordinator()
        let popup = BehaviorPopup()
        coordinator.taskbarView = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        coordinator.applySpaceFullscreen(false, source: "managed-space")
        popup.present(content: NSView(), frame: .zero, anchorWindow: nil)
        XCTAssertTrue(popup.isPresented)

        coordinator.spaceWillChange()

        XCTAssertFalse(popup.isPresented)
        XCTAssertEqual(coordinator.visibilityState, .desktop)
        coordinator.tearDown()
    }

    func testHeightAdjustmentReceivesOnlyTheVisibleSmallPanelOnActiveSpace() {
        let coordinator = coordinator()
        defer { coordinator.tearDown() }
        let frame = CGRect(x: 0, y: 0, width: 800, height: TaskbarMetrics.height)
        let panel = DetachedDockPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        coordinator.dockPanel = panel
        coordinator.applySpaceFullscreen(false, source: "managed-space")
        coordinator.panelsAreVisible = true
        panel.ordered = true

        XCTAssertEqual(coordinator.visibleTaskbarFrame, frame)
        XCTAssertEqual(coordinator.visibleTaskbarFrame?.height, 32)
        panel.fullyOccluded = true
        XCTAssertNil(coordinator.visibleTaskbarFrame)
        panel.fullyOccluded = false
        XCTAssertEqual(coordinator.visibleTaskbarFrame, frame)
        panel.activeSpace = false
        XCTAssertNil(coordinator.visibleTaskbarFrame)
        panel.activeSpace = true
        coordinator.applySpaceFullscreen(true, source: "managed-space")
        XCTAssertNil(coordinator.visibleTaskbarFrame)
    }

    func testDisplayDisconnectAndReconnectRebuildUnitsWithoutShowingPanels() {
        var snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        var starts = 0
        let orchestrator = TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: snapshot),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter()),
            topologySnapshotProvider: { snapshot }, startCoordinator: { _ in starts += 1; return true }, makeGeometryObserver: { nil })
        orchestrator.start()
        XCTAssertTrue(orchestrator.units.isEmpty)
        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"], attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(orchestrator.units.map(\.key), ["A", "B"])
        XCTAssertEqual(starts, 2)
        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(orchestrator.units.isEmpty)
        orchestrator.suspendAndRelease()
    }

    private func coordinator(placement: TaskbarUnitPlacement = .primary,
                             screens: @escaping @MainActor () -> [NSScreen] = { [] },
                             mainScreen: @escaping @MainActor () -> NSScreen? = { nil }) -> PanelCoordinator {
        PanelCoordinator(placement: placement, runtime: AppRuntime(tracker: PanelInventory()),
                         stripOrderStore: StripOrderStore(),
                         displayTopologyStore: DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
                            physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)),
                         screenProvider: screens, mainScreenProvider: mainScreen)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    }
}
