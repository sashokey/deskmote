import CoreGraphics
import XCTest

final class CGSnapshotReuseDecisionTests: XCTestCase {
    private typealias Decision = CGSnapshotReuseDecision

    private func input(
        usesSnapshotCache: Bool = true,
        hasCachedSnapshot: Bool = true,
        didCacheReadFail: Bool = false,
        cachedSnapshotAge: TimeInterval = 0.5,
        isSnapshotGenerationCurrent: Bool = true,
        hasPendingAbsenceCheck: Bool = false,
        hasUnresolvedPhantomSeat: Bool = false,
        hasActiveWindowObserver: Bool = true
    ) -> Decision.Input {
        Decision.Input(
            usesSnapshotCache: usesSnapshotCache,
            hasCachedSnapshot: hasCachedSnapshot,
            didCacheReadFail: didCacheReadFail,
            cachedSnapshotAge: cachedSnapshotAge,
            isSnapshotGenerationCurrent: isSnapshotGenerationCurrent,
            hasPendingAbsenceCheck: hasPendingAbsenceCheck,
            hasUnresolvedPhantomSeat: hasUnresolvedPhantomSeat,
            hasActiveWindowObserver: hasActiveWindowObserver
        )
    }

    func testGatesBeforeProbe() {
        let cases: [(name: String, input: Decision.Input, expected: Decision.PreVerdict)] = [
            ("Reusable", input(), .probeThenCompare),
            ("Reuse disabled", input(usesSnapshotCache: false), .captureWithoutProbe),
            ("No cache", input(hasCachedSnapshot: false), .captureAndPrime(.noCache)),
            ("Failed capture", input(didCacheReadFail: true), .captureAndPrime(.cachedCaptureFailed)),
            ("At expiry", input(cachedSnapshotAge: Decision.maximumSnapshotReuseAge), .captureAndPrime(.cacheExpired)),
            ("Negative age", input(cachedSnapshotAge: -1), .captureAndPrime(.cacheExpired)),
            ("Event generation changed", input(isSnapshotGenerationCurrent: false), .captureAndPrime(.eventSinceCache)),
            ("Absence clock running", input(hasPendingAbsenceCheck: true), .captureAndPrime(.absenceClockRunning)),
            ("Phantom candidate", input(hasUnresolvedPhantomSeat: true), .captureAndPrime(.phantomCandidate)),
            ("Inactive observer", input(hasActiveWindowObserver: false), .captureAndPrime(.observerInactive)),
        ]

        for (name, input, expected) in cases {
            XCTAssertEqual(Decision.decideBeforeProbe(input), expected, name)
        }
    }

    func testProbeComparisonUsesTheWholeIDSet() {
        let cachedProbe: Set<CGWindowID> = [1, 2, 3]
        XCTAssertEqual(Decision.decideAfterProbe(probe: [1, 2, 3], cachedProbe: cachedProbe), .reuse)

        let changedProbes: [Set<CGWindowID>] = [[1, 2], [1, 2, 4]]
        for probe in changedProbes {
            XCTAssertEqual(Decision.decideAfterProbe(probe: probe, cachedProbe: cachedProbe), .captureAndPrime(.probeChanged))
        }
    }

    func testCachedLayerVetoAppliesOnlyWhenAXListsACachedBelowLayerID() {
        let cases: [(belowNormalIDs: Set<CGWindowID>, veto: Bool)] = [
            ([2, 9], true),
            ([9], false),
            ([], false),
        ]
        for (belowNormalIDs, veto) in cases {
            XCTAssertEqual(Decision.cacheHasNonstandardLayer(axWindowIDs: [1, 2], cachedBelowNormalLayerIDs: belowNormalIDs), veto)
        }
    }
}
