import AppKit
import Combine
import Foundation

@MainActor
final class TaskbarScreenOrchestrator: NSObject {
    struct Unit {
        let key: String?
        let coordinator: PanelCoordinator
    }

    private struct PanelDisplayState: Equatable {
        let primary: String?
        let borderlessFullscreen: String?

        init(snapshot: DockSnapshot, table: WindowDisplayAttribution.Table) {
            primary = table.primaryUUID
            let frame = snapshot.windows.values.first {
                $0.status == .active && $0.bundleIdentifier == BorderlessFullscreenGame.bundleIdentifier
                    && $0.borderlessFullscreenFrame != nil
            }?.borderlessFullscreenFrame
            borderlessFullscreen = BorderlessFullscreenGame.display(for: frame, in: table)
        }
    }

    private(set) var units: [Unit] = []

    private let runtime: AppRuntime
    private let stripOrderStore: StripOrderStore
    private let displayTopologyStore: DisplayTopologyStore
    private let spaceStore: TaskbarSpaceStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let startCoordinator: (PanelCoordinator) -> Bool
    private let topologyRetryScheduler: DisplayTopologyRefreshController.ScheduleAfter

    var leadingSlotFactory: TaskbarLeadingSlotFactory?

    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var topologyRefreshController: DisplayTopologyRefreshController?
    var windowAdjustmentAllowed: () -> Bool = { true }
    private var windowHeightFallback: WindowHeightFallback?
    private let windowAdjustmentDisplays: (() -> [WindowAdjustmentDisplay])?
    private var spaceSubscriptions = Set<AnyCancellable>()

    var onSpaceCompatibilityFailure: ((String, String) -> Void)? {
        didSet { spaceStore.onCompatibilityFailure = onSpaceCompatibilityFailure }
    }

    init(
        runtime: AppRuntime,
        stripOrderStore: StripOrderStore,
        displayTopologyStore: DisplayTopologyStore,
        spaceStore: TaskbarSpaceStore = TaskbarSpaceStore(),
        topologySnapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot = {
            DisplayIdentity.topologySnapshot()
        },
        startCoordinator: @escaping (PanelCoordinator) -> Bool = { $0.start() },
        topologyRetryScheduler: @escaping DisplayTopologyRefreshController.ScheduleAfter = { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        },
        windowAdjustmentAccessibility: any AccessibilityOperations = NativeAccessibilityOperations(),
        windowAdjustmentDisplays: (() -> [WindowAdjustmentDisplay])? = nil,
        windowAdjustmentEnabled: Bool = true,
        makeHeightPoller: ((@escaping @Sendable () -> WindowHeightFallbackContext?) -> WindowHeightFallback)? = nil
    ) {
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.displayTopologyStore = displayTopologyStore
        self.spaceStore = spaceStore
        self.topologySnapshotProvider = topologySnapshotProvider
        self.topologyRetryScheduler = topologyRetryScheduler
        self.startCoordinator = startCoordinator
        self.windowAdjustmentDisplays = windowAdjustmentDisplays
        super.init()
        if windowAdjustmentEnabled {
            let context: @Sendable () -> WindowHeightFallbackContext? = { [weak self] in
                DispatchQueue.main.sync { self?.heightFallbackContext() }
            }
            if let makeHeightPoller {
                windowHeightFallback = makeHeightPoller(context)
            } else {
                let system = NativeWindowSystem()
                let reader = AXWindowReader(accessibility: windowAdjustmentAccessibility)
                let resolver = NativeHeightFallbackResolver(accessibility: windowAdjustmentAccessibility, system: system,
                    inventory: { [weak self] key in
                        DispatchQueue.main.sync { self?.heightFallbackInventory(key) ?? .unknown }
                    }, confirmedDesktop: { [weak self] key, element, display, desktop in
                        DispatchQueue.main.sync {
                            self?.heightFallbackDesktop(key, element: element, display: display, desktop: desktop)
                                ?? HeightFallbackMembership(confirmed: false)
                        }
                    })
                windowHeightFallback = WindowHeightFallback(
                    readFrame: { reader.heightAdjustmentFrame(of: $0.e) },
                    write: { action, element in
                        switch action {
                        case .size(let size): reader.writeWindowSize(size, to: element.e)
                        case .position(let point): reader.writeWindowPosition(point, to: element.e)
                        }
                    },
                    capture: { AppTrackerCGWindowSnapshot.heightScanRows(system: system) },
                    context: context, resolve: resolver.resolve, isCurrent: resolver.isCurrent,
                    isCurrentPosition: resolver.isCurrentPosition, membership: resolver.membership,
                    readNativeDesktop: resolver.readNativeDesktop)
            }
        }
    }

