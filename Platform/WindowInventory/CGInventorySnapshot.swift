import CoreGraphics
import Foundation

struct AppTrackerCGWindowSnapshot: Equatable {
    let allWindowIDs: Set<CGWindowID>
    let onScreenWindowIDs: Set<CGWindowID>
    let windowIDsByPID: [pid_t: Set<CGWindowID>]
    let ownerPIDByWindowID: [CGWindowID: pid_t]
    let alphaByWindowID: [CGWindowID: Double]
    let boundsByWindowID: [CGWindowID: CGRect]
    let belowNormalLayerWindowIDs: Set<CGWindowID>
    let captureFailed: Bool
    let parentWindowIDs: [CGWindowID: CGWindowID]
    private(set) var capturedAt: ContinuousClock.Instant?

    init(
        allWindowIDs: Set<CGWindowID>,
        onScreenWindowIDs: Set<CGWindowID>,
        windowIDsByPID: [pid_t: Set<CGWindowID>],
        alphaByWindowID: [CGWindowID: Double],
        boundsByWindowID: [CGWindowID: CGRect] = [:],
        belowNormalLayerWindowIDs: Set<CGWindowID> = [],
        captureFailed: Bool = false,
        parentWindowIDs: [CGWindowID: CGWindowID] = [:]
    ) {
        self.allWindowIDs = allWindowIDs
        self.onScreenWindowIDs = onScreenWindowIDs
        self.windowIDsByPID = windowIDsByPID
        var owners: [CGWindowID: pid_t] = [:]
        var conflictingIDs = Set<CGWindowID>()
        for (pid, ids) in windowIDsByPID where pid > 0 {
            for id in ids {
                if owners.updateValue(pid, forKey: id) != nil { conflictingIDs.insert(id) }
            }
        }
        for id in conflictingIDs { owners.removeValue(forKey: id) }
        ownerPIDByWindowID = owners
        self.alphaByWindowID = alphaByWindowID
        self.boundsByWindowID = boundsByWindowID
        self.belowNormalLayerWindowIDs = belowNormalLayerWindowIDs
        self.captureFailed = captureFailed
        self.parentWindowIDs = parentWindowIDs
    }

    static var failed: AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:],
            boundsByWindowID: [:],
            captureFailed: true
        )
    }

    static func timedCapture(_ capture: () -> Self) -> Self {
        let capturedAt = ContinuousClock.now
        var snapshot = capture()
        snapshot.capturedAt = capturedAt
        return snapshot
    }

    static func capture() -> AppTrackerCGWindowSnapshot {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return .failed
        }
        let ids = Set(windowInfo.compactMap(layerZeroWindowID(in:)))
        return parse(windowInfo, parentWindowIDs: NativeWindowParentReader.parents(for: ids))
    }

    static func captureOnScreenWindowIDs() -> Set<CGWindowID>? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return layerZeroWindowIDs(in: windowInfo)
    }

    static func parse(_ windowInfo: [[String: Any]], parentWindowIDs: [CGWindowID: CGWindowID] = [:]) -> AppTrackerCGWindowSnapshot {
        var allWindowIDs: Set<CGWindowID> = []
        var onScreenWindowIDs: Set<CGWindowID> = []
        var windowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        var alphaByWindowID: [CGWindowID: Double] = [:]
        var boundsByWindowID: [CGWindowID: CGRect] = [:]
        var belowNormalLayerWindowIDs: Set<CGWindowID> = []

        for info in windowInfo {
            if let layer = info[kCGWindowLayer as String] as? Int, layer < 0 {
                if let windowID = nativeWindowNumber(in: info) {
                    belowNormalLayerWindowIDs.insert(windowID)
                }
                continue
            }
            guard let windowID = layerZeroWindowID(in: info) else { continue }
            allWindowIDs.insert(windowID)
            if info[kCGWindowIsOnscreen as String] as? Bool == true {
                onScreenWindowIDs.insert(windowID)
            }
            if let rawPID = info[kCGWindowOwnerPID as String] as? Int, let ownerPID = pid_t(exactly: rawPID) {
                windowIDsByPID[ownerPID, default: []].insert(windowID)
            }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue {
                alphaByWindowID[windowID] = alpha
            }
            if let dict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict) {
                boundsByWindowID[windowID] = rect
            }
        }

        return AppTrackerCGWindowSnapshot(
            allWindowIDs: allWindowIDs,
            onScreenWindowIDs: onScreenWindowIDs,
            windowIDsByPID: windowIDsByPID,
            alphaByWindowID: alphaByWindowID,
            boundsByWindowID: boundsByWindowID,
            belowNormalLayerWindowIDs: belowNormalLayerWindowIDs,
            parentWindowIDs: parentWindowIDs.filter { allWindowIDs.contains($0.key) }
        )
    }

    func isNormalRoot(windowID: CGWindowID, pid: pid_t) -> Bool {
        !captureFailed && windowIDsByPID[pid]?.contains(windowID) == true && parentWindowIDs[windowID] == 0
    }

    private static func layerZeroWindowIDs(in windowInfo: [[String: Any]]) -> Set<CGWindowID> {
        Set(windowInfo.compactMap(layerZeroWindowID(in:)))
    }

    private static func layerZeroWindowID(in info: [String: Any]) -> CGWindowID? {
        guard info[kCGWindowLayer as String] as? Int == 0 else { return nil }
        return nativeWindowNumber(in: info)
    }
}

enum NativeWindowParentReader {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Query = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowID = @convention(c) (CFTypeRef) -> UInt32

    private static let functions: (Connection, Query, CopyWindows, Advance, WindowID, WindowID)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let connection = dlsym(library, "SLSMainConnectionID"),
              let query = dlsym(library, "SLSWindowQueryWindows"),
              let copy = dlsym(library, "SLSWindowQueryResultCopyWindows"),
              let advance = dlsym(library, "SLSWindowIteratorAdvance"),
              let windowID = dlsym(library, "SLSWindowIteratorGetWindowID"),
              let parentID = dlsym(library, "SLSWindowIteratorGetParentID") else {
            dlclose(library)
            return nil
        }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(query, to: Query.self),
                unsafeBitCast(copy, to: CopyWindows.self), unsafeBitCast(advance, to: Advance.self),
                unsafeBitCast(windowID, to: WindowID.self), unsafeBitCast(parentID, to: WindowID.self))
    }()

    static func parents(for ids: Set<CGWindowID>) -> [CGWindowID: CGWindowID] {
        guard !ids.isEmpty, let (connection, query, copy, advance, windowID, parentID) = functions else { return [:] }
        let ordered = ids.sorted()
        var parents: [CGWindowID: CGWindowID] = [:]
        for start in stride(from: 0, to: ordered.count, by: 1024) {
            let batch = Array(ordered[start..<min(start + 1024, ordered.count)])
            guard let result = query(connection(), batch.map { NSNumber(value: $0) } as CFArray, Int32(batch.count))?.takeRetainedValue(),
                  let iterator = copy(result)?.takeRetainedValue() else { continue }
            var count = 0
            while count < batch.count, advance(iterator) {
                count += 1
                let id = windowID(iterator)
                if ids.contains(id) { parents[id] = parentID(iterator) }
            }
        }
        return parents
    }
}
