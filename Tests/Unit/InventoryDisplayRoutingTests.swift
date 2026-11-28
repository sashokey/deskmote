import ApplicationServices
import Combine
import CoreGraphics
import Synchronization
import XCTest

@MainActor
final class AppTrackerDisplayAttributionTests: XCTestCase {
    private let pid: pid_t = 5151
    private let cgWindow: CGWindowID = 91

    private let frameOnA = CGRect(x: 100, y: 100, width: 500, height: 400)
    private let frameOnAMoved = CGRect(x: 300, y: 150, width: 500, height: 400)
    private let frameOnB = CGRect(x: 1200, y: 100, width: 500, height: 400)

    private let tableAB = WindowDisplayAttribution.Table(
        displays: [
            .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ],
        primaryUUID: "A"
    )

    func testNativeMovementUpdatesInventoryWithUnchangedVisibleWindowNumbers() async throws {
        let (pid, cgWindow, table) = (pid, cgWindow, tableAB)
        let reader = DisplayMovementReader(pid: pid, windowID: cgWindow, bounds: frameOnA)
        let fullCaptures = Mutex(0)
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: pid, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        let tracker = AppTracker(reader: reader, processProvider: DisplayAttributionFixedProcessProvider(),
            cgSnapshotProvider: {
                fullCaptures.withLock { $0 += 1 }
                return .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                             alphaByWindowID: [:], boundsByWindowID: [cgWindow: reader.bounds.withLock { $0 }],
                             parentWindowIDs: [cgWindow: 0])
            }, cgWindowSnapshotProvider: { id in
                .init(allWindowIDs: [id], onScreenWindowIDs: [id], windowIDsByPID: [pid: [id]],
                      alphaByWindowID: [:], boundsByWindowID: [id: reader.bounds.withLock { $0 }], parentWindowIDs: [id: 0])
            }, onScreenWindowIDsProvider: { [cgWindow] }, cgSnapshotReuseEnabled: true,
            uptimeProvider: { 100 }, frontmostPIDProvider: { pid }, displayTableProvider: { table })
        defer { tracker.stop() }
        let id = WindowID(rawValue: "cgw-\(cgWindow)")
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.observeWindows(observer)
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.scheduleEventReadForTesting(pid: pid, source: .initialEnumeration)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "A")
        XCTAssertEqual(fullCaptures.withLock { $0 }, 1)
        XCTAssertEqual(observer.subscribedElement(cgWindowID: cgWindow).map { AXElementKey(e: $0.element) }, reader.element)
        let receive = try XCTUnwrap(callback.withLock { $0 })

        var publications: [String?] = []
        let subscription = tracker.snapshots.sink { publications.append($0.windows[id]?.displayUUID) }
        defer { subscription.cancel() }
        reader.bounds.withLock { $0 = frameOnB }
        receive(AXElementKey(e: AXUIElementCreateApplication(pid + 1)), kAXWindowMovedNotification)
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { tracker.snapshot.windows[id]?.displayUUID == "B" }
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(reader.reads.withLock { $0 }, 1)
        XCTAssertEqual(fullCaptures.withLock { $0 }, 1)
        XCTAssertEqual(tracker.snapshot.windows[id]?.cgWindowID, cgWindow)

        reader.bounds.withLock { $0 = frameOnA }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { tracker.snapshot.windows[id]?.displayUUID == "A" }
        XCTAssertEqual(fullCaptures.withLock { $0 }, 1)
        reader.bounds.withLock { $0 = frameOnAMoved }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement {
            tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.confirmedCGDisplayBounds == frameOnAMoved
        }
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(publications, ["A", "B", "A"])
        XCTAssertEqual(fullCaptures.withLock { $0 }, 1)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)

        let replaced = reader.element
        let replacement = AXElementKey(e: AXUIElementCreateApplication(pid + 2))
        reader.currentElement.withLock { $0 = replacement }
        receive(replacement, kAXWindowCreatedNotification)
        await waitForMovement {
            observer.subscribedElement(cgWindowID: cgWindow).map { AXElementKey(e: $0.element) } == replacement
        }
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        let readsBeforeMove = reader.reads.withLock { $0 }
        let capturesBeforeMove = fullCaptures.withLock { $0 }
        reader.bounds.withLock { $0 = frameOnB }
        receive(replaced, kAXWindowMovedNotification)
        await Task.yield()
        receive(replacement, kAXWindowMovedNotification)
        await waitForMovement { tracker.snapshot.windows[id]?.displayUUID == "B" }
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(reader.reads.withLock { $0 }, readsBeforeMove)
        XCTAssertEqual(fullCaptures.withLock { $0 }, capturesBeforeMove)
    }

    func testNativeResizeInvalidatesOnlyTheExactTrackedWindowEvenWithoutASnapshotChange() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        var invalidations: [CGWindowID] = []
        let subscription = fixture.tracker.windowSpaceInvalidations.sink { invalidations.append($0) }
        defer { subscription.cancel() }
        let previous = fixture.tracker.snapshot

        fixture.receive(AXElementKey(e: AXUIElementCreateApplication(pid + 1)), kAXWindowResizedNotification)
        fixture.receive(fixture.reader.element, kAXWindowResizedNotification)
        await waitForMovement { invalidations == [cgWindow] }
        await drainMovementWork(fixture.tracker)

        XCTAssertEqual(invalidations, [cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot, previous)
    }

    func testMoveBurstRoutesTheLatestFrameWithoutFullInventoryOrCapture() async throws {
        let gate = DisplayCaptureGate()
        let fixture = try await makeMovementFixture(firstExactGate: gate)
        defer { gate.open(); fixture.tracker.stop() }
        let initialReads = fixture.reader.reads.withLock { $0 }
        let initialFullCaptures = fixture.cg.fullCaptures.withLock { $0 }
        let move = fixture.observer.onWindowMoved
        var accepted = 0
        fixture.observer.onWindowMoved = { pid, id, element in
            move?(pid, id, element)
            accepted += 1
        }
        fixture.reader.bounds.withLock { $0 = frameOnAMoved }
        fixture.cg.bounds.withLock { $0 = frameOnAMoved }
        gate.arm()
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { gate.isBlocked }

        fixture.cg.bounds.withLock { $0 = frameOnB }
        for _ in 1..<100 {
            fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        }
        await waitForMovement { accepted == 100 }
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "A")
        gate.open()
        await drainMovementWork(fixture.tracker)

        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, Array(repeating: cgWindow, count: 3))
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, initialReads)
        XCTAssertEqual(fixture.cg.fullCaptures.withLock { $0 }, initialFullCaptures)
        XCTAssertFalse(gate.timedOut)
    }

    func testTabSwitchImmediatelyAfterTargetedMoveRetainsItsSeat() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        let handle = try XCTUnwrap(fixture.observer.subscribedElement(cgWindowID: cgWindow))
        let token = try XCTUnwrap(fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.token)
        fixture.cg.bounds.withLock { $0 = frameOnAMoved }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement {
            fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.confirmedCGDisplayBounds == frameOnAMoved
        }
        XCTAssertEqual(fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)

        let replacement = cgWindow + 1
        let snapshot = AppTrackerCGWindowSnapshot.timedCapture {
            .init(allWindowIDs: [cgWindow, replacement], onScreenWindowIDs: [replacement],
                  windowIDsByPID: [pid: [cgWindow, replacement]], alphaByWindowID: [:],
                  boundsByWindowID: [cgWindow: frameOnAMoved, replacement: frameOnAMoved],
                  parentWindowIDs: [cgWindow: 0, replacement: 0])
        }
        let candidate = AXWindowSnapshot(pid: pid, cgWindowID: replacement, titleRead: .value("Next tab"),
            bounds: frameOnAMoved, role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(pid + 1), isMinimizedRead: false)
        let evidence = AbsentSeatProbeEvidence(request: .init(cgWindowID: cgWindow, seatToken: token,
            element: AXElementKey(e: handle.element), instanceID: handle.instanceID, probeCount: 0),
            element: .alive(minimized: false), windowSpaceIDs: [], currentSpaceIDs: [1])
        fixture.tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: snapshot, now: Date(),
            eligible: [candidate], readOutcome: .success, rawAXCgIDs: [replacement], absenceEvidence: [cgWindow: evidence])

        let app = try XCTUnwrap(fixture.tracker.fixtureAppForTesting(pid: pid))
        XCTAssertEqual(app.windowOrder, [replacement])
        XCTAssertEqual(app.windowsByID[replacement]?.token, token)
        XCTAssertEqual(app.windowsByID[replacement]?.priorTabWindowNumbers, [cgWindow])
    }

    func testOlderFullCGCaptureCannotOverrideCompletedTargetedTransfer() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        let stale = AppTrackerCGWindowSnapshot.timedCapture { cgSnapshot(bounds: [cgWindow: frameOnA]) }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { fixture.tracker.snapshot.windows[fixture.id]?.displayUUID == "B" }

        XCTAssertFalse(fixture.tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: stale))
        XCTAssertFalse(fixture.tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: stale))
        let seat = fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]
        XCTAssertEqual(seat?.displayUUID, "B")
        XCTAssertEqual(seat?.confirmedCGDisplayBounds, frameOnB)
    }

    func testTargetedMoveFallsBackWhenTheWindowBecomesANativeChild() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        let fullCaptures = fixture.cg.fullCaptures.withLock { $0 }
        var displays: [String?] = []
        let subscription = fixture.tracker.snapshots.sink { displays.append($0.windows[fixture.id]?.displayUUID) }
        defer { subscription.cancel() }
        fixture.cg.parent.withLock { $0 = cgWindow + 1 }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { fixture.tracker.snapshot.windows[fixture.id] == nil }
        await drainMovementWork(fixture.tracker)

        XCTAssertFalse(displays.contains("B"))
        XCTAssertEqual(fixture.cg.fullCaptures.withLock { $0 }, fullCaptures + 1)
    }

    func testOlderNativeChildSnapshotCannotRetireRootAfterTargetedMove() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        let stale = AppTrackerCGWindowSnapshot.timedCapture {
            .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                  alphaByWindowID: [:], boundsByWindowID: [cgWindow: frameOnA], parentWindowIDs: [cgWindow: cgWindow + 1])
        }
        fixture.cg.bounds.withLock { $0 = frameOnAMoved }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement {
            fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.confirmedCGDisplayBounds == frameOnAMoved
        }

        _ = fixture.tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: stale, now: Date(), eligible: [],
            readOutcome: .unread)
        XCTAssertEqual(fixture.tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [cgWindow])
    }

    func testOlderEmptyInventoryCannotRetireRootAfterTargetedMove() async throws {
        let fixture = try await makeMovementFixture()
        defer { fixture.tracker.stop() }
        let stale = AppTrackerCGWindowSnapshot.timedCapture {
            .init(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        }
        fixture.cg.bounds.withLock { $0 = frameOnAMoved }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement {
            fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.confirmedCGDisplayBounds == frameOnAMoved
        }

        _ = fixture.tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: stale, now: Date(), eligible: [],
            readOutcome: .success, rawAXCgIDs: [])
        XCTAssertEqual(fixture.tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [cgWindow])
    }

    func testNewerNativeMovementSuppressesAnOlderDisplayReadBeforeItPublishes() async throws {
        let (pid, cgWindow, table, frameOnB) = (pid, cgWindow, tableAB, frameOnB)
        let reader = DisplayMovementReader(pid: pid, windowID: cgWindow, bounds: frameOnA)
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: pid, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        let entered = Mutex(false)
        let timeouts = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let tracker = AppTracker(reader: reader, processProvider: DisplayAttributionFixedProcessProvider(),
            cgSnapshotProvider: {
                let bounds = reader.bounds.withLock { $0 }
                if bounds == frameOnB {
                    entered.withLock { $0 = true }
                    if gate.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
                }
                return .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                             alphaByWindowID: [:], boundsByWindowID: [cgWindow: bounds], parentWindowIDs: [cgWindow: 0])
            }, onScreenWindowIDsProvider: { [cgWindow] }, cgSnapshotReuseEnabled: true,
            uptimeProvider: { 100 }, frontmostPIDProvider: { pid }, displayTableProvider: { table })
        defer { gate.signal(); tracker.stop() }
        let id = WindowID(rawValue: "cgw-\(cgWindow)")
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.observeWindows(observer)
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.scheduleEventReadForTesting(pid: pid, source: .initialEnumeration)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        let receive = try XCTUnwrap(callback.withLock { $0 })

        var acceptedEvents = 0
        let trackMove = observer.onWindowMoved
        observer.onWindowMoved = { pid, windowID, element in
            trackMove?(pid, windowID, element)
            acceptedEvents += 1
        }
        var publications: [String?] = []
        let subscription = tracker.snapshots.sink { publications.append($0.windows[id]?.displayUUID) }
        defer { subscription.cancel() }
        reader.bounds.withLock { $0 = frameOnB }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { entered.withLock { $0 } }
        let blockedRead = tracker.pendingInventoryWorkForTesting
        reader.bounds.withLock { $0 = frameOnAMoved }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { acceptedEvents == 2 }

        gate.signal()
        for task in blockedRead { await task.value }
        await waitForMovement { reader.reads.withLock { $0 } == 3 }
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(publications, ["A"])
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "A")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnAMoved)
        XCTAssertEqual(timeouts.withLock { $0 }, 0)
    }

    func testNativeMovementChecksCurrentCGWhenAXStillReportsTheOldDisplay() async throws {
        let (pid, cgWindow, table) = (pid, cgWindow, tableAB)
        let reader = DisplayMovementReader(pid: pid, windowID: cgWindow, bounds: frameOnA)
        let cgBounds = Mutex(frameOnA)
        let capturedWindowIDs = Mutex<[CGWindowID]>([])
        let allowSamples = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        let timeouts = Mutex(0)
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: pid, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        let tracker = AppTracker(reader: reader, processProvider: DisplayAttributionFixedProcessProvider(),
            cgSnapshotProvider: {
                .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                      alphaByWindowID: [:], boundsByWindowID: [cgWindow: cgBounds.withLock { $0 }], parentWindowIDs: [cgWindow: 0])
            }, cgWindowSnapshotProvider: { id in
                let attempt = capturedWindowIDs.withLock { $0.append(id); return $0.count }
                if attempt.isMultiple(of: 2), allowSamples.indices.contains(attempt / 2 - 1),
                   allowSamples[attempt / 2 - 1].wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
                return .init(allWindowIDs: [id], onScreenWindowIDs: [id], windowIDsByPID: [pid: [id]],
                             alphaByWindowID: [:], boundsByWindowID: [id: cgBounds.withLock { $0 }], parentWindowIDs: [id: 0])
            }, onScreenWindowIDsProvider: { [cgWindow] }, cgSnapshotReuseEnabled: true,
            uptimeProvider: { 100 }, frontmostPIDProvider: { pid }, displayTableProvider: { table })
        defer { for gate in allowSamples { gate.signal() }; tracker.stop() }
        let id = WindowID(rawValue: "cgw-\(cgWindow)")
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.observeWindows(observer)
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.scheduleEventReadForTesting(pid: pid, source: .initialEnumeration)
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "A")
        let receive = try XCTUnwrap(callback.withLock { $0 })

        reader.bounds.withLock { $0 = frameOnAMoved }
        cgBounds.withLock { $0 = frameOnB }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { capturedWindowIDs.withLock { $0.count } == 2 }
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "A")
        allowSamples[0].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)

        reader.bounds.withLock { $0 = frameOnB }
        cgBounds.withLock { $0 = frameOnA }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { capturedWindowIDs.withLock { $0.count } == 4 }
        cgBounds.withLock { $0 = frameOnB }
        allowSamples[1].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "B")

        cgBounds.withLock { $0 = frameOnA }
        receive(reader.element, kAXWindowMovedNotification)
        await waitForMovement { capturedWindowIDs.withLock { $0.count } == 6 }
        receive(reader.element, kAXWindowMiniaturizedNotification)
        await waitForMovement { tracker.snapshot.windows[id]?.status == .minimized }
        allowSamples[2].signal()
        for task in tracker.pendingInventoryWorkForTesting { await task.value }
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "B")
        XCTAssertEqual(capturedWindowIDs.withLock { $0 }, Array(repeating: cgWindow, count: 6))
        XCTAssertEqual(timeouts.withLock { $0 }, 0)
    }

    func testNativeMoveCompletesWhileATitleReadIsBlocked() async throws {
        let gate = DisplayCaptureGate()
        let fixture = try await makeMovementFixture(bulkGate: gate)
        defer { gate.open(); fixture.tracker.stop() }
        let actions = DisplayMovementActions()
        let runtime = AppRuntime(tracker: DisplayMovementInventory(tracker: fixture.tracker), actionExecutor: actions)
        let layouts = ["A": SpaceLayoutSnapshot(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1),
                       "B": SpaceLayoutSnapshot(orderedSpaceIDs: [10], fullscreenSpaceIDs: [], currentSpaceID: 10)]
        let spaces = TaskbarSpaceStore(read: { requests in
            WindowSpaceSnapshot(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.displayUUID == "B" ? Set([10]) : Set([1]))
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"], attributionTable: tableAB))
        let domain = "DeskMote.QueuedMovement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let ordering = StripOrderStore(defaults: defaults)
        let a = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let b = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenters = [("A", a), ("B", b)].map { display, view in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: spaces,
                             displayUUID: display, backgroundMenu: { _, _ in },
                             contextMenuVisibilityChanged: { _ in })
        }
        func ids(_ view: TaskbarView) -> [String] { view.taskbarContent.groups.flatMap(\.windows).map(\.item.actionWindowID) }
        runtime.start()
        spaces.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer {
            spaces.stop()
            runtime.stop()
            defaults.removePersistentDomain(forName: domain)
            withExtendedLifetime(presenters) {}
        }
        await waitForMovement { ids(a) == [fixture.id.rawValue] && ids(b).isEmpty }
        let target = try XCTUnwrap(runtime.snapshot.windows[fixture.id]?.actionIdentity)
        let spaceIdentity = try XCTUnwrap(StripItem.openWindows(from: runtime.snapshot).first?.spaceIdentity)

        let readTitle = fixture.observer.onTitleChanged
        var titleEvents = 0
        fixture.observer.onTitleChanged = { pid, windowID in
            readTitle?(pid, windowID)
            titleEvents += 1
        }
        let readMove = fixture.observer.onWindowMoved
        var moveEvents = 0
        fixture.observer.onWindowMoved = { pid, windowID, element in
            readMove?(pid, windowID, element)
            moveEvents += 1
        }
        gate.arm()
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { gate.isBlocked }

        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { moveEvents == 1 }
        fixture.reader.title.withLock { $0 = "Latest title" }
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { titleEvents == 2 }
        await waitForMovement { fixture.tracker.snapshot.windows[fixture.id]?.displayUUID == "B" }
        await waitForMovement { ids(a).isEmpty && ids(b) == [fixture.id.rawValue] }

        gate.open()
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow, cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.title, "Latest title")
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
        await waitForMovement { ids(a).isEmpty && ids(b) == [fixture.id.rawValue] }
        XCTAssertEqual(spaces.snapshot.memberships[spaceIdentity], [10])
        a.taskbarContent.actions.close(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(actions.ids.withLock { $0.isEmpty })
        b.taskbarContent.actions.close(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(actions.ids.withLock { $0 }, [fixture.id])
        XCTAssertFalse(gate.timedOut)
    }

    func testNativeMoveBackRejectsDisplayCapturedByAnInFlightTitleRead() async throws {
        let gate = DisplayCaptureGate()
        let fixture = try await makeMovementFixture(bulkGate: gate)
        defer { gate.open(); fixture.tracker.stop() }
        let readMove = fixture.observer.onWindowMoved
        var moveEvents = 0
        fixture.observer.onWindowMoved = { pid, windowID, element in
            readMove?(pid, windowID, element)
            moveEvents += 1
        }
        var displays: [String?] = []
        let subscription = fixture.tracker.snapshots.sink { displays.append($0.windows[fixture.id]?.displayUUID) }
        defer { subscription.cancel() }

        fixture.reader.bounds.withLock { $0 = frameOnB }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        gate.arm()
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { gate.isBlocked }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { moveEvents == 1 }
        fixture.reader.bounds.withLock { $0 = frameOnAMoved }
        fixture.reader.title.withLock { $0 = "Title after returning" }
        fixture.cg.bounds.withLock { $0 = frameOnAMoved }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { moveEvents == 2 }
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)

        gate.open()
        await drainMovementWork(fixture.tracker)
        XCTAssertFalse(displays.contains("B"))
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.title, "Title after returning")
        XCTAssertEqual(fixture.tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnAMoved)
        XCTAssertFalse(gate.timedOut)
    }

    func testNativeMoveReceivesBothExactSamplesDuringInventoryBackoff() async throws {
        let uptime = UptimeBox()
        let fixture = try await makeMovementFixture(uptime: { uptime.now })
        defer { fixture.tracker.stop() }
        fixture.reader.unread.withLock { $0 = true }
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { fixture.reader.reads.withLock { $0 == 2 } }
        await drainMovementWork(fixture.tracker)

        let readMove = fixture.observer.onWindowMoved
        var receivedMove = false
        fixture.observer.onWindowMoved = { pid, windowID, element in
            readMove?(pid, windowID, element)
            receivedMove = true
        }
        fixture.reader.unread.withLock { $0 = false }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { receivedMove }
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 2)
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "A")

        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 2)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow, cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
    }

    func testUnreadNativeMoveRetriesFromTheFrontmostTickAndMovesItsButton() async throws {
        let uptime = UptimeBox()
        let fixture = try await makeMovementFixture(exactFailures: 1, uptime: { uptime.now })
        defer { fixture.tracker.stop() }
        let runtime = AppRuntime(tracker: DisplayMovementInventory(tracker: fixture.tracker),
                                 actionExecutor: DisplayMovementActions())
        let layouts = ["A": SpaceLayoutSnapshot(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1),
                       "B": SpaceLayoutSnapshot(orderedSpaceIDs: [10], fullscreenSpaceIDs: [], currentSpaceID: 10)]
        let spaces = TaskbarSpaceStore(read: { requests in
            WindowSpaceSnapshot(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.displayUUID == "B" ? Set([10]) : Set([1]))
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"], attributionTable: tableAB))
        let domain = "DeskMote.UnreadMovement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let ordering = StripOrderStore(defaults: defaults)
        let a = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let b = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenters = [("A", a), ("B", b)].map { display, view in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: spaces,
                             displayUUID: display, backgroundMenu: { _, _ in },
                             contextMenuVisibilityChanged: { _ in })
        }
        func ids(_ view: TaskbarView) -> [String] { view.taskbarContent.groups.flatMap(\.windows).map(\.item.actionWindowID) }
        runtime.start()
        spaces.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer {
            spaces.stop()
            runtime.stop()
            defaults.removePersistentDomain(forName: domain)
            withExtendedLifetime(presenters) {}
        }
        await waitForMovement { ids(a) == [fixture.id.rawValue] && ids(b).isEmpty }

        fixture.reader.unread.withLock { $0 = true }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { fixture.reader.reads.withLock { $0 == 2 } }
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow])
        XCTAssertEqual(ids(a), [fixture.id.rawValue])
        XCTAssertTrue(ids(b).isEmpty)

        fixture.reader.unread.withLock { $0 = false }
        uptime.now = 100.49
        fixture.tracker.scheduleFrontmostPollForTesting(pid: pid + 1)
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 2)

        uptime.now = 100.5
        fixture.tracker.scheduleFrontmostPollForTesting(pid: pid + 1)
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 3)
        XCTAssertEqual(fixture.reader.bounds.withLock { $0 }, frameOnA)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow, cgWindow, cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
        await waitForMovement { ids(a).isEmpty && ids(b) == [fixture.id.rawValue] }
    }

    func testUnreadNativeMoveKeepsItsExactSamplesForThePeriodicTail() async throws {
        let uptime = UptimeBox()
        let fixture = try await makeMovementFixture(exactFailures: 1, uptime: { uptime.now })
        defer { fixture.tracker.stop() }
        fixture.reader.unread.withLock { $0 = true }
        fixture.cg.bounds.withLock { $0 = frameOnB }
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { fixture.reader.reads.withLock { $0 == 2 } }
        await drainMovementWork(fixture.tracker)

        for (index, due) in [100.5, 101.5, 103.5].enumerated() {
            uptime.now = due - 0.01
            fixture.tracker.scheduleFrontmostPollForTesting(pid: pid + 1)
            await drainMovementWork(fixture.tracker)
            XCTAssertEqual(fixture.reader.reads.withLock { $0 }, index + 2)

            uptime.now = due
            fixture.tracker.scheduleFrontmostPollForTesting(pid: pid + 1)
            await drainMovementWork(fixture.tracker)
            XCTAssertEqual(fixture.reader.reads.withLock { $0 }, index + 3)
        }

        fixture.reader.unread.withLock { $0 = false }
        uptime.now = 105
        fixture.tracker.scheduleFrontmostPollForTesting(pid: pid + 1)
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 5)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "A")

        fixture.tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB]))
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.reader.reads.withLock { $0 }, 6)
        XCTAssertEqual(fixture.cg.exactIDs.withLock { $0 }, [cgWindow, cgWindow, cgWindow])
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
    }

    func testTitleUpdatesWhileSecondExactDisplaySampleIsBlocked() async throws {
        let gate = DisplayCaptureGate()
        let fixture = try await makeMovementFixture(secondExactGate: gate)
        defer { gate.open(); fixture.tracker.stop() }
        let readTitle = fixture.observer.onTitleChanged
        var receivedTitle = false
        fixture.observer.onTitleChanged = { pid, windowID in
            readTitle?(pid, windowID)
            receivedTitle = true
        }
        fixture.reader.title.withLock { $0 = "First update" }
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { fixture.tracker.snapshot.windows[fixture.id]?.title == "First update" }
        receivedTitle = false
        fixture.cg.bounds.withLock { $0 = frameOnB }
        gate.arm()
        fixture.receive(fixture.reader.element, kAXWindowMovedNotification)
        await waitForMovement { gate.isBlocked }
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.title, "First update")
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "A")

        fixture.reader.title.withLock { $0 = "Next update" }
        fixture.receive(fixture.reader.element, kAXTitleChangedNotification)
        await waitForMovement { receivedTitle }
        await waitForMovement { fixture.tracker.snapshot.windows[fixture.id]?.title == "Next update" }
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "A")

        gate.open()
        await drainMovementWork(fixture.tracker)
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.displayUUID, "B")
        XCTAssertEqual(fixture.tracker.snapshot.windows[fixture.id]?.title, "Next update")
        XCTAssertFalse(gate.timedOut)
    }

    private struct MovementFixture {
        let tracker: AppTracker
        let observer: AppWindowObserver
        let reader: DisplayMovementReader
        let receive: @Sendable (AXElementKey, String) -> Void
        let cg: CGState
        let id: WindowID
    }

    private final class CGState: Sendable {
        let bounds: Mutex<CGRect>
        let exactIDs = Mutex<[CGWindowID]>([])
        let fullCaptures = Mutex(0)
        let parent = Mutex<CGWindowID>(0)

        init(bounds: CGRect) { self.bounds = Mutex(bounds) }
    }

    private final class UptimeBox {
        var now: TimeInterval = 100
    }

    private func makeMovementFixture(
        bulkGate: DisplayCaptureGate? = nil, firstExactGate: DisplayCaptureGate? = nil,
        secondExactGate: DisplayCaptureGate? = nil, exactFailures: Int = 0,
        uptime: @escaping () -> TimeInterval = { 100 }
    ) async throws -> MovementFixture {
        let (pid, cgWindow, table) = (pid, cgWindow, tableAB)
        let reader = DisplayMovementReader(pid: pid, windowID: cgWindow, bounds: frameOnA)
        let cg = CGState(bounds: frameOnA)
        let session = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: pid, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return session
        })
        let tracker = AppTracker(reader: reader, processProvider: DisplayAttributionFixedProcessProvider(),
            cgSnapshotProvider: {
                cg.fullCaptures.withLock { $0 += 1 }
                let bounds = cg.bounds.withLock { $0 }
                bulkGate?.waitIfArmed()
                return .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                             alphaByWindowID: [:], boundsByWindowID: [cgWindow: bounds],
                             parentWindowIDs: [cgWindow: cg.parent.withLock { $0 }])
            }, cgWindowSnapshotProvider: { id in
                let attempt = cg.exactIDs.withLock { $0.append(id); return $0.count }
                if attempt <= exactFailures { return .failed }
                let bounds = cg.bounds.withLock { $0 }
                if attempt == 1 { firstExactGate?.waitIfArmed() }
                if attempt == 2 { secondExactGate?.waitIfArmed() }
                return .init(allWindowIDs: [cgWindow], onScreenWindowIDs: [cgWindow], windowIDsByPID: [pid: [cgWindow]],
                             alphaByWindowID: [:], boundsByWindowID: [cgWindow: bounds],
                             parentWindowIDs: [cgWindow: cg.parent.withLock { $0 }])
            }, onScreenWindowIDsProvider: { [cgWindow] }, cgSnapshotReuseEnabled: false,
            uptimeProvider: uptime, frontmostPIDProvider: { pid }, displayTableProvider: { table })
        let id = WindowID(rawValue: "cgw-\(cgWindow)")
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.observeWindows(observer)
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.scheduleEventReadForTesting(pid: pid, source: .initialEnumeration)
        await drainMovementWork(tracker)
        for task in observer.pendingWorkForTesting { await task.value }
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertEqual(tracker.snapshot.windows[id]?.displayUUID, "A")
        XCTAssertEqual(observer.subscribedElement(cgWindowID: cgWindow).map { AXElementKey(e: $0.element) }, reader.element)
        return MovementFixture(tracker: tracker, observer: observer, reader: reader, receive: try XCTUnwrap(callback.withLock { $0 }),
                               cg: cg, id: id)
    }

    private func drainMovementWork(_ tracker: AppTracker) async {
        while !tracker.pendingInventoryWorkForTesting.isEmpty {
            for task in tracker.pendingInventoryWorkForTesting { await task.value }
        }
    }

    private func waitForMovement(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testMovingAcrossDisplaysChangesTheSignatureAndPublishes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "A")

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success
        )

        XCTAssertTrue(changed, "A cross-display move must publish the new seat location")
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")
    }

    func testMovingWithinOneDisplayIsNotAChange() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        let before = tracker.snapshot

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnAMoved, isMinimized: false)],
            readOutcome: .success
        )

        XCTAssertFalse(changed, "Movement within a display must avoid an inventory rebuild")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertEqual(tracker.snapshot, before)
    }

    func testTwoTitleChangesPublishWhenTheirContentsCollideWithSignatureDelimiters() async {
        let (pid, firstID, initialBounds, secondBounds, table) = (pid, cgWindow, frameOnA, frameOnAMoved, tableAB)
        let secondID: CGWindowID = 92
        let secondToken = "tabgrp-5151-s2"
        let delimiters = ":0:0:A|\(secondID):\(secondToken):"
        var app = makeApp(displayUUID: "A")
        let firstElement = AXElementKey(e: AXUIElementCreateApplication(pid))
        let secondElement = AXElementKey(e: AXUIElementCreateApplication(pid + 1))
        app.windowsByID[cgWindow]?.title = "Alpha\(delimiters)Beta"
        app.windowsByID[cgWindow]?.actionTarget = WindowActionTarget(element: firstElement)
        app.windowsByID[secondID] = WindowEntry(cgWindowID: secondID, token: secondToken, title: "Gamma",
            bounds: frameOnAMoved, isMinimized: false, isFocused: false, everSeenVisible: true,
            displayUUID: "A", actionTarget: WindowActionTarget(element: secondElement))
        app.windowOrder.append(secondID)
        let titles = ["Alpha", "Beta\(delimiters)Gamma"]
        let reader = DisplayAttributionReader {
            .success([
                AXWindowSnapshot(pid: pid, cgWindowID: firstID, titleRead: .value(titles[0]), bounds: initialBounds,
                    role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, isMinimized: false,
                    isFocusedWindow: false, element: firstElement.e),
                AXWindowSnapshot(pid: pid, cgWindowID: secondID, titleRead: .value(titles[1]), bounds: secondBounds,
                    role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, isMinimized: false,
                    isFocusedWindow: false, element: secondElement.e)
            ])
        }
        let ids: Set<CGWindowID> = [firstID, secondID]
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: ids, onScreenWindowIDs: ids,
            windowIDsByPID: [pid: ids], alphaByWindowID: [:])
        let tracker = AppTracker(reader: reader, processProvider: DisplayAttributionFixedProcessProvider(),
            cgSnapshotProvider: { cg }, onScreenWindowIDsProvider: { ids }, frontmostPIDProvider: { nil },
            displayTableProvider: { table })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(app)
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: ids)
        let initialTitles = ["Alpha\(delimiters)Beta", "Gamma"]
        var publications: [[String]] = []
        let subscription = tracker.snapshots.sink { snapshot in
            publications.append(snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0]?.title })
        }
        defer { subscription.cancel() }
        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)
        await drainMovementWork(tracker)
        XCTAssertEqual(publications, [initialTitles, titles])
    }

    func testMinimizedSeatKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isMinimized: true))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: true)],
            readOutcome: .success
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        let cgChanged = tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        )
        XCTAssertFalse(cgChanged)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testHiddenAppKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isHidden: true))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testPeriodicCGPassMovesVisibleSeatsWithoutAnAXRead() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnAMoved])
        ))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testPeriodicWoWFullscreenEvidenceChangesOnTheSameDisplay() throws {
        let tracker = makeTracker()
        var game = makeApp(displayUUID: "A", bundleIdentifier: "com.blizzard.worldofwarcraft")
        game.windowsByID[cgWindow]?.confirmedCGDisplayBounds = frameOnA
        tracker.installFixtureForTesting(game)
        let fullFrame = try XCTUnwrap(tableAB.displays.first?.cgFrame)
        func sample(_ frame: CGRect, onScreen: Bool = true) -> AppTrackerCGWindowSnapshot {
            .init(allWindowIDs: [cgWindow], onScreenWindowIDs: onScreen ? [cgWindow] : [],
                  windowIDsByPID: [pid: [cgWindow]], alphaByWindowID: [cgWindow: 1],
                  boundsByWindowID: [cgWindow: frame], parentWindowIDs: [cgWindow: 0])
        }

        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: sample(fullFrame)))
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        let id = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[id]?.borderlessFullscreenFrame, fullFrame)
        XCTAssertEqual(tracker.snapshot.windows[id]?.bounds, frameOnA)
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: sample(fullFrame)))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: .failed))

        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: sample(frameOnA)))
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertNil(tracker.snapshot.windows[id]?.borderlessFullscreenFrame)

        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: sample(fullFrame)))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: sample(fullFrame, onScreen: false)))
        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [])
        XCTAssertNil(tracker.snapshot.windows[id]?.borderlessFullscreenFrame)
    }

    func testATickDuringTheMinimizeAnimationDoesNotMoveTheSeat() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let midAnimation = CGRect(x: 1400, y: 500, width: 120, height: 90)

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success
        )
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: midAnimation])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testUnusableCGTickBreaksTheSequenceOfDisplayEvidence() {
        for unusable in [cgSnapshot(), .failed] {
            let tracker = makeTracker()
            tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
            let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
            XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
            XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: unusable))
            XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
            XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
            XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        }
    }

    func testUnknownCGBoundsLeaveTheKeyAlone() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot()))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: CGRect(x: 9000, y: 9000, width: 10, height: 10)])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testScreenParametersChangeReattributesFromStoredBounds() {
        let box = TableBox(tableAB)
        let tracker = makeTracker(tableProvider: { box.table })
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        box.table = WindowDisplayAttribution.Table(
            displays: [
                .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                .init(uuid: "C", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
            ],
            primaryUUID: "A"
        )
        tracker.screenParametersChangedForTesting()

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "C")
    }

    func testTopologyChangeRetainsAConfirmedCGDisplayMoveWithOldAXBounds() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        tracker.updateDisplayTopology(.init(displays: tableAB.displays + [
            .init(uuid: "C", cgFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)

        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B-Reidentified", cgFrame: tableAB.displays[1].cgFrame)
        ], primaryUUID: "A"))
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B-Reidentified")
    }

    func testStaleAXReadRetainsAConfirmedCGDisplayMoveForTheSameWindow() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldAX = makeSnapshot(bounds: frameOnA, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success)
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: moved, now: Date(),
            eligible: [oldAX], readOutcome: .success)
        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B-Reidentified", cgFrame: tableAB.displays[1].cgFrame)
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B-Reidentified")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testCGMovementWithinTheConfirmedDisplayUpdatesBoundsUsedByLaterTopology() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        let later = cgSnapshot(bounds: [cgWindow: CGRect(x: 1750, y: 100, width: 200, height: 400)])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: later))
        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 600, height: 800)),
            .init(uuid: "C", cgFrame: CGRect(x: 1600, y: 0, width: 400, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "C")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testSameDisplayAXLocationDoesNotDiscardDifferentConfirmedCGBounds() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)], readOutcome: .success)
        let confirmed = cgSnapshot(bounds: [cgWindow: CGRect(x: 1750, y: 100, width: 200, height: 400)])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: confirmed))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: confirmed))
        tracker.rebuildSnapshotForTesting()
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: confirmed, now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)], readOutcome: .success)

        tracker.updateDisplayTopology(.init(displays: [
            tableAB.displays[0],
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 600, height: 800)),
            .init(uuid: "C", cgFrame: CGRect(x: 1600, y: 0, width: 400, height: 800))
        ], primaryUUID: "A"))

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "C")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnB)
    }

    func testChangedAXLocationCanAdvanceBeyondConfirmedCGDisplayWhenCGIsUnavailable() {
        let table = WindowDisplayAttribution.Table(displays: tableAB.displays + [
            .init(uuid: "C", cgFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
        ], primaryUUID: "A")
        let tracker = makeTracker(tableProvider: { table })
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldAX = makeSnapshot(bounds: frameOnA, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success)
        let moved = cgSnapshot(bounds: [cgWindow: frameOnB])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))

        XCTAssertFalse(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: .failed, now: Date(),
            eligible: [oldAX], readOutcome: .success))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        let newAX = makeSnapshot(bounds: CGRect(x: 2200, y: 100, width: 500, height: 400), isMinimized: false)
        XCTAssertTrue(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: .failed, now: Date(),
            eligible: [newAX], readOutcome: .success))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
    }

    func testNearMatchingAXFrameOnAdjacentDisplayDoesNotOverrideConfirmedCGMove() {
        let tracker = makeTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        let oldBounds = CGRect(x: 742, y: 100, width: 500, height: 400)
        let newBounds = oldBounds.offsetBy(dx: 16, dy: 0)
        let oldAX = makeSnapshot(bounds: oldBounds, isMinimized: false)
        tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [oldAX], readOutcome: .success)
        let moved = cgSnapshot(bounds: [cgWindow: newBounds])
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: moved))
        tracker.rebuildSnapshotForTesting()

        XCTAssertFalse(tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: moved, now: Date(),
            eligible: [oldAX], readOutcome: .success))
        tracker.rebuildSnapshotForTesting()

        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, oldBounds)
    }

    func testDisplayUUIDRetryReattributesExistingInventoryWithoutAnotherSystemNotification() {
        let incomplete = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A"],
            attributionTable: .init(displays: [tableAB.displays[0]], primaryUUID: "A"))
        let complete = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"],
            attributionTable: tableAB)
        let store = DisplayTopologyStore(initialSnapshot: incomplete)
        let tracker = makeTracker(tableProvider: { store.table })
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: nil))
        tracker.rebuildSnapshotForTesting()
        let windowID = WindowID(rawValue: "cgw-\(cgWindow)")
        var snapshot = incomplete
        var retryCallbacks: [() -> Void] = []
        let orchestrator = TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: tracker),
            stripOrderStore: StripOrderStore(), displayTopologyStore: store,
            spaceStore: TaskbarSpaceStore(read: { _ in nil }, pollInterval: 0),
            topologySnapshotProvider: { snapshot }, startCoordinator: { _ in true },
            topologyRetryScheduler: { _, action in
                retryCallbacks.append(action)
                return DispatchWorkItem(block: action)
            })
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        XCTAssertNil(tracker.snapshot.windows[windowID]?.displayUUID)

        snapshot = complete
        XCTAssertEqual(retryCallbacks.count, 2)
        retryCallbacks.first?()

        XCTAssertEqual(orchestrator.units.map(\.key), ["A", "B"])
        XCTAssertEqual(tracker.snapshot.windows[windowID]?.displayUUID, "B")
    }

    func testNewSeatTakesItsDisplayFromTheAXFrame() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [:],
            windowOrder: [],
            isHidden: false
        ))
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
    }

    func testClosingLastWindowLeavesNoCardAndRetainsProcessObservation() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "B"))
        tracker.rebuildSnapshotForTesting()

        let empty = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: empty, now: Date(), eligible: [], readOutcome: .success
        ))
        tracker.rebuildSnapshotForTesting()
        XCTAssertTrue(tracker.snapshot.windows.isEmpty)
        XCTAssertTrue(tracker.snapshot.orderedWindowIDs.isEmpty)
        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid))


    }


    private final class TableBox {
        var table: WindowDisplayAttribution.Table
        init(_ table: WindowDisplayAttribution.Table) { self.table = table }
    }

    private func makeTracker(
        tableProvider: (@MainActor () -> WindowDisplayAttribution.Table)? = nil
    ) -> AppTracker {
        let table = tableAB
        return AppTracker(
            reader: DisplayAttributionReader(),
            processProvider: DisplayAttributionFixedProcessProvider(),
            displayTableProvider: tableProvider ?? { table }
        )
    }

    private func cgSnapshot(bounds: [CGWindowID: CGRect] = [:]) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow],
            onScreenWindowIDs: [cgWindow],
            windowIDsByPID: [pid: [cgWindow]],
            alphaByWindowID: [:],
            boundsByWindowID: bounds
        )
    }

    private func makeApp(
        bounds: CGRect? = nil,
        displayUUID: String?,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        token: String? = nil,
        bundleIdentifier: String = "com.example.fixture"
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindow,
            token: token ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: bounds ?? frameOnA,
            isMinimized: isMinimized,
            isFocused: false,
            everSeenVisible: true,
            displayUUID: displayUUID
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindow: seat],
            windowOrder: [cgWindow],
            isHidden: isHidden
        )
    }

    private func makeSnapshot(bounds: CGRect, isMinimized: Bool, cgWindowID: CGWindowID? = nil) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID ?? cgWindow,
            titleRead: .value("Window"),
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: isMinimized,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid),
            isMinimizedRead: isMinimized
        )
    }
}