    isolated deinit {
        stopWindowHeightPolling()
        stopSpaceObservation()
        spaceStore.stop()
        topologyRefreshController?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !started, !isSuspended else { return }
        started = true
        let seedController = makeTopologyRefreshController()
        topologyRefreshController = seedController
        let snapshot = seedController.prepareForTopologyChange()
        startSpaceObservation()
        spaceStore.start(snapshots: runtime.$snapshot.eraseToAnyPublisher(), utilityOnActiveSpace: { [weak runtime] id in
            runtime?.utilityWindowOnActiveSpace(id)
        }, windowInvalidations: runtime.windowSpaceInvalidations)
        rebuildUnits(reason: "start", snapshot: snapshot)
        windowHeightFallback?.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func suspendAndRelease() {
        guard !isSuspended else { return }
        isSuspended = true
        stopWindowHeightPolling()
        stopSpaceObservation()
        spaceStore.stop()
        for unit in units {
            unit.coordinator.tearDown(source: "runtime-suspended")
        }
        units = []
        topologyRefreshController?.cancel()
        topologyRefreshController = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func rebuildUnits(reason: String, snapshot: ScreenTopologySnapshot) {
        guard started, !isSuspended else { return }
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            connectedKeys: snapshot.identifiedDisplayUUIDs, physicalDisplayCount: snapshot.physicalDisplayCount,
            hasIdentifiedPrimary: snapshot.attributionTable.primaryUUID != nil
        )
        let current = units.map(\.key)
        guard desired != current else { return }
        let desiredSet = Set(desired.map { $0 ?? "" })
        var survivors: [String?: Unit] = [:]
        for unit in units {
            if desiredSet.contains(unit.key ?? "") {
                survivors[unit.key] = unit
            } else {
                unit.coordinator.tearDown(source: "topology-\(reason)")
            }
        }
        units = desired.compactMap { key in
            if let survivor = survivors[key] { return survivor }
            guard let unit = makeUnit(key: key) else { return nil }
            return unit
        }
        applySpaceLayouts(spaceStore.activeLayouts,
                          displays: PanelDisplayState(snapshot: runtime.snapshot, table: snapshot.attributionTable))
    }

    private func makeUnit(key: String?) -> Unit? {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .primary
        let coordinator = PanelCoordinator(
            placement: placement,
            runtime: runtime,
            stripOrderStore: stripOrderStore,
            displayTopologyStore: displayTopologyStore,
            spaceStore: spaceStore
        )
        coordinator.leadingSlotFactory = leadingSlotFactory
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onAccessoryInteraction = { [weak self] unit, kind in
            self?.admitAccessory(for: unit, kind: kind) ?? false
        }
        guard startCoordinator(coordinator) else { return nil }
        return Unit(key: key, coordinator: coordinator)
    }

    @objc private func screenParametersChanged() {
        let snapshot: ScreenTopologySnapshot
        if let seedController = topologyRefreshController {
            snapshot = seedController.prepareForTopologyChange()
        } else {
            snapshot = topologySnapshotProvider()
            applyTopologySnapshot(snapshot)
        }
        rebuildUnits(reason: "screens", snapshot: snapshot)
        units.forEach { $0.coordinator.screenParametersChanged() }
    }

    private func makeTopologyRefreshController() -> DisplayTopologyRefreshController {
        DisplayTopologyRefreshController(
            snapshotProvider: topologySnapshotProvider,
            applySnapshot: { [weak self] snapshot in
                self?.applyTopologySnapshot(snapshot)
            },
            onRetrySnapshot: { [weak self] snapshot in
                self?.rebuildUnits(
                    reason: "topology-retry",
                    snapshot: snapshot
                )
                self?.units.forEach { $0.coordinator.screenParametersChanged() }
            },
            scheduleAfter: topologyRetryScheduler
        )
    }

    private func applyTopologySnapshot(_ snapshot: ScreenTopologySnapshot) {
        spaceStore.updateTopology(snapshot)
        displayTopologyStore.apply(snapshot)
        runtime.updateDisplayTopology(snapshot.attributionTable)
    }

    private func admitAccessory(for unit: PanelCoordinator, kind: PanelCoordinator.AccessoryKind) -> Bool {
        let others = units.filter { $0.coordinator !== unit }
        if kind == .backgroundClick {
            for other in others { other.coordinator.taskbarView?.taskbarContent.dismissLeadingSlot() }
            return true
        }
        if kind == .implicit, others.contains(where: { $0.coordinator.taskbarView?.taskbarContent.hasExplicitPopup == true }) {
            return false
        }
        for other in others {
            other.coordinator.dismissTaskbarPopups()
        }
        return true
    }

    private func heightFallbackContext() -> WindowHeightFallbackContext? {
        guard started, !isSuspended, windowAdjustmentAllowed(),
              let revision = spaceStore.heightFallbackLayoutEpoch else { return nil }
        let displays = currentAdjustmentDisplays()
        var desktops: [String: Int] = [:]
        for display in displays {
            guard let uuid = display.displayUUID, display.panelFrame != nil,
                  let desktop = spaceStore.heightFallbackDesktop(on: uuid) else { continue }
            desktops[uuid] = desktop
        }
        guard !desktops.isEmpty else { return nil }
        return WindowHeightFallbackContext(epoch: revision, displays: displays, desktopIDs: desktops)
    }

    private func heightFallbackInventory(_ key: HeightWriteKey) -> HeightFallbackInventory {
        HeightFallbackInventory.classify(key, in: runtime.snapshot.windows.values)
    }

    private func heightFallbackDesktop(_ key: HeightWriteKey, element: AXElementKey, display: String,
                                       desktop: Int) -> HeightFallbackMembership {
        guard spaceStore.heightFallbackDesktop(on: display) == desktop else {
            return HeightFallbackMembership(confirmed: false)
        }
        switch heightFallbackInventory(key) {
        case .unknown:
            return HeightFallbackMembership(confirmed: nil)
        case .excluded, .unavailable:
            return HeightFallbackMembership(confirmed: false)
        case let .ordinary(identity, currentElement):
            guard currentElement == element else { return HeightFallbackMembership(confirmed: false) }
            return spaceStore.heightMembership(for: identity, on: display)
        }
    }

    private func currentAdjustmentDisplays() -> [WindowAdjustmentDisplay] {
        if let windowAdjustmentDisplays { return windowAdjustmentDisplays() }
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.maxY else { return [] }
        let panelFrames = units.compactMap { $0.coordinator.visibleTaskbarFrame }
        return screens.map { screen in
            let panel = panelFrames.first { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            return WindowAdjustmentDisplay(
                frame: DisplayIdentity.windowServerFrame(fromAppKit: screen.frame, primaryDisplayHeight: primaryHeight),
                visibleFrame: DisplayIdentity.windowServerFrame(fromAppKit: screen.visibleFrame, primaryDisplayHeight: primaryHeight),
                panelFrame: panel.map { DisplayIdentity.windowServerFrame(fromAppKit: $0, primaryDisplayHeight: primaryHeight) },
                displayUUID: DisplayIdentity.uuidString(for: screen)
            )
        }
    }

    func stopWindowHeightPolling() {
        windowHeightFallback?.stop()
    }

    private func startSpaceObservation() {
        let displays = runtime.$snapshot.combineLatest(displayTopologyStore.$table)
            .map { PanelDisplayState(snapshot: $0, table: $1) }
            .removeDuplicates()
        spaceStore.$activeLayouts.combineLatest(displays).sink { [weak self] layouts, displays in
            self?.applySpaceLayouts(layouts, displays: displays)
        }.store(in: &spaceSubscriptions)
        spaceStore.activeSpaceChanges.sink { [weak self] _ in
            guard let self else { return }
            self.units.forEach { $0.coordinator.spaceWillChange() }
        }.store(in: &spaceSubscriptions)
        spaceStore.desktopReturns.sink { [weak self] _ in
            self?.runtime.refreshFrontmostWindow()
        }.store(in: &spaceSubscriptions)
    }

    private func applySpaceLayouts(_ layouts: TaskbarSpaceStore.Layouts, displays: PanelDisplayState) {
        guard started, !isSuspended else { return }
        for unit in units {
            let key = unit.key ?? displays.primary
            let local = key.flatMap { layouts[$0] }
            let shared = layouts.count == 1 ? layouts["Main"] : nil
            let primaryFallback = key == nil && units.count == 1 && layouts.count == 1 ? layouts.values.first : nil
            guard let layout = local ?? shared ?? primaryFallback else {
                unit.coordinator.applySpaceUnavailable(source: "space-layout")
                continue
            }
            let fullscreen = layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
            let borderless = key.map { $0 == displays.borderlessFullscreen } ?? false
            unit.coordinator.applySpaceFullscreen(fullscreen || borderless,
                                                   source: borderless && !fullscreen ? "borderless-fullscreen" : "space-layout")
        }
    }

    private func stopSpaceObservation() {
        spaceSubscriptions.removeAll()
    }
}
