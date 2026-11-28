import Foundation

struct SpaceLayoutSnapshot: Equatable, Sendable {
    let orderedSpaceIDs: [Int]
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int
    static let fullscreenSpaceType = 4
}

struct WindowSpaceIdentity: Hashable, Sendable {
    let actionIdentity: WindowActionIdentity
    let windowID: UInt32

    var itemID: String { actionIdentity.groupID }

    init?(_ actionIdentity: WindowActionIdentity, windowNumber: UInt32? = nil) {
        guard let windowID = windowNumber ?? actionIdentity.cgWindowID else { return nil }
        self.actionIdentity = actionIdentity
        self.windowID = windowID
    }
}

struct WindowSpaceRequest: Equatable, Sendable {
    let identity: WindowSpaceIdentity
    let isParked: Bool
    let isOnDesktop: Bool
    let displayUUID: String?
    let isUtility: Bool
    let isOnActiveSpace: Bool?

    init(identity: WindowSpaceIdentity, isParked: Bool, isOnDesktop: Bool, displayUUID: String? = nil,
         isUtility: Bool = false, isOnActiveSpace: Bool? = nil) {
        self.identity = identity
        self.isParked = isParked
        self.isOnDesktop = isOnDesktop
        self.displayUUID = displayUUID
        self.isUtility = isUtility
        self.isOnActiveSpace = isOnActiveSpace
    }
}

struct HeightMembershipStamp: Equatable, Sendable {
    let displayUUID: String
    let spaceRevision: UInt64
    let layoutRevision: UInt64
    let windowRevision: UInt64
    let spaceID: Int
    let isMember: Bool
}

struct WindowSpaceSnapshot: Equatable, Sendable {
    private struct DisplayTransfer: Equatable, Sendable {
        let source: String
        let destination: String
        var confirmed = false
    }

    var layouts: [String: SpaceLayoutSnapshot]
    var memberships: [WindowSpaceIdentity: Set<Int>]
    var heightMembershipStamps: [WindowSpaceIdentity: HeightMembershipStamp] = [:]
    private var requestedIdentities: [UInt32: Set<WindowSpaceIdentity>] = [:]
    private var retiredWindowNumbers: [UInt32] = []
    private var requiresFreshMembership = false
    private var unconfirmedMemberships: Set<WindowSpaceIdentity> = []
    private var externalDisplayUUIDs: [WindowSpaceIdentity: String] = [:]
    private var displayTransfers: [WindowSpaceIdentity: DisplayTransfer] = [:]
    private var lastVisibleUtilitySpaces: [WindowSpaceIdentity: Int] = [:]
    private var utilitiesAwaitingLayout: Set<WindowSpaceIdentity> = []
    private var pendingUtilityMemberships: [WindowSpaceIdentity: Set<Int>] = [:]

    init(layouts: [String: SpaceLayoutSnapshot] = [:], memberships: [WindowSpaceIdentity: Set<Int>] = [:]) {
        self.layouts = layouts
        self.memberships = memberships
    }

    func confirmedMembership(for identity: WindowSpaceIdentity, on displayUUID: String,
                             active: SpaceLayoutSnapshot) -> Bool? {
        guard let stamp = heightMembershipStamps[identity], stamp.displayUUID == displayUUID,
              displayTransfers[identity]?.confirmed != false,
              (layouts[displayUUID] ?? (layouts.count == 1 ? layouts["Main"] : nil)) == active,
              stamp.spaceID == active.currentSpaceID else { return nil }
        return active.orderedSpaceIDs.contains(active.currentSpaceID)
            && !active.fullscreenSpaceIDs.contains(active.currentSpaceID)
            && stamp.isMember
    }

    func permitsProjection(on displayUUID: String?) -> Bool {
        guard let displayUUID, !layouts.isEmpty else { return true }
        return layouts[displayUUID] != nil || layouts["Main"] != nil
    }

    func matchesExternalDisplay(_ identity: WindowSpaceIdentity?, displayUUID: String?) -> Bool {
        guard let identity, let displayUUID, let previous = externalDisplayUUIDs[identity] else { return true }
        return previous == displayUUID
    }

    func transfers(in requests: [WindowSpaceRequest], attachedDisplays: Set<String>? = nil) -> [WindowSpaceRequest] {
        requests.filter { request in
            guard let transfer = displayTransfers[request.identity], !transfer.confirmed else { return false }
            return request.displayUUID == transfer.destination && attachedDisplays?.contains(transfer.destination) != false
        }
    }

    func clearingConfirmedTransfers() -> Self {
        var next = self
        next.displayTransfers = displayTransfers.filter { !$0.value.confirmed }
        return next
    }

    func shows(_ identity: WindowSpaceIdentity?, on displayUUID: String?) -> Bool {
        guard permitsProjection(on: displayUUID) else { return false }
        guard let identity else { return true }
        guard let spaces = memberships[identity] else {
            return !unconfirmedMemberships.contains(identity) && !reusesWindowNumber(identity)
        }
        if let displayUUID, let layout = layouts[displayUUID] ?? layouts["Main"] {
            return spaces.contains(layout.currentSpaceID)
        }
        if displayUUID == nil, let main = layouts["Main"] {
            return spaces.contains(main.currentSpaceID)
        }
        guard displayUUID == nil, !layouts.isEmpty else { return true }
        return !spaces.isDisjoint(with: layouts.values.map(\.currentSpaceID))
    }

