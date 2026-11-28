import CoreGraphics
import Foundation

struct SpaceReadFailure: Error, Hashable, Sendable, CustomStringConvertible {
    enum Reason: String, Sendable {
        case untestedSystemVersion
        case libraryUnavailable
        case symbolUnavailable
        case connectionUnavailable
        case nullResponse
        case invalidType
        case invalidValue
        case duplicateValue
        case missingCurrentSpace
        case unknownSpaceType
        case cancelled
        case deadlineExceeded
    }

    let api: String
    let reason: Reason
    let field: String?
    let value: Int?

    init(api: String, reason: Reason, field: String? = nil, value: Int? = nil) {
        self.api = api
        self.reason = reason
        self.field = field
        self.value = value
    }

    var diagnosticCode: String { "\(api).\(reason.rawValue)" }

    var description: String {
        [diagnosticCode, field.map { "field=\($0)" }, value.map { "value=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }

    var isInterruption: Bool { reason == .cancelled || reason == .deadlineExceeded }
}

struct SpaceMembershipRead: Equatable, Sendable {
    let memberships: [WindowSpaceIdentity: Set<Int>]
    let failures: [SpaceReadFailure]
}

private enum SpaceNativeReader {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private static let connectionAPI = "SLSMainConnectionID"
    private static let connection = function(connectionAPI, as: MainConnectionID.self)
    nonisolated(unsafe) private static let library = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    )

    static func compatibilityFailure(api: String, majorVersion: Int) -> SpaceReadFailure? {
        guard majorVersion != WindowPlatformABI.validatedMajorVersion else { return nil }
        return SpaceReadFailure(api: api, reason: .untestedSystemVersion, field: "macOS.majorVersion", value: majorVersion)
    }

    static func function<T>(_ name: String, as type: T.Type) -> Result<T, SpaceReadFailure> {
        if let failure = compatibilityFailure(api: name, majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            return .failure(failure)
        }
        guard let library else {
            return .failure(SpaceReadFailure(api: name, reason: .libraryUnavailable, field: "SkyLight"))
        }
        guard let address = dlsym(library, name) else {
            return .failure(SpaceReadFailure(api: name, reason: .symbolUnavailable))
        }
        return .success(unsafeBitCast(address, to: type))
    }

    static func connectionID() -> Result<Int32, SpaceReadFailure> {
        connection.flatMap { function in
            let id = function()
            guard id > 0 else {
                return .failure(SpaceReadFailure(api: connectionAPI, reason: .connectionUnavailable, value: Int(id)))
            }
            return .success(id)
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        return number as? Int
    }

    static func identifiers(_ result: CFTypeRef?, api: String) -> Result<[Int], SpaceReadFailure> {
        guard let result else { return .failure(SpaceReadFailure(api: api, reason: .nullResponse)) }
        guard CFGetTypeID(result) == CFArrayGetTypeID(), let values = result as? [Any] else {
            return .failure(SpaceReadFailure(api: api, reason: .invalidType, field: "response"))
        }
        var ids: [Int] = []
        ids.reserveCapacity(values.count)
        for value in values {
            guard let id = integer(value), id > 0 else {
                return .failure(SpaceReadFailure(api: api, reason: .invalidValue, field: "identifier"))
            }
            ids.append(id)
        }
        return .success(ids)
    }
}

enum ManagedSpaceLayoutReader {
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let api = "SLSCopyManagedDisplaySpaces"
    private static let copySpaces = SpaceNativeReader.function(api, as: CopySpaces.self)

    static func layout(forDisplayUUID uuid: String) -> SpaceLayoutSnapshot? {
        guard let layouts = layouts() else { return nil }
        return layouts[uuid] ?? layouts["Main"]
    }

    static func layouts() -> [String: SpaceLayoutSnapshot]? { try? read().get() }

    static func read(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> Result<[String: SpaceLayoutSnapshot], SpaceReadFailure> {
        if let failure = SpaceNativeReader.compatibilityFailure(api: api, majorVersion: majorVersion) {
            return .failure(failure)
        }
        return copySpaces.flatMap { copy in
            SpaceNativeReader.connectionID().flatMap { connection in
                let response = copy(connection)?.takeRetainedValue()
                guard let result = response else { return failure(.nullResponse) }
                guard CFGetTypeID(result) == CFArrayGetTypeID() else { return failure(.invalidType, field: "response") }
                return parseChecked(result)
            }
        }
    }

    static func parse(_ displays: [[String: Any]]) -> [String: SpaceLayoutSnapshot]? {
        try? parseChecked(displays).get()
    }

    static func parseChecked(_ response: Any) -> Result<[String: SpaceLayoutSnapshot], SpaceReadFailure> {
        guard let displays = response as? [[String: Any]] else { return failure(.invalidType, field: "displays") }
        guard !displays.isEmpty else { return failure(.invalidValue, field: "displays", value: 0) }
        var result: [String: SpaceLayoutSnapshot] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String, !uuid.isEmpty else {
                return failure(.invalidType, field: "Display Identifier")
            }
            guard result[uuid] == nil else { return failure(.duplicateValue, field: "Display Identifier") }
            guard let spaces = display["Spaces"] as? [[String: Any]] else {
                return failure(.invalidType, field: "Spaces")
            }
            guard let current = display["Current Space"] as? [String: Any] else {
                return failure(.invalidType, field: "Current Space")
            }
            guard let currentID = spaceID(current) else { return failure(.invalidValue, field: "Current Space ID") }

            var ordered: [Int] = []
            var seen: Set<Int> = []
            var fullscreen: Set<Int> = []
            var currentType: Int?
            for space in spaces {
                guard let id = spaceID(space) else { return failure(.invalidValue, field: "Space ID") }
                guard seen.insert(id).inserted else { return failure(.duplicateValue, field: "Space ID", value: id) }
                guard let type = SpaceNativeReader.integer(space["type"]) else {
                    return failure(.invalidType, field: "Space type")
                }
                switch type {
                case 0: break
                case SpaceLayoutSnapshot.fullscreenSpaceType: fullscreen.insert(id)
                default: return failure(.unknownSpaceType, field: "Space type", value: type)
                }
                ordered.append(id)
                if id == currentID { currentType = type }
            }
            guard let currentType else { return failure(.missingCurrentSpace, field: "Current Space ID", value: currentID) }
            if let value = current["type"] {
                guard let type = SpaceNativeReader.integer(value) else {
                    return failure(.invalidType, field: "Current Space type")
                }
                guard type == 0 || type == SpaceLayoutSnapshot.fullscreenSpaceType else {
                    return failure(.unknownSpaceType, field: "Current Space type", value: type)
                }
                guard type == currentType else {
                    return failure(.invalidValue, field: "Current Space type", value: type)
                }
            }
            result[uuid] = SpaceLayoutSnapshot(
                orderedSpaceIDs: ordered, fullscreenSpaceIDs: fullscreen, currentSpaceID: currentID
            )
        }
        return .success(result)
    }

    private static func failure(_ reason: SpaceReadFailure.Reason, field: String? = nil, value: Int? = nil)
        -> Result<[String: SpaceLayoutSnapshot], SpaceReadFailure> {
        .failure(SpaceReadFailure(api: api, reason: reason, field: field, value: value))
    }

    private static func spaceID(_ dict: [String: Any]) -> Int? {
        guard let id = SpaceNativeReader.integer(dict["ManagedSpaceID"]) ?? SpaceNativeReader.integer(dict["id64"]),
              id > 0 else { return nil }
        return id
    }
}

enum WindowSpaceObservation {
    #if DESKMOTE_TEST
    enum Mode: String {
        case standard
        case batch

    }


    static func capture(_ requests: [WindowSpaceRequest], cancellation: OperationCancellation,
                        maximumDuration: TimeInterval = 1,
                        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        layouts: () -> [String: SpaceLayoutSnapshot]? = ManagedSpaceLayoutReader.layouts,
                        membership: (Int) -> [Int]? = WindowSpaceMembershipReader.spaceIDs,
                        mode: Mode = .standard,
                        windowsInSpace: (Int) -> Set<Int>? = WindowSpaceMembershipReader.windowNumbers) -> WindowSpaceSnapshot? {
        let budget = OperationReadBudget(maximumDuration: maximumDuration, cancellation: cancellation, uptime: uptime)
        guard budget.canContinue, let initial = layouts() else { return nil }
        let result = readMemberships(requests, layouts: initial, budget: budget, mode: mode, membership: { number in
            guard let ids = membership(number) else {
                return .failure(SpaceReadFailure(api: WindowSpaceMembershipReader.membershipAPI, reason: .nullResponse))
            }
            return .success(ids)
        }, windowsInSpace: { space in
            guard let windows = windowsInSpace(space) else {
                return .failure(SpaceReadFailure(api: WindowSpaceMembershipReader.batchAPI, reason: .nullResponse))
            }
            return .success(windows)
        })
        guard case .success(let read) = result, budget.canContinue, initial == layouts(), budget.canContinue else {
            return nil
        }
        return WindowSpaceSnapshot(layouts: initial, memberships: read.memberships)
    }

    static func readMemberships(_ requests: [WindowSpaceRequest], layouts: [String: SpaceLayoutSnapshot],
                                cancellation: OperationCancellation, maximumDuration: TimeInterval = 1,
                                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                mode: Mode,
                                membership: (Int) -> Result<[Int], SpaceReadFailure> = WindowSpaceMembershipReader.readSpaceIDs,
                                windowsInSpace: (Int) -> Result<Set<Int>, SpaceReadFailure> = WindowSpaceMembershipReader.readWindowNumbers)
        -> Result<SpaceMembershipRead, SpaceReadFailure> {
        let budget = OperationReadBudget(maximumDuration: maximumDuration, cancellation: cancellation, uptime: uptime)
        return readMemberships(requests, layouts: layouts, budget: budget, mode: mode,
                               membership: membership, windowsInSpace: windowsInSpace)
    }

    private static func readMemberships(_ requests: [WindowSpaceRequest], layouts: [String: SpaceLayoutSnapshot],
                                        budget: OperationReadBudget, mode: Mode,
                                        membership: (Int) -> Result<[Int], SpaceReadFailure>,
                                        windowsInSpace: (Int) -> Result<Set<Int>, SpaceReadFailure>)
        -> Result<SpaceMembershipRead, SpaceReadFailure> {
        var failures: [SpaceReadFailure] = []
        func readBySpace() -> [Int: Set<Int>]? {
            let uniqueNumbers = Set(requests.map { Int($0.identity.windowID) })
            let scalarOnly = Set(requests.filter { $0.isParked || !$0.isOnDesktop || $0.isUtility }
                .map { Int($0.identity.windowID) })
            let eligible = uniqueNumbers.subtracting(scalarOnly)
            guard eligible.count > 1 else { return nil }
            var spaces: Set<Int> = []
            for request in requests where eligible.contains(Int(request.identity.windowID)) {
                guard let display = request.displayUUID, let layout = layouts[display] ?? layouts["Main"] else {
                    spaces = Set(layouts.values.flatMap(\.orderedSpaceIDs))
                    break
                }
                spaces.formUnion(layout.orderedSpaceIDs)
            }
            guard !spaces.isEmpty, spaces.count < eligible.count else { return nil }
            var result: [Int: Set<Int>] = [:]
            for space in spaces.sorted() {
                guard budget.canContinue else { return nil }
                switch windowsInSpace(space) {
                case .success(let windows):
                    for number in windows where eligible.contains(number) {
                        result[number, default: []].insert(space)
                    }
                case .failure(let failure):
                    failures.append(failure)
                    return nil
                }
            }
            return result
        }

        let cache = mode == .batch ? readBySpace() ?? [:] : [:]
        return readByWindow(requests, budget: budget, membership: membership, cache: cache, initialFailures: failures)
    }
    #endif

    static func readMemberships(_ requests: [WindowSpaceRequest], cancellation: OperationCancellation)
        -> Result<SpaceMembershipRead, SpaceReadFailure> {
        let budget = OperationReadBudget(maximumDuration: 1, cancellation: cancellation)
        return readByWindow(requests, budget: budget, membership: WindowSpaceMembershipReader.readSpaceIDs)
    }

    private static func readByWindow(_ requests: [WindowSpaceRequest], budget: OperationReadBudget,
                                     membership: (Int) -> Result<[Int], SpaceReadFailure>,
                                     cache: [Int: Set<Int>] = [:], initialFailures: [SpaceReadFailure] = [])
        -> Result<SpaceMembershipRead, SpaceReadFailure> {
        var failures = initialFailures
        var result = cache
        var read = Set(cache.keys)
        for request in requests {
            let number = Int(request.identity.windowID)
            guard read.insert(number).inserted else { continue }
            guard budget.canContinue else { return interrupted() }
            switch membership(number) {
            case .success(let ids): result[number] = Set(ids)
            case .failure(let failure):
                if !failures.contains(failure) { failures.append(failure) }
            }
        }
        guard budget.canContinue else { return interrupted() }
        var memberships: [WindowSpaceIdentity: Set<Int>] = [:]
        for request in requests {
            memberships[request.identity] = result[Int(request.identity.windowID)]
        }
        return .success(SpaceMembershipRead(memberships: memberships, failures: failures))

        func interrupted() -> Result<SpaceMembershipRead, SpaceReadFailure> {
            .failure(SpaceReadFailure(api: WindowSpaceMembershipReader.membershipAPI,
                                      reason: budget.cancellation.isCancelled ? .cancelled : .deadlineExceeded))
        }
    }
}

enum WindowSpaceMembershipReader {
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFTypeRef>?
    static let membershipAPI = "SLSCopySpacesForWindows"
    private static let copySpaces = SpaceNativeReader.function(membershipAPI, as: CopySpacesForWindows.self)

    #if DESKMOTE_TEST
    private typealias CopyWindowsForSpace = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFTypeRef>?

    static let batchAPI = "SLSCopyWindowsWithOptionsAndTags"
    private static let copyWindows = SpaceNativeReader.function(batchAPI, as: CopyWindowsForSpace.self)

    static func windowNumbers(forSpaceID spaceID: Int) -> Set<Int>? { try? readWindowNumbers(spaceID).get() }
    #endif

    static func spaceIDs(forWindowNumber windowNumber: Int) -> [Int]? { try? readSpaceIDs(windowNumber).get() }

    #if DESKMOTE_TEST
    static func readWindowNumbers(_ spaceID: Int) -> Result<Set<Int>, SpaceReadFailure> {
        guard spaceID > 0 else {
            return .failure(SpaceReadFailure(api: batchAPI, reason: .invalidValue, field: "Space ID", value: spaceID))
        }
        return copyWindows.flatMap { copy in
            SpaceNativeReader.connectionID().flatMap { connection in
                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                let numbers = [NSNumber(value: spaceID)] as CFArray
                let response = copy(connection, 0, numbers, 0x7, &setTags, &clearTags)?.takeRetainedValue()
                return SpaceNativeReader.identifiers(response, api: batchAPI).map(Set.init)
            }
        }
    }

    #endif

    static func readSpaceIDs(_ windowNumber: Int) -> Result<[Int], SpaceReadFailure> {
        guard windowNumber > 0 else {
            return .failure(SpaceReadFailure(api: membershipAPI, reason: .invalidValue,
                                             field: "window number", value: windowNumber))
        }
        return copySpaces.flatMap { copy in
            SpaceNativeReader.connectionID().flatMap { connection in
                let numbers = [NSNumber(value: windowNumber)] as CFArray
                let response = copy(connection, 0x7, numbers)?.takeRetainedValue()
                return SpaceNativeReader.identifiers(response, api: membershipAPI)
            }
        }
    }
}
