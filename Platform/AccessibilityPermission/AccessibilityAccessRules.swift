import Foundation


enum AppInstallLocation: String, Equatable {
    case applications
    case readOnlyVolume
    case appTranslocation
    case other

    init(bundleURL: URL, isReadOnlyVolume: (URL) -> Bool?) {
        let url = bundleURL.standardizedFileURL
        let path = url.path
        let readOnly = isReadOnlyVolume(url)

        let tail = Array(url.pathComponents.suffix(4))
        let systemTemporaryPath = path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
        if readOnly != false, systemTemporaryPath, tail.count == 4,
           tail[0] == "AppTranslocation", tail[2] == "d", url.pathExtension == "app" {
            self = .appTranslocation
        } else if readOnly == true {
            self = .readOnlyVolume
        } else if Self.isUnderApplications(path) {
            self = .applications
        } else {
            self = .other
        }
    }

    private static func isUnderApplications(_ path: String) -> Bool {
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    var allowsAccessibilityPrompt: Bool { !isTransient }

    var isTransient: Bool {
        switch self {
        case .readOnlyVolume, .appTranslocation:
            return true
        case .applications, .other:
            return false
        }
    }
}


enum PermissionOnboardingState: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case granted

    static func initial(installLocation: AppInstallLocation, isTrusted: Bool) -> Self {
        guard installLocation.allowsAccessibilityPrompt else {
            return .moveToApplications(installLocation)
        }
        return isTrusted ? .granted : .waiting
    }

    func updated(isTrusted: Bool, elapsed: TimeInterval, stallAfter: TimeInterval) -> Self {
        if case .moveToApplications = self { return self }
        if isTrusted { return .granted }
        return elapsed >= stallAfter ? .stalled : .waiting
    }
}


enum AccessibilitySettingsLink {
    static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
