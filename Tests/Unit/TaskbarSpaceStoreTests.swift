import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

@MainActor
private final class SpaceInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }
    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() {}
    func stop() {}
}

private final class SpaceActionRecorder: WindowActionExecuting {
    let calls = Mutex<[WindowID]>([])

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        if let id = request.windowID { calls.withLock { $0.append(id) } }
        return false
    }
}

private final class SpaceBlockedAction: WindowActionExecuting {
    let token = Mutex<OperationCancellation?>(nil)
    let release = DispatchSemaphore(value: 0)

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        token.withLock { $0 = cancellation }
        _ = release.wait(timeout: .now() + 3)
        return !cancellation.isCancelled
    }
}

@MainActor
private final class VisibleUtilitySpaceWindow: NSWindow {
    var activeSpace = true
    var minimized = false

    override var isVisible: Bool { !minimized }
    override var isMiniaturized: Bool { minimized }
    override var isOnActiveSpace: Bool { activeSpace }
    override var screen: NSScreen? { nil }
    override var windowNumber: Int { 749 }
}

@MainActor
final class TaskbarSpaceStoreTests: XCTestCase {
    func testRegisteredWindowAdoptsNewSpaceWhenMinimizedBeforeLayoutCatchesUp() async throws {
        try await verifyRegisteredWindowAdoptsNewSpace(firstPostChangeMembership: 2)
    }

    func testRegisteredWindowKeepsAwaitingLayoutAfterAnInitiallyUnchangedCapture() async throws {
        try await verifyRegisteredWindowAdoptsNewSpace(firstPostChangeMembership: 1)
    }

