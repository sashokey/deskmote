import AppKit
import Combine
import Foundation
#if DEBUG
import os
#endif

@MainActor
final class TaskbarScreenOrchestrator: NSObject, WindowLiftAvoidanceHost {
    struct Unit {
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []
    let overlaySpaceHost: OverlaySpaceHost?

    private let runtime: AppRuntime
    private let stripOrderStore: StripOrderStore
    private let displayTopologyStore: DisplayTopologyStore
    private let spaceStore: TaskbarSpaceStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let startCoordinator: (PanelCoordinator) -> Bool
    private let topologyRetryScheduler: DisplayTopologyRefreshController.ScheduleAfter
    private let captureFullscreenCGWindows: @MainActor () -> [[String: Any]]?
    private let workspaceNotifications: NotificationCenter
    private let frontmostApplicationPID: () -> pid_t?
    private let fullscreenUptime: @Sendable () -> TimeInterval
    #if DEBUG
    private let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "taskbar-screens")
    #endif

    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var topologyRefreshController: DisplayTopologyRefreshController?
    private var fullscreenTimer: Timer?
    private var fullscreenObservers: [NSObjectProtocol] = []

    init(
        runtime: AppRuntime,
        stripOrderStore: StripOrderStore,
        displayTopologyStore: DisplayTopologyStore,
        spaceStore: TaskbarSpaceStore = TaskbarSpaceStore(),
        overlaySpaceHost: OverlaySpaceHost? = OverlaySpaceHost.make(),
        topologySnapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot = {
            DisplayIdentity.topologySnapshot()
        },
        startCoordinator: @escaping (PanelCoordinator) -> Bool = { $0.start() },
        topologyRetryScheduler: @escaping DisplayTopologyRefreshController.ScheduleAfter = { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        },
        captureFullscreenCGWindows: @escaping @MainActor () -> [[String: Any]]? = PanelCoordinator.captureFullscreenCGWindows,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplicationPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        fullscreenUptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.overlaySpaceHost = overlaySpaceHost
        self.runtime = runtime
        self.stripOrderStore = stripOrderStore
        self.displayTopologyStore = displayTopologyStore
        self.spaceStore = spaceStore
        self.topologySnapshotProvider = topologySnapshotProvider
        self.topologyRetryScheduler = topologyRetryScheduler
        self.startCoordinator = startCoordinator
        self.captureFullscreenCGWindows = captureFullscreenCGWindows
        self.workspaceNotifications = workspaceNotifications
        self.frontmostApplicationPID = frontmostApplicationPID
        self.fullscreenUptime = fullscreenUptime
        super.init()
    }

    isolated deinit {
        stopFullscreenMonitoring()
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
        spaceStore.start(snapshots: runtime.$snapshot.eraseToAnyPublisher(), utilityOnActiveSpace: { [weak runtime] id in
            runtime?.utilityWindowOnActiveSpace(id)
        })
        rebuildUnits(reason: "start", snapshot: snapshot)
        startFullscreenMonitoring()
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
        stopFullscreenMonitoring()
        spaceStore.stop()
        for unit in units {
            unit.coordinator.tearDown(source: "runtime-suspended")
        }
        units = []
        overlaySpaceHost?.tearDown()
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
        let initialRead = makeFullscreenReadBatch()
        lazy var initialPID = frontmostApplicationPID()
        units = desired.compactMap { key in
            if let survivor = survivors[key] { return survivor }
            guard let unit = makeUnit(key: key) else { return nil }
            unit.coordinator.lastActiveApplicationPID = initialPID
            unit.coordinator.triggerAsyncFullscreenCheck(source: "initial-ax", sharedRead: initialRead)
            return unit
        }
        #if DEBUG
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        #endif
    }

    private func makeUnit(key: String?) -> Unit? {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .primary
        let coordinator = PanelCoordinator(
            placement: placement,
            overlaySpaceHost: overlaySpaceHost,
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
        updateFullscreenPanels { $0.screenParametersChanged(sharedRead: $1) }
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
                self?.updateFullscreenPanels { $0.screenParametersChanged(sharedRead: $1) }
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

    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    func windowGeometryChanged() {
        updateFullscreenPanels { $0.windowGeometryChanged(sharedRead: $1) }
    }

    private func startFullscreenMonitoring() {
        fullscreenObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        fullscreenObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.updateFullscreenPanels { $0.handleAppActivated(pid: pid, sharedRead: $1) }
            }
        })
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileFullscreenState()
            }
        }
        fullscreenTimer?.tolerance = 0.5
    }

    private func handleSpaceChange() {
        guard started, !isSuspended, !units.isEmpty else { return }
        overlaySpaceHost?.reconcileVisibility()
        updateFullscreenPanels { $0.handleSpaceChange(sharedRead: $1) }
    }

    func reconcileFullscreenState() {
        updateFullscreenPanels { $0.reconcileFullscreenState(sharedRead: $1) }
    }

    private func stopFullscreenMonitoring() {
        fullscreenTimer?.invalidate()
        fullscreenTimer = nil
        fullscreenObservers.forEach { workspaceNotifications.removeObserver($0) }
        fullscreenObservers.removeAll()
    }

    private func updateFullscreenPanels(_ update: (PanelCoordinator, FullscreenReadBatch) -> Void) {
        guard started, !isSuspended, !units.isEmpty else { return }
        let batch = makeFullscreenReadBatch()
        units.forEach { update($0.coordinator, batch) }
    }

    private func makeFullscreenReadBatch() -> FullscreenReadBatch {
        FullscreenReadBatch(uptime: fullscreenUptime, readCG: captureFullscreenCGWindows) {
            PanelCoordinator.readFullscreenAXObservation(pid: $0)
        }
    }

}
