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
