import CoreGraphics
import Foundation

enum PeriodicReconcileSkipDecision {
    static let defaultMaxSkipInterval: TimeInterval = 30

    struct Input {
        var captureFailed: Bool
        var currentCGIDs: Set<CGWindowID>
        var lastObservedCGIDs: Set<CGWindowID>?
        var dirtySinceLastRead: Bool
        var hasPendingAbsenceCheck: Bool
        var hasUnresolvedPhantomSeat: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        var hasActiveWindowObserver: Bool
        var allSeatsSubscribed: Bool
        var uptimeSinceLastFullRead: TimeInterval
        var maxSkipInterval: TimeInterval = PeriodicReconcileSkipDecision.defaultMaxSkipInterval
        var seatOnScreenChanged: Bool = false
    }

    enum Reason: String, Equatable {
        case captureFailed
        case neverRead
        case refreshDue
        case observerInactive
        case subscriptionIncomplete
        case lastReadUnread
        case dirtyEvents
        case cgSetChanged
        case absenceClockRunning
        case phantomCandidate
        case lastRoundChanged
        case seatOnScreenChanged
    }

    enum Verdict: Equatable {
        case fullRead(Reason)
        case skip
    }

    static func decisionFromEvidence(_ input: Input) -> Verdict {
        fullReadReason(input).map(Verdict.fullRead) ?? .skip
    }

    private static func fullReadReason(_ input: Input) -> Reason? {
        if input.captureFailed { return .captureFailed }
        guard let lastObservedCGIDs = input.lastObservedCGIDs else { return .neverRead }
        if input.uptimeSinceLastFullRead >= input.maxSkipInterval { return .refreshDue }
        if !input.hasActiveWindowObserver { return .observerInactive }
        if !input.allSeatsSubscribed { return .subscriptionIncomplete }
        if input.lastReadWasUnread { return .lastReadUnread }
        if input.dirtySinceLastRead { return .dirtyEvents }
        if input.currentCGIDs != lastObservedCGIDs { return .cgSetChanged }
        if input.seatOnScreenChanged { return .seatOnScreenChanged }
        if input.hasPendingAbsenceCheck { return .absenceClockRunning }
        if input.hasUnresolvedPhantomSeat { return .phantomCandidate }
        if input.lastRoundChanged { return .lastRoundChanged }
        return nil
    }
}
