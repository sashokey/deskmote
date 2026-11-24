import CoreGraphics
import Foundation

enum ScanProbeGateDecision {
    static let defaultFullScanInterval: TimeInterval = 60

    struct Memo: Equatable {
        var identity: ScanAdmissionDecision.ProcessIdentity
        var lastCGIDs: Set<CGWindowID>
        var lastCGParents: [CGWindowID: CGWindowID] = [:]
        var verdictWasNoEligible: Bool
    }

    struct Input {
        var captureFailed: Bool
        var cgWindowIDs: Set<CGWindowID>
        var cgParents: [CGWindowID: CGWindowID] = [:]
        var memo: Memo?
        var currentIdentity: ScanAdmissionDecision.ProcessIdentity
        var workspaceDirty: Bool
        var slowFullScanDue: Bool
    }

    enum Reason: String, Equatable {
        case captureFailed
        case fullScanDue
        case workspaceDirty
        case noMemo
        case identityChanged
        case cgSetChanged
        case cgParentsChanged
        case memoNotConclusive
    }

    enum Verdict: Equatable {
        case probe(Reason)
        case skipNoCGWindows
        case skipMemoized
    }

    static func decisionFromEvidence(_ input: Input) -> Verdict {
        if input.captureFailed { return .probe(.captureFailed) }
        if input.slowFullScanDue { return .probe(.fullScanDue) }
        if input.workspaceDirty { return .probe(.workspaceDirty) }
        if input.cgWindowIDs.isEmpty { return .skipNoCGWindows }
        return switch input.memo {
        case nil:
            .probe(.noMemo)
        case let memo? where !ScanAdmissionDecision.ProcessIdentity.matches(
            probed: memo.identity,
            current: input.currentIdentity
        ):
            .probe(.identityChanged)
        case let memo? where memo.lastCGIDs != input.cgWindowIDs:
            .probe(.cgSetChanged)
        case let memo? where memo.lastCGParents != input.cgParents:
            .probe(.cgParentsChanged)
        case let memo? where !memo.verdictWasNoEligible:
            .probe(.memoNotConclusive)
        case .some:
            .skipMemoized
        }
    }

    static func parents(for windowIDs: Set<CGWindowID>, in parents: [CGWindowID: CGWindowID]) -> [CGWindowID: CGWindowID] {
        windowIDs.reduce(into: [:]) { evidence, id in evidence[id] = parents[id] }
    }
}
