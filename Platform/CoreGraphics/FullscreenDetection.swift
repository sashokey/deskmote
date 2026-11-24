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

    static func belongsMostlyToDisplay(_ frame: CGRect, _ screen: CGRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        return overlap.width * overlap.height >= frameArea * 0.5
    }
}

struct FullscreenCGEvidence {
    enum State {
        case fullscreen, windowed, splitOrTiled
    }

    let state: State
    let overlayWindowID: CGWindowID?

    static func classify(_ windows: [[String: Any]], on screen: CGRect, excludingPID: pid_t) -> Self? {
        var foundForegroundWindow = false
        var screenHeightWindows: [CGRect] = []
        for window in windows {
            if (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == excludingPID { continue }
            if let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer < 0 { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            guard let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  !bounds.isNull, !bounds.isInfinite else { return nil }
            let overlap = bounds.intersection(screen)
            guard !overlap.isNull else { continue }
            if !foundForegroundWindow, overlap.width > screen.width * 0.7,
               bounds.width >= 80, bounds.height >= 40,
               FullscreenWindowClassifier.belongsMostlyToDisplay(bounds, screen) {
                foundForegroundWindow = true
                if FullscreenWindowClassifier.matchesScreenFrame(bounds, screen) {
                    let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    return Self(state: .fullscreen, overlayWindowID: id == 0 ? nil : id)
                }
            }
            if overlap.height >= screen.height * 0.9, overlap.width >= screen.width * 0.2,
               abs(overlap.maxY - screen.maxY) < FullscreenWindowClassifier.frameTolerance {
                screenHeightWindows.append(overlap)
            }
        }
        let tolerance = FullscreenWindowClassifier.frameTolerance
        let left = screenHeightWindows.filter { abs($0.minX - screen.minX) < tolerance }
        let right = screenHeightWindows.filter { abs($0.maxX - screen.maxX) < tolerance }
        let split = left.contains { leading in
            right.contains { abs(leading.maxX - $0.minX) < tolerance }
        }
        return Self(state: split ? .splitOrTiled : .windowed, overlayWindowID: nil)
    }
}
