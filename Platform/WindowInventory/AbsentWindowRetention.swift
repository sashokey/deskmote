import ApplicationServices
import CoreGraphics
import Foundation

enum AbsentSeatReleaseDecision {
    static let confirmMinInterval: TimeInterval = 2
    static let confirmMaxInterval: TimeInterval = 10
    static let maxProbesPerRead = 4

    static func backoff(afterDispatch probeCount: Int) -> TimeInterval {
        switch probeCount {
        case ...1: return 2
        case 2: return 5
        case 3: return 15
        default: return 60
        }
    }

    enum ElementState: Equatable, Sendable {
        case dead
        case alive(minimized: Bool?)
        case unknown(errorCode: Int32)
    }

    enum SpaceClass: String, Equatable {
        case unknown
        case none
        case onlyCurrent
        case includesNonCurrent

        static func classify(windowSpaceIDs: [Int]?, currentSpaceIDs: Set<Int>?) -> SpaceClass {
            guard let windowSpaceIDs, let currentSpaceIDs else { return .unknown }
            if windowSpaceIDs.isEmpty { return .none }
            return Set(windowSpaceIDs).isSubset(of: currentSpaceIDs) ? .onlyCurrent : .includesNonCurrent
        }
    }

    struct Input {
        var evidenceMatchesSeat: Bool
        var element: ElementState
        var spaces: SpaceClass
        var firstHidden: AbsentSeatProbeState.FirstHiddenMark?
        var cgWindowID: CGWindowID
        var instanceID: UInt64
        var now: TimeInterval
    }

    enum NotHiddenReason: String, Equatable {
        case evidenceMismatch
        case elementAlive
        case elementUnknown
        case spaceUnknown
        case onNonCurrentSpace
    }

    enum Verdict: Equatable {
        case release
        case markFirst
        case holdMark
        case notHidden(NotHiddenReason)
    }

    static func decisionFromEvidence(_ input: Input) -> Verdict {
        guard input.evidenceMatchesSeat else { return .notHidden(.evidenceMismatch) }
        switch input.element {
        case .dead: break
        case .alive: return .notHidden(.elementAlive)
        case .unknown: return .notHidden(.elementUnknown)
        }
        switch input.spaces {
        case .none, .onlyCurrent: break
        case .unknown: return .notHidden(.spaceUnknown)
        case .includesNonCurrent: return .notHidden(.onNonCurrentSpace)
        }
        guard let first = input.firstHidden,
              first.cgWindowID == input.cgWindowID,
              first.instanceID == input.instanceID else { return .markFirst }
        let age = input.now - first.uptime
        if age < confirmMinInterval { return .holdMark }
        if age > confirmMaxInterval { return .markFirst }
        return .release
    }
}

struct AbsentSeatProbeState: Equatable {
    struct TentativeTabReplacement: Equatable {
        let cgWindowID: CGWindowID
        let seatToken: String
        let element: AXElementKey
        let sourceElement: AXElementKey
        let sourceInstanceID: UInt64
        let frameKey: String
        let expiresAt: TimeInterval
    }

    struct FirstHiddenMark: Equatable {
        let uptime: TimeInterval
        let cgWindowID: CGWindowID
        let instanceID: UInt64
    }

    var nextProbeUptime: TimeInterval
    var probeCount: Int = 0
    var firstHidden: FirstHiddenMark?
    var tentativeTabReplacement: TentativeTabReplacement?
}

struct AbsentSeatProbeRequest: Sendable {
    let cgWindowID: CGWindowID
    let seatToken: String
    let element: AXElementKey
    let instanceID: UInt64
    let probeCount: Int
}

struct AbsentSeatProbeEvidence: Sendable {
    let request: AbsentSeatProbeRequest
    let element: AbsentSeatReleaseDecision.ElementState
    let windowSpaceIDs: [Int]?
    let currentSpaceIDs: Set<Int>?

    var spaces: AbsentSeatReleaseDecision.SpaceClass {
        .classify(windowSpaceIDs: windowSpaceIDs, currentSpaceIDs: currentSpaceIDs)
    }
}

protocol AbsentSeatProbing: Sendable {
    func probe(_ request: AbsentSeatProbeRequest, messagingTimeout: TimeInterval) -> AbsentSeatProbeEvidence
}

struct LiveAbsentSeatProber: AbsentSeatProbing {
    func probe(_ request: AbsentSeatProbeRequest, messagingTimeout: TimeInterval) -> AbsentSeatProbeEvidence {
        AXUIElementSetMessagingTimeout(request.element.e, Float(messagingTimeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(request.element.e, kAXMinimizedAttribute as CFString, &value)
        let element: AbsentSeatReleaseDecision.ElementState
        switch error {
        case .success: element = .alive(minimized: value as? Bool)
        case .invalidUIElement: element = .dead
        default: element = .unknown(errorCode: error.rawValue)
        }
        return AbsentSeatProbeEvidence(
            request: request,
            element: element,
            windowSpaceIDs: Self.spaceIDs(of: request.cgWindowID),
            currentSpaceIDs: Self.currentSpaceIDs()
        )
    }

    private static func spaceIDs(of cgWindowID: CGWindowID) -> [Int]? {
        WindowSpaceMembershipReader.spaceIDs(forWindowNumber: Int(cgWindowID))
    }

    private static func currentSpaceIDs() -> Set<Int>? {
        guard let layouts = ManagedSpaceLayoutReader.layouts(), !layouts.isEmpty else { return nil }
        return Set(layouts.values.map(\.currentSpaceID))
    }
}
