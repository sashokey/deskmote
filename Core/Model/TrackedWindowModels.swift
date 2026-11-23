import Foundation
import CoreGraphics

func nativeWindowNumber(in info: [String: Any]) -> CGWindowID? {
    let value = info[kCGWindowNumber as String]
    if let number = value as? CGWindowID { return number }
    if let number = value as? Int32 { return CGWindowID(bitPattern: number) }
    guard let number = value as? Int else { return nil }
    if let signed = Int32(exactly: number) { return CGWindowID(bitPattern: signed) }
    return CGWindowID(exactly: number)
}

struct ProcessGeneration: Hashable, Sendable {
    let seconds: Int64
    let microseconds: Int32

    init(_ time: timeval) {
        seconds = Int64(time.tv_sec)
        microseconds = time.tv_usec
    }
}

struct ApplicationOrigin: Hashable, Sendable {
    let bundlePath: String

    init?(bundleURL: URL?) {
        guard let bundleURL, bundleURL.isFileURL else { return nil }
        bundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct ApplicationIdentity: Hashable, Sendable {
    static let properWMIdentifier = "io.github.sashokey.deskmote"
    static let properWMDevelopmentIdentifier = "\(properWMIdentifier).dev"

    static func isDeskMote(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == properWMIdentifier || bundleIdentifier == properWMDevelopmentIdentifier
    }

    let pid: Int32
    let bundleIdentifier: String
    let origin: ApplicationOrigin
    let generation: ProcessGeneration
}

struct WindowActionIdentity: Hashable, Sendable {
    let windowID: WindowID
    let pid: Int32
    let processGeneration: ProcessGeneration?
    let cgWindowID: CGWindowID?
    let groupID: String
    let targetID: UUID?

    func representsSameTarget(as other: WindowActionIdentity) -> Bool {
        targetID != nil && targetID == other.targetID && groupID == other.groupID
            && pid == other.pid && processGeneration != nil && processGeneration == other.processGeneration
    }
}

struct WindowActionTarget: Hashable, Sendable {
    let id = UUID()
    let element: AXElementKey
}

struct WindowRecord: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case external
        case utility(spaceWindowNumber: UInt32?)
    }

    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var applicationOrigin: ApplicationOrigin?
    var processGeneration: ProcessGeneration?
    var owningApplication: ApplicationIdentity?
    let actionTarget: WindowActionTarget?
    let source: Source
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool
    var groupID: String
    var displayUUID: String?
    var utilityDisplayID: CGDirectDisplayID?

    var actionIdentity: WindowActionIdentity {
        WindowActionIdentity(windowID: id, pid: pid, processGeneration: processGeneration,
                             cgWindowID: cgWindowID, groupID: groupID, targetID: actionTarget?.id)
    }

    func sharesApplicationFocus(with other: WindowRecord) -> Bool {
        (owningApplication?.pid ?? pid) == (other.owningApplication?.pid ?? other.pid)
            && (owningApplication?.generation ?? processGeneration)
                == (other.owningApplication?.generation ?? other.processGeneration)
    }

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false,
        groupID: String = "",
        displayUUID: String? = nil,
        applicationOrigin: ApplicationOrigin? = nil,
        processGeneration: ProcessGeneration? = nil,
        owningApplication: ApplicationIdentity? = nil,
        actionTarget: WindowActionTarget? = nil,
        source: Source = .external,
        utilityDisplayID: CGDirectDisplayID? = nil
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.applicationOrigin = applicationOrigin
        self.processGeneration = processGeneration
        self.owningApplication = owningApplication
        self.actionTarget = actionTarget
        self.source = source
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
        self.groupID = groupID.isEmpty ? id.rawValue : groupID
        self.displayUUID = displayUUID
        self.utilityDisplayID = utilityDisplayID
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}

struct OptimisticWindowState: Hashable, Sendable {
    let status: WindowStatus
    let createdAt: Date
    let focusHandoffGrace: Bool
    let systemPredicted: Bool
    let handoffSourceToken: UUID?

    init(status: WindowStatus, createdAt: Date, focusHandoffGrace: Bool = false,
         systemPredicted: Bool = false, handoffSourceToken: UUID? = nil) {
        self.status = status
        self.createdAt = createdAt
        self.focusHandoffGrace = focusHandoffGrace
        self.systemPredicted = systemPredicted
        self.handoffSourceToken = handoffSourceToken
    }
}

extension OptimisticWindowState {
    static let handoffSupersessionGrace: TimeInterval = 1.5

    static func systemPredictionFalsified(state: OptimisticWindowState, actual: WindowStatus) -> Bool {
        guard state.systemPredicted, state.status == .active else { return false }
        return actual == .minimized || actual == .hidden
    }

    static func supersededByActiveSibling(
        windowID: String,
        state: OptimisticWindowState,
        now: Date,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot,
        handoffGraceEnabled: Bool
    ) -> Bool {
        guard state.status == .active else { return false }
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let crediblyActiveSibling = snapshot.windows.values.contains { sibling in
            guard sibling.id != record.id, sibling.status == .active, sibling.sharesApplicationFocus(with: record) else {
                return false
            }
            let inFlight = optimisticStates[sibling.id.rawValue]?.status
            return inFlight != .minimized && inFlight != .hidden
        }
        guard crediblyActiveSibling else { return false }
        guard handoffGraceEnabled,
              state.focusHandoffGrace,
              now.timeIntervalSince(state.createdAt) <= Self.handoffSupersessionGrace
        else { return true }
        let siblingActivationClicked = optimisticStates.contains { key, sibling in
            guard key != windowID, sibling.status == .active else { return false }
            guard let siblingRecord = snapshot.windows[WindowID(rawValue: key)] else { return false }
            return siblingRecord.sharesApplicationFocus(with: record)
        }
        return siblingActivationClicked
    }

    static func siblingActivationInFlight(
        windowID: String,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot
    ) -> Bool {
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let ownActivationCreatedAt: Date? = {
            guard let own = optimisticStates[windowID], own.status == .active else { return nil }
            return own.createdAt
        }()
        return optimisticStates.contains { key, state in
            guard key != windowID, state.status == .active else { return false }
            guard let sibling = snapshot.windows[WindowID(rawValue: key)] else { return false }
            guard sibling.status != .active, sibling.sharesApplicationFocus(with: record) else { return false }
            if let own = ownActivationCreatedAt, own > state.createdAt { return false }
            return true
        }
    }
}
