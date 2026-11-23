import CoreGraphics
import Foundation

private enum NativeTabOwner {
    case none
    case unique(CGWindowID)
    case ambiguous

    static func resolve<Seat>(_ seats: [Seat], matching predicate: (Seat) -> Bool,
                              id: (Seat) -> CGWindowID) -> Self {
        var owner = Self.none
        for seat in seats where predicate(seat) {
            if case .none = owner {
                owner = .unique(id(seat))
            } else {
                owner = .ambiguous
            }
        }
        return owner
    }
}

enum TabFoldDecision {
    enum Verdict: Equatable {
        case fold(ownerActiveCgID: CGWindowID?, reason: Reason)
        case newSeat
    }

    enum Reason: String {
        case membership
    }

    static func decisionFromEvidence(candidateCgID: CGWindowID, candidateIsMinimized: Bool, placedSeats: [PlacedSeat]) -> Verdict {
        guard candidateIsMinimized else { return .newSeat }
        let owner = NativeTabOwner.resolve(placedSeats, matching: { $0.priorTabWindowNumbers.contains(candidateCgID) },
                                           id: \.seatActiveWindowNumber)
        switch owner {
        case .none: return .newSeat
        case let .unique(id): return .fold(ownerActiveCgID: id, reason: .membership)
        case .ambiguous: return .fold(ownerActiveCgID: nil, reason: .membership)
        }
    }

    struct PlacedSeat {
        let seatActiveWindowNumber: CGWindowID
        let priorTabWindowNumbers: Set<CGWindowID>
    }
}

enum TabMergeDecision {
    static func decisionFromEvidence(
        candidateIsConfirmedDormant: Bool,
        candidateIsOnScreen: Bool,
        candidateCGBounds: CGRect?,
        candidateSeatBounds: CGRect?,
        axPresentSeats: [AXPresentSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        guard candidateIsConfirmedDormant, !candidateIsOnScreen,
              let key = frameKey(candidateCGBounds ?? candidateSeatBounds) else { return .retain }

        let owner = NativeTabOwner.resolve(axPresentSeats, matching: { seat in
            !seat.isMinimized && frameKey(seat.bounds) == key
        }, id: \.seatActiveWindowNumber)
        switch owner {
        case .none: return .retain
        case let .unique(id): return .release(ownerActiveCgID: id)
        case .ambiguous: return .release(ownerActiveCgID: nil)
        }
    }

    enum Verdict: Equatable {
        case release(ownerActiveCgID: CGWindowID?)
        case retain
    }

    struct AXPresentSeat {
        let seatActiveWindowNumber: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
    }
}

enum PhantomSeatDecision {
    enum HoldReason: String, Hashable {
        case everSeenVisible
        case absenceGraceNotElapsed
        case cgMissing
        case noEligibleWindows
        case noAXPresentSibling
        case dormantWindowUnconfirmed
        case noCoframedAXSibling
    }

    struct Evaluation: Equatable {
        let permitsSeatRelease: Bool
        #if DEBUG
        let retentionReasons: Set<HoldReason>
        #endif
    }

    static func evaluate(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int,
        confirmedDormantWindow: Bool,
        hasCoframedAXSibling: Bool
    ) -> Evaluation {
        var permitsSeatRelease = true
        #if DEBUG
        var reasons: Set<HoldReason> = []
        #endif
        func hold(_ reason: HoldReason) {
            permitsSeatRelease = false
            #if DEBUG
            reasons.insert(reason)
            #endif
        }
        if everSeenVisible { hold(.everSeenVisible) }
        if axAbsentFor < threshold { hold(.absenceGraceNotElapsed) }
        if !cgStillPresent { hold(.cgMissing) }
        if !axReadSawWindows { hold(.noEligibleWindows) }
        if axPresentSiblingCount < 1 { hold(.noAXPresentSibling) }
        if !confirmedDormantWindow { hold(.dormantWindowUnconfirmed) }
        if !hasCoframedAXSibling { hold(.noCoframedAXSibling) }
        #if DEBUG
        return Evaluation(permitsSeatRelease: permitsSeatRelease, retentionReasons: reasons)
        #else
        return Evaluation(permitsSeatRelease: permitsSeatRelease)
        #endif
    }

    static func permitsSeatRelease(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int,
        confirmedDormantWindow: Bool,
        hasCoframedAXSibling: Bool
    ) -> Bool {
        evaluate(
            everSeenVisible: everSeenVisible,
            axAbsentFor: axAbsentFor,
            threshold: threshold,
            cgStillPresent: cgStillPresent,
            axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: axPresentSiblingCount,
            confirmedDormantWindow: confirmedDormantWindow,
            hasCoframedAXSibling: hasCoframedAXSibling
        ).permitsSeatRelease
    }
}

#if DEBUG
extension PhantomSeatDecision.HoldReason: Codable {}
#endif
