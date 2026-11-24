import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct DockWindowEligibilityPolicy {
    static let selfBundleIdentifier = ApplicationIdentity.properWMIdentifier
    static let systemSurfaceBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter"
    ]

    enum Decision: Equatable {
        case keep
        case filter
    }

    enum Verdict: String, Equatable, CaseIterable {
        case eligible, selfApp, transparent, invalidGeometry
        case systemSurfaceBundle, systemSurfaceAppName, systemSurfaceExtension
        case systemSurfaceExecutable
        case prohibitedPolicy, accessoryWithoutTitleOrTooSmall, emptyTitleNotStandardOrTooSmall
        case belowNormalLayer, finderNotTrackable, notMainWindow
    }

    struct Candidate {
        let bundleIdentifier: String?
        let appName: String
        let title: String?
        let subrole: String?
        let bounds: CGRect?
        let alpha: Double?
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
        var allowsUntitledWindow = false
    }

    func evaluate(_ candidate: Candidate) -> Decision {
        decisionFromEvidence(candidate) == .eligible ? .keep : .filter
    }

    func decisionFromEvidence(_ candidate: Candidate) -> Verdict {
        let verdict = classify(candidate)
        if verdict == .eligible, let bounds = candidate.bounds, !WindowFrameMatchPolicy.isValid(bounds) { return .invalidGeometry }
        return verdict
    }

    private func classify(_ candidate: Candidate) -> Verdict {
        if ApplicationIdentity.isDeskMote(candidate.bundleIdentifier) {
            return .selfApp
        }

        if candidate.alpha == 0 {
            return .transparent
        }

        if let rejection = systemSurfaceVerdict(candidate) { return rejection }

        switch candidate.activationPolicy {
        case .prohibited:
            return .prohibitedPolicy
        case .accessory:
            guard hasTitle(candidate.title) || candidate.allowsUntitledWindow,
                  hasMinimumFrame(candidate.bounds) else {
                return .accessoryWithoutTitleOrTooSmall
            }
            return .eligible
        case .regular:
            if hasTitle(candidate.title) {
                return .eligible
            }
            guard candidate.subrole == (kAXStandardWindowSubrole as String) || candidate.allowsUntitledWindow,
                  hasMinimumFrame(candidate.bounds) else {
                return .emptyTitleNotStandardOrTooSmall
            }
            return .eligible
        @unknown default:
            return hasTitle(candidate.title) ? .eligible : .emptyTitleNotStandardOrTooSmall
        }
    }

    private func systemSurfaceVerdict(_ candidate: Candidate) -> Verdict? {
        if let bundleIdentifier = candidate.bundleIdentifier,
           Self.systemSurfaceBundleIdentifiers.contains(bundleIdentifier) {
            return .systemSurfaceBundle
        }

        if filteredAppNames.contains(candidate.appName) {
            return .systemSurfaceAppName
        }

        if let executablePath = candidate.executablePath {
            if executablePath.contains(".appex/") {
                return .systemSurfaceExtension
            }

            if filteredExecutablePathFragments.contains(where: { executablePath.contains($0) }) {
                return .systemSurfaceExecutable
            }
        }

        return nil
    }

    private func hasTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasMinimumFrame(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.width >= 80 && bounds.height >= 40
    }

    private let filteredAppNames: Set<String> = [
        "Notification Center",
        "Control Center"
    ]

    private let filteredExecutablePathFragments: [String] = [
        "ThemeWidgetControlViewService.xpc",
        "ChronoCore.framework/Support/chronod",
        "DockHelper.xpc",
        "com.apple.dock.extra.xpc",
        "ControlCenterHelper.xpc"
    ]
}

struct AppTrackerWindowEligibility {
    struct Application: Sendable {
        let bundleIdentifier: String?
        let appName: String
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
        let bundleURL: URL?

        init(bundleIdentifier: String?, appName: String, activationPolicy: NSApplication.ActivationPolicy,
             executablePath: String?, bundleURL: URL? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.appName = appName
            self.activationPolicy = activationPolicy
            self.executablePath = executablePath
            self.bundleURL = bundleURL
        }

        var isEmbeddedHelper: Bool {
            guard let bundleURL = canonicalAccessoryBundleURL else { return false }
            return isEmbeddedHelper(bundleURL: bundleURL)
        }

        private var canonicalAccessoryBundleURL: URL? {
            guard activationPolicy == .accessory, !ApplicationIdentity.isDeskMote(bundleIdentifier),
                  let origin = ApplicationOrigin(bundleURL: bundleURL) else { return nil }
            let canonicalURL = URL(fileURLWithPath: origin.bundlePath)
            return canonicalURL.pathExtension.lowercased() == "app" ? canonicalURL : nil
        }

        private func isEmbeddedHelper(bundleURL: URL) -> Bool {
            let components = bundleURL.deletingLastPathComponent().pathComponents
            return components.indices.contains { index in
                guard components[index] == "Contents", index > 0 else { return false }
                let enclosingPath = NSString.path(withComponents: Array(components[..<index]))
                let enclosingBundle = Bundle(url: URL(fileURLWithPath: enclosingPath, isDirectory: true))
                if let packageType = enclosingBundle?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String {
                    return packageType == "APPL"
                }
                if let bundle = enclosingBundle, bundle.bundleIdentifier != nil, let executable = bundle.executableURL,
                   FileManager.default.fileExists(atPath: executable.path) { return true }
                let resemblesBundle = components[index - 1].lowercased().hasSuffix(".app") ||
                    components[..<index].contains { $0.lowercased().hasSuffix(".appbundle") }
                return resemblesBundle && !FileManager.default.fileExists(atPath: enclosingPath)
            }
        }

