import ApplicationServices
import CoreGraphics

enum FinderWindowRules {
    static let bundleIdentifier = "com.apple.finder"

    static func isFinder(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }

    static func isTrackableForObservation(_ window: AXWindowSnapshot, applicationName: String?,
                                          cgObservations: [SystemObservation]) -> Bool {
        let isCorroborated: Bool
        if let id = window.cgWindowID, id != 0, let bounds = window.bounds {
            isCorroborated = cgObservations.contains { observation in
                observation.source == .coreGraphics && observation.kind != .disappeared
                    && observation.pid == window.pid && observation.cgWindowID == id
                    && observation.bounds.map { WindowFrameMatchPolicy.areClose($0, bounds) } == true
            }
        } else {
            isCorroborated = false
        }
        return isTrackable(title: window.title, role: window.role, subrole: window.subrole, bounds: window.bounds,
                           applicationName: applicationName, isModal: window.isModal, isTopLevel: window.isTopLevel,
                           hasCorroboratedGeometry: isCorroborated)
    }

    static func isTrackable(
        title: String?,
        role: String?,
        subrole: String?,
        bounds: CGRect?,
        applicationName: String? = nil,
        isModal: Bool? = nil,
        isTopLevel: Bool? = nil,
        isNativeRoot: Bool = false,
        matchesCommonWindowRules: Bool? = nil,
        hasCorroboratedGeometry: Bool = false
    ) -> Bool {
        guard isModal != true, isTopLevel != false,
              matchesCommonWindowRules ?? AXTaskbarWindowRules.isMainWindow(role: role, subrole: subrole,
                bounds: bounds, isModal: isModal, isTopLevel: isTopLevel),
              let bounds, WindowFrameMatchPolicy.isValid(bounds), bounds.width >= 40, bounds.height >= 40,
              let normalized = normalizedWindowTitle(title) else {
            return false
        }

        if isNativeRoot || hasCorroboratedGeometry, subrole == kAXStandardWindowSubrole as String { return true }
        return normalized != "finder" && normalized != normalizedWindowTitle(applicationName)
    }
}
