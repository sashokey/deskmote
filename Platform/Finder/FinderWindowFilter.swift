import ApplicationServices
import CoreGraphics

enum FinderWindowRules {
    static let bundleIdentifier = "com.apple.finder"

    static func isFinder(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }

    static func isTrackable(
        title: String?,
        role: String?,
        subrole: String?,
        bounds: CGRect?,
        isMinimized: Bool,
        applicationName: String? = nil
    ) -> Bool {
        guard AXTaskbarWindowRules.isMainWindow(
            role: role,
            subrole: subrole,
            bounds: bounds
        ) || isMinimizedMainWindow(role: role, subrole: subrole, isMinimized: isMinimized) else {
            return false
        }

        guard let bounds, bounds.width >= 40, bounds.height >= 40 else {
            return false
        }

        guard let normalized = canonicalWindowTitle(title),
              normalized != "finder",
              normalized != canonicalWindowTitle(applicationName) else {
            return false
        }

        return true
    }

    private static func isMinimizedMainWindow(role: String?, subrole: String?, isMinimized: Bool) -> Bool {
        isMinimized
            && role == (kAXWindowRole as String)
            && subrole == (kAXDialogSubrole as String)
    }

    static func canonicalWindowTitle(_ title: String?) -> String? {
        normalizedWindowTitle(title)
    }
}
