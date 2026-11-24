import AppKit
import Combine
import Synchronization
import XCTest

@MainActor
private final class RuntimeInventory: WindowInventoryTracking {
    let values: CurrentValueSubject<DockSnapshot, Never>
    var starts = 0
    var stops = 0
    var snapshots: AnyPublisher<DockSnapshot, Never> { values.eraseToAnyPublisher() }

    init(_ snapshot: DockSnapshot) { values = CurrentValueSubject(snapshot) }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

private final class RuntimeExecutor: WindowActionExecuting {
    let calls = Mutex(0)
    let predictionReported = Mutex(false)
    let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
    let results: [Bool]
    let predictedWindow: WindowID?
    let predictionGate: DispatchSemaphore?
    private let gateDeadline: @Sendable () -> DispatchTime

    init(results: [Bool], predictedWindow: WindowID? = nil, pauseAfterPrediction: Bool = false,
         gateDeadline: @escaping @Sendable () -> DispatchTime = { .now() + 3 }) {
        self.results = results
        self.gateDeadline = gateDeadline
        self.predictedWindow = predictedWindow
        predictionGate = pauseAfterPrediction ? DispatchSemaphore(value: 0) : nil
    }

    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                 forcedMinimizedPrior: Bool, cancellation: OperationCancellation,
                 onHandoffActivePrediction: (@Sendable (WindowID) -> Void)?) -> Bool {
        let index = calls.withLock { value in
            defer { value += 1 }
            return value
        }
        guard gates.indices.contains(index), results.indices.contains(index) else { return false }
        guard gates[index].wait(timeout: gateDeadline()) == .success else { return false }
        if let predictedWindow, let onHandoffActivePrediction, index == 0 {
            onHandoffActivePrediction(predictedWindow)
            predictionReported.withLock { $0 = true }
            if let predictionGate, predictionGate.wait(timeout: gateDeadline()) != .success { return false }
        }
        return results[index]
    }
}

@MainActor
private final class RuntimeUtilityWindow: NSWindow {
    private var minimized = false
    private var key = false
    var allowsClose = true
    var closeAttempts = 0
    override var windowNumber: Int { 749 }
    override var isMiniaturized: Bool { minimized }
    override var isKeyWindow: Bool { key }

    init(title: String) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        self.title = title
    }

    override func miniaturize(_ sender: Any?) {
        minimized = true
        key = false
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: self)
    }

    override func deminiaturize(_ sender: Any?) {
        minimized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: self)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self)
    }

    override func performClose(_ sender: Any?) {
        closeAttempts += 1
        guard allowsClose else { return }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: self)
    }
}

