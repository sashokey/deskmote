import AppKit

enum DisplayIdentity {
    @MainActor
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor
    static func uuidString(for screen: NSScreen) -> String? {
        guard let id = displayID(for: screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    @MainActor
    static func attributionTable() -> WindowDisplayAttribution.Table {
        attributionTable(screens: NSScreen.screens)
    }

    @MainActor
    static func attributionTable(screens: [NSScreen]) -> WindowDisplayAttribution.Table {
        let primaryHeight = screens.first?.frame.maxY ?? 0
        var primaryUUID: String?
        let displays: [WindowDisplayAttribution.Display] = screens.enumerated().compactMap { index, screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            if index == 0 { primaryUUID = uuid }
            return WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: WindowLiftAvoidance.windowServerFrame(fromAppKit: screen.frame, primaryDisplayHeight: primaryHeight),
                usableWindowServerFrame: WindowLiftAvoidance.windowServerFrame(fromAppKit: screen.visibleFrame,
                                                                primaryDisplayHeight: primaryHeight)
            )
        }
        return WindowDisplayAttribution.Table(
            displays: displays,
            primaryUUID: primaryUUID
        )
    }

    @MainActor
    static func topologySnapshot() -> ScreenTopologySnapshot {
        let screens = NSScreen.screens
        let table = attributionTable(screens: screens)
        return ScreenTopologySnapshot(
            physicalDisplayCount: screens.count,
            identifiedDisplayUUIDs: table.orderedUUIDs,
            attributionTable: table
        )
    }


}