        var canOwnTaskbarWindows: Bool {
            guard !ApplicationIdentity.isDeskMote(bundleIdentifier) else { return false }
            switch activationPolicy {
            case .regular: return true
            case .accessory:
                guard let bundleURL = canonicalAccessoryBundleURL else { return false }
                return !isEmbeddedHelper(bundleURL: bundleURL)
            case .prohibited: return false
            @unknown default: return false
            }
        }
    }

    private let policy = DockWindowEligibilityPolicy()

    func isEligible(
        title: String?,
        role: String?,
        subrole: String?,
        bounds: CGRect?,
        alpha: Double?,
        isMinimized: Bool,
        isBelowNormalLayer: Bool,
        application: Application, isModal: Bool? = nil, isTopLevel: Bool? = nil,
        isNativeRoot: Bool = false, isFocusedWindow: Bool = false, isKnownWindow: Bool = false,
        retainsUntitledAccessoryWindow: Bool = false
    ) -> Bool {
        decisionFromEvidence(title: title, role: role, subrole: subrole, bounds: bounds, alpha: alpha,
                isMinimized: isMinimized, isBelowNormalLayer: isBelowNormalLayer,
                application: application, isModal: isModal, isTopLevel: isTopLevel,
                isNativeRoot: isNativeRoot, isFocusedWindow: isFocusedWindow, isKnownWindow: isKnownWindow,
                retainsUntitledAccessoryWindow: retainsUntitledAccessoryWindow) == .eligible
    }

    func decisionFromEvidence(
        title: String?, role: String?, subrole: String?, bounds: CGRect?, alpha: Double?,
        isMinimized: Bool, isBelowNormalLayer: Bool, application: Application,
        isModal: Bool? = nil, isTopLevel: Bool? = nil,
        isNativeRoot: Bool = false, isFocusedWindow: Bool = false, isKnownWindow: Bool = false,
        retainsUntitledAccessoryWindow: Bool = false
    ) -> DockWindowEligibilityPolicy.Verdict {
        guard !isBelowNormalLayer else { return .belowNormalLayer }
        let customWindow = AXTaskbarWindowRules.isCustomWindowRoot(role: role, subrole: subrole, bounds: bounds,
            title: title, isModal: isModal, isTopLevel: isTopLevel,
            isNativeRoot: isNativeRoot, isFocusedWindow: isFocusedWindow, isKnownWindow: isKnownWindow)
        let candidate = DockWindowEligibilityPolicy.Candidate(
            bundleIdentifier: application.bundleIdentifier,
            appName: application.appName,
            title: title,
            subrole: subrole,
            bounds: bounds,
            alpha: alpha,
            activationPolicy: application.activationPolicy,
            executablePath: application.executablePath,
            allowsUntitledWindow: customWindow || (application.activationPolicy == .accessory && retainsUntitledAccessoryWindow)
        )
        let verdict = policy.decisionFromEvidence(candidate)
        guard verdict == .eligible else { return verdict }

        let matchesCommonWindowRules = customWindow || AXTaskbarWindowRules.isMainWindow(role: role, subrole: subrole,
            bounds: bounds, isModal: isModal, isTopLevel: isTopLevel)
        if FinderWindowRules.isFinder(bundleIdentifier: application.bundleIdentifier) {
            return FinderWindowRules.isTrackable(
                title: title,
                role: role,
                subrole: subrole,
                bounds: bounds,
                applicationName: application.appName,
                isModal: isModal,
                isTopLevel: isTopLevel,
                isNativeRoot: isNativeRoot,
                matchesCommonWindowRules: matchesCommonWindowRules
            ) ? .eligible : .finderNotTrackable
        }

        return matchesCommonWindowRules ? .eligible : .notMainWindow
    }
}

enum AXTaskbarWindowRules {
    static func isCustomWindowRoot(role: String?, subrole: String?, bounds: CGRect?, title: String?,
                                   isModal: Bool?, isTopLevel: Bool?, isNativeRoot: Bool,
                                   isFocusedWindow: Bool, isKnownWindow: Bool) -> Bool {
        role == kAXWindowRole as String && subrole == kAXUnknownSubrole as String
            && isModal == false && isTopLevel == true && isNativeRoot && hasReasonableFrame(bounds)
            && (isKnownWindow || isFocusedWindow || title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    enum Decision: Equatable {
        case mainWindow
        case unconfirmedMainWindow
        case rejected

        var isAccepted: Bool {
            self != .rejected
        }
    }

    static func decision(role: String?, subrole: String?, bounds: CGRect?,
                         isModal: Bool? = nil, isTopLevel: Bool? = nil) -> Decision {
        guard role == (kAXWindowRole as String) else { return .rejected }

        if subrole == (kAXStandardWindowSubrole as String) {
            return .mainWindow
        }

        if subrole == kAXDialogSubrole as String, isModal == false, isTopLevel == true, hasReasonableFrame(bounds) {
            return .mainWindow
        }

        guard subrole == nil, hasReasonableFrame(bounds) else {
            return .rejected
        }

        return .unconfirmedMainWindow
    }

    static func isMainWindow(role: String?, subrole: String?, bounds: CGRect?,
                             isModal: Bool? = nil, isTopLevel: Bool? = nil) -> Bool {
        decision(role: role, subrole: subrole, bounds: bounds, isModal: isModal, isTopLevel: isTopLevel).isAccepted
    }

    private static func hasReasonableFrame(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.width >= 80 && bounds.height >= 40
    }
}