    private func verifyRegisteredWindowAdoptsNewSpace(firstPostChangeMembership: Int) async throws {
        var record = WindowRecord(id: WindowID(rawValue: "utility"), appID: AppID(rawValue: "desk"), pid: 42,
            bundleIdentifier: nil, title: "Utility", bounds: nil, status: .active, isOnDesktop: true,
            displayUUID: "left", source: .utility(spaceWindowNumber: 749))
        let inventory = SpaceInventory(.init(windows: [record.id: record], orderedWindowIDs: [record.id]))
        let identity = try XCTUnwrap(StripItem(record: record).spaceIdentity)
        let notifications = NotificationCenter()
        let observation = Mutex((layout: 1, membership: 1))
        let store = TaskbarSpaceStore(read: { requests in
            let (layout, membership) = observation.withLock { $0 }
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: layout)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, [membership]) })
            )
        }, notifications: notifications, pollInterval: 0)
        var activeSpace: Bool? = true
        store.start(snapshots: inventory.snapshots, utilityOnActiveSpace: { _ in activeSpace })
        defer { store.stop() }
        let filter = StripDisplayFilter(scope: "left", connectedUUIDs: ["left"], primaryUUID: "left")
        func visibleIDs() -> Set<String> {
            Set(TaskbarPresentation.visibleItems(StripItem.openWindows(from: inventory.values.value),
                filter: filter, spaces: store.snapshot, utilityOnPanelDisplay: { _ in true },
                utilityOnActiveSpace: { _ in activeSpace }).keys)
        }

        await waitUntil { store.snapshot.memberships[identity] == [1] }
        observation.withLock { $0.membership = firstPostChangeMembership }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { store.confirmedSpaceRevision == 1 }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1)
        XCTAssertEqual(store.snapshot.memberships[identity], [firstPostChangeMembership])
        XCTAssertEqual(visibleIDs(), [identity.itemID])

        if firstPostChangeMembership != 2 {
            observation.withLock { $0.membership = 2 }
            store.refresh()
            await waitUntil { store.snapshot.memberships[identity] == [2] }
            XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1)
            XCTAssertEqual(visibleIDs(), [identity.itemID])
        }
        activeSpace = nil
        record.status = .minimized
        record.isOnDesktop = false
        inventory.values.send(.init(windows: [record.id: record], orderedWindowIDs: [record.id]))
        await flushSnapshotDelivery()
        for task in store.pendingWorkForTesting { await task.value }

        observation.withLock { $0.layout = 2 }
        store.refresh()
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertEqual(store.snapshot.memberships[identity], [2])
        XCTAssertEqual(visibleIDs(), [identity.itemID])
    }

    func testRegisteredWindowUsesLiveSpaceWhileWindowServerCatchesUp() async throws {
        let inventory = SpaceInventory(.empty)
        let runtime = AppRuntime(tracker: inventory)
        let notifications = NotificationCenter()
        let current = Mutex(1)
        let membership = Mutex(Set<Int>())
        let allowFirstMembership = DispatchSemaphore(value: 0)
        let firstMembership = Mutex(true)
        let allowSpaceChangeRead = DispatchSemaphore(value: 0)
        let delaySpaceChangeRead = Mutex(false)
        let store = TaskbarSpaceStore(read: { requests in
            if !requests.isEmpty && firstMembership.withLock({ pending in
                defer { pending = false }
                return pending
            }) {
                _ = allowFirstMembership.wait(timeout: .now() + 3)
            }
            if delaySpaceChangeRead.withLock({ delay in
                defer { delay = false }
                return delay
            }) {
                _ = allowSpaceChangeRead.wait(timeout: .now() + 3)
            }
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: current.withLock { $0 })],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, membership.withLock { $0 }) })
            )
        }, notifications: notifications, pollInterval: 0)
        let domain = "DeskMote.UtilitySpaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .empty))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: StripOrderStore(defaults: defaults),
            topology: topology, spaces: store, displayUUID: nil, backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher(), utilityOnActiveSpace: { [weak runtime] id in
            runtime?.utilityWindowOnActiveSpace(id)
        })
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { !store.snapshot.layouts.isEmpty }

        let window = VisibleUtilitySpaceWindow(contentRect: CGRect(x: 10, y: 10, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Utility"
        runtime.registerUtilityWindow(window)
        await waitUntil { view.taskbarContent.groups.count == 1 }
        let item = try XCTUnwrap(StripItem.openWindows(from: runtime.snapshot).first)
        let identity = try XCTUnwrap(item.spaceIdentity)
        allowFirstMembership.signal()
        await waitUntil { store.snapshot.memberships[identity] == [] }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [item.id],
                       "An empty first membership read must keep the visible local button")

        window.minimized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        await waitUntil { runtime.snapshot.windows[item.actionIdentity.windowID]?.status == .minimized }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [item.id],
                       "A quick minimize must preserve the Space AppKit reported before an empty membership read")

        membership.withLock { $0 = [2] }
        store.refresh()
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [item.id],
                       "A stale read while parked must preserve the last observed Space")
        window.minimized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        await waitUntil { runtime.snapshot.windows[item.actionIdentity.windowID]?.status != .minimized }
        store.refresh()
        await waitUntil { store.snapshot.memberships[identity] == [2] }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [item.id],
                       "A stale membership must not hide a window AppKit sees on the active Space")

        window.activeSpace = false
        membership.withLock { $0 = [1] }
        current.withLock { $0 = 2 }
        delaySpaceChangeRead.withLock { $0 = true }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { view.taskbarContent.groups.isEmpty }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1,
                       "The AppKit projection must update before the WindowServer read returns")
        allowSpaceChangeRead.signal()
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        await flushSnapshotDelivery()
        XCTAssertTrue(view.taskbarContent.groups.isEmpty, "A visible window on another Space must be excluded")

        store.refresh()
        for task in store.pendingWorkForTesting { await task.value }
        window.minimized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        await waitUntil { runtime.snapshot.windows[item.actionIdentity.windowID]?.status == .minimized }
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertTrue(view.taskbarContent.groups.isEmpty)
        XCTAssertEqual(store.snapshot.memberships[identity], [1])
    }

    func testIconRecoveryRefreshesExistingButtonsWithoutAnInventoryChange() async throws {
        let fixture = SpaceInventory(inventory())
        let runtime = AppRuntime(tracker: fixture)
        let center = NotificationCenter()
        var resolved = false
        var rendered = false
        let icons = AppIconResolver(notifications: center, applicationURL: { _ in
            resolved ? URL(fileURLWithPath: "/fixture/Icon.app") : nil
        }, imageForFile: { _ in rendered = true; return NSImage(size: .init(width: 32, height: 32)) },
            fallbackImage: { NSImage(size: .init(width: 32, height: 32)) })
        let store = TaskbarSpaceStore(read: { requests in
            .init(layouts: ["left": .init(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1)],
                  memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "DeskMote.IconRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .empty))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: StripOrderStore(defaults: defaults),
            topology: topology, spaces: store, displayUUID: nil, backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in }, icons: icons)
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { view.taskbarContent.buttonViews.count == 2 && store.snapshot.memberships.count == 2 }
        let button = try XCTUnwrap(view.taskbarContent.buttonViews.values.first)
        let originalImage = button.image
        let originalSnapshot = runtime.snapshot
        resolved = true
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await waitUntil { rendered && button.image !== originalImage }
        XCTAssertEqual(runtime.snapshot, originalSnapshot)
        XCTAssertNil(view.window)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func reorderSecondBeforeFirst(_ ordering: StripOrderStore) {
        let items = StripItem.openWindows(from: inventory())
        ordering.reorderGroup(items[1].applicationKey, relativeTo: items[0].applicationKey,
                              after: false, current: items.map(\.id))
    }

    private func inventory() -> DockSnapshot {
        let records = (1...2).map { index in
            WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "app-\(index)"), pid: Int32(40 + index),
                bundleIdentifier: "test.space.\(index)", title: "Window \(index)", bounds: nil,
                status: .inactive, cgWindowID: UInt32(index), groupID: "window-\(index)", displayUUID: "left")
        }
        return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), orderedWindowIDs: records.map(\.id))
    }

    func testSpaceNotificationsRefreshPresentationWithoutLosingInventoryOrManualOrder() async {
        let fixture = SpaceInventory(inventory())
        let runtime = AppRuntime(tracker: fixture)
        let center = NotificationCenter()
        let current = Mutex(1)
        let store = TaskbarSpaceStore(read: { requests in
            WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: current.withLock { $0 })],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([Int($0.identity.windowID)])) }))
        }, notifications: center, pollInterval: 0)
        let domain = "DeskMote.SpaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .empty))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
            topology: topology, spaces: store, displayUUID: nil,
            backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { store.snapshot.memberships.count == 2 && view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-1"] }
        reorderSecondBeforeFirst(ordering)
        await waitUntil { ordering.liveOrder == ["window-2", "window-1"] }
        current.withLock { $0 = 2 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-2"] }
        XCTAssertEqual(runtime.snapshot.windows.count, 2)
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        current.withLock { $0 = 1 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["window-1"] }
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        XCTAssertNil(view.window)
    }

    func testSpaceChangeInvalidatesProjectionBeforeTheFirstKnownLayout() async throws {
        let initial = inventory()
        let item = try XCTUnwrap(StripItem.openWindows(from: initial).first)
        let identity = try XCTUnwrap(item.spaceIdentity)
        let center = NotificationCenter()
        let response = Mutex<WindowSpaceSnapshot?>(nil)
        let reads = Mutex(0)
        let store = TaskbarSpaceStore(read: { _ in
            reads.withLock { $0 += 1 }
            return response.withLock { $0 }
        }, notifications: center, pollInterval: 0)
        store.start(snapshots: Just(initial).eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { reads.withLock { $0 > 0 } }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertTrue(store.canUseProjection(on: "left", renderedSpaceRevision: 0))
        response.withLock { $0 = .init(layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 2)]) }
        store.refresh()
        await waitUntil { store.confirmedSpaceRevision == 1 }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: 0))
        XCTAssertFalse(store.snapshot.shows(identity, on: "left"))
    }

    func testPartialLayoutCannotAuthorizeActionsOnAPreviouslyKnownMissingDisplay() async throws {
        let initial = inventory()
        let identity = try XCTUnwrap(StripItem.openWindows(from: initial).first?.spaceIdentity)
        let left = SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)
        let right = SpaceLayoutSnapshot(orderedSpaceIDs: [10, 11], fullscreenSpaceIDs: [], currentSpaceID: 10)
        let response = Mutex(WindowSpaceSnapshot(layouts: ["left": left, "right": right], memberships: [identity: [11]]))
        let center = NotificationCenter()
        let store = TaskbarSpaceStore(read: { _ in response.withLock { $0 } }, notifications: center, pollInterval: 0)
        store.start(snapshots: Just(initial).eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships[identity] == [11] }
        XCTAssertFalse(store.snapshot.shows(identity, on: "right"))
        XCTAssertFalse(store.snapshot.shows(identity, on: "new-display"))
        XCTAssertFalse(store.canUseProjection(on: "new-display", renderedSpaceRevision: store.confirmedSpaceRevision))
        response.withLock { $0 = .init(layouts: ["left": left], memberships: [identity: [11]]) }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { store.confirmedSpaceRevision == 1 }
        XCTAssertFalse(store.snapshot.shows(identity, on: "right"))
        XCTAssertFalse(store.canUseProjection(on: "right", renderedSpaceRevision: store.confirmedSpaceRevision))
        XCTAssertTrue(store.canUseProjection(on: "left", renderedSpaceRevision: store.confirmedSpaceRevision))
        let updatedRight = SpaceLayoutSnapshot(orderedSpaceIDs: [10, 11], fullscreenSpaceIDs: [], currentSpaceID: 11)
        response.withLock { $0 = .init(layouts: ["left": left, "right": updatedRight], memberships: [identity: [11]]) }
        store.refresh()
        await waitUntil { store.snapshot.shows(identity, on: "right") }
        XCTAssertTrue(store.canUseProjection(on: "right", renderedSpaceRevision: store.confirmedSpaceRevision))
    }

    func testFirstUnchangedLayoutAfterSpaceChangeCannotAuthoriseAStaleAction() async {
        let layouts = [
            WindowSpaceSnapshot(layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)]),
            WindowSpaceSnapshot(layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 2)])
        ]
        let center = NotificationCenter()
        let index = Mutex(0)
        let reads = Mutex(0)
        let store = TaskbarSpaceStore(read: { _ in
            reads.withLock { $0 += 1 }
            return layouts[index.withLock { $0 }]
        }, notifications: center, pollInterval: 0)
        store.start(snapshots: Just(DockSnapshot.empty).eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 1 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitUntil { reads.withLock { $0 >= 2 } }
        store.refresh()
        await waitUntil { reads.withLock { $0 >= 3 } }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: 0))
        index.withLock { $0 = 1 }
        await waitUntil { store.confirmedSpaceRevision == 1 }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 2)
    }

    func testSpaceChangeCancelsAnAdmittedActionBeforeReadingUtilityVisibility() async throws {
        var source = inventory()
        let external = WindowID(rawValue: "window-1")
        let utility = WindowID(rawValue: "space-utility")
        source.windows[utility] = WindowRecord(id: utility, appID: AppID(rawValue: "utility"), pid: -51230,
            bundleIdentifier: nil, title: "Utility", bounds: nil, status: .inactive, cgWindowID: 3,
            displayUUID: "left", source: .utility(spaceWindowNumber: 3))
        source.orderedWindowIDs.append(utility)
        let target = try XCTUnwrap(source.windows[external]?.actionIdentity)
        let center = NotificationCenter()
        let executor = SpaceBlockedAction()
        let runtime = AppRuntime(tracker: SpaceInventory(source), actionExecutor: executor)
        let store = TaskbarSpaceStore(read: { requests in
            WindowSpaceSnapshot(layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, [1]) }))
        }, notifications: center, pollInterval: 0)
        var cancellationAtVisibility: Bool?
        var projectionAtVisibility: Bool?
        var checkingNotification = false
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher(), utilityOnActiveSpace: { _ in
            if checkingNotification {
                cancellationAtVisibility = executor.token.withLock { $0?.isCancelled }
                projectionAtVisibility = store.canUseProjection(on: "left", renderedSpaceRevision: 0)
                executor.release.signal()
            }
            return true
        })
        defer { executor.release.signal(); store.stop(); runtime.stop() }
        await waitUntil { store.snapshot.memberships.count == 3 }
        runtime.trigger(.activate(external), expected: target, projectionInvalidations: store.activeSpaceChanges) {
            store.canUseProjection(on: "left", renderedSpaceRevision: 0)
        }
        await waitUntil { executor.token.withLock { $0 != nil } }
        checkingNotification = true
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        checkingNotification = false

        XCTAssertEqual(cancellationAtVisibility, true)
        XCTAssertEqual(projectionAtVisibility, false)
    }

    func testRestartRequiresAFreshLayoutBeforeAuthorizingAProjection() async {
        let entered = Mutex(0)
        let freshRead = DispatchSemaphore(value: 0)
        let unread = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { _ in
            let call = entered.withLock { $0 += 1; return $0 }
            if call == 2 {
                _ = unread.wait(timeout: .now() + 3)
                return nil
            }
            if call == 3 { _ = freshRead.wait(timeout: .now() + 3) }
            return .init(layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: call == 1 ? 1 : 2)])
        }, notifications: NotificationCenter(), pollInterval: 0)
        let source = Just(inventory()).eraseToAnyPublisher()
        defer { unread.signal(); freshRead.signal(); store.stop() }
        store.start(snapshots: source)
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 1 }
        let previous = store.confirmedSpaceRevision
        XCTAssertTrue(store.canUseProjection(on: "left", renderedSpaceRevision: previous))

        store.stop()
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: previous))
        store.start(snapshots: source)
        await waitUntil { entered.withLock { $0 == 2 } }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: store.confirmedSpaceRevision))
        unread.signal()
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: store.confirmedSpaceRevision))

        store.refresh()
        await waitUntil { entered.withLock { $0 == 3 } }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: store.confirmedSpaceRevision))
        freshRead.signal()
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertFalse(store.canUseProjection(on: "left", renderedSpaceRevision: previous))
        XCTAssertTrue(store.canUseProjection(on: "left", renderedSpaceRevision: store.confirmedSpaceRevision))
    }

    func testPartialReadAfterSpaceChangeCannotProjectOrActOnStaleMembership() async throws {
        let source = inventory()
        let first = WindowID(rawValue: "window-1")
        let second = WindowID(rawValue: "window-2")
        let firstTarget = try XCTUnwrap(source.windows[first]?.actionIdentity)
        let secondTarget = try XCTUnwrap(source.windows[second]?.actionIdentity)
        let executor = SpaceActionRecorder()
        let runtime = AppRuntime(tracker: SpaceInventory(source), actionExecutor: executor)
        let center = NotificationCenter()
        let phase = Mutex(0)
        let store = TaskbarSpaceStore(read: { requests in
            let step = phase.withLock { $0 }
            return WindowSpaceObservation.capture(requests, cancellation: OperationCancellation(), layouts: {
                guard step != 1 else { return nil }
                let current = step == 0 ? 1 : step == 2 ? 2 : 3
                return ["left": .init(orderedSpaceIDs: [1, 2, 3], fullscreenSpaceIDs: [], currentSpaceID: current)]
            }, membership: { id in
                if id == 2 || step == 0 { return [2] }
                return step == 3 ? [3] : nil
            })
        }, notifications: center, pollInterval: 0)
        let domain = "DeskMote.PartialSpaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1,
            identifiedDisplayUUIDs: ["left"], attributionTable: .init(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
            ], primaryUUID: "left")))
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: StripOrderStore(defaults: defaults),
            topology: topology, spaces: store, displayUUID: "left", backgroundMenu: { _, _ in },
            popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenter) {} }
        await waitUntil { store.snapshot.memberships.count == 2 }
        await flushSnapshotDelivery()
        XCTAssertTrue(view.taskbarContent.groups.isEmpty)

        phase.withLock { $0 = 1 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1)
        XCTAssertFalse(view.taskbarContent.canUseWindowActions())

        phase.withLock { $0 = 2 }
        store.refresh()
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 2)
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [second.rawValue])
        view.taskbarContent.actions.close(firstTarget)
        for task in runtime.pendingActionsForTesting { await task.value }
        view.taskbarContent.actions.activate(firstTarget)
        for task in runtime.pendingActionsForTesting { await task.value }
        view.taskbarContent.actions.close(secondTarget)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, [second])

        store.refresh()
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [second.rawValue])

        phase.withLock { $0 = 3 }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertEqual(view.taskbarContent.groups.flatMap(\.windows).map(\.id), [first.rawValue])
        view.taskbarContent.actions.activate(firstTarget)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, [second, first])
    }

    func testReplacingTheNativeTargetRefreshesSpaceMembershipForTheSameWindowNumber() async throws {
        let id = WindowID(rawValue: "window-1")
        func inventoryWithTarget(_ element: AXUIElement) throws -> DockSnapshot {
            var source = inventory()
            let record = try XCTUnwrap(source.windows[id])
            source.windows[id] = WindowRecord(id: id, appID: record.appID, pid: record.pid,
                bundleIdentifier: record.bundleIdentifier, title: record.title, bounds: record.bounds,
                status: .minimized, cgWindowID: record.cgWindowID, displayUUID: record.displayUUID,
                actionTarget: WindowActionTarget(element: AXElementKey(e: element)))
            return source
        }
        let source = CurrentValueSubject<DockSnapshot, Never>(try inventoryWithTarget(AXUIElementCreateApplication(getpid())))
        let oldIdentity = try XCTUnwrap(StripItem.openWindows(from: source.value).first?.spaceIdentity)
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            return WindowSpaceSnapshot(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues:
                requests.compactMap { request in
                    if request.identity.windowID == 2 || call == 1 { return (request.identity, Set([1])) }
                    return call == 3 ? (request.identity, Set([2])) : nil
                }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships.count == 2 }
        let replacement = try inventoryWithTarget(AXUIElementCreateSystemWide())
        let newIdentity = try XCTUnwrap(StripItem.openWindows(from: replacement).first?.spaceIdentity)
        XCTAssertFalse(store.snapshot.shows(newIdentity, on: "left"))
        source.send(replacement)
        await flushSnapshotDelivery()
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertNotEqual(oldIdentity, newIdentity)
        XCTAssertNil(store.snapshot.memberships[oldIdentity])
        XCTAssertFalse(store.snapshot.shows(newIdentity, on: "left"))

        store.refresh()
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(calls.withLock { $0 }, 3)
        XCTAssertEqual(store.snapshot.memberships[newIdentity], [2])
    }

    func testCoalescedReadsRunOffMainAndStopRejectsLateResults() async {
        let calls = Mutex<[Bool]>([])
        let gate = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { _ in
            calls.withLock { $0.append(Thread.isMainThread) }
            _ = gate.wait(timeout: .now() + 2)
            return WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1)])
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: Just(DockSnapshot.empty).eraseToAnyPublisher())
        await waitUntil { calls.withLock { $0.count } == 1 }
        for _ in 0..<20 { store.refresh() }
        gate.signal()
        await waitUntil { calls.withLock { $0.count } == 2 }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)
        let pending = store.pendingWorkForTesting
        store.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)
        XCTAssertFalse(calls.withLock { $0.contains(true) })
        store.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, 2)
    }

    func testFailedReadPreservesLastConfirmedSpaceAndRecoveryUpdatesIt() async {
        let response = Mutex<WindowSpaceSnapshot?>(WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)]))
        let calls = Mutex(0)
        let store = TaskbarSpaceStore(read: { _ in calls.withLock { $0 += 1 }; return response.withLock { $0 } },
                                     notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: Just(DockSnapshot.empty).eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 1 }
        response.withLock { $0 = nil }
        store.refresh()
        let pending = store.pendingWorkForTesting
        for task in pending { await task.value }
        XCTAssertEqual(store.snapshot.layouts["left"]?.currentSpaceID, 1)
        response.withLock { $0 = WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 2)]) }
        store.refresh()
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    func testRestartRejectsThePreviousReadAndUsesTheNewInventory() async {
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { _ = gate.wait(timeout: .now() + 2) }
            return WindowSpaceSnapshot(layouts: ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: call)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([call])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let original = inventory()
        store.start(snapshots: Just(original).eraseToAnyPublisher())
        await waitUntil { calls.withLock { $0 } == 1 }
        let pending = store.pendingWorkForTesting
        store.stop()
        var replacement = original
        replacement.windows[WindowID(rawValue: "window-1")] = nil
        replacement.orderedWindowIDs = [WindowID(rawValue: "window-2")]
        store.start(snapshots: Just(replacement).eraseToAnyPublisher())
        gate.signal()
        for task in pending { await task.value }
        await waitUntil { store.snapshot.layouts["left"]?.currentSpaceID == 2 }
        XCTAssertEqual(store.snapshot.memberships.keys.map(\.itemID), ["window-2"])
        store.stop()
    }

    private func flushSnapshotDelivery() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private var twoDisplayLayouts: [String: SpaceLayoutSnapshot] {
        ["left": SpaceLayoutSnapshot(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1),
         "right": SpaceLayoutSnapshot(orderedSpaceIDs: [10, 11], fullscreenSpaceIDs: [], currentSpaceID: 10)]
    }

    func testDisplayTransferUpdatesBothPresentersWithoutPollingOrWaitingForBulkMembership() async throws {
        let first = WindowID(rawValue: "window-1")
        let second = WindowID(rawValue: "window-2")
        var original = inventory()
        original.windows[second]?.status = .minimized
        let target = try XCTUnwrap(original.windows[first]?.actionIdentity)
        let fixture = SpaceInventory(original)
        let executor = SpaceActionRecorder()
        let runtime = AppRuntime(tracker: fixture, actionExecutor: executor)
        let bulkReads = Mutex(0)
        let destinationReads = Mutex(0)
        let bulkGate = DispatchSemaphore(value: 0)
        let destinationGate = DispatchSemaphore(value: 0)
        let timeouts = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            var space = Set([1])
            if requests.count == 1, requests.first?.displayUUID == "right" {
                let attempt = destinationReads.withLock { $0 += 1; return $0 }
                if attempt == 1 { return nil }
                if attempt == 3 {
                    if destinationGate.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
                    space = [10]
                }
            } else if requests.count == 2 {
                let attempt = bulkReads.withLock { $0 += 1; return $0 }
                if attempt == 1 { space = [1, 10] }
                if attempt == 2, bulkGate.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
                if attempt == 4 { space = [10] }
            }
            return WindowSpaceSnapshot(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues:
                requests.map { ($0.identity, $0.identity.windowID == 1 ? space : Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "DeskMote.DisplayTransferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let topology = DisplayTopologyStore(initialSnapshot: ScreenTopologySnapshot(
            physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"],
            attributionTable: WindowDisplayAttribution.Table(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                .init(uuid: "right", cgFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "left")
        ))
        let left = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let right = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenters = [("left", left), ("right", right)].map { display, view in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
                topology: topology, spaces: store, displayUUID: display,
                backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        }
        func ids(_ view: TaskbarView) -> [String] { view.taskbarContent.groups.flatMap(\.windows).map(\.id) }
        runtime.start()
        defer {
            bulkGate.signal()
            destinationGate.signal()
            store.stop()
            runtime.stop()
            withExtendedLifetime(presenters) {}
        }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        await waitUntil { store.snapshot.memberships.count == 2 && ids(left) == ["window-1", "window-2"] }
        XCTAssertTrue(ids(right).isEmpty)
        reorderSecondBeforeFirst(ordering)
        await waitUntil { ids(left) == ["window-2", "window-1"] }
        let identity = try XCTUnwrap(StripItem.openWindows(from: original).first?.spaceIdentity)
        XCTAssertEqual(store.snapshot.memberships[identity], [1, 10])
        store.refresh()
        await waitUntil { bulkReads.withLock { $0 } == 2 }
        var moved = original
        moved.windows[first]?.displayUUID = "right"
        fixture.values.send(moved)
        await waitUntil { ids(left) == ["window-2"] && destinationReads.withLock { $0 } == 3 }
        guard destinationReads.withLock({ $0 }) == 3 else { return }
        XCTAssertTrue(ids(right).isEmpty)
        XCTAssertNil(store.snapshot.memberships[identity])
        left.taskbarContent.actions.close(target)
        right.taskbarContent.actions.activate(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(executor.calls.withLock { $0.isEmpty })

        destinationGate.signal()
        await waitUntil { ids(left) == ["window-2"] && ids(right) == ["window-1"] }
        XCTAssertEqual(bulkReads.withLock { $0 }, 2)
        XCTAssertEqual(timeouts.withLock { $0 }, 0)
        left.taskbarContent.actions.close(target)
        right.taskbarContent.actions.activate(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, [first])
        XCTAssertEqual(ordering.liveOrder, ["window-2", "window-1"])
        moved.windows[first]?.status = .minimized
        fixture.values.send(moved)
        await waitUntil { runtime.snapshot.windows[first]?.status == .minimized }
        await flushSnapshotDelivery()
        var lostDestination = false
        let observation = store.$snapshot.sink { value in
            if value.memberships[identity] != [10] { lostDestination = true }
        }
        let pendingBulk = store.pendingWorkForTesting
        bulkGate.signal()
        for task in pendingBulk { await task.value }
        await waitUntil { bulkReads.withLock { $0 } == 3 }
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        observation.cancel()
        XCTAssertFalse(lostDestination)
        XCTAssertEqual(ids(right), ["window-1"])
        XCTAssertEqual(ids(left), ["window-2"])
        left.taskbarContent.actions.close(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, [first])

        store.refresh()
        await waitUntil { bulkReads.withLock { $0 } == 4 }
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(store.snapshot.memberships[identity], [10])
        store.refresh()
        await waitUntil { bulkReads.withLock { $0 } == 5 && store.snapshot.memberships[identity] == [1] }
        await flushSnapshotDelivery()
        XCTAssertEqual(ids(left), ["window-2", "window-1"])
        XCTAssertTrue(ids(right).isEmpty)

        fixture.values.send(original)
        await waitUntil { ids(left) == ["window-2", "window-1"] && ids(right).isEmpty }
        XCTAssertEqual(runtime.snapshot.windows.count, 2)
        XCTAssertNil(left.window)
        XCTAssertNil(right.window)
    }

    func testDisplayTransferToAnInactiveDestinationSpaceNeedsNoRetry() async throws {
        let original = inventory()
        let identity = try XCTUnwrap(StripItem.openWindows(from: original).first?.spaceIdentity)
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let reads = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            reads.withLock { $0 += 1 }
            return .init(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.displayUUID == "right" ? [11] : [1])
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships[identity] == [1] }

        var moved = original
        moved.windows[identity.actionIdentity.windowID]?.displayUUID = "right"
        source.send(moved)
        await waitUntil { store.snapshot.memberships[identity] == [11] }
        for task in store.pendingWorkForTesting { await task.value }

        XCTAssertFalse(store.snapshot.shows(identity, on: "right"))
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    func testReversingATransferDiscardsTheBlockedDestinationRead() async throws {
        let original = inventory()
        let identity = try XCTUnwrap(StripItem.openWindows(from: original).first?.spaceIdentity)
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let timeouts = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            if requests.contains(where: { $0.displayUUID == "right" }) {
                entered.withLock { $0 = true }
                if gate.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
            }
            return .init(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.displayUUID == "right" ? [10] : [1])
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { gate.signal(); store.stop() }
        await waitUntil { store.snapshot.memberships[identity] == [1] }

        var moved = original
        moved.windows[identity.actionIdentity.windowID]?.displayUUID = "right"
        source.send(moved)
        await waitUntil { entered.withLock { $0 } }
        let old = store.pendingWorkForTesting
        XCTAssertFalse(store.snapshot.shows(identity, on: "right"))

        source.send(original)
        await waitUntil { store.snapshot.memberships[identity] == [1] }
        gate.signal()
        for task in old { await task.value }
        XCTAssertEqual(timeouts.withLock { $0 }, 0)
        XCTAssertEqual(store.snapshot.memberships[identity], [1])
        XCTAssertTrue(store.snapshot.shows(identity, on: "left"))
        XCTAssertFalse(store.snapshot.shows(identity, on: "right"))
    }

    func testDisplayChangesDuringAReadCoalesceAndRejectOldMembership() async {
        let original = inventory()
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let calls = Mutex(0)
        let membership = Mutex<Set<Int>>([1])
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            guard requests.count == 2 else { return nil }
            let call = calls.withLock { $0 += 1; return $0 }
            let spaces = membership.withLock { $0 }
            if call == 1 { _ = firstGate.wait(timeout: .now() + 3) }
            if call == 2 { _ = secondGate.wait(timeout: .now() + 3) }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, spaces) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { firstGate.signal(); secondGate.signal(); store.stop() }
        await waitUntil { calls.withLock { $0 } == 1 }
        for display in ["right", "left", "right"] {
            var moved = original
            moved.windows[WindowID(rawValue: "window-1")]?.displayUUID = display
            source.send(moved)
        }
        membership.withLock { $0 = [10] }
        await flushSnapshotDelivery()
        firstGate.signal()
        await waitUntil { calls.withLock { $0 } == 2 }
        XCTAssertTrue(store.snapshot.memberships.isEmpty)
        secondGate.signal()
        await waitUntil { store.snapshot.memberships.values.allSatisfy { $0 == [10] } && store.snapshot.memberships.count == 2 }
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testDisplayTransferConfirmsMembershipWhileTheInitialLayoutReadIsBlocked() async throws {
        let original = inventory()
        let movedID = WindowID(rawValue: "window-1")
        let identity = try XCTUnwrap(StripItem.openWindows(from: original).first?.spaceIdentity)
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let initialReadEntered = Mutex(false)
        let initialRead = DispatchSemaphore(value: 0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let initial = requests.count == 2 && initialReadEntered.withLock { entered in
                defer { entered = true }
                return !entered
            }
            if initial { _ = initialRead.wait(timeout: .now() + 8) }
            return .init(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.displayUUID == "right" ? [10] : [1])
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { initialRead.signal(); store.stop() }
        await waitUntil { initialReadEntered.withLock { $0 } }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)

        var moved = original
        moved.windows[movedID]?.displayUUID = "right"
        source.send(moved)
        await waitUntil { store.snapshot.memberships[identity] == [10] }
        XCTAssertTrue(store.snapshot.shows(identity, on: "right"))
    }

    func testPartialTransferCanRetryAfterEstablishingTheInitialLayout() async throws {
        let original = inventory()
        let identities = StripItem.openWindows(from: original).compactMap(\.spaceIdentity)
        XCTAssertEqual(identities.map(\.windowID), [1, 2])
        let first = try XCTUnwrap(identities.first)
        let second = try XCTUnwrap(identities.last)
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let initialReadEntered = Mutex(false)
        let initialReadFinished = Mutex(false)
        let initialRead = DispatchSemaphore(value: 0)
        let allowSecondMembership = DispatchSemaphore(value: 0)
        let requested = Mutex<[[UInt32]]>([])
        let timeouts = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            if requests.allSatisfy({ $0.displayUUID == "left" }) {
                initialReadEntered.withLock { $0 = true }
                if initialRead.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
                initialReadFinished.withLock { $0 = true }
                return .init(layouts: layouts, memberships: [first: [1], second: [1]])
            }
            let attempt = requested.withLock {
                $0.append(requests.map(\.identity.windowID))
                return $0.count
            }
            if attempt == 1 { return .init(layouts: layouts, memberships: [first: [10]]) }
            if allowSecondMembership.wait(timeout: .now() + 8) == .timedOut { timeouts.withLock { $0 += 1 } }
            return .init(layouts: layouts, memberships: [second: [10]])
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer {
            store.stop()
            initialRead.signal()
            allowSecondMembership.signal()
        }
        await waitUntil { initialReadEntered.withLock { $0 } }
        XCTAssertTrue(store.snapshot.layouts.isEmpty)

        var moved = original
        moved.windows[first.actionIdentity.windowID]?.displayUUID = "right"
        moved.windows[second.actionIdentity.windowID]?.displayUUID = "right"
        source.send(moved)
        await waitUntil { store.snapshot.shows(first, on: "right") && store.snapshot.layouts == layouts }
        XCTAssertFalse(store.snapshot.shows(second, on: "right"))
        await waitUntil { requested.withLock { $0.count } == 2 }

        allowSecondMembership.signal()
        await waitUntil { store.snapshot.shows(second, on: "right") }
        XCTAssertTrue(store.snapshot.shows(first, on: "right"))
        XCTAssertFalse(initialReadFinished.withLock { $0 })
        XCTAssertEqual(requested.withLock { $0 }, [[1, 2], [2]])
        XCTAssertEqual(timeouts.withLock { $0 }, 0)
    }

    func testMinimizingDuringTransferKeepsStaleSourceMembershipOutOfBothPanels() async throws {
        let original = inventory()
        let first = WindowID(rawValue: "window-1")
        let target = try XCTUnwrap(original.windows[first]?.actionIdentity)
        let fixture = SpaceInventory(original)
        let executor = SpaceActionRecorder()
        let runtime = AppRuntime(tracker: fixture, actionExecutor: executor)
        let confirmed = Mutex(false)
        let staleParkedReads = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let available = confirmed.withLock { $0 }
            if !available, requests.count == 2,
               requests.contains(where: { $0.identity.windowID == 1 && $0.isParked && $0.displayUUID == "right" }) {
                staleParkedReads.withLock { $0 += 1 }
            }
            return .init(layouts: layouts, memberships: Dictionary(uniqueKeysWithValues: requests.map {
                ($0.identity, $0.identity.windowID == 1 && $0.displayUUID == "right" && available ? [10] : [1])
            }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let domain = "DeskMote.ParkedTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let ordering = StripOrderStore(defaults: defaults)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 2,
            identifiedDisplayUUIDs: ["left", "right"], attributionTable: .init(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                .init(uuid: "right", cgFrame: CGRect(x: 800, y: 0, width: 800, height: 600))
            ], primaryUUID: "left")))
        let left = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let right = TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32))
        let presenters = [("left", left), ("right", right)].map { display, view in
            TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: store,
                displayUUID: display, backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        }
        func ids(_ view: TaskbarView) -> [String] { view.taskbarContent.groups.flatMap(\.windows).map(\.id) }
        runtime.start()
        store.start(snapshots: runtime.$snapshot.eraseToAnyPublisher())
        defer { store.stop(); runtime.stop(); withExtendedLifetime(presenters) {} }
        await waitUntil { store.snapshot.memberships.count == 2 && ids(left) == ["window-1", "window-2"] }

        var moved = original
        moved.windows[first]?.displayUUID = "right"
        fixture.values.send(moved)
        await waitUntil { ids(left) == ["window-2"] && ids(right).isEmpty }
        moved.windows[first]?.status = .minimized
        fixture.values.send(moved)
        await waitUntil { runtime.snapshot.windows[first]?.status == .minimized }
        await flushSnapshotDelivery()
        store.refresh()
        await waitUntil { staleParkedReads.withLock { $0 > 0 } }
        for task in store.pendingWorkForTesting { await task.value }
        await flushSnapshotDelivery()
        XCTAssertEqual(ids(left), ["window-2"])
        XCTAssertTrue(ids(right).isEmpty)
        left.taskbarContent.actions.close(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(executor.calls.withLock { $0.isEmpty })

        confirmed.withLock { $0 = true }
        store.refresh()
        await waitUntil { ids(left) == ["window-2"] && ids(right) == ["window-1"] }
        right.taskbarContent.actions.close(target)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(executor.calls.withLock { $0 }, [first])
    }

    func testSameDisplayGeometryTitleAndFocusChangesDoNotRefreshSpaces() async {
        let source = CurrentValueSubject<DockSnapshot, Never>(inventory())
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            calls.withLock { $0 += 1 }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([1])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships.count == 2 }
        for index in 0..<20 {
            var changed = source.value
            let key = WindowID(rawValue: "window-1")
            changed.windows[key]?.bounds = CGRect(x: 10 + index, y: 100, width: 900, height: 600)
            changed.windows[key]?.title = "Updated \(index)"
            changed.windows[key]?.status = index.isMultiple(of: 2) ? .active : .inactive
            source.send(changed)
        }
        await flushSnapshotDelivery()
        for task in store.pendingWorkForTesting { await task.value }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testResolvingAnUnknownDisplayRefreshesMembership() async {
        var original = inventory()
        let key = WindowID(rawValue: "window-1")
        original.windows[key]?.displayUUID = nil
        let source = CurrentValueSubject<DockSnapshot, Never>(original)
        let calls = Mutex(0)
        let layouts = twoDisplayLayouts
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            return WindowSpaceSnapshot(layouts: layouts,
                memberships: Dictionary(uniqueKeysWithValues: requests.map { ($0.identity, Set([call == 1 ? 1 : 10])) }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        store.start(snapshots: source.eraseToAnyPublisher())
        defer { store.stop() }
        await waitUntil { store.snapshot.memberships.count == 2 }
        var resolved = original
        resolved.windows[key]?.displayUUID = "right"
        source.send(resolved)
        await waitUntil { calls.withLock { $0 } == 2 && store.snapshot.memberships.values.allSatisfy { $0 == [10] } }
    }

}
