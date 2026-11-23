import CoreGraphics
import XCTest

final class ScanProbeGateDecisionTests: XCTestCase {
    private let identity = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1, startTimeUsec: 2, bundleID: "com.example.fixture"
    )

    private var conclusiveMemo: ScanProbeGateDecision.Memo {
        ScanProbeGateDecision.Memo(identity: identity, lastCGIDs: [77], verdictWasNoEligible: true)
    }

    private var staleIdentity: ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(
            pid: identity.pid, startTimeSec: 9, startTimeUsec: 9, bundleID: identity.bundleID
        )
    }

    private func input(
        captureFailed: Bool = false,
        cgWindowIDs: Set<CGWindowID> = [77],
        memo: ScanProbeGateDecision.Memo?,
        workspaceDirty: Bool = false,
        slowFullScanDue: Bool = false
    ) -> ScanProbeGateDecision.Input {
        ScanProbeGateDecision.Input(
            captureFailed: captureFailed,
            cgWindowIDs: cgWindowIDs,
            memo: memo,
            currentIdentity: identity,
            workspaceDirty: workspaceDirty,
            slowFullScanDue: slowFullScanDue
        )
    }

    func testForcedProbeReasonsOverrideAnEmptyWindowList() {
        let cases: [(input: ScanProbeGateDecision.Input, reason: ScanProbeGateDecision.Reason)] = [
            (input(captureFailed: true, cgWindowIDs: [], memo: conclusiveMemo), .captureFailed),
            (input(cgWindowIDs: [], memo: conclusiveMemo, slowFullScanDue: true), .fullScanDue),
            (input(cgWindowIDs: [], memo: conclusiveMemo, workspaceDirty: true), .workspaceDirty),
        ]
        for (input, reason) in cases {
            XCTAssertEqual(ScanProbeGateDecision.decisionFromEvidence(input), .probe(reason))
        }
    }

    func testForcedProbeReportsTheHighestPriorityReason() {
        var input = input(
            captureFailed: true, cgWindowIDs: [], memo: conclusiveMemo, workspaceDirty: true, slowFullScanDue: true
        )
        XCTAssertEqual(ScanProbeGateDecision.decisionFromEvidence(input), .probe(.captureFailed))
        input.captureFailed = false
        XCTAssertEqual(ScanProbeGateDecision.decisionFromEvidence(input), .probe(.fullScanDue))
    }

    func testNoCGWindowsSkipsWithoutMemo() {
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(cgWindowIDs: [], memo: nil)),
            .skipNoCGWindows
        )
    }

    func testNoMemoProbes() {
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(memo: nil)),
            .probe(.noMemo)
        )
    }

    func testIdentityChangeInvalidatesMemo() {
        var stale = conclusiveMemo
        stale.identity = staleIdentity
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(memo: stale)),
            .probe(.identityChanged)
        )
    }

    func testCGSetChangeInvalidatesMemo() {
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(cgWindowIDs: [77, 78], memo: conclusiveMemo)),
            .probe(.cgSetChanged)
        )
    }

    func testInconclusiveMemoProbes() {
        var memo = conclusiveMemo
        memo.verdictWasNoEligible = false
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(memo: memo)),
            .probe(.memoNotConclusive)
        )
    }

    func testMemoValidationReportsTheHighestPriorityReason() {
        var memo = conclusiveMemo
        memo.identity = staleIdentity
        memo.verdictWasNoEligible = false
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(cgWindowIDs: [78], memo: memo)),
            .probe(.identityChanged)
        )
        memo.identity = identity
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(cgWindowIDs: [78], memo: memo)),
            .probe(.cgSetChanged)
        )
    }

    func testIntactConclusiveMemoSkips() {
        XCTAssertEqual(
            ScanProbeGateDecision.decisionFromEvidence(input(memo: conclusiveMemo)),
            .skipMemoized
        )
    }
}
