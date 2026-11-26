import AppKit
import Combine
import Foundation
#if DEBUG
import os
#endif

@MainActor
final class TaskbarScreenOrchestrator: NSObject {
    struct Unit {
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []

    private let runtime: AppRuntime
    private let stripOrderStore: StripOrderStore
    private let displayTopologyStore: DisplayTopologyStore
    private let spaceStore: TaskbarSpaceStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let startCoordinator: (PanelCoordinator) -> Bool
    private let topologyRetryScheduler: DisplayTopologyRefreshController.ScheduleAfter
    private let workspaceNotifications: NotificationCenter
    private let frontmostApplicationPID: () -> pid_t?
    private let makeGeometryObserver: () -> FrontmostWindowGeometryObserver?
    #if DEBUG
    private let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "taskbar-screens")
    private static let heightLog = Logger(subsystem: "io.github.sashokey.deskmote", category: "window-height")
    #endif

    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var topologyRefreshController: DisplayTopologyRefreshController?
    var windowAdjustmentAllowed: () -> Bool = { true }
    private let windowHeightAdjustment: WindowHeightAdjustment?
    private let windowAdjustmentDisplays: (() -> [WindowAdjustmentDisplay])?
    private var geometryObserver: FrontmostWindowGeometryObserver?
    private var launchFocusSubscription: AnyCancellable?
    private var desktopReturns: AnyCancellable?
    private var geometryObservers: [NSObjectProtocol] = []
    private var panelGeometryObserver: NSObjectProtocol?
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
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplicationPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        makeGeometryObserver: @escaping () -> FrontmostWindowGeometryObserver? = { FrontmostWindowGeometryObserver() },
        windowAdjustmentAccessibility: any AccessibilityOperations = NativeAccessibilityOperations(),
        windowAdjustmentDisplays: (() -> [WindowAdjustmentDisplay])? = nil,
        windowAdjustmentEnabled: Bool = DebugSwitch.windowLift.isEnabled()
    ) {
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.displayTopologyStore = displayTopologyStore
        self.spaceStore = spaceStore
        self.topologySnapshotProvider = topologySnapshotProvider
        self.topologyRetryScheduler = topologyRetryScheduler
        self.startCoordinator = startCoordinator
        self.workspaceNotifications = workspaceNotifications
        self.frontmostApplicationPID = frontmostApplicationPID
        self.makeGeometryObserver = makeGeometryObserver
        windowHeightAdjustment = windowAdjustmentEnabled
            ? WindowHeightAdjustment(accessibility: windowAdjustmentAccessibility) : nil
        self.windowAdjustmentDisplays = windowAdjustmentDisplays
        super.init()
    }

    isolated deinit {
        stopWindowGeometryObservation()
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
        startWindowGeometryObservation()
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
        stopWindowGeometryObservation()
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
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.displays.rebuild")
        defer { span?.finish() }
        #endif
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
        applySpaceLayouts(spaceStore.activeLayouts)
        #if DEBUG
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        #endif
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
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.displays.update")
        defer { span?.finish() }
        #endif
        windowHeightAdjustment?.invalidateLayout()
        spaceStore.updateTopology(snapshot)
        displayTopologyStore.apply(snapshot)
        runtime.updateDisplayTopology(snapshot.attributionTable)
    }

    private func admitAccessory(for unit: PanelCoordinator, kind: PanelCoordinator.AccessoryKind) -> Bool {
        let others = units.filter { $0.coordinator !== unit }
        if kind == .backgroundClick {
            for other in others { other.coordinator.taskbarView?.taskbarContent.dismissAppsMenu() }
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

    private func startWindowGeometryObservation() {
        guard windowHeightAdjustment != nil, let observer = makeGeometryObserver() else { return }
        observer.onEvent = { [weak self] event in
            self?.handleWindowGeometryEvent(event)
        }
        observer.isLaunchFocusCurrent = { [weak self] focus in
            guard let self else { return false }
            return self.windowAdjustmentAllowed() && self.frontmostApplicationPID() == focus.pid
                && self.runtime.isLaunchWindowFocusCurrent(focus)
        }
        geometryObserver = observer
        launchFocusSubscription = runtime.launchWindowFocus.sink { [weak observer] focus in
            observer?.acceptLaunchFocus(focus)
        }
        panelGeometryObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let panel = note.object as? NSWindow else { return }
            let identity = ObjectIdentifier(panel)
            MainActor.assumeIsolated {
                guard let self, self.units.contains(where: { $0.coordinator.dockPanel.map(ObjectIdentifier.init) == identity }) else { return }
                self.windowHeightAdjustment?.invalidateLayout()
            }
        }
        geometryObservers = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ].map { name in
            workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak observer] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    #if DEBUG
                    Self.heightLog.notice("workspace-event name=\(name.rawValue, privacy: .public) pid=\(pid ?? 0)")
                    #endif
                    switch name {
                    case NSWorkspace.didActivateApplicationNotification:
                        observer?.activate(pid: pid)
                    case NSWorkspace.didLaunchApplicationNotification:
                        if let pid { observer?.applicationLaunched(pid: pid) }
                    case NSWorkspace.didTerminateApplicationNotification:
                        if let pid { observer?.applicationTerminated(pid: pid) }
                    default:
                        break
                    }
                }
            }
        }
        observer.start(pid: frontmostApplicationPID())
    }

    private func handleWindowGeometryEvent(_ event: FrontmostWindowGeometryObserver.Event) {
        guard let windowHeightAdjustment else { return }
        switch event {
        case let .windowBindingChanged(window, ownerPID):
            windowHeightAdjustment.bind(window, ownerPID: ownerPID)
        case let .newFocusedWindow(window, evidence):
            guard windowAdjustmentAllowed() else {
                #if DEBUG
                Self.heightLog.notice("height-skip reason=adjustment-not-allowed source=\(evidence.rawValue, privacy: .public) window=\(window.hashValue)")
                #endif
                return
            }
            windowHeightAdjustment.newWindowConfirmed(window,
                displays: currentAdjustmentDisplays(), evidence: evidence.rawValue)
        case let .geometryChanged(window, notification, receivedAt):
            guard windowAdjustmentAllowed() else { return }
            windowHeightAdjustment.geometryChanged(window, displays: currentAdjustmentDisplays(),
                                                   notification: notification, receivedAt: receivedAt)
        default:
            break
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
                panelFrame: panel.map { DisplayIdentity.windowServerFrame(fromAppKit: $0, primaryDisplayHeight: primaryHeight) }
            )
        }
    }

    func stopWindowGeometryObservation() {
        launchFocusSubscription?.cancel()
        launchFocusSubscription = nil
        geometryObservers.forEach { workspaceNotifications.removeObserver($0) }
        geometryObservers.removeAll()
        if let panelGeometryObserver { NotificationCenter.default.removeObserver(panelGeometryObserver) }
        panelGeometryObserver = nil
        windowHeightAdjustment?.stop()
        geometryObserver?.stop()
        geometryObserver = nil
    }

    private func startSpaceObservation() {
        spaceStore.$activeLayouts.sink { [weak self] layouts in
            self?.applySpaceLayouts(layouts)
        }.store(in: &spaceSubscriptions)
        spaceStore.activeSpaceChanges.sink { [weak self] _ in
            guard let self else { return }
            self.windowHeightAdjustment?.invalidateLayout()
            self.units.forEach { $0.coordinator.spaceWillChange() }
            self.geometryObserver?.retryUnavailableObservation()
        }.store(in: &spaceSubscriptions)
        spaceStore.desktopReturns.sink { [weak self] _ in
            self?.runtime.refreshFrontmostWindow()
        }.store(in: &spaceSubscriptions)
    }

    private func applySpaceLayouts(_ layouts: TaskbarSpaceStore.Layouts) {
        guard started, !isSuspended else { return }
        windowHeightAdjustment?.invalidateLayout()
        let primary = displayTopologyStore.table.primaryUUID
        for unit in units {
            let key = unit.key ?? primary
            let local = key.flatMap { layouts[$0] }
            let shared = layouts.count == 1 ? layouts["Main"] : nil
            let primaryFallback = key == nil && units.count == 1 && layouts.count == 1 ? layouts.values.first : nil
            guard let layout = local ?? shared ?? primaryFallback else {
                unit.coordinator.applySpaceUnavailable(source: "space-layout")
                continue
            }
            let fullscreen = layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
            unit.coordinator.applySpaceFullscreen(fullscreen, source: "space-layout")
        }
    }

    private func stopSpaceObservation() {
        spaceSubscriptions.removeAll()
    }
}
