import XCTest

final class ScanAdmissionDecisionTests: XCTestCase {

    private struct FakeWindow: Equatable {
        let name: String
        let eligible: Bool
    }

    private func isEligible(_ w: FakeWindow) -> Bool { w.eligible }

    private let identityA = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1_700_000_000, startTimeUsec: 123_456, bundleID: "com.example.app"
    )

    private func decisionFromEvidence(
        _ prepared: ScanAdmissionDecision.Prepared<FakeWindow>,
        probed: ScanAdmissionDecision.ProcessIdentity? = nil,
        current: ScanAdmissionDecision.ProcessIdentity? = nil,
        isWindowApplication: Bool = true,
        isTerminated: Bool = false,
        alreadyTracked: Bool = false
    ) -> ScanAdmissionDecision.Verdict {
        ScanAdmissionDecision.decisionFromEvidence(
            prepared,
            probedIdentity: probed ?? identityA,
            currentIdentity: current ?? identityA,
            isWindowApplication: isWindowApplication,
            isTerminated: isTerminated,
            alreadyTracked: alreadyTracked
        )
    }


    func testRawWindowsPresentButNoneEligibleIsRejected() {
        let raw = [
            FakeWindow(name: "Transparent panel", eligible: false),
            FakeWindow(name: "Extension window", eligible: false),
            FakeWindow(name: "Internal system window", eligible: false)
        ]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertTrue(prepared.eligible.isEmpty)
        XCTAssertFalse(prepared.readFailed)
        XCTAssertEqual(decisionFromEvidence(prepared), .skipNoEligible)
    }

    func testMixedWindowsCarryOnlyEligibleOnes() {
        let keeper = FakeWindow(name: "Eligible window", eligible: true)
        let raw = [FakeWindow(name: "Ineligible window", eligible: false), keeper, FakeWindow(name: "Ineligible window2", eligible: false)]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertEqual(prepared.eligible, [keeper])
        XCTAssertEqual(decisionFromEvidence(prepared), .admit)
    }

    func testUnreadIsDistinctFromEmpty() {
        let unread = ScanAdmissionDecision.prepare(rawWindows: nil, isEligible: isEligible)
        XCTAssertTrue(unread.readFailed)
        XCTAssertEqual(unread.rawCount, 0)
        XCTAssertEqual(decisionFromEvidence(unread), .skipUnread)

        let empty = ScanAdmissionDecision.prepare(rawWindows: [FakeWindow](), isEligible: isEligible)
        XCTAssertFalse(empty.readFailed)
        XCTAssertEqual(decisionFromEvidence(empty), .skipNoEligible)
    }


    private func eligiblePrepared() -> ScanAdmissionDecision.Prepared<FakeWindow> {
        ScanAdmissionDecision.prepare(
            rawWindows: [FakeWindow(name: "Eligible window", eligible: true)],
            isEligible: isEligible
        )
    }

    func testSameIdentityAdmits() {
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: identityA), .admit)
    }

    func testDifferentPIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: 9999, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    func testDifferentBundleIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: "com.example.other"
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    func testDifferentStartTimeIsIdentityMismatch() {
        let laterSec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: 1_700_000_099, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: laterSec), .skipIdentityMismatch)

        let laterUsec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: 999_999,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: laterUsec), .skipIdentityMismatch)
    }

    func testMissingStartTimeOnOneSideIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: identityA, current: missing), .skipIdentityMismatch)
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: missing, current: identityA), .skipIdentityMismatch)
    }

    func testMissingStartTimeOnBothSidesIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), probed: missing, current: missing), .skipIdentityMismatch)
    }


    func testAlreadyTrackedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), alreadyTracked: true), .skipAlreadyTracked)
    }

    func testTerminatedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), isTerminated: true), .skipTerminated)
    }

    func testUnsupportedApplicationIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(decisionFromEvidence(eligiblePrepared(), isWindowApplication: false), .skipUnsupportedApplication)
    }
}
