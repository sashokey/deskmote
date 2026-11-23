import AppKit
import CoreGraphics
import Foundation

struct CoreGraphicsSource {
    struct WindowSnapshot {
        let cgWindowID: UInt32
        let pid: pid_t
        let bundleIdentifier: String?
        let appName: String
        let title: String?
        let bounds: CGRect?
    }

    private var previousWindowsByID: [UInt32: WindowSnapshot] = [:]
    private let eligibilityPolicy = DockWindowEligibilityPolicy()

    mutating func observe(inventoryDegradedPIDs: Set<pid_t> = [])
        -> (windowInfo: [[String: Any]], observations: [SystemObservation])? {
        let now = Date()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let currentWindows = currentSnapshots(from: windowInfo)
        return (windowInfo, observations(from: currentWindows, at: now, inventoryDegradedPIDs: inventoryDegradedPIDs))
    }

    mutating func observations(
        from currentWindows: [WindowSnapshot], at now: Date, inventoryDegradedPIDs: Set<pid_t> = []
    ) -> [SystemObservation] {
        let currentByID = Dictionary(uniqueKeysWithValues: currentWindows.map { ($0.cgWindowID, $0) })

        var events: [SystemObservation] = []

        for window in currentWindows {
            let kind: SystemObservation.ObservationKind
            if let previous = previousWindowsByID[window.cgWindowID], previous.pid == window.pid {
                if previous.title != window.title {
                    kind = .titleChanged
                } else {
                    kind = .unchanged
                }
            } else {
                kind = .appeared
            }

            events.append(
                SystemObservation(
                    timestamp: now,
                    kind: kind,
                    source: .coreGraphics,
                    pid: window.pid,
                    bundleIdentifier: window.bundleIdentifier,
                    cgWindowID: window.cgWindowID,
                    title: window.title,
                    appName: window.appName,
                    bounds: window.bounds
                    ,
                    isMinimized: false,
                    isFocusedWindow: false,
                    isInventoryDegraded: inventoryDegradedPIDs.contains(window.pid)
                )
            )
        }

        for previous in previousWindowsByID.values where currentByID[previous.cgWindowID]?.pid != previous.pid {
            events.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: .coreGraphics,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds
                    ,
                    isMinimized: false,
                    isFocusedWindow: false,
                    isInventoryDegraded: inventoryDegradedPIDs.contains(previous.pid)
                )
            )
        }

        previousWindowsByID = currentByID

        return events.sorted { lhs, rhs in
            let lhsID = lhs.cgWindowID ?? 0
            let rhsID = rhs.cgWindowID ?? 0
            if lhsID != rhsID {
                return lhsID < rhsID
            }
            return lhs.kind == .disappeared && rhs.kind != .disappeared
        }
    }

    private func currentSnapshots(from windowInfo: [[String: Any]]) -> [WindowSnapshot] {
        windowInfo.compactMap { info -> WindowSnapshot? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            guard let cgWindowID = nativeWindowNumber(in: info) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let cgName = info[kCGWindowOwnerName as String] as? String
            guard let appName = cgName.flatMap({ $0.isEmpty ? nil : $0 }) ?? app?.localizedName,
                  !appName.isEmpty else { return nil }

            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap {
                CGRect(dictionaryRepresentation: $0 as CFDictionary)
            }

            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            let bundleIdentifier = app?.bundleIdentifier

            let decision = eligibilityPolicy.evaluate(
                DockWindowEligibilityPolicy.Candidate(
                    bundleIdentifier: bundleIdentifier,
                    appName: appName,
                    title: title,
                    subrole: nil,
                    bounds: bounds,
                    alpha: alpha,
                    activationPolicy: app?.activationPolicy ?? .prohibited,
                    executablePath: app?.executableURL?.path,
                    allowsUntitledWindow: true
                )
            )
            guard decision == .keep else { return nil }

            return WindowSnapshot(
                cgWindowID: cgWindowID,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                title: (title?.isEmpty == false) ? title : nil,
                bounds: bounds
            )
        }
    }
}
