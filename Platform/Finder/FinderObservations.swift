import AppKit
import ApplicationServices

final class FinderSource {
    private let reader = AXWindowReader()
    private var history = AXObservationHistory()

    func observe(cgObservations: [SystemObservation]) -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier)
        }

        return history.observe(apps, reader: reader) { window, app in
            FinderWindowRules.isTrackableForObservation(window, applicationName: app.localizedName,
                                                        cgObservations: cgObservations)
        }
    }
}
