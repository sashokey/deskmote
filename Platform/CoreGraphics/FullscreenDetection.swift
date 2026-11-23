import ApplicationServices
import CoreGraphics


enum FullscreenAXVerdict: Equatable, Sendable {
    case unknown
    case fullscreen
    case windowed
    case notOnThisScreen
}

enum FullscreenWindowClassifier {
    static let frameTolerance: CGFloat = 8

    static func classify(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        windowLayer: Int?,
        displayWindowServerFrame: CGRect
    ) -> FullscreenAXVerdict {
        guard role == kAXWindowRole else { return .windowed }

        if isAXFullscreen {
            guard let wf = windowFrame else { return .fullscreen }
            return belongsMostlyToDisplay(wf, displayWindowServerFrame) ? .fullscreen : .notOnThisScreen
        }

        if let wf = windowFrame {
            if matchesScreenFrame(wf, displayWindowServerFrame) {
                if let windowLayer, windowLayer < 0 { return .windowed }
                return .fullscreen
            }
            return belongsMostlyToDisplay(wf, displayWindowServerFrame) ? .windowed : .notOnThisScreen
        }

        return .windowed
    }

    static func matchesScreenFrame(_ frame: CGRect, _ screen: CGRect) -> Bool {
        abs(frame.width - screen.width) < frameTolerance
            && abs(frame.height - screen.height) < frameTolerance
            && abs(frame.minX - screen.minX) < frameTolerance
            && abs(frame.minY - screen.minY) < frameTolerance
    }

    private static func belongsMostlyToDisplay(_ frame: CGRect, _ screen: CGRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        return overlap.width * overlap.height >= frameArea * 0.5
    }
}
