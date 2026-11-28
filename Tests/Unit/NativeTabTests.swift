import CoreGraphics
import XCTest

final class TabFoldDecisionTests: XCTestCase {
    private func seat(cg: CGWindowID, former: Set<CGWindowID> = []) -> TabFoldDecision.PlacedSeat {
        TabFoldDecision.PlacedSeat(seatActiveWindowNumber: cg, priorTabWindowNumbers: former)
    }

    private func decisionFromEvidence(cg: CGWindowID = 240522, minimized: Bool = true,
                         placed: [TabFoldDecision.PlacedSeat]) -> TabFoldDecision.Verdict {
        TabFoldDecision.decisionFromEvidence(candidateCgID: cg, candidateIsMinimized: minimized, placedSeats: placed)
    }

    func testUnknownMinimizedCandidateCreatesIndependentSeatBesideOneSeat() {
        XCTAssertEqual(decisionFromEvidence(placed: [seat(cg: 249469)]), .newSeat)
    }

    func testUnknownMinimizedCandidateCreatesIndependentSeatBesideMultipleSeats() {
        XCTAssertEqual(decisionFromEvidence(placed: [seat(cg: 249469), seat(cg: 253982)]), .newSeat)
    }

    func testUnknownMinimizedCandidateCreatesSeatWithoutPlacedSeats() {
        XCTAssertEqual(decisionFromEvidence(placed: []), .newSeat)
    }

    func testKnownMinimizedMemberFoldsIntoItsOwner() {
        XCTAssertEqual(decisionFromEvidence(placed: [seat(cg: 249469, former: [240522])]),
                       .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testMembershipSelectsItsOwnerAmongIndependentSeats() {
        XCTAssertEqual(decisionFromEvidence(placed: [seat(cg: 249469), seat(cg: 253982, former: [240522])]),
                       .fold(ownerActiveCgID: 253982, reason: .membership))
    }

    func testNonMinimizedFormerMemberGetsIndependentSeat() {
        XCTAssertEqual(decisionFromEvidence(minimized: false, placed: [seat(cg: 249469, former: [240522])]), .newSeat)
    }

    func testAmbiguousMembershipFoldsWithoutLearning() {
        XCTAssertEqual(decisionFromEvidence(placed: [seat(cg: 249469, former: [240522]), seat(cg: 253982, former: [240522])]),
                       .fold(ownerActiveCgID: nil, reason: .membership))
    }

}

final class PhantomSeatDecisionTests: XCTestCase {

    private func release(
        everSeenVisible: Bool = false,
        axAbsentFor: TimeInterval = 12,
        cgStillPresent: Bool = true,
        axReadSawWindows: Bool = true,
        siblings: Int = 1,
        confirmedDormantWindow: Bool = true,
        hasCoframedAXSibling: Bool = true
    ) -> Bool {
        PhantomSeatDecision.permitsSeatRelease(
            everSeenVisible: everSeenVisible, axAbsentFor: axAbsentFor, threshold: 10,
            cgStillPresent: cgStillPresent, axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: siblings, confirmedDormantWindow: confirmedDormantWindow,
            hasCoframedAXSibling: hasCoframedAXSibling
        )
    }

    func testReleasesWhenAllGatesPass() {
        XCTAssertTrue(release())
    }

    func testEverSeenVisibleProtectsRealWindow() {
        XCTAssertFalse(release(everSeenVisible: true))
    }

    func testUnderThresholdDoesNotRelease() {
        XCTAssertFalse(release(axAbsentFor: 9.9))
    }

    func testHungAppDoesNotRelease() {
        XCTAssertFalse(release(axReadSawWindows: false))
    }

    func testLoneSeatNeverReleases() {
        XCTAssertFalse(release(siblings: 0))
    }

    func testCgGoneIsNotHealingBusiness() {
        XCTAssertFalse(release(cgStillPresent: false))
    }

    func testUnconfirmedDormantWindowCannotHealFromAbsenceAndSiblingAlone() {
        XCTAssertFalse(release(confirmedDormantWindow: false))
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false, axAbsentFor: 12, threshold: 10,
            cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1,
            confirmedDormantWindow: false, hasCoframedAXSibling: true
        )
        XCTAssertFalse(evaluation.permitsSeatRelease)
    }

    func testDormantWindowWithoutCoframedSiblingCannotHeal() {
        XCTAssertFalse(release(hasCoframedAXSibling: false))
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false, axAbsentFor: 12, threshold: 10,
            cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1,
            confirmedDormantWindow: true, hasCoframedAXSibling: false
        )
        XCTAssertFalse(evaluation.permitsSeatRelease)
    }

    func testEvaluationRejectsWhenEveryGateFails() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: true,
            axAbsentFor: 9.9,
            threshold: 10,
            cgStillPresent: false,
            axReadSawWindows: false,
            axPresentSiblingCount: 0, confirmedDormantWindow: false, hasCoframedAXSibling: false
        )

        XCTAssertFalse(evaluation.permitsSeatRelease)
    }

    func testEvaluationExportsEachFailedGate() {
        let cases: [(PhantomSeatDecision.HoldReason, PhantomSeatDecision.Evaluation)] = [
            (.everSeenVisible, PhantomSeatDecision.evaluate(
                everSeenVisible: true, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: true
            )),
            (.absenceGraceNotElapsed, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 9.9, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: true
            )),
            (.cgMissing, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: false, axReadSawWindows: true, axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: true
            )),
            (.noEligibleWindows, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: false, axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: true
            )),
            (.noAXPresentSibling, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 0, confirmedDormantWindow: true, hasCoframedAXSibling: true
            )),
            (.dormantWindowUnconfirmed, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1, confirmedDormantWindow: false, hasCoframedAXSibling: true
            )),
            (.noCoframedAXSibling, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: false
            )),
        ]

        for (_, evaluation) in cases {
            XCTAssertFalse(evaluation.permitsSeatRelease)
        }
    }

    func testEvaluationPermitsReleaseWhenAllGatesPass() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false,
            axAbsentFor: 10,
            threshold: 10,
            cgStillPresent: true,
            axReadSawWindows: true,
            axPresentSiblingCount: 1, confirmedDormantWindow: true, hasCoframedAXSibling: true
        )

        XCTAssertTrue(evaluation.permitsSeatRelease)
    }
}

final class TabMergeDecisionTests: XCTestCase {

    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func sibling(cg: CGWindowID, bounds: CGRect?, min: Bool = false) -> TabMergeDecision.AXPresentSeat {
        TabMergeDecision.AXPresentSeat(seatActiveWindowNumber: cg, bounds: bounds, isMinimized: min)
    }

    private let mergedFrame = CGRect(x: 297, y: 340, width: 1227, height: 504)
    private let oldFrame = CGRect(x: 268, y: 311, width: 1227, height: 504)

    func testMatchingOffscreenFrameWithoutDormantEvidenceRetainsItsSeat() {
        let verdict = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: false,
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(verdict, .retain)
    }

    func testMergedTabReleasesAndLearnsOwner() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testOnScreenCandidateIsNeverReleased() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: true, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testNoCoFramedVisibleSiblingRetains() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: oldFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testMinimizedSiblingDoesNotOwn() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame, min: true)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testAmbiguousOwnersReleaseWithoutLearning() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 1, bounds: mergedFrame), sibling(cg: 2, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: nil))
    }

    func testFallsBackToSeatBoundsWhenCGHasNoRect() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testNoBoundsAtAllRetains() {
        let v = TabMergeDecision.decisionFromEvidence(
            candidateIsConfirmedDormant: true,
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }
}
