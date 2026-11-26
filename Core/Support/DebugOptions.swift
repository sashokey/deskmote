import Foundation

enum DebugSwitch: String, CaseIterable, Sendable {
    enum Kind: Sendable { case killSwitch, trace, value }

    case reconcileSkip = "DOCK_RECONCILE_SKIP"
    case scanGate = "DOCK_SCAN_GATE"
    case frontmostCache = "DOCK_FRONTMOST_CACHE"
    case cgSnapshotReuse = "DOCK_CG_SNAPSHOT_REUSE"
    case axElementCache = "DOCK_AX_ELEMENT_CACHE"
    case absentSeatRelease = "DOCK_ABSENT_SEAT_RELEASE"
    case skylightFocus = "DOCK_SKYLIGHT_FOCUS"
    case fastWindowHandle = "DOCK_FAST_WINDOW_HANDLE"
    case windowLift = "DOCK_WINDOW_LIFT"
    #if DEBUG
    case chipProbe = "DOCK_CHIP_PROBE"
    case clickTrace = "DOCK_CLICK_TRACE"
    case hoverTrace = "DOCK_HOVER_TRACE"
    case labelProbe = "DOCK_LABEL_PROBE"
    case simulateNoDestroy = "DOCK_SIMULATE_NO_DESTROY"
    case inventoryLog = "DOCK_INVENTORY_LOG"
    case spaceBatchMode = "DOCK_SPACE_BATCH_MODE"
    #endif
    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    case panelLevel = "DOCK_PANEL_LEVEL"

    var kind: Kind {
        switch self {
        case .reconcileSkip, .scanGate, .frontmostCache, .cgSnapshotReuse, .axElementCache, .absentSeatRelease, .skylightFocus, .fastWindowHandle, .windowLift:
            return .killSwitch
        #if DEBUG
        case .chipProbe, .clickTrace, .hoverTrace, .labelProbe, .simulateNoDestroy:
            return .trace
        case .inventoryLog, .spaceBatchMode:
            return .value
        #endif
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .panelLevel:
            return .value
        }
    }

    func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }

    func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch kind {
        case .killSwitch: return environment[rawValue] != "0"
        case .trace: return environment[rawValue] == "1"
        case .value:
            assertionFailure("\(rawValue) is a value switch; read it with value(in:)")
            return environment[rawValue] != nil
        }
    }
}