    func uniqueDisplay(for identity: WindowSpaceIdentity?, among displays: Set<String>) -> String? {
        guard let identity, let spaces = memberships[identity], !spaces.isEmpty else { return nil }
        let matches = displays.filter { display in
            guard let layout = layouts[display] else { return false }
            return !spaces.isDisjoint(with: layout.orderedSpaceIDs)
        }
        return matches.count == 1 ? matches.first : nil
    }

    func recordingSpaceChange(requests: [WindowSpaceRequest]) -> Self {
        var next = self
        let parked = Set(requests.filter(\.isParked).map(\.identity))
        next.utilitiesAwaitingLayout.formIntersection(parked)
        next.pendingUtilityMemberships = next.pendingUtilityMemberships.filter { parked.contains($0.key) }
        return next.updating(with: nil, requests: requests, afterSpaceChange: true)
    }

    func updating(with observation: WindowSpaceSnapshot?, requests: [WindowSpaceRequest],
                  afterSpaceChange: Bool = false, attachedDisplays: Set<String>? = nil,
                  targetedTransferRead: Bool = false) -> Self {
        let identities = Set(requests.map(\.identity))
        let observation = observation.flatMap { $0.layouts.isEmpty ? nil : $0 }
        let canRetainConfirmedTransfer = !afterSpaceChange && (observation.map { $0.layouts == layouts } ?? true)
        var next = canRetainConfirmedTransfer ? self : clearingConfirmedTransfers()
        let previouslyRequested = layouts.isEmpty ? Set<WindowSpaceIdentity>() :
            Set(requestedIdentities.values.flatMap { $0 })
        let retired = Set(memberships.keys).union(unconfirmedMemberships).union(previouslyRequested).subtracting(identities)
        let added = Set(retired.map(\.windowID))
        next.retiredWindowNumbers.removeAll(where: added.contains)
        next.retiredWindowNumbers.append(contentsOf: added.sorted())
        next.retiredWindowNumbers = Array(next.retiredWindowNumbers.suffix(4096))
        next.memberships = memberships.filter { identities.contains($0.key) }
        next.heightMembershipStamps = next.heightMembershipStamps.filter { identities.contains($0.key) }
        next.requestedIdentities = Dictionary(grouping: identities, by: \.windowID).mapValues(Set.init)
        next.unconfirmedMemberships.formIntersection(identities)
        next.unconfirmedMemberships.formUnion(identities.filter(reusesWindowNumber))
        next.lastVisibleUtilitySpaces = lastVisibleUtilitySpaces.filter { identities.contains($0.key) }
        next.utilitiesAwaitingLayout.formIntersection(identities)
        next.pendingUtilityMemberships = pendingUtilityMemberships.filter { identities.contains($0.key) }
        next.externalDisplayUUIDs = Dictionary(requests.compactMap { request in
            guard !request.isUtility, !request.isParked, let displayUUID = request.displayUUID else { return nil }
            return (request.identity, displayUUID)
        }, uniquingKeysWith: { first, _ in first })
        let priorTransfers = next.displayTransfers
        next.displayTransfers = Dictionary(requests.compactMap { request in
            guard !request.isUtility, let transfer = priorTransfers[request.identity],
                  transfer.destination == request.displayUUID else { return nil }
            return (request.identity, transfer)
        }, uniquingKeysWith: { first, _ in first })
        for (identity, destination) in next.externalDisplayUUIDs {
            if let source = externalDisplayUUIDs[identity], source != destination {
                next.displayTransfers[identity] = DisplayTransfer(source: source, destination: destination)
                next.memberships.removeValue(forKey: identity)
                next.unconfirmedMemberships.insert(identity)
            }
        }
        if let observation { next.layouts = observation.layouts }
        if afterSpaceChange, observation != nil { next.requiresFreshMembership = true }
        for request in requests {
            let identity = request.identity
            let spaces = observation?.memberships[identity]
            if let transfer = next.displayTransfers[identity] {
                let reachesDestination = spaces.map { membership in
                    next.layout(on: transfer.destination).map { !membership.isDisjoint(with: $0.orderedSpaceIDs) } == true
                } == true && attachedDisplays?.contains(transfer.destination) != false
                if reachesDestination {
                    if targetedTransferRead {
                        next.displayTransfers[identity]?.confirmed = true
                    } else {
                        next.displayTransfers.removeValue(forKey: identity)
                    }
                } else {
                    guard transfer.confirmed else { continue }
                    if let spaces, !spaces.isEmpty, let source = next.layout(on: transfer.source),
                       spaces.isSubset(of: source.orderedSpaceIDs) { continue }
                }
            }
            if request.isUtility, !request.isParked, request.isOnActiveSpace == true,
               afterSpaceChange, observation == nil {
                next.utilitiesAwaitingLayout.insert(identity)
            }
            if request.isUtility, !request.isParked, !afterSpaceChange || observation != nil,
               let currentLayout = next.layout(on: request.displayUUID) {
                let visibleSpace = currentLayout.currentSpaceID
                let displayLayoutChanged = layoutChanged(on: request.displayUUID, to: next.layouts)
                let currentSpaceChanged = layout(on: request.displayUUID).map { $0.currentSpaceID != visibleSpace } == true
                let inventoryConfirms = request.isOnDesktop && (spaces?.contains(visibleSpace) == true ||
                    (!afterSpaceChange && !displayLayoutChanged))
                if request.isOnActiveSpace ?? inventoryConfirms {
                    if request.isOnActiveSpace == true, !currentSpaceChanged,
                       afterSpaceChange || next.utilitiesAwaitingLayout.contains(identity),
                       let spaces, !spaces.contains(visibleSpace),
                       spaces.intersection(currentLayout.orderedSpaceIDs).count == 1 {
                        next.utilitiesAwaitingLayout.insert(identity)
                        next.pendingUtilityMemberships[identity] = spaces
                    } else if next.pendingUtilityMemberships[identity] == nil || currentSpaceChanged ||
                                spaces?.contains(visibleSpace) == true {
                        next.lastVisibleUtilitySpaces[identity] = visibleSpace
                        if currentSpaceChanged || request.isOnActiveSpace != true {
                            next.utilitiesAwaitingLayout.remove(identity)
                        }
                        next.pendingUtilityMemberships.removeValue(forKey: identity)
                    }
                }
            }

            if request.isUtility, request.isParked, let previousSpace = next.lastVisibleUtilitySpaces[identity] {
                let displayRemoved = request.displayUUID.map { attachedDisplays?.contains($0) == false } ?? false
                let spaceRemoved = next.layout(on: request.displayUUID).map {
                    !$0.orderedSpaceIDs.contains(previousSpace)
                } ?? (displayRemoved && observation != nil &&
                    !next.layouts.values.contains { $0.orderedSpaceIDs.contains(previousSpace) })
                var delayedLayoutConfirmed = false
                if next.utilitiesAwaitingLayout.contains(identity), observation != nil,
                   let currentLayout = next.layout(on: request.displayUUID), let spaces,
                   !spaces.contains(previousSpace), spaces.intersection(currentLayout.orderedSpaceIDs).count == 1 {
                    delayedLayoutConfirmed = (currentLayout.currentSpaceID != previousSpace
                        && spaces.contains(currentLayout.currentSpaceID)) || next.pendingUtilityMemberships[identity] == spaces
                    next.pendingUtilityMemberships[identity] = spaces
                }
                if spaces?.contains(previousSpace) == true || spaceRemoved || delayedLayoutConfirmed {
                    next.lastVisibleUtilitySpaces.removeValue(forKey: identity)
                    next.utilitiesAwaitingLayout.remove(identity)
                    next.pendingUtilityMemberships.removeValue(forKey: identity)
                } else {
                    if next.memberships[identity]?.contains(previousSpace) != true {
                        next.memberships[identity] = [previousSpace]
                    }
                    next.unconfirmedMemberships.remove(identity)
                    continue
                }
            }

            if (request.isParked || next.requiresFreshMembership),
               !next.layouts.isEmpty, next.memberships[identity]?.isEmpty != false {
                next.unconfirmedMemberships.insert(identity)
            }
            guard let observation else { continue }
            let displayChanged = layoutChanged(on: request.displayUUID, to: observation.layouts)
            let unresolvedSpaceChange = afterSpaceChange &&
                (observation.layouts == layouts || layout(on: request.displayUUID) == nil ||
                    next.layout(on: request.displayUUID) == nil)
            if let spaces, !request.isParked || !spaces.isEmpty {
                next.memberships[identity] = spaces
                next.unconfirmedMemberships.remove(identity)
                next.retiredWindowNumbers.removeAll { $0 == identity.windowID }
            } else if (!request.isParked || next.memberships[identity]?.isEmpty != false),
                      displayChanged || unresolvedSpaceChange {
                next.memberships.removeValue(forKey: identity)
                next.unconfirmedMemberships.insert(identity)
            }
        }
        return next
    }

    private func reusesWindowNumber(_ identity: WindowSpaceIdentity) -> Bool {
        retiredWindowNumbers.contains(identity.windowID) || (requestedIdentities[identity.windowID]?.contains { prior in
            prior != identity && (!layouts.isEmpty || memberships[prior] != nil || unconfirmedMemberships.contains(prior))
        } ?? false)
    }

    private func layout(on displayUUID: String?) -> SpaceLayoutSnapshot? {
        if let displayUUID { return layouts[displayUUID] ?? layouts["Main"] }
        if let main = layouts["Main"] { return main }
        guard layouts.count == 1 else { return nil }
        return layouts.values.first
    }

    private func layoutChanged(on displayUUID: String?, to next: [String: SpaceLayoutSnapshot]) -> Bool {
        guard !layouts.isEmpty else { return false }
        guard let displayUUID else { return layouts != next }
        return (layouts[displayUUID] ?? layouts["Main"]) != (next[displayUUID] ?? next["Main"])
    }
}
