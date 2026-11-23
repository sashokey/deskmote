import Foundation

enum ScanAdmissionDecision {

    struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let startTimeSec: Int64?
        let startTimeUsec: Int32?
        let bundleID: String?

        init(pid: pid_t, startTimeSec: Int64?, startTimeUsec: Int32?, bundleID: String?) {
            self.pid = pid
            self.startTimeSec = startTimeSec
            self.startTimeUsec = startTimeUsec
            self.bundleID = bundleID
        }

        static func matches(probed: Self, current: Self) -> Bool {
            guard probed.pid == current.pid, probed.bundleID == current.bundleID else { return false }
            guard let probedSec = probed.startTimeSec, let currentSec = current.startTimeSec,
                  let probedUsec = probed.startTimeUsec, let currentUsec = current.startTimeUsec
            else { return false }
            return probedSec == currentSec && probedUsec == currentUsec
        }
    }

    struct Prepared<Window> {
        let eligible: [Window]
        let rawCount: Int
        let readFailed: Bool
    }

    enum Verdict: Equatable {
        case admit
        case skipUnsupportedApplication
        case skipTerminated
        case skipAlreadyTracked
        case skipIdentityMismatch
        case skipUnread
        case skipNoEligible
    }

    static func prepare<Window>(
        rawWindows: [Window]?,
        isEligible: (Window) -> Bool
    ) -> Prepared<Window> {
        guard let rawWindows else {
            return Prepared(eligible: [], rawCount: 0, readFailed: true)
        }
        return Prepared(
            eligible: rawWindows.filter(isEligible),
            rawCount: rawWindows.count,
            readFailed: false
        )
    }

    static func decisionFromEvidence<Window>(
        _ prepared: Prepared<Window>,
        probedIdentity: ProcessIdentity,
        currentIdentity: ProcessIdentity,
        isWindowApplication: Bool,
        isTerminated: Bool,
        alreadyTracked: Bool
    ) -> Verdict {
        if !isWindowApplication { return .skipUnsupportedApplication }
        if isTerminated { return .skipTerminated }
        if alreadyTracked { return .skipAlreadyTracked }
        if !ProcessIdentity.matches(probed: probedIdentity, current: currentIdentity) {
            return .skipIdentityMismatch
        }
        if prepared.readFailed { return .skipUnread }
        if prepared.eligible.isEmpty { return .skipNoEligible }
        return .admit
    }
}
