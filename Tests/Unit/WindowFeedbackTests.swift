import Foundation
import XCTest

final class DockSnapshotEqualityTests: XCTestCase {
    func testEquivalentSnapshotsCompareEqual() {
        let id = WindowID(rawValue: "cgw-1")
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 42,
            bundleIdentifier: "com.example.app",
            title: "Window",
            bounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            status: .inactive,
            cgWindowID: 10,
            isOnDesktop: true,
            groupID: "seat-1"
        )
        let lhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
        let rhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])

        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, .empty)
    }
}

final class IntentFeedbackStateRetentionTests: XCTestCase {

    private let windowID = "cgw-1"

    private func snapshot(status: WindowStatus) -> DockSnapshot {
        let id = WindowID(rawValue: windowID)
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 1234,
            bundleIdentifier: "com.example.app",
            title: "Window",
            bounds: nil,
            status: status,
            isOnDesktop: true,
            groupID: windowID
        )
        return DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
    }

    func testPendingBecomesFailureAfterRetention() {
        var state = IntentFeedbackState()
        let start = ContinuousClock.now
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .inactive), now: start + .milliseconds(4500))

        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)
    }

    func testFailureIsUpgradedToSuccessWhenSnapshotLaterConfirms() {
        var state = IntentFeedbackState()
        let start = ContinuousClock.now
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.markFailed(windowID: windowID, action: .minimize, at: start + .milliseconds(50))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start + .milliseconds(400))
        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.phase,
            .success,
            "A later snapshot can confirm an AX action after an immediate read reported failure"
        )
    }

    func testSuccessIsNotRestampedWhileWindowStaysInTargetState() {
        var state = IntentFeedbackState()
        let start = ContinuousClock.now
        state.begin(windowID: windowID, action: .minimize, at: start)
        state.reconcile(snapshot: snapshot(status: .minimized), now: start + .milliseconds(200))
        let firstSuccessAt = state.entriesByWindowID[windowID]?.updatedAt
        XCTAssertNotNil(firstSuccessAt)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start + .milliseconds(700))

        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.updatedAt,
            firstSuccessAt,
            "Repeated reconciliation in the same phase must preserve the retention deadline"
        )
    }

    func testTerminalEntryIsDroppedAfterRetentionSoTheTimerCanStop() {
        var state = IntentFeedbackState()
        let start = ContinuousClock.now
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start + .milliseconds(500))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start + .milliseconds(2200))
        XCTAssertTrue(
            state.entriesByWindowID.isEmpty,
            "The on-demand timer can stop after terminal entries expire"
        )
    }

    @MainActor
    func testPendingAndTerminalRetentionUseTheInjectedContinuousClock() {
        let start = ContinuousClock.now
        var now = start
        let pipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner(isAppFrontmost: { _ in false }),
                                      monotonicNow: { now })
        let id = WindowID(rawValue: windowID)
        let intent = UserIntent.toggle(id)
        let unconfirmed = snapshot(status: .inactive)
        pipeline.registerPending(intent: intent, request: .init(kind: .minimizeWindow, windowID: id))

        now = start + .seconds(4)
        pipeline.reconcile(with: unconfirmed)
        XCTAssertEqual(pipeline.feedbackState.entriesByWindowID[windowID]?.phase, .pending)

        now = now + .nanoseconds(1)
        let failureTime = now
        pipeline.reconcile(with: unconfirmed)
        XCTAssertEqual(pipeline.feedbackState.entriesByWindowID[windowID]?.phase, .failure)

        now = failureTime + .milliseconds(1500)
        pipeline.reconcile(with: unconfirmed)
        XCTAssertEqual(pipeline.feedbackState.entriesByWindowID[windowID]?.phase, .failure)

        now = now + .nanoseconds(1)
        pipeline.reconcile(with: unconfirmed)
        XCTAssertNil(pipeline.feedbackState.entriesByWindowID[windowID])
    }

    func testCloseFeedbackDistinguishesAnOrderedOnlyIDFromAnAbsentWindow() {
        let start = ContinuousClock.now
        let id = WindowID(rawValue: windowID)
        let orderedOnly = DockSnapshot(windows: [:], orderedWindowIDs: [id])
        var state = IntentFeedbackState()
        state.begin(windowID: windowID, action: .close, at: start)

        state.reconcile(snapshot: orderedOnly, now: start)
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .pending)

        state.reconcile(snapshot: .empty, now: start)
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)
    }
}

@MainActor
final class RuntimeFeedbackClockTests: XCTestCase {
    func testAnUnconfirmedMinimizeExpiresWithItsFeedbackAfterFourSeconds() async {
        let start = ContinuousClock.now
        var now = start
        let desktop = BehaviorDesktop()
        let id = WindowID(rawValue: "editor-a")
        var observation = desktop.values.value
        let runtime = AppRuntime(tracker: BehaviorInventory(desktop), actionExecutor: FeedbackSucceededMinimize(),
                                 isAppFrontmost: { _ in true }, monotonicNow: { now })
        runtime.start()
        defer { runtime.stop() }
        await flushSnapshots()
        XCTAssertEqual(runtime.snapshot.windows[id]?.status, .active)

        runtime.toggle(windowID: id.rawValue)
        for task in runtime.pendingActionsForTesting { await task.value }
        XCTAssertNotNil(runtime.pendingMinimizations[id.rawValue])
        XCTAssertEqual(runtime.feedbackTestProbe.feedbackEntriesByWindowID[id.rawValue]?.phase, .pending)

        now = start + .seconds(4)
        observation.windows[id]?.title = "At the deadline"
        desktop.values.send(observation)
        await flushSnapshots()
        XCTAssertNotNil(runtime.pendingMinimizations[id.rawValue])
        XCTAssertEqual(runtime.feedbackTestProbe.feedbackEntriesByWindowID[id.rawValue]?.phase, .pending)

        now = now + .nanoseconds(1)
        observation.windows[id]?.title = "Past the deadline"
        desktop.values.send(observation)
        await flushSnapshots()
        XCTAssertNil(runtime.pendingMinimizations[id.rawValue])
        XCTAssertEqual(runtime.feedbackTestProbe.feedbackEntriesByWindowID[id.rawValue]?.phase, .failure)
    }

    private func flushSnapshots() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private struct FeedbackSucceededMinimize: WindowActionExecuting {
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot, forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation, onHandoffTarget: (@Sendable (WindowID) -> Void)?) -> Bool {
        request.kind == .minimizeWindow && !cancellation.isCancelled
    }
}
