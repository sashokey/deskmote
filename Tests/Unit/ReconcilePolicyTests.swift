import CoreGraphics
import XCTest

final class PeriodicReconcileSkipDecisionTests: XCTestCase {
    private typealias Decision = PeriodicReconcileSkipDecision

    private let quietInput = Decision.Input(
        captureFailed: false,
        currentCGIDs: [77, 78],
        lastObservedCGIDs: [77, 78],
        dirtySinceLastRead: false,
        hasPendingAbsenceCheck: false,
        hasUnresolvedPhantomSeat: false,
        lastReadWasUnread: false,
        lastRoundChanged: false,
        hasActiveWindowObserver: true,
        allSeatsSubscribed: true,
        uptimeSinceLastFullRead: 5
    )

    func testAllQuietSkips() {
        XCTAssertEqual(Decision.decisionFromEvidence(quietInput), .skip)
    }

    func testFullReadGatesAndTheirPriority() {
        let gates: [(reason: Decision.Reason, change: (inout Decision.Input) -> Void)] = [
            (.captureFailed, { $0.captureFailed = true }),
            (.neverRead, { $0.lastObservedCGIDs = nil }),
            (.refreshDue, { $0.uptimeSinceLastFullRead = $0.maxSkipInterval }),
            (.observerInactive, { $0.hasActiveWindowObserver = false }),
            (.subscriptionIncomplete, { $0.allSeatsSubscribed = false }),
            (.lastReadUnread, { $0.lastReadWasUnread = true }),
            (.dirtyEvents, { $0.dirtySinceLastRead = true }),
            (.cgSetChanged, { $0.currentCGIDs = [77] }),
            (.seatOnScreenChanged, { $0.seatOnScreenChanged = true }),
            (.absenceClockRunning, { $0.hasPendingAbsenceCheck = true }),
            (.phantomCandidate, { $0.hasUnresolvedPhantomSeat = true }),
            (.lastRoundChanged, { $0.lastRoundChanged = true }),
        ]

        for gate in gates {
            var input = quietInput
            gate.change(&input)
            XCTAssertEqual(Decision.decisionFromEvidence(input), .fullRead(gate.reason))
        }

        for (first, next) in zip(gates, gates.dropFirst()) {
            var input = quietInput
            first.change(&input)
            next.change(&input)
            XCTAssertEqual(Decision.decisionFromEvidence(input), .fullRead(first.reason), "Before \(next.reason)")
        }
    }

    func testDoesNotRefreshJustBeforeTheInterval() {
        var input = quietInput
        input.uptimeSinceLastFullRead = input.maxSkipInterval - 0.001
        XCTAssertEqual(Decision.decisionFromEvidence(input), .skip)
    }

    func testAddedCGWindowForcesFullRead() {
        var input = quietInput
        input.currentCGIDs.insert(79)
        XCTAssertEqual(Decision.decisionFromEvidence(input), .fullRead(.cgSetChanged))
    }
}