@MainActor
private final class DisplayMovementInventory: WindowInventoryTracking {
    let tracker: AppTracker

    init(tracker: AppTracker) { self.tracker = tracker }
    var snapshots: AnyPublisher<DockSnapshot, Never> { tracker.snapshots }
    func start() {}
    func stop() {}
}

private final class DisplayMovementActions: WindowActionExecuting {
    let ids = Mutex<[WindowID]>([])

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffTarget: (@Sendable (WindowID) -> Void)?) -> Bool {
        if let id = request.windowID { ids.withLock { $0.append(id) } }
        return false
    }
}

private struct DisplayAttributionReader: AppTrackerWindowReading {
    var read: @Sendable () -> AXWindowReadResult = { .success([]) }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { read().windowsOrEmpty }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { read() }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { read() }
}

private final class DisplayMovementReader: AppTrackerWindowReading, Sendable {
    let currentElement: Mutex<AXElementKey>
    var element: AXElementKey { currentElement.withLock { $0 } }
    let bounds: Mutex<CGRect>
    let title = Mutex("Window")
    let unread = Mutex(false)
    let reads = Mutex(0)
    let windowID: CGWindowID

    init(pid: pid_t, windowID: CGWindowID, bounds: CGRect) {
        currentElement = Mutex(AXElementKey(e: AXUIElementCreateApplication(pid)))
        self.windowID = windowID
        self.bounds = Mutex(bounds)
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { windowReadResult(forPID: pid).windowsOrEmpty }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        reads.withLock { $0 += 1 }
        if unread.withLock({ $0 }) { return .unread(.cannotComplete) }
        return .success([.init(pid: pid, cgWindowID: windowID, titleRead: .value(title.withLock { $0 }), bounds: bounds.withLock { $0 },
                              role: kAXWindowRole, subrole: kAXStandardWindowSubrole, isMinimized: false,
                              isFocusedWindow: false, element: element.e, isMinimizedRead: false)])
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        windowReadResult(forPID: pid)
    }
}

private final class DisplayCaptureGate: Sendable {
    private let armed = Mutex(false)
    private let blocked = Mutex(false)
    private let timeout = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    var isBlocked: Bool { blocked.withLock { $0 } }
    var timedOut: Bool { timeout.withLock { $0 } }

    func arm() { armed.withLock { $0 = true } }
    func open() { semaphore.signal() }

    func waitIfArmed() {
        guard armed.withLock({ armed in
            let wasArmed = armed
            armed = false
            return wasArmed
        }) else { return }
        blocked.withLock { $0 = true }
        if semaphore.wait(timeout: .now() + 8) == .timedOut { timeout.withLock { $0 = true } }
    }
}

private struct DisplayAttributionFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}