@MainActor
final class AppRuntimeTests: XCTestCase {
    private func snapshot(activeWindowID: String? = nil) -> DockSnapshot {
        let records = (1...2).map { index in
            WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "test"), pid: 42,
                         bundleIdentifier: "test.runtime", title: "Window \(index)", bounds: nil,
                         status: activeWindowID == "window-\(index)" ? .active : .inactive, cgWindowID: UInt32(index))
        }
        return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                            orderedWindowIDs: records.map(\.id))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func start(_ executor: RuntimeExecutor, activeWindowID: String? = nil) async -> (AppRuntime, RuntimeInventory) {
        let inventory = RuntimeInventory(snapshot(activeWindowID: activeWindowID))
        let runtime = AppRuntime(tracker: inventory, actionExecutor: executor,
                                 isAppFrontmost: { activeWindowID != nil && $0 == 42 })
        runtime.start()
        await waitUntil { runtime.snapshot.windows.count == 2 }
        return (runtime, inventory)
    }

    @MainActor
    private final class FocusPanels {
        let inventory: RuntimeInventory
        let runtime: AppRuntime
        private let defaults: UserDefaults
        private let domain = "DeskMote.FocusPanels.\(UUID().uuidString)"
        private let views: [TaskbarView]
        private let presenters: [TaskbarPresenter]
        private let includesSafari: Bool

        init(executor: RuntimeExecutor, actual: String?, includesSafari: Bool = false,
             monotonicNow: @escaping () -> ContinuousClock.Instant = { .now }) {
            self.includesSafari = includesSafari
            inventory = RuntimeInventory(Self.snapshot(actual: actual, includesSafari: includesSafari))
            runtime = AppRuntime(tracker: inventory, actionExecutor: executor, isAppFrontmost: { _ in true },
                                 monotonicNow: monotonicNow)
            defaults = UserDefaults(suiteName: domain)!
            let displays = ["left", "right"]
            let attribution = WindowDisplayAttribution.Table(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                .init(uuid: "right", cgFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "left")
            let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 2,
                identifiedDisplayUUIDs: ["left", "right"], attributionTable: attribution))
            let spaces = TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0)
            let ordering = StripOrderStore(defaults: defaults, bootTimeProvider: { 123 })
            let system = BehaviorDesktop()
            views = displays.map { _ in
                TaskbarView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: BehaviorPopup(),
                            contextMenu: BehaviorMenu(), delay: { _ in await Task.yield() })
            }
            let runtime = runtime
            presenters = zip(views, displays).map { view, display in
                TaskbarPresenter(view: view, runtime: runtime, ordering: ordering, topology: topology, spaces: spaces,
                                 displayUUID: display, backgroundMenu: { _, _ in }, popupPresented: { _ in },
                                 contextMenuVisibilityChanged: { _ in }, system: system)
            }
            runtime.start()
        }

        private static func snapshot(actual: String?, includesSafari: Bool, title: String? = nil) -> DockSnapshot {
            var windows = [("steam", Int32(-41000), UInt32(1001), "left"),
                           ("chrome", Int32(-42000), UInt32(2001), "right")]
            if includesSafari { windows.append(("safari", -43000, 3001, "left")) }
            let records = windows.map { name, pid, cgID, display in
                WindowRecord(id: WindowID(rawValue: name), appID: AppID(rawValue: name), pid: pid,
                             bundleIdentifier: "test." + name, title: name == actual ? title ?? name : name, bounds: nil,
                             status: name == actual ? .active : .inactive, cgWindowID: cgID, displayUUID: display)
            }
            return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                                orderedWindowIDs: records.map(\.id))
        }

        func focus(_ name: String, title: String? = nil) {
            inventory.values.send(Self.snapshot(actual: name, includesSafari: includesSafari, title: title))
        }

        var ready: Bool {
            views.map { $0.taskbarContent.buttonViews.count } == [includesSafari ? 2 : 1, 1]
        }

        var highlights: [String] {
            ["steam", "chrome", "safari"].filter { name in
                views.contains { $0.taskbarContent.buttonViews["window:\(name)"]?.isActiveWindow == true }
            }
        }

        func stop() {
            runtime.stop()
            defaults.removePersistentDomain(forName: domain)
        }
    }

    private func drainFocusPanels() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testNewNativeFocusReplacesCrossApplicationActivationPrediction() async {
        let executor = RuntimeExecutor(results: [true, true])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])

        panels.focus("chrome")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])
        panels.runtime.toggle(windowID: "steam")
        XCTAssertEqual(panels.runtime.debugState.feedbackEntriesByWindowID["steam"]?.action, .activate)
        executor.gates[0].signal()
        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testPendingActivationExclusivelyHighlightsChromeAndFailureRestoresNativeSteam() async {
        let executor = RuntimeExecutor(results: [false])
        let panels = FocusPanels(executor: executor, actual: "steam")
        defer { panels.stop() }
        await waitUntil { panels.ready }
        XCTAssertEqual(panels.highlights, ["steam"])

        panels.runtime.activate(windowID: "chrome")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.gates[0].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
    }

    func testLateOlderActivationSuccessCannotOverrideChromeOrReappearAfterItsFailure() async {
        let executor = RuntimeExecutor(results: [true, false])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, [])
    }

    func testNativeConfirmationOfAnOlderActivationWaitsBehindNewerPendingChrome() async {
        let executor = RuntimeExecutor(results: [true, false])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        panels.focus("steam")
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
    }

    func testReturnToTheInitialNativeFocusSupersedesTheNewestPendingActivation() async {
        let executor = RuntimeExecutor(results: [true, true, true])
        let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true)
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "chrome")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "safari")

        panels.focus("chrome")
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["safari"])
        panels.focus("chrome", title: "New Chrome title")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["safari"])

        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        panels.runtime.toggle(windowID: "safari")
        XCTAssertEqual(panels.runtime.debugState.feedbackEntriesByWindowID["safari"]?.action, .activate)
        executor.gates[1].signal()
        executor.gates[2].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testDirectFocusAfterAnOlderActivationFailureSupersedesTheNewerPrediction() async {
        let executor = RuntimeExecutor(results: [false, true])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testOlderActivationFailureReconsidersNativeFocusSeenBeforeTheResult() async {
        let executor = RuntimeExecutor(results: [false, true])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testOlderWindowRemovalReconsidersTheIncomingNativeSnapshot() async {
        let executor = RuntimeExecutor(results: [false, true])
        let panels = FocusPanels(executor: executor, actual: nil)
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        var snapshot = panels.runtime.snapshot
        let removed = WindowID(rawValue: "steam")
        snapshot.windows.removeValue(forKey: removed)
        snapshot.orderedWindowIDs.removeAll { $0 == removed }
        panels.inventory.values.send(snapshot)
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])
        executor.gates[0].signal()
        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testCloseRemovesTheSupersededActivationBeforeAnotherWindowIsToggled() async {
        let executor = RuntimeExecutor(results: [false, true, true])
        let panels = FocusPanels(executor: executor, actual: "steam")
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.activate(windowID: "chrome")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        panels.runtime.close(windowID: "chrome")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        panels.runtime.toggle(windowID: "steam")
        XCTAssertEqual(panels.runtime.debugState.feedbackEntriesByWindowID["steam"]?.action, .minimize)
        executor.gates[1].signal()
        executor.gates[2].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testDirectFocusToAStillQueuedEarlierTargetSupersedesTheNewerPrediction() async {
        let executor = RuntimeExecutor(results: [true, true, true])
        let panels = FocusPanels(executor: executor, actual: nil, includesSafari: true)
        defer { executor.gates.forEach { $0.signal() }; panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "safari")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "steam")
        panels.runtime.activate(windowID: "chrome")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
        executor.gates.forEach { $0.signal() }
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testCloseHandoffSurvivesAnUpdateFromItsStillFocusedSourceUntilNewNativeFocus() async {
        let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "chrome"),
                                       pauseAfterPrediction: true)
        let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true)
        defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "steam")
        executor.gates[0].signal()
        await waitUntil { panels.highlights == ["chrome"] }

        panels.focus("steam", title: "Closing Steam window")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        panels.focus("safari")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["safari"])
        executor.predictionGate?.signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testCloseHandoffAcceptsNewlyConfirmedExactSourceAndRejectsUnrelatedFocus() async {
        for (actual, expected) in [("steam", "chrome"), ("safari", "safari")] {
            let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "chrome"),
                                           pauseAfterPrediction: true)
            let panels = FocusPanels(executor: executor, actual: nil, includesSafari: true)
            defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
            await waitUntil { panels.ready }
            panels.runtime.close(windowID: "steam")
            await waitUntil { executor.calls.withLock { $0 } == 1 }
            panels.focus(actual)
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, [actual])

            executor.gates[0].signal()
            executor.predictionGate?.signal()
            for task in panels.runtime.pendingActionsForTesting { await task.value }
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, [expected])
        }
    }

    func testCancelledQueuedActivationDoesNotBlockAnEarlierValidCloseHandoff() async throws {
        let now = ContinuousClock.now
        let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "safari"),
                                       pauseAfterPrediction: true, gateDeadline: { .distantFuture })
        let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true, monotonicNow: { now })
        defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let id = WindowID(rawValue: "chrome")
        let target = try XCTUnwrap(panels.runtime.snapshot.windows[id]?.actionIdentity)
        let invalidations = PassthroughSubject<Void, Never>()
        panels.runtime.trigger(.activate(id), expected: target, projectionInvalidations: invalidations.eraseToAnyPublisher(),
                               isProjectionCurrent: { true })
        await waitUntil { panels.highlights == ["chrome"] }
        invalidations.send(())
        await waitUntil { panels.highlights == ["steam"] }
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)

        executor.gates[0].signal()
        await waitUntil { panels.runtime.optimisticStatesByWindowID["safari"]?.systemPredicted == true }
        executor.predictionGate?.signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(panels.runtime.effectiveActiveWindowID, WindowID(rawValue: "safari"))
        await waitUntil { panels.highlights == ["safari"] }
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
    }

    private func queueChromeActivation(in panels: FocusPanels) throws -> PassthroughSubject<Void, Never> {
        let id = WindowID(rawValue: "chrome")
        let target = try XCTUnwrap(panels.runtime.snapshot.windows[id]?.actionIdentity)
        let invalidations = PassthroughSubject<Void, Never>()
        panels.runtime.trigger(.activate(id), expected: target, projectionInvalidations: invalidations.eraseToAnyPublisher(),
                               isProjectionCurrent: { true })
        return invalidations
    }

    func testReportedCloseHandoffReturnsWhenTheQueuedActivationIsCancelled() async throws {
        let cases: [(Duration, String, WindowStatus?)] = [
            (.seconds(4), "safari", .active),
            (.seconds(4) + .nanoseconds(1), "steam", nil),
        ]
        for (elapsed, highlight, prediction) in cases {
            let start = ContinuousClock.now
            var now = start
            let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "safari"),
                                           pauseAfterPrediction: true)
            let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true, monotonicNow: { now })
            defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
            await waitUntil { panels.ready }
            panels.runtime.close(windowID: "steam")
            await waitUntil { executor.calls.withLock { $0 } == 1 }
            let invalidations = try queueChromeActivation(in: panels)
            executor.gates[0].signal()
            await waitUntil { executor.predictionReported.withLock { $0 } }
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, ["chrome"])

            now = start + elapsed
            invalidations.send(())
            XCTAssertEqual(panels.runtime.optimisticStatesByWindowID["safari"]?.status, prediction)
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, [highlight])
            XCTAssertEqual(executor.calls.withLock { $0 }, 1)
            executor.predictionGate?.signal()
            for task in panels.runtime.pendingActionsForTesting { await task.value }
        }
    }

    func testReportedCloseHandoffSurvivesTheFirstConfirmationOfItsExactSource() async {
        let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "chrome"),
                                       pauseAfterPrediction: true)
        let panels = FocusPanels(executor: executor, actual: nil, includesSafari: true)
        defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "steam")
        executor.gates[0].signal()
        await waitUntil { panels.highlights == ["chrome"] }

        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        panels.focus("safari")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["safari"])
        executor.predictionGate?.signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
    }

    func testFocusOnAnUnadmittedActivationDoesNotRetireAnEarlierCloseHandoff() async throws {
        let executor = RuntimeExecutor(results: [true], predictedWindow: WindowID(rawValue: "safari"),
                                       pauseAfterPrediction: true)
        let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true)
        defer { executor.gates[0].signal(); executor.predictionGate?.signal(); panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let invalidations = try queueChromeActivation(in: panels)
        panels.focus("chrome")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        invalidations.send(())
        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)

        executor.gates[0].signal()
        executor.predictionGate?.signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["safari"])
        XCTAssertEqual(executor.calls.withLock { $0 }, 1)
    }

    func testSuccessfulNewerActivationRetiresAnEarlierCloseHandoff() async {
        let executor = RuntimeExecutor(results: [true, true], predictedWindow: WindowID(rawValue: "safari"),
                                       pauseAfterPrediction: true)
        let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true)
        defer { executor.gates.forEach { $0.signal() }; executor.predictionGate?.signal(); panels.stop() }
        await waitUntil { panels.ready }
        panels.runtime.close(windowID: "steam")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        panels.runtime.activate(windowID: "chrome")
        executor.gates[0].signal()
        await waitUntil { executor.predictionReported.withLock { $0 } }
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["chrome"])

        executor.predictionGate?.signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        executor.gates[1].signal()
        for task in panels.runtime.pendingActionsForTesting { await task.value }
        panels.focus("chrome")
        await drainFocusPanels()
        panels.focus("steam")
        await drainFocusPanels()
        XCTAssertEqual(panels.highlights, ["steam"])
    }

    func testNativeHandoffFromAnOlderCommandDoesNotSupersedeTheNewerActivation() async {
        for close in [true, false] {
            let executor = RuntimeExecutor(results: [true, false], predictedWindow: WindowID(rawValue: "safari"),
                                           pauseAfterPrediction: true)
            let panels = FocusPanels(executor: executor, actual: "steam", includesSafari: true)
            defer {
                executor.gates.forEach { $0.signal() }
                executor.predictionGate?.signal()
                panels.stop()
            }
            await waitUntil { panels.ready }
            if close { panels.runtime.close(windowID: "steam") }
            else { panels.runtime.toggle(windowID: "steam") }
            await waitUntil { executor.calls.withLock { $0 } == 1 }
            panels.runtime.activate(windowID: "chrome")
            executor.gates[0].signal()
            executor.predictionGate?.signal()
            await waitUntil { executor.calls.withLock { $0 } == 2 }
            panels.focus("safari")
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, ["chrome"])
            executor.gates[1].signal()
            for task in panels.runtime.pendingActionsForTesting { await task.value }
            await drainFocusPanels()
            XCTAssertEqual(panels.highlights, ["safari"])
        }
    }

    func testRegisteredUtilityWindowUsesItsExactNativeTargetAndKeepsExternalInventory() async throws {
        let executor = RuntimeExecutor(results: [])
        let inventory = RuntimeInventory(snapshot())
        let runtime = AppRuntime(tracker: inventory, actionExecutor: executor, isAppFrontmost: { _ in true },
                                 activateUtilityApplication: {})
        let utility = RuntimeUtilityWindow(title: "Example Utility")
        let unregistered = RuntimeUtilityWindow(title: "Unregistered")
        runtime.registerUtilityWindow(utility)
        runtime.registerUtilityWindow(utility)
        runtime.start()
        defer { runtime.stop() }
        await waitUntil { runtime.snapshot.windows[WindowID(rawValue: "window-1")] != nil }
        let record = try XCTUnwrap(runtime.snapshot.windows.values.first { $0.title == "Example Utility" })
        let id = record.id.rawValue
        XCTAssertEqual(runtime.snapshot.windows.count, 3)
        XCTAssertNil(record.cgWindowID)
        let item = StripItem(record: record)
        XCTAssertEqual(item.spaceIdentity?.windowID, 749)
        let group = TaskbarGroupPresentation(id: "utility", name: "App", windows: [
            TaskbarWindowPresentation(item: item, title: item.title, isActive: false)
        ])
        let button = TaskbarButtonLayout(id: item.id, groupID: group.id, windowIDs: [item.id], isCombined: false, frame: .zero)
        XCTAssertEqual(TaskbarContextMenuModel.actions(button: button, group: group), [.closeWindow(id)])

        utility.title = "Utility Title Changed"
        await waitUntil { runtime.snapshot.windows[record.id]?.title == "Utility Title Changed" }

        runtime.activate(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(utility.isKeyWindow)
        XCTAssertEqual(runtime.snapshot.windows[record.id]?.status, .active)

        runtime.toggle(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(utility.isMiniaturized)
        XCTAssertEqual(runtime.snapshot.windows[record.id]?.status, .minimized)

        runtime.toggle(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertFalse(utility.isMiniaturized)
        XCTAssertEqual(runtime.snapshot.windows[record.id]?.status, .active)

        utility.allowsClose = false
        runtime.close(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(utility.closeAttempts, 1)
        XCTAssertNotNil(runtime.snapshot.windows[record.id])

        utility.allowsClose = true
        runtime.close(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(utility.closeAttempts, 2)
        XCTAssertEqual(unregistered.closeAttempts, 0)
        XCTAssertNil(runtime.snapshot.windows[record.id])
        XCTAssertEqual(runtime.snapshot.windows.count, 2)

        runtime.registerUtilityWindow(utility)
        let reopened = try XCTUnwrap(runtime.snapshot.windows.values.first { $0.title == "Utility Title Changed" })
        XCTAssertNotEqual(reopened.id, record.id)
        runtime.close(windowID: id)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertNotNil(runtime.snapshot.windows[reopened.id])
        XCTAssertEqual(utility.closeAttempts, 2)
        XCTAssertEqual(executor.calls.withLock { $0 }, 0)
    }

    func testFailedActionPublishesFailureAfterClearingItsOptimisticState() async {
        let executor = RuntimeExecutor(results: [false])
        let (runtime, _) = await start(executor)
        defer { runtime.stop() }
        var publishedFailure = false
        let subscription = runtime.debugState.$feedbackEntriesByWindowID.sink { entries in
            guard entries["window-1"]?.phase == .failure else { return }
            publishedFailure = true
            XCTAssertNil(runtime.optimisticStatesByWindowID["window-1"])
        }
        defer { subscription.cancel() }
        runtime.activate(windowID: "window-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-1"]?.status, .active)
        let pending = runtime.pendingActionsForTesting
        XCTAssertFalse(pending.isEmpty)
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertNil(runtime.optimisticStatesByWindowID["window-1"])
        XCTAssertTrue(publishedFailure)
    }

    func testOlderFailureCannotClearNewerSuccessfulIntent() async {
        let executor = RuntimeExecutor(results: [false, true])
        let (runtime, _) = await start(executor)
        defer { runtime.stop() }
        runtime.activate(windowID: "window-1")
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let older = runtime.pendingActionsForTesting
        runtime.activate(windowID: "window-1")
        executor.gates[0].signal()
        await waitUntil { executor.calls.withLock { $0 } == 2 }
        executor.gates[1].signal()
        await waitUntil { runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase == .success }
        executor.gates[0].signal()
        for task in older { await task.value }
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-1"]?.status, .active)
        XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase, .success)
    }

    private func startPredictedHandoff(
        close: Bool = false, results: [Bool]
    ) async -> (AppRuntime, RuntimeInventory, RuntimeExecutor) {
        let executor = RuntimeExecutor(results: results, predictedWindow: WindowID(rawValue: "window-2"),
                                       pauseAfterPrediction: true)
        let (runtime, inventory) = await start(executor, activeWindowID: "window-1")
        if close { runtime.close(windowID: "window-1") }
        else { runtime.toggle(windowID: "window-1") }
        executor.gates[0].signal()
        await waitUntil { runtime.optimisticStatesByWindowID["window-2"]?.systemPredicted == true }
        return (runtime, inventory, executor)
    }

    func testFailedHandoffDoesNotTurnTheNextSiblingClickIntoMinimize() async {
        for close in [false, true] {
            let (runtime, _, executor) = await startPredictedHandoff(close: close, results: [false, true])
            defer { runtime.stop() }
            executor.predictionGate?.signal()
            for task in runtime.pendingActionsForTesting { await task.value }
            XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase, .failure)
            XCTAssertNil(runtime.optimisticStatesByWindowID["window-2"])

            runtime.toggle(windowID: "window-2")
            XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-2"]?.action, .activate)
            executor.gates[1].signal()
            for task in runtime.pendingActionsForTesting { await task.value }
        }
    }

    func testSupersededHandoffClearsItsPredictionImmediately() async {
        let (runtime, _, executor) = await startPredictedHandoff(results: [false, true])
        defer { runtime.stop() }

        runtime.close(windowID: "window-1")
        XCTAssertNil(runtime.optimisticStatesByWindowID["window-2"])
        executor.predictionGate?.signal()
        executor.gates[1].signal()
        for task in runtime.pendingActionsForTesting { await task.value }
    }

    func testReplacingHandoffSourceClearsItsPredictionImmediately() async {
        let (runtime, inventory, executor) = await startPredictedHandoff(results: [false])
        defer { runtime.stop() }
        let sourceID = WindowID(rawValue: "window-1")
        var replacement = runtime.snapshot
        replacement.windows[sourceID]?.cgWindowID = 3
        inventory.values.send(replacement)
        await waitUntil { runtime.snapshot.windows[sourceID]?.cgWindowID == 3 }

        XCTAssertNil(runtime.optimisticStatesByWindowID["window-2"])
        executor.predictionGate?.signal()
        for task in runtime.pendingActionsForTesting { await task.value }
    }

    func testFailedHandoffKeepsAnIndependentTargetAction() async {
        let (runtime, _, executor) = await startPredictedHandoff(results: [false, true])
        defer { runtime.stop() }
        runtime.activate(windowID: "window-2")
        executor.predictionGate?.signal()
        await waitUntil { runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase == .failure }

        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-2"]?.status, .active)
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-2"]?.systemPredicted, false)
        executor.gates[1].signal()
        for task in runtime.pendingActionsForTesting { await task.value }
    }

    func testSuccessfulHandoffKeepsThePredictionForTheNextSiblingClick() async {
        let (runtime, _, executor) = await startPredictedHandoff(results: [true, true])
        defer { runtime.stop() }
        executor.predictionGate?.signal()
        for task in runtime.pendingActionsForTesting { await task.value }

        runtime.toggle(windowID: "window-2")
        XCTAssertEqual(runtime.debugState.feedbackEntriesByWindowID["window-2"]?.action, .minimize)
        executor.gates[1].signal()
        for task in runtime.pendingActionsForTesting { await task.value }
    }

    func testInventoryConfirmedCloseKeepsTheSiblingHandoffPrediction() async {
        let (runtime, inventory, executor) = await startPredictedHandoff(close: true, results: [true])
        defer { runtime.stop() }
        let sourceID = WindowID(rawValue: "window-1")
        var closed = runtime.snapshot
        closed.windows.removeValue(forKey: sourceID)
        closed.orderedWindowIDs.removeAll { $0 == sourceID }
        inventory.values.send(closed)
        await waitUntil { runtime.debugState.feedbackEntriesByWindowID["window-1"]?.phase == .success }

        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-2"]?.status, .active)
        executor.predictionGate?.signal()
        for task in runtime.pendingActionsForTesting { await task.value }
    }

    func testStopAndRestartRejectLateExecutionAndHandoffPrediction() async {
        let executor = RuntimeExecutor(results: [false], predictedWindow: WindowID(rawValue: "window-2"))
        let (runtime, inventory) = await start(executor, activeWindowID: "window-1")
        runtime.toggle(windowID: "window-1")
        XCTAssertEqual(runtime.optimisticStatesByWindowID["window-1"]?.status, .minimized)
        await waitUntil { executor.calls.withLock { $0 } == 1 }
        let pending = runtime.pendingActionsForTesting
        runtime.stop()
        XCTAssertTrue(runtime.snapshot.windows.isEmpty)
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.debugState.feedbackEntriesByWindowID.isEmpty)
        runtime.start()
        defer { runtime.stop() }
        await waitUntil { runtime.snapshot.windows.count == 2 }
        executor.gates[0].signal()
        for task in pending { await task.value }
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.debugState.feedbackEntriesByWindowID.isEmpty)
        XCTAssertEqual(inventory.starts, 2)
        XCTAssertEqual(inventory.stops, 1)
    }

    func testStoppedRuntimeDoesNotDispatchActionsOrAcceptSnapshots() async {
        let executor = RuntimeExecutor(results: [])
        let (runtime, inventory) = await start(executor)
        runtime.stop()
        runtime.activate(windowID: "window-1")
        inventory.values.send(snapshot())
        XCTAssertTrue(runtime.pendingActionsForTesting.isEmpty)
        XCTAssertEqual(executor.calls.withLock { $0 }, 0)
        XCTAssertTrue(runtime.optimisticStatesByWindowID.isEmpty)
        XCTAssertTrue(runtime.snapshot.windows.isEmpty)
    }

    func testReleasingRuntimeStopsItsInventorySubscription() {
        let inventory = RuntimeInventory(snapshot())
        var runtime: AppRuntime? = AppRuntime(tracker: inventory, actionExecutor: RuntimeExecutor(results: []))
        weak var reference = runtime
        runtime?.start()
        runtime = nil
        XCTAssertNil(reference)
        XCTAssertEqual(inventory.stops, 1)
    }

    func testCancelledBackgroundOperationNeverExecutesItsSideEffect() async {
        let queue = DispatchQueue(label: "test.cancelled-actions")
        let calls = Mutex(0)
        queue.suspend()
        let task = Task {
            await AsyncWorkScope.performBlocking(on: queue) {
                calls.withLock { $0 += 1 }
                return true
            }
        }
        task.cancel()
        queue.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testBackgroundOperationRunsOffMainAndReturnsItsResult() async {
        let result = await AsyncWorkScope.performBlocking { !Thread.isMainThread }
        XCTAssertEqual(result, true)
    }
}
