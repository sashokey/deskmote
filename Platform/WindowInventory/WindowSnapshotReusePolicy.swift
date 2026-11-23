import CoreGraphics
import Foundation

enum CGSnapshotReuseDecision {
    static let maximumSnapshotReuseAge: TimeInterval = 2.0

    static func decideBeforeProbe(_ input: Input) -> PreVerdict {
        guard input.usesSnapshotCache else { return .captureWithoutProbe }
        return input.rejection.map(PreVerdict.captureAndPrime) ?? .probeThenCompare
    }

    static func decideAfterProbe(probe: Set<CGWindowID>, cachedProbe: Set<CGWindowID>) -> ProbeVerdict {
        probe == cachedProbe ? .reuse : .captureAndPrime(.probeChanged)
    }

    static func cacheHasNonstandardLayer(
        axWindowIDs: Set<CGWindowID>,
        cachedBelowNormalLayerIDs: Set<CGWindowID>
    ) -> Bool {
        !axWindowIDs.isDisjoint(with: cachedBelowNormalLayerIDs)
    }

    static func cachedParentVetoApplies(windowIDs: Set<CGWindowID>,
                                       cachedParentWindowIDs: [CGWindowID: CGWindowID]) -> Bool {
        windowIDs.contains { cachedParentWindowIDs[$0, default: 0] != 0 }
    }

    enum PreVerdict: Equatable {
        case captureWithoutProbe
        case captureAndPrime(FreshReason)
        case probeThenCompare
    }

    enum ProbeVerdict: Equatable {
        case reuse
        case captureAndPrime(FreshReason)
    }

    enum FreshReason: Equatable {
        case disabled
        case noCache, cachedCaptureFailed, cacheExpired
        case eventSinceCache, absenceClockRunning, phantomCandidate, observerInactive
        case probeChanged
    }

    struct Input: Equatable {
        let usesSnapshotCache: Bool
        let hasCachedSnapshot: Bool
        let didCacheReadFail: Bool
        let cachedSnapshotAge: TimeInterval
        let isSnapshotGenerationCurrent: Bool
        let hasPendingAbsenceCheck: Bool
        let hasUnresolvedPhantomSeat: Bool
        let hasActiveWindowObserver: Bool

        fileprivate var rejection: FreshReason? {
            if !hasCachedSnapshot { return .noCache }
            if didCacheReadFail { return .cachedCaptureFailed }
            if cachedSnapshotAge < 0 || cachedSnapshotAge >= CGSnapshotReuseDecision.maximumSnapshotReuseAge { return .cacheExpired }
            if !isSnapshotGenerationCurrent { return .eventSinceCache }
            if hasPendingAbsenceCheck { return .absenceClockRunning }
            if hasUnresolvedPhantomSeat { return .phantomCandidate }
            return hasActiveWindowObserver ? nil : .observerInactive
        }
    }
}
