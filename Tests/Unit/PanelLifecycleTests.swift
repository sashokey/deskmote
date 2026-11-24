import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

@MainActor
private final class PanelInventory: WindowInventoryTracking {
    var snapshots: AnyPublisher<DockSnapshot, Never> { Just(DockSnapshot.empty).eraseToAnyPublisher() }
    func start() {}
    func stop() {}
}

@MainActor
final class PanelLifecycleTests: XCTestCase {
    #if DEBUG
    func testVisibilityJournalRecordsNativeLossEvenWhenThePanelIsStillRequested() throws {
        let lines = Mutex<[Data]>([])
        let journal = TaskbarVisibilityJournal { line in lines.withLock { $0.append(line) } }
        var state = TaskbarVisibilitySample(windowNumber: 25, primaryDisplay: true,
                                            requestedVisible: true, fullscreen: false, appKitVisible: true,
                                            onActiveSpace: true, windowServerOnScreen: true,
                                            occlusionVisible: true, alpha: "opaque", repairingMembership: false)
        journal.capture(state)
        journal.capture(state)
        state.windowServerOnScreen = false
        journal.capture(state)
        journal.capture(state, event: "order-front", source: "space-ax-cg", candidateWindowID: 51)
        journal.flush()
        let recorded = lines.withLock { $0 }
        let values = try recorded.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.map { $0["event"] as? String }, ["observed", "observed", "order-front"])
        let interrupted = try XCTUnwrap(values[1]["state"] as? [String: Any])
        XCTAssertEqual(interrupted["primaryDisplay"] as? Bool, true)
        XCTAssertEqual(interrupted["requestedVisible"] as? Bool, true)
        XCTAssertEqual(interrupted["windowServerOnScreen"] as? Bool, false)
        XCTAssertNotNil(values[1]["timestamp"] as? String)
        XCTAssertEqual(values[2]["source"] as? String, "space-ax-cg")
        XCTAssertEqual(values[2]["candidateWindowID"] as? Int, 51)
    }
    #endif

    private final class DetachedDockPanel: NSPanel {
        var onOrderOut: (() -> Void)?

        override func orderOut(_ sender: Any?) { onOrderOut?() }
        override func close() {}
    }

    @MainActor
    private final class CGWindows {
        var windows: [[String: Any]]?
        private(set) var captures = 0

        init(_ windows: [[String: Any]]?) { self.windows = windows }

        func capture() -> [[String: Any]]? {
            captures += 1
            return windows
        }
    }

    func testSpaceChangeSharesOneFreshFullscreenCGCaptureAcrossPanels() throws {
        let leftFrame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let rightFrame = leftFrame.offsetBy(dx: leftFrame.width, dy: 0)
        func window(on frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
             kCGWindowLayer as String: 0, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let cg = CGWindows([window(on: leftFrame)])
        let uptime = Mutex<TimeInterval>(10)
        var overlayVisibilityReads = 0
        let overlay = OverlaySpaceHost(operations: .init(
            create: { 7 }, prepare: { _ in },
            isVisible: { _ in overlayVisibilityReads += 1; return true },
            addWindows: { _, _ in }, spaces: { _ in [7] }, release: { _ in }
        ))
        XCTAssertTrue(overlay.pin(windowNumbers: [10]))
        overlayVisibilityReads = 0
        let topology = ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"], attributionTable: .empty
        )
        let notifications = NotificationCenter()
        let orchestrator = TaskbarScreenOrchestrator(
            runtime: AppRuntime(tracker: PanelInventory()), stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
            overlaySpaceHost: overlay, topologySnapshotProvider: { topology },
            startCoordinator: { panel in
                let isLeft = panel.fixedDisplayUUID == "left"
                panel.fullscreenFrameProvider = {
                    if !isLeft { uptime.withLock { $0 += 1 } }
                    return isLeft ? leftFrame : rightFrame
                }
                panel.fullscreenCGWindowObservationProvider = { _ in nil }
                return true
            },
            captureFullscreenCGWindows: cg.capture,
            workspaceNotifications: notifications,
            frontmostApplicationPID: { nil },
            fullscreenUptime: { uptime.withLock { $0 } }
        )
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        let left = try XCTUnwrap(orchestrator.units.first(where: { $0.key == "left" })?.coordinator)
        let right = try XCTUnwrap(orchestrator.units.first(where: { $0.key == "right" })?.coordinator)
        let spaceChanged = NSWorkspace.activeSpaceDidChangeNotification

        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(cg.captures, 1)
        XCTAssertEqual(overlayVisibilityReads, 1)
        XCTAssertFalse(left.visibilityState.isVisible)
        XCTAssertTrue(right.visibilityState.isVisible)

        cg.windows = nil
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(cg.captures, 2)
        XCTAssertFalse(left.visibilityState.isVisible)
        XCTAssertTrue(right.visibilityState.isVisible)

        cg.windows = [window(on: rightFrame)]
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(cg.captures, 3)
        XCTAssertFalse(right.visibilityState.isVisible)

        left.fullscreenFrameProvider = { nil }
        right.fullscreenFrameProvider = { nil }
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(cg.captures, 3)
        XCTAssertEqual(overlayVisibilityReads, 4)

        left.fullscreenFrameProvider = { leftFrame }
        right.fullscreenFrameProvider = { rightFrame }
        orchestrator.suspendAndRelease()
        notifications.post(name: spaceChanged, object: nil)
        XCTAssertEqual(cg.captures, 3)
        XCTAssertEqual(overlayVisibilityReads, 4)
    }

    func testOtherDisplayFocusUsesFrontmostLocalWindowForFullscreen() {
        let panel = coordinator(placement: .fixed(displayUUID: "left"))
        defer { panel.tearDown() }
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let overlapping = CGRect(x: 590, y: 15, width: 490, height: 470)
        let localWindow = CGRect(x: 20, y: 20, width: 530, height: 420)
        func window(_ id: Int, _ frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: -42,
             kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        var windows = [window(10, overlapping), window(11, screen)]
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenCGWindowsProvider = { windows }
        panel.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test", displayUUID: "left")
        let probe = FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil, spaceVerdict: false)

        panel.receiveFullscreenProbe(probe, request: request)

        XCTAssertFalse(panel.visibilityState.isVisible)
        windows = [window(10, overlapping), window(12, localWindow), window(11, screen)]
        panel.receiveFullscreenProbe(probe, request: request)
        XCTAssertTrue(panel.visibilityState.isVisible)
    }

    func testPeriodicFullscreenFallbackSharesOneCaptureAcrossDisplays() async {
        let leftFrame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let rightFrame = leftFrame.offsetBy(dx: 600, dy: 0)
        let cg = CGWindows([[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
            kCGWindowLayer as String: 0, kCGWindowBounds as String: leftFrame.dictionaryRepresentation]])
        let topology = ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"], attributionTable: .empty
        )
        let orchestrator = TaskbarScreenOrchestrator(
            runtime: AppRuntime(tracker: PanelInventory()), stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
            overlaySpaceHost: nil, topologySnapshotProvider: { topology },
            startCoordinator: { panel in
                panel.fullscreenFrameProvider = { nil }
                panel.fullscreenCGWindowsProvider = { XCTFail("Unbatched capture"); return nil }
                panel.fullscreenCGWindowObservationProvider = { _ in nil }
                panel.fullscreenProbeWorker = FullscreenProbeWorker(read: { _ in
                    FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil)
                }, deliver: { [weak panel] request, probe in
                    panel?.receiveFullscreenProbe(probe, request: request)
                })
                return true
            },
            captureFullscreenCGWindows: cg.capture,
            workspaceNotifications: NotificationCenter(),
            frontmostApplicationPID: { nil }
        )
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        for unit in orchestrator.units {
            let frame = unit.key == "left" ? leftFrame : rightFrame
            unit.coordinator.fullscreenFrameProvider = { frame }
        }

        orchestrator.reconcileFullscreenState()
        for unit in orchestrator.units {
            while let work = unit.coordinator.fullscreenProbeWorker?.pendingWorkForTesting.first { await work.value }
        }

        XCTAssertEqual(cg.captures, 1)
        XCTAssertEqual(orchestrator.units.map(\.coordinator.visibilityState.isVisible), [false, true])
    }

    func testFullscreenFallbackRejectsCGWindowsFromAReplacementDisplay() {
        let panel = coordinator(placement: .fixed(displayUUID: "left"))
        defer { panel.tearDown() }
        let screen = CGRect(x: 600, y: 0, width: 600, height: 500)
        let cg = CGWindows([[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
            kCGWindowLayer as String: 0, kCGWindowBounds as String: screen.dictionaryRepresentation]])
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenDisplayUUIDProvider = { "right" }
        panel.fullscreenCGWindowsProvider = cg.capture
        panel.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test", displayUUID: "left")
        let probe = FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil, spaceVerdict: false)

        panel.receiveFullscreenProbe(probe, request: request)

        XCTAssertTrue(panel.visibilityState.isVisible)
        XCTAssertEqual(cg.captures, 0)
        panel.fullscreenDisplayUUIDProvider = { "left" }
        panel.receiveFullscreenProbe(probe, request: request)
        XCTAssertFalse(panel.visibilityState.isVisible)
        XCTAssertEqual(cg.captures, 1)
    }

    func testImmediateSpaceFallbackRejectsWindowsFromAReplacementDisplay() {
        let panel = coordinator(placement: .fixed(displayUUID: "left"))
        defer { panel.tearDown() }
        let screen = CGRect(x: 600, y: 0, width: 600, height: 500)
        let cg = CGWindows([[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
            kCGWindowLayer as String: 0, kCGWindowBounds as String: screen.dictionaryRepresentation]])
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenDisplayUUIDProvider = { "right" }
        panel.fullscreenCGWindowsProvider = cg.capture

        panel.handleSpaceChange()

        XCTAssertTrue(panel.visibilityState.isVisible)
        XCTAssertEqual(cg.captures, 0)
    }

    func testSpaceWorkerRejectsFullscreenVerdictFromAReplacementDisplay() async throws {
        let panel = coordinator(placement: .fixed(displayUUID: "left"))
        defer { panel.tearDown() }
        let screen = CGRect(x: 600, y: 0, width: 600, height: 500)
        let spaceReads = Mutex<[String]>([])
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenDisplayUUIDProvider = { "right" }
        panel.fullscreenCGWindowsProvider = { nil }
        panel.fullscreenSpaceProvider = { uuid in
            spaceReads.withLock { $0.append(uuid) }
            return true
        }
        panel.setupFullscreenMonitor { _ in .unknown }
        let worker = try XCTUnwrap(panel.fullscreenProbeWorker)

        panel.handleSpaceChange()
        while let work = worker.pendingWorkForTesting.first { await work.value }

        XCTAssertTrue(panel.visibilityState.isVisible)
        XCTAssertEqual(spaceReads.withLock { $0 }, ["left"])
    }

    func testPrimaryFullscreenResultRequiresUnchangedPhysicalUUID() {
        let cases: [(String?, String?, Bool)] = [
            (nil, "left", true), ("left", "right", true), ("left", nil, true), ("left", "left", false)
        ]
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        for (requestedUUID, currentUUID, expectedVisible) in cases {
            let panel = coordinator()
            panel.fullscreenFrameProvider = { screen }
            panel.fullscreenDisplayUUIDProvider = { currentUUID }
            panel.fullscreenProbeGeneration = 1
            let request = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: nil,
                                                 finalConfirmation: false, source: "test", displayUUID: requestedUUID)

            panel.receiveFullscreenProbe(
                FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil, spaceVerdict: true), request: request
            )

            XCTAssertEqual(panel.visibilityState.isVisible, expectedVisible)
            panel.tearDown()
        }
    }

    func testPrimaryFullscreenWorkerCanUseSLSMainWithoutAPhysicalUUID() async throws {
        let panel = coordinator()
        defer { panel.tearDown() }
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let reads = Mutex<[String]>([])
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenDisplayUUIDProvider = { nil }
        panel.fullscreenSpaceProvider = { uuid in
            reads.withLock { $0.append(uuid) }
            return true
        }
        panel.setupFullscreenMonitor { _ in .unknown }
        let worker = try XCTUnwrap(panel.fullscreenProbeWorker)

        panel.reconcileFullscreenState()
        while let work = worker.pendingWorkForTesting.first { await work.value }

        XCTAssertEqual(reads.withLock { $0 }, ["Main"])
        XCTAssertFalse(panel.visibilityState.isVisible)
    }

    func testSpaceChangeIgnoresLargeWindowMostlyOnAnotherDisplay() {
        let panel = coordinator()
        defer { panel.tearDown() }
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let overlapping = CGRect(x: 590, y: 15, width: 490, height: 470)
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenCGWindowsProvider = {
            [overlapping, screen].enumerated().map { offset, frame in
                [kCGWindowNumber as String: offset + 10, kCGWindowOwnerPID as String: -42,
                 kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
                 kCGWindowBounds as String: frame.dictionaryRepresentation]
            }
        }

        panel.handleSpaceChange()

        XCTAssertFalse(panel.visibilityState.isVisible)
    }

    func testOverlayExitRevealsTaskbarWithSLSDisabledBeforePeriodicCheck() async throws {
        try await assertOverlayExitRevealsTaskbarWithSLSDisabled(axKeepsFocus: true)
    }

    func testOverlayExitWithoutAXFocusRevealsTaskbarWithSLSDisabledBeforePeriodicCheck() async throws {
        try await assertOverlayExitRevealsTaskbarWithSLSDisabled(axKeepsFocus: false)
    }

    private func assertOverlayExitRevealsTaskbarWithSLSDisabled(axKeepsFocus: Bool) async throws {
        let panel = coordinator(placement: .fixed(displayUUID: "left"), usesSLS: false)
        defer { panel.tearDown() }
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let otherDisplay = screen.offsetBy(dx: 600, dy: 0)
        var windows: [[String: Any]] = [[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
            kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1, kCGWindowBounds as String: screen.dictionaryRepresentation]]
        let spaceReads = Mutex(0)
        let axHasFocus = Mutex(true)
        var overlayIsVisible = true
        var described: [CGWindowID] = []
        panel.lastActiveApplicationPID = 42
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenCGWindowsProvider = { windows }
        panel.fullscreenCGWindowObservationProvider = {
            if overlayIsVisible { return (true, screen) }
            described.append($0)
            return (false, nil)
        }
        panel.fullscreenSpaceProvider = { _ in spaceReads.withLock { $0 += 1 }; return true }
        panel.setupFullscreenMonitor { _ in
            guard axHasFocus.withLock({ $0 }) else { return .unknown }
            return .window(role: kAXWindowRole as String, isFullscreen: false, frame: otherDisplay, id: nil, layer: 0)
        }
        let worker = try XCTUnwrap(panel.fullscreenProbeWorker)

        panel.triggerAsyncFullscreenCheck(source: "initial-ax")
        while let work = worker.pendingWorkForTesting.first { await work.value }
        XCTAssertFalse(panel.visibilityState.isVisible)

        let watch = try XCTUnwrap(panel.overlayWindowWatchTimer)
        axHasFocus.withLock { $0 = axKeepsFocus }
        windows = []
        overlayIsVisible = false
        watch.fire()
        let deadline = ContinuousClock.now + .seconds(2)
        while !panel.visibilityState.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertTrue(panel.visibilityState.isVisible)
        XCTAssertEqual(described, [10])
        XCTAssertEqual(spaceReads.withLock { $0 }, 0)
    }

    func testMissingCGSnapshotCannotRevealCGConfirmedFullscreenAfterAXFocusIsLost() {
        let panel = coordinator(placement: .fixed(displayUUID: "left"), usesSLS: false)
        defer { panel.tearDown() }
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let cg = CGWindows([[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
            kCGWindowLayer as String: 0, kCGWindowBounds as String: screen.dictionaryRepresentation]])
        panel.fullscreenFrameProvider = { screen }
        panel.fullscreenCGWindowsProvider = cg.capture
        panel.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test", displayUUID: "left")
        let otherDisplay = FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil)
        let unknown = FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        panel.receiveFullscreenProbe(otherDisplay, request: request)
        XCTAssertFalse(panel.visibilityState.isVisible)

        cg.windows = nil
        panel.receiveFullscreenProbe(unknown, request: request)
        XCTAssertFalse(panel.visibilityState.isVisible)
        cg.windows = [[kCGWindowBounds as String: "invalid"]]
        panel.receiveFullscreenProbe(unknown, request: request)
        XCTAssertFalse(panel.visibilityState.isVisible)

        cg.windows = []
        panel.receiveFullscreenProbe(unknown, request: request)
        XCTAssertTrue(panel.visibilityState.isVisible)
    }

    func testAXConfirmationPreservesCGFullscreenOnlyForTheSameOverlay() {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let cases: [(CGWindowID?, Bool)] = [(10, true), (11, false), (nil, false)]
        for (axOverlayID, expectedVisible) in cases {
            let panel = coordinator(placement: .fixed(displayUUID: "left"), usesSLS: false)
            let cg = CGWindows([[kCGWindowNumber as String: 10, kCGWindowOwnerPID as String: -42,
                kCGWindowLayer as String: 0, kCGWindowBounds as String: screen.dictionaryRepresentation]])
            panel.fullscreenFrameProvider = { screen }
            panel.fullscreenDisplayUUIDProvider = { "left" }
            panel.fullscreenCGWindowsProvider = cg.capture
            panel.fullscreenProbeGeneration = 1
            let request = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: nil,
                                                 finalConfirmation: false, source: "test", displayUUID: "left")
            panel.receiveFullscreenProbe(
                FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil), request: request
            )
            XCTAssertFalse(panel.visibilityState.isVisible)

            panel.receiveFullscreenProbe(
                FullscreenAXProbe(verdict: .fullscreen, overlayWindowID: axOverlayID), request: request
            )
            XCTAssertFalse(panel.visibilityState.isVisible)
            cg.windows = []
            panel.receiveFullscreenProbe(
                FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil), request: request
            )

            XCTAssertEqual(panel.visibilityState.isVisible, expectedVisible)
            panel.tearDown()
        }
    }

    func testStoppedPanelCannotAcquireAnActivationHold() {
        let panel = coordinator()
        panel.visibilityState.setFullscreen(true)
        panel.lastActiveApplicationPID = 42
        panel.handleAppActivated(pid: 42)
        XCTAssertNotNil(panel.fullscreenSpaceHoldTimer)

        panel.tearDown()
        panel.handleAppActivated(pid: 43)
        panel.setupFullscreenMonitor()

        XCTAssertEqual(panel.lastActiveApplicationPID, 42)
        XCTAssertNil(panel.fullscreenProbeWorker)
        XCTAssertNil(panel.fullscreenSpaceHold)
        XCTAssertNil(panel.fullscreenSpaceHoldTimer)
    }

    func testVisibilityHideCancelsInteractionsOnceBeforeOrderingOut() {
        let coordinator = coordinator()
        defer { coordinator.tearDown() }
        let panel = DetachedDockPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let popup = BehaviorPopup()
        let view = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        coordinator.dockPanel = panel
        coordinator.taskbarView = view
        var effects: [String] = []
        popup.onDismiss = { effects.append("cancel interaction") }
        panel.onOrderOut = { effects.append("order out") }

        coordinator.applyPanelVisibility()

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

    func testFullscreenAXProbeRejectsFocusedWindowOwnedByAnotherProcess() {
        let desktop = BehaviorDesktop()
        let reads = Mutex<[String]>([])
        desktop.state.withLock {
            $0.publishedFocusedWindows[-41000] = 2001
            $0.publishedFocusedWindows[-42000] = 2001
            $0.beforeRead = { attribute in reads.withLock { $0.append(attribute) } }
        }
        let screen = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let reader = AXWindowReader(accessibility: desktop)

        let foreign = PanelCoordinator.readFullscreenAXObservation(pid: -41000, reader: reader, system: desktop)
        XCTAssertEqual(foreign.probe(on: screen).verdict, .unknown)
        XCTAssertEqual(reads.withLock { $0 }, [kAXFocusedWindowAttribute as String])

        let owned = PanelCoordinator.readFullscreenAXObservation(pid: -42000, reader: reader, system: desktop)
        XCTAssertEqual(owned.probe(on: screen).verdict, .fullscreen)
    }

    func testSharedFullscreenReadClassifiesTheSameObservationSeparatelyForEachScreen() async {
        let reads = Mutex(0)
        let left = CGRect(x: 0, y: 0, width: 600, height: 500)
        let right = left.offsetBy(dx: left.width, dy: 0)
        let batch = FullscreenReadBatch { _ in
            reads.withLock { $0 += 1 }
            return .window(role: kAXWindowRole as String, isFullscreen: false, frame: left, id: 10, layer: 0)
        }
        async let leftResult = Task.detached { batch.observation(for: 42).probe(on: left) }.value
        async let rightResult = Task.detached { batch.observation(for: 42).probe(on: right) }.value
        let (leftProbe, rightProbe) = await (leftResult, rightResult)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertEqual(leftProbe.verdict, .fullscreen)
        XCTAssertEqual(leftProbe.overlayWindowID, 10)
        XCTAssertEqual(rightProbe.verdict, .notOnThisScreen)
        XCTAssertNil(rightProbe.overlayWindowID)
    }

    func testDelayedPanelRefreshesAnExpiredSharedFullscreenObservation() {
        let reads = Mutex(0)
        let now = Mutex<TimeInterval>(10)
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let window = CGRect(x: 20, y: 20, width: 500, height: 400)
        let batch = FullscreenReadBatch(uptime: { now.withLock { $0 } }) { _ in
            reads.withLock { count in
                count += 1
                return count == 1
                    ? .window(role: kAXWindowRole as String, isFullscreen: true, frame: screen, id: nil, layer: nil)
                    : .window(role: kAXWindowRole as String, isFullscreen: false, frame: window, id: nil, layer: nil)
            }
        }
        XCTAssertEqual(batch.observation(for: 42).probe(on: screen).verdict, .fullscreen)
        now.withLock { $0 += 1 }
        XCTAssertEqual(batch.observation(for: 42).probe(on: screen).verdict, .windowed)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    func testDelayedCGProbeRefreshesAnExpiredImmediateSpaceSnapshot() {
        let uptime = Mutex<TimeInterval>(10)
        let cg = CGWindows(nil)
        let batch = FullscreenReadBatch(uptime: { uptime.withLock { $0 } }, readCG: cg.capture) { _ in .unknown }
        func capture() -> [[String: Any]]? {
            XCTFail("Unbatched capture")
            return nil
        }
        XCTAssertNil(batch.cgWindows(isImmediateSpaceChange: true, fallback: capture))
        cg.windows = []
        uptime.withLock { $0 += 1 }

        XCTAssertNil(batch.cgWindows(isImmediateSpaceChange: true, fallback: capture))
        XCTAssertEqual(cg.captures, 1)

        XCTAssertEqual(batch.cgWindows(fallback: capture)?.count, 0)
        XCTAssertEqual(cg.captures, 2)
    }

    private func coordinator(placement: TaskbarUnitPlacement = .primary, usesSLS: Bool = true) -> PanelCoordinator {
        let coordinator = PanelCoordinator(placement: placement, overlaySpaceHost: nil, runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
                physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)),
            fullscreenSLSVerdictEnabled: usesSLS, screenProvider: { [] }, mainScreenProvider: { nil })
        coordinator.fullscreenFrameProvider = { .zero }
        coordinator.fullscreenCGWindowsProvider = { [] }
        coordinator.fullscreenCGWindowObservationProvider = { _ in nil }
        return coordinator
    }

    func testPanelCreationAndPlacementWaitForAnAvailableScreen() {
        let coordinator = coordinator()
        XCTAssertFalse(coordinator.start())
        XCTAssertNil(coordinator.dockPanel)
        XCTAssertNil(coordinator.currentScreen)
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        XCTAssertNil(coordinator.panelCurrentScreen(panel: panel))
        coordinator.dockPanel = panel
        coordinator.relayout()
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
    }

    func testUnknownFullscreenNeverClearsLastKnownFullscreen() {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        coordinator.fullscreenProbeGeneration = 2
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test")
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil), request: request)
        XCTAssertFalse(coordinator.visibilityState.isVisible)
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil), request: request)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
    }

    func testFinalSpaceHoldReleasesWithConfirmedDesktopAndWindowedCGWhenAXIsUnknown() async {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        let otherScreen = screen.offsetBy(dx: screen.width, dy: 0)
        func window(_ id: UInt32, _ frame: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: -42,
             kCGWindowLayer as String: layer, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let desktopWindows = [window(10, CGRect(x: 10, y: 20, width: 500, height: 450)),
                              window(11, otherScreen), window(12, screen, layer: -1)]
        let stillFullscreen = [window(13, screen, layer: 2)] + desktopWindows
        let cases: [(String, Bool?, [[String: Any]]?, Bool)] = [
            ("confirmed desktop", false, desktopWindows, true),
            ("empty desktop", false, [], true),
            ("window list failed", false, nil, false),
            ("display Space unavailable", nil, desktopWindows, false),
            ("native fullscreen Space", true, desktopWindows, false),
            ("screen-sized overlay still present", false, stillFullscreen, false)
        ]
        for (label, space, windows, expectedVisible) in cases {
            let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
            defer { coordinator.tearDown() }
            coordinator.fullscreenFrameProvider = { screen }
            coordinator.fullscreenCGWindowsProvider = { windows }
            coordinator.visibilityState.setFullscreen(true)
            coordinator.lastActiveApplicationPID = 42
            var confirmed = false
            coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { _ in
                FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
            }, readSpace: { $0.displayUUID == "left" ? space : nil }, deliver: { [weak coordinator] request, probe in
                coordinator?.receiveFullscreenProbe(probe, request: request)
                if request.finalConfirmation { confirmed = true }
            })

            coordinator.handleSpaceChange()
            XCTAssertFalse(coordinator.visibilityState.isVisible, label)
            coordinator.fullscreenSpaceHoldTimer?.fire()
            let deadline = ContinuousClock.now + .seconds(2)
            while !confirmed, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(confirmed, label)
            XCTAssertEqual(coordinator.visibilityState.isVisible, expectedVisible, label)
        }
    }

    func testActivationWithoutFocusedWindowKeepsPanelHiddenWhenDisplaySpaceIsUnknown() async throws {
        let coordinator = coordinator(placement: .fixed(displayUUID: "right"))
        defer { coordinator.tearDown() }
        coordinator.fullscreenFrameProvider = { nil }
        coordinator.fullscreenSpaceProvider = { _ in nil }
        coordinator.fullscreenCGWindowsProvider = { [] }
        coordinator.setupFullscreenMonitor()
        let worker = try XCTUnwrap(coordinator.fullscreenProbeWorker)
        coordinator.fullscreenFrameProvider = { CGRect(x: 600, y: 0, width: 600, height: 500) }
        coordinator.visibilityState.setFullscreen(true)

        coordinator.handleAppActivated(pid: nil, sharedRead: FullscreenReadBatch { _ in .unknown })
        let confirmation = try XCTUnwrap(coordinator.fullscreenSpaceHoldTimer)
        confirmation.fire()
        while let work = worker.pendingWorkForTesting.first { await work.value }

        XCTAssertFalse(coordinator.visibilityState.isVisible)
    }

    func testSystemFocusCannotRevealThePanelWhileItsDisplayRemainsInAFullscreenSpace() {
        let coordinator = coordinator()
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: true, source: "system-focus")
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: true), request: request)
        XCTAssertFalse(coordinator.visibilityState.isVisible)
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: false), request: request)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testMissingSpaceAndCGReadsKeepAnIdentifiedFullscreenDisplayHidden() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        for verdict in [FullscreenAXVerdict.windowed, .notOnThisScreen] {
            let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
            coordinator.fullscreenFrameProvider = { frame }
            coordinator.fullscreenCGWindowsProvider = { nil }
            coordinator.fullscreenProbeGeneration = 1
            coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 2, pid: 42, displayWindowServerFrame: frame)
            coordinator.visibilityState.setFullscreen(true)
            let request = FullscreenProbeRequest(pid: 42, screenFrame: frame, generation: 1, spaceGeneration: 2,
                                                 finalConfirmation: true, source: "fixture", displayUUID: "left")
            coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: verdict, overlayWindowID: nil), request: request)
            XCTAssertFalse(coordinator.visibilityState.isVisible)
            coordinator.receiveFullscreenProbe(
                FullscreenAXProbe(verdict: verdict, overlayWindowID: nil, spaceVerdict: false), request: request)
            XCTAssertTrue(coordinator.visibilityState.isVisible)
            coordinator.tearDown()
        }
    }

    func testClosedFullscreenOverlayRevealsDesktopWithoutASpaceChange() {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        let frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        coordinator.fullscreenFrameProvider = { frame }
        coordinator.fullscreenCGWindowsProvider = { [] }
        coordinator.fullscreenProbeGeneration = 1
        coordinator.visibilityState.setFullscreen(true)
        let request = FullscreenProbeRequest(pid: 42, screenFrame: frame, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "fixture", displayUUID: "left")
        coordinator.receiveFullscreenProbe(
            FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil, spaceVerdict: false), request: request)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testSplitViewKeepsFullscreenPanelHiddenWhenSpaceReadingFails() {
        for placement in [TaskbarUnitPlacement.primary, .fixed(displayUUID: "left")] {
            let coordinator = coordinator(placement: placement)
            let frame = CGRect(x: 0, y: 0, width: 600, height: 500)
            coordinator.fullscreenFrameProvider = { frame }
            coordinator.fullscreenCGWindowsProvider = {
                [CGRect(x: 0, y: 20, width: 298, height: 480),
                 CGRect(x: 302, y: 20, width: 298, height: 480)].map {
                    [kCGWindowBounds as String: $0.dictionaryRepresentation]
                }
            }
            coordinator.fullscreenProbeGeneration = 1
            coordinator.visibilityState.setFullscreen(true)
            let request = FullscreenProbeRequest(pid: 42, screenFrame: frame, generation: 1, spaceGeneration: nil,
                                                 finalConfirmation: false, source: "fixture",
                                                 displayUUID: coordinator.fixedUnitDisplayUUID)
            coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil), request: request)
            XCTAssertFalse(coordinator.visibilityState.isVisible)
            coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 2, pid: 42, displayWindowServerFrame: frame)
            let otherDisplay = FullscreenProbeRequest(pid: 42, screenFrame: frame, generation: 1, spaceGeneration: 2,
                                                      finalConfirmation: true, source: "fixture",
                                                      displayUUID: coordinator.fixedUnitDisplayUUID)
            coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil),
                                                request: otherDisplay)
            XCTAssertFalse(coordinator.visibilityState.isVisible)
            coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .notOnThisScreen, overlayWindowID: nil, spaceVerdict: false),
                                                request: otherDisplay)
            XCTAssertTrue(coordinator.visibilityState.isVisible)
            coordinator.tearDown()
        }
    }

    func testFullscreenCallbackDoesNotSynchronouslyReadManagedSpaces() {
        let coordinator = coordinator()
        coordinator.fullscreenProbeGeneration = 1
        let reads = Mutex(0)
        coordinator.fullscreenSpaceProvider = { _ in
            reads.withLock { $0 += 1 }
            return true
        }
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
                                             finalConfirmation: false, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil), request: request)

        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testFullscreenWorkerReadsFreshSpacesOffMainThreadAndAppliesBothTransitions() async {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        coordinator.fullscreenFrameProvider = { .zero }
        let reads = Mutex<[Bool]>([])
        let fullSpace = Mutex(true)
        var delivered = 0
        let worker = FullscreenProbeWorker(read: { _ in
            FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, readSpace: { request in
            guard request.displayUUID == "left" else { return nil }
            reads.withLock { $0.append(Thread.isMainThread) }
            return fullSpace.withLock { $0 }
        }, deliver: { request, probe in
            delivered += 1
            coordinator.receiveFullscreenProbe(probe, request: request)
        })
        coordinator.fullscreenProbeGeneration = 1
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left"))
        let firstDeadline = ContinuousClock.now + .seconds(2)
        while delivered < 1, ContinuousClock.now < firstDeadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(coordinator.visibilityState.isVisible)

        fullSpace.withLock { $0 = false }
        coordinator.fullscreenProbeGeneration = 2
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left"))
        let secondDeadline = ContinuousClock.now + .seconds(2)
        while delivered < 2, ContinuousClock.now < secondDeadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 2)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        XCTAssertEqual(reads.withLock { $0 }, [false, false])
        worker.stop()
        coordinator.tearDown()
    }

    func testLateFullscreenSpaceResultCannotApplyToANewerProbeGeneration() async {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        let screen = CGRect(x: 0, y: 0, width: 600, height: 500)
        coordinator.fullscreenFrameProvider = { screen }
        coordinator.fullscreenProbeGeneration = 1
        coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 3, pid: 42, displayWindowServerFrame: screen)
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        var delivered = 0
        let worker = FullscreenProbeWorker(read: { _ in
            FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        }, readSpace: { _ in
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return true
        }, deliver: { request, probe in
            delivered += 1
            coordinator.receiveFullscreenProbe(probe, request: request)
        })
        defer { gate.signal(); worker.stop(); coordinator.tearDown() }
        worker.request(FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 1, spaceGeneration: 3,
            finalConfirmation: true, source: "test", displayUUID: "left"))
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(entered.withLock { $0 })
        coordinator.fullscreenProbeGeneration = 2
        gate.signal()
        while delivered == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        let current = FullscreenProbeRequest(pid: 42, screenFrame: screen, generation: 2, spaceGeneration: 3,
            finalConfirmation: true, source: "test", displayUUID: "left")
        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil, spaceVerdict: true),
                                           request: current)
        XCTAssertFalse(coordinator.visibilityState.isVisible)
    }

    func testFullscreenSpaceResultCannotApplyAfterDisplayGeometryChanges() {
        let coordinator = coordinator(placement: .fixed(displayUUID: "left"))
        coordinator.fullscreenFrameProvider = { CGRect(x: 100, y: 0, width: 100, height: 100) }
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 1, spaceGeneration: nil,
            finalConfirmation: false, source: "test", displayUUID: "left")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil, spaceVerdict: true), request: request)

        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testWindowedSpaceResultCannotClearANewerFullscreenHold() {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        coordinator.fullscreenProbeGeneration = 2
        coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 4, pid: 42, displayWindowServerFrame: .zero)
        let request = FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: 2, spaceGeneration: 3,
            finalConfirmation: true, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil, spaceVerdict: false), request: request)

        XCTAssertFalse(coordinator.visibilityState.isVisible)
        XCTAssertEqual(coordinator.fullscreenSpaceHold?.generation, 4)
        coordinator.tearDown()
    }

    func testResidentPanelUsesNativeMissionControlHidingWithoutDesktopPresentation() {
        let coordinator = coordinator()
        let panel = NonConstrainingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        coordinator.configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.isVisible)
        coordinator.tearDown()
    }

    func testFullscreenWorkerCoalescesBurstAndDoesNotPublishAfterStop() async {
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        var results: [UInt64] = []
        let worker = FullscreenProbeWorker(read: { _ in
            calls.withLock { $0 += 1 }
            _ = gate.wait(timeout: .now() + 2)
            return FullscreenAXProbe(verdict: .fullscreen, overlayWindowID: nil)
        }, deliver: { request, _ in results.append(request.generation) })
        for generation in 1...20 {
            worker.request(FullscreenProbeRequest(pid: 42, screenFrame: .zero, generation: UInt64(generation),
                                                  spaceGeneration: nil, finalConfirmation: false, source: "test"))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while calls.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        gate.signal()
        while calls.withLock({ $0 }) < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertTrue(results.isEmpty)
        let pending = worker.pendingWorkForTesting
        worker.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertTrue(results.isEmpty)
    }

    func testDesktopSpaceChangeDismissesAnOpenPopupSynchronously() {
        let coordinator = coordinator()
        coordinator.panelsAreVisible = false
        let popup = BehaviorPopup()
        let view = TaskbarView(frame: .zero, popup: popup, contextMenu: BehaviorMenu())
        coordinator.taskbarView = view
        popup.present(content: NSView(), frame: .zero, anchorWindow: nil)
        XCTAssertTrue(popup.isPresented)
        XCTAssertTrue(coordinator.visibilityState.isVisible)

        coordinator.handleSpaceChange()

        XCTAssertFalse(popup.isPresented)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }

    func testGeometryProbeCanCompleteTheExpiredFullscreenHold() async {
        let coordinator = coordinator()
        coordinator.visibilityState.setFullscreen(true)
        let requests = Mutex<[FullscreenProbeRequest]>([])
        let unblockFirstProbe = DispatchSemaphore(value: 0)
        var delivered: [FullscreenProbeRequest] = []
        coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { request in
            let first = requests.withLock {
                $0.append(request)
                return $0.count == 1
            }
            if first { _ = unblockFirstProbe.wait(timeout: .now() + 3) }
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, deliver: { [weak coordinator] request, probe in
            delivered.append(request)
            coordinator?.receiveFullscreenProbe(probe, request: request)
        })
        defer {
            unblockFirstProbe.signal()
            coordinator.tearDown()
        }

        coordinator.handleAppActivated(pid: 42)
        let holdGeneration = coordinator.fullscreenSpaceHold?.generation
        XCTAssertNotNil(holdGeneration)
        coordinator.fullscreenSpaceHoldTimer?.fire()
        let deadline = ContinuousClock.now + .seconds(2)
        while coordinator.fullscreenSpaceHoldTimer != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(coordinator.fullscreenSpaceHoldTimer)

        coordinator.windowGeometryChanged()
        let latestGeneration = coordinator.fullscreenProbeGeneration
        unblockFirstProbe.signal()
        while delivered.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(delivered.map(\.generation), [latestGeneration])
        XCTAssertEqual(delivered.first?.spaceGeneration, holdGeneration)
        XCTAssertNil(coordinator.fullscreenSpaceHold)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
    }

    func testPeriodicFullscreenCheckRunsWhileVisibleAndCompletesAPendingHold() async {
        let coordinator = coordinator()
        coordinator.fullscreenFrameProvider = { CGRect(x: 0, y: 0, width: 100, height: 100) }
        var cgReads = 0
        coordinator.fullscreenCGWindowsProvider = { cgReads += 1; return [] }
        let reads = Mutex(0)
        var requests: [FullscreenProbeRequest] = []
        coordinator.fullscreenProbeWorker = FullscreenProbeWorker(read: { _ in
            reads.withLock { $0 += 1 }
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, deliver: { [weak coordinator] request, probe in
            requests.append(request)
            coordinator?.receiveFullscreenProbe(probe, request: request)
        })
        coordinator.reconcileFullscreenState()
        let deadline = ContinuousClock.now + .seconds(2)
        while requests.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(reads.withLock { $0 }, 1)
        coordinator.visibilityState.setFullscreen(true)
        coordinator.lastActiveApplicationPID = 42
        coordinator.fullscreenSpaceHold = FullscreenSpaceHold(generation: 7, pid: 42, displayWindowServerFrame: coordinator.currentPanelScreenCGFrame())
        coordinator.reconcileFullscreenState()
        while requests.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(requests.last?.spaceGeneration, 7)
        XCTAssertEqual(requests.last?.finalConfirmation, true)
        XCTAssertNil(coordinator.fullscreenSpaceHold)
        XCTAssertTrue(coordinator.visibilityState.isVisible)
        XCTAssertEqual(cgReads, 1)
        coordinator.tearDown()
    }

    func testDisplayDisconnectAndReconnectRebuildUnitsWithoutShowingPanels() {
        var snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        var starts = 0
        let orchestrator = TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: PanelInventory()),
            stripOrderStore: StripOrderStore(),
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: snapshot),
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
            topologySnapshotProvider: { snapshot }, startCoordinator: { _ in starts += 1; return true })
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
}

extension PanelLifecycleTests {
    func testFullscreenResultRejectsChangedGeometryWhenDisplayUUIDIsUnavailable() {
        let coordinator = coordinator()
        coordinator.fullscreenFrameProvider = { CGRect(x: 100, y: 0, width: 100, height: 100) }
        coordinator.fullscreenProbeGeneration = 1
        let request = FullscreenProbeRequest(pid: 42, screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            generation: 1, spaceGeneration: nil, finalConfirmation: false, source: "test")

        coordinator.receiveFullscreenProbe(FullscreenAXProbe(verdict: .fullscreen, overlayWindowID: nil), request: request)

        XCTAssertTrue(coordinator.visibilityState.isVisible)
        coordinator.tearDown()
    }
}
