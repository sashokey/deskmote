import Foundation

struct IdentityRuleEngine {
    func titleForMatching(_ title: String?, bundleIdentifier: String?) -> String? {
        normalizedWindowTitle(title) ?? (FinderWindowRules.isFinder(bundleIdentifier: bundleIdentifier)
            ? "finder-window" : nil)
    }
}
