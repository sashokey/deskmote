import CoreGraphics
import Foundation

struct AXWindowMatchPolicy {
    struct Candidate: Equatable {
        let title: String?
        let bounds: CGRect?
        var cgWindowID: UInt32? = nil
    }

    static func unambiguousCandidateIndex(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidates: [Candidate],
        expectedCGWindowID: UInt32? = nil
    ) -> Int? {
        if let windowNumber = expectedCGWindowID {
            guard windowNumber != 0 else { return nil }
            return bestIndex(in: candidates) { candidate in
                candidate.cgWindowID == windowNumber ? 0 : nil
            }
        }

        let target = MatchCriteria(title: targetTitle, bounds: targetBounds)
        return bestIndex(in: candidates, score: target.score)
    }

    static func matchingPenalty(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidateTitle: String?,
        candidateBounds: CGRect?
    ) -> Int? {
        MatchCriteria(title: targetTitle, bounds: targetBounds)
            .score(Candidate(title: candidateTitle, bounds: candidateBounds))
    }

    private static func bestIndex(in candidates: [Candidate], score: (Candidate) -> Int?) -> Int? {
        var lowestScore: Int?
        var winner: Int?
        for (index, candidate) in candidates.enumerated() {
            guard let candidateScore = score(candidate) else { continue }
            if let lowestScore, candidateScore >= lowestScore {
                if candidateScore == lowestScore { winner = nil }
                continue
            }
            lowestScore = candidateScore
            winner = index
        }
        return winner
    }

    private struct MatchCriteria {
        let canonicalWindowTitle: String?
        let bounds: CGRect?

        init(title: String?, bounds: CGRect?) {
            canonicalWindowTitle = title.map(Self.normalize)
            self.bounds = bounds
        }

        func score(_ candidate: Candidate) -> Int? {
            guard let titlePenalty = titlePenalty(for: candidate.title) else { return nil }
            guard let bounds else { return titlePenalty }
            guard let candidateBounds = candidate.bounds,
                  WindowFrameMatchPolicy.areClose(bounds, candidateBounds) else { return nil }
            return titlePenalty + WindowFrameMatchPolicy.score(bounds, candidateBounds)
        }

        private func titlePenalty(for candidate: String?) -> Int? {
            guard let canonicalWindowTitle else { return 0 }
            guard let candidate else { return nil }
            let title = Self.normalize(candidate)
            if title == canonicalWindowTitle { return 0 }
            if title.contains(canonicalWindowTitle) || canonicalWindowTitle.contains(title) { return 25 }
            return nil
        }

        private static func normalize(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
