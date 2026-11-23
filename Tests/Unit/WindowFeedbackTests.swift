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

final class FeedbackTickPolicyTests: XCTestCase {
    func testTickRequiresARunningRuntimeWithPendingWork() {
        let cases: [(running: Bool, feedback: Bool, optimistic: Bool, ticks: Bool)] = [
            (true, false, false, false),
            (true, true, false, true),
            (true, false, true, true),
            (true, true, true, true),
            (false, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, true, true, false),
        ]
        for (running, feedback, optimistic, ticks) in cases {
            XCTAssertEqual(
                FeedbackTickPolicy.shouldTick(
                    isRunning: running,
                    hasFeedbackEntries: feedback,
                    hasOptimisticStates: optimistic
                ),
                ticks,
                "Running: \(running), feedback: \(feedback), optimistic: \(optimistic)"
            )
        }
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
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .inactive), now: start.addingTimeInterval(4.5))

        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)
    }

    func testFailureIsUpgradedToSuccessWhenSnapshotLaterConfirms() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.markFailed(windowID: windowID, action: .minimize, at: start.addingTimeInterval(0.05))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.4))
        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.phase,
            .success,
            "A later snapshot can confirm an AX action after an immediate read reported failure"
        )
    }

    func testSuccessIsNotRestampedWhileWindowStaysInTargetState() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.2))
        let firstSuccessAt = state.entriesByWindowID[windowID]?.updatedAt
        XCTAssertNotNil(firstSuccessAt)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.7))

        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.updatedAt,
            firstSuccessAt,
            "Repeated reconciliation in the same phase must preserve the retention deadline"
        )
    }

    func testTerminalEntryIsDroppedAfterRetentionSoTheTimerCanStop() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.5))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)

        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(2.2))
        XCTAssertTrue(
            state.entriesByWindowID.isEmpty,
            "The on-demand timer can stop after terminal entries expire"
        )
    }
}
