import AppKit
import Combine

@MainActor
final class TaskbarSpaceStore: ObservableObject {
    typealias Layouts = [String: SpaceLayoutSnapshot]
    typealias LayoutRead = @Sendable () -> Result<Layouts, SpaceReadFailure>
    typealias MembershipRead = @Sendable ([WindowSpaceRequest], Layouts, OperationCancellation)
        -> Result<SpaceMembershipRead, SpaceReadFailure>

    private enum LayoutTrigger: String {
        case start
        case explicitRefresh = "explicit-refresh"
        case activeSpace = "active-space-notification"
        case applicationActivated = "application-activated"
        case windowEvent = "window-event"
        case interfaceTopology = "display-topology"
        case windowInventory = "window-inventory"

        var corroboratesLayout: Bool {
            switch self {
            case .start, .activeSpace, .windowInventory: false
            case .explicitRefresh, .applicationActivated, .windowEvent, .interfaceTopology: true
            }
        }
    }

    private typealias MembershipSample = Result<(WindowSpaceSnapshot?, [SpaceReadFailure]), SpaceReadFailure>

    private struct TransferRead {
        let request: WindowSpaceRequest
        let batch: UInt64
    }

    @Published private(set) var activeLayouts: Layouts = [:]
    @Published private(set) var snapshot = WindowSpaceSnapshot()
    @Published private(set) var confirmedSpaceRevision: UInt64 = 0
    private let activeSpaceChange = PassthroughSubject<Void, Never>()
    private let desktopReturn = PassthroughSubject<Set<String>, Never>()
    var desktopReturns: AnyPublisher<Set<String>, Never> { desktopReturn.eraseToAnyPublisher() }
    var activeSpaceChanges: AnyPublisher<Void, Never> { activeSpaceChange.eraseToAnyPublisher() }
    var onCompatibilityFailure: ((String, String) -> Void)?

    private let readLayouts: LayoutRead?
    private let readMemberships: MembershipRead?
    private let readSnapshot: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)?
    private let notifications: NotificationCenter
    private let layoutQueue = DispatchQueue(label: "io.github.sashokey.deskmote.space-layout", qos: .userInitiated)
    private let membershipQueue = DispatchQueue(label: "io.github.sashokey.deskmote.window-spaces", qos: .utility)
    private let work = AsyncWorkScope()
    private var subscriptions = Set<AnyCancellable>()
    private var spaceObserver: NSObjectProtocol?
    private var requests: [WindowSpaceRequest] = []
    private var utilityOnActiveSpace: (WindowID) -> Bool? = { _ in nil }
    private var spaceRevision: UInt64 = 0
    private var minimumProjectionRevision: UInt64 = 0
    private var layoutRevision: UInt64 = 0
    private var verifiedHeightFallbackLayout: UInt64?
    private var membershipRevision: UInt64 = 0
    private var transferRevision: UInt64 = 0
    private var transferReads: [UInt64: Task<Void, Never>] = [:]
    private var activeTransfers: [WindowSpaceIdentity: TransferRead] = [:]
    private var pendingTransferEvents: Set<WindowSpaceIdentity> = []
    private var nextWindowRevision: UInt64 = 0
    private var windowRevisions: [WindowSpaceIdentity: UInt64] = [:]
    private var corroboratedSpaceRevision: UInt64?
    private var invalidatedDisplays: Set<String> = []
    private var layoutInFlight = false
    private var nextLayoutSource: LayoutTrigger?
    private var membershipInFlight = false
    private var pendingMemberships: Set<WindowSpaceIdentity> = []
    private var needsMembershipRead = false
    private var isRunning = false
    private var receivedInventory = false
    private var attachedDisplays: Set<String>?
    private var screenTopology: ScreenTopologySnapshot?
    private var reportedFailures = Set<String>()

    init(read: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)? = nil,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pollInterval _: TimeInterval = 0, readLayouts: LayoutRead? = nil, readMemberships: MembershipRead? = nil) {
        readSnapshot = read
        if let readLayouts { self.readLayouts = readLayouts }
        else if read == nil { self.readLayouts = { ManagedSpaceLayoutReader.read() } }
        else { self.readLayouts = nil }
        if let readMemberships { self.readMemberships = readMemberships }
        else if read == nil {
            self.readMemberships = { requests, layouts, cancellation in
                WindowSpaceObservation.readMemberships(requests, cancellation: cancellation)
            }
        } else { self.readMemberships = nil }
        self.notifications = notifications
    }

    func start(snapshots: AnyPublisher<DockSnapshot, Never>,
               utilityOnActiveSpace: @escaping (WindowID) -> Bool? = { _ in nil },
               windowInvalidations: AnyPublisher<CGWindowID, Never> = Empty().eraseToAnyPublisher()) {
        guard !isRunning else { return }
        isRunning = true
        self.utilityOnActiveSpace = utilityOnActiveSpace
        work.restart()
        publish(snapshot.clearingConfirmedTransfers())
        let generation = work.generation
        spaceObserver = notifications.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.work.isCurrent(generation) else { return }
                self.activeSpaceChanged()
            }
        }
        notifications.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.work.isCurrent(generation),
                      self.confirmedSpaceRevision != self.spaceRevision || self.activeLayouts.isEmpty else { return }
                self.requestLayout(source: .applicationActivated)
            }.store(in: &subscriptions)
        snapshots.receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self, self.work.isCurrent(generation) else { return }
            self.updateWindows(from: value)
        }.store(in: &subscriptions)
        windowInvalidations.receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self, self.work.isCurrent(generation) else { return }
            self.windowChanged(id)
        }.store(in: &subscriptions)
        requestLayout(source: .start)
    }

    func stop() {
        if isRunning {
            spaceRevision &+= 1
            minimumProjectionRevision = spaceRevision
        }
        isRunning = false
        verifiedHeightFallbackLayout = nil
        work.stop()
        if let spaceObserver { notifications.removeObserver(spaceObserver) }
        spaceObserver = nil
        subscriptions.removeAll()
        layoutInFlight = false
        nextLayoutSource = nil
        cancelTransfers()
        windowRevisions.removeAll()
        revokeHeightMemberships()
        membershipInFlight = false
        pendingMemberships.removeAll()
        needsMembershipRead = false
        receivedInventory = false
        utilityOnActiveSpace = { _ in nil }
        if !activeLayouts.isEmpty { activeLayouts = [:] }
    }

    func refresh() {
        guard isRunning else { return }
        membershipRevision &+= 1
        requestLayout(source: .explicitRefresh)
        if readLayouts != nil { requestMembership(Set(requests.map(\.identity))) }
    }

    func heightMembership(for identity: WindowSpaceIdentity, on displayUUID: String) -> HeightFallbackMembership {
        HeightFallbackMembership(confirmed: confirmedDesktopMembership(for: identity, on: displayUUID),
                                 revision: windowRevisions[identity])
    }

    func confirmedDesktopMembership(for identity: WindowSpaceIdentity, on displayUUID: String) -> Bool? {
        confirmedDesktopMembership(for: identity, on: displayUUID, sample: snapshot,
                                   confirmedRevision: confirmedSpaceRevision)
    }

    func confirmedDesktopMembership(for identity: WindowSpaceIdentity, on displayUUID: String,
                                    sample: WindowSpaceSnapshot, confirmedRevision: UInt64) -> Bool? {
        guard confirmedRevision == spaceRevision, confirmedRevision >= minimumProjectionRevision,
              let stamp = sample.heightMembershipStamps[identity], stamp.spaceRevision == spaceRevision,
              stamp.layoutRevision == layoutRevision, stamp.windowRevision == windowRevisions[identity],
              let layout = activeLayouts[displayUUID] ?? (activeLayouts.count == 1 ? activeLayouts["Main"] : nil),
              sample.permitsProjection(on: displayUUID) else { return nil }
        return sample.confirmedMembership(for: identity, on: displayUUID, active: layout)
    }

    private func revokeHeightMemberships() {
        var next = snapshot
        next.heightMembershipStamps.removeAll()
        publish(next)
    }

    private func recordHeightMemberships(
        _ relevant: WindowSpaceSnapshot, requested: [WindowSpaceRequest], windowRevision: UInt64,
        layoutRevision: UInt64, into next: inout WindowSpaceSnapshot
    ) {
        for request in requested where windowRevisions[request.identity] == windowRevision {
            next.heightMembershipStamps[request.identity] = nil
            guard !request.isParked, !request.isUtility, request.isOnDesktop, let display = request.displayUUID,
                  let layout = Self.effectiveLayout(for: request, in: relevant.layouts),
                  let row = relevant.memberships[request.identity], !row.isEmpty else { continue }
            next.heightMembershipStamps[request.identity] = HeightMembershipStamp(displayUUID: display,
                spaceRevision: spaceRevision, layoutRevision: layoutRevision, windowRevision: windowRevision,
                spaceID: layout.currentSpaceID, isMember: row.contains(layout.currentSpaceID))
        }
    }

    func canUseProjection(on displayUUID: String?, renderedSpaceRevision: UInt64) -> Bool {
        guard renderedSpaceRevision >= minimumProjectionRevision,
              confirmedSpaceRevision >= minimumProjectionRevision,
              snapshot.permitsProjection(on: displayUUID) else { return false }
        if readLayouts != nil {
            guard !activeLayouts.isEmpty, !snapshot.layouts.isEmpty,
                  requests.isEmpty || !snapshot.memberships.isEmpty else { return false }
            if let displayUUID {
                guard let active = activeLayouts[displayUUID] ?? activeLayouts["Main"],
                      active == (snapshot.layouts[displayUUID] ?? snapshot.layouts["Main"]) else { return false }
            } else if activeLayouts != snapshot.layouts { return false }
        }
        if renderedSpaceRevision == spaceRevision { return true }
        guard let displayUUID else { return invalidatedDisplays.isEmpty }
        return !invalidatedDisplays.contains(displayUUID) && !invalidatedDisplays.contains("Main")
    }

    var heightFallbackLayoutEpoch: UInt64? {
        guard isRunning, verifiedHeightFallbackLayout == layoutRevision else { return nil }
        return verifiedHeightFallbackLayout
    }

    func heightFallbackDesktop(on display: String) -> Int? {
        guard heightFallbackLayoutEpoch != nil, attachedDisplays?.contains(display) != false,
              let layout = activeLayouts[display] ?? (activeLayouts.count == 1 ? activeLayouts["Main"] : nil),
              layout.orderedSpaceIDs.contains(layout.currentSpaceID),
              !layout.fullscreenSpaceIDs.contains(layout.currentSpaceID) else { return nil }
        return layout.currentSpaceID
    }

    private func activeSpaceChanged() {
        invalidatedDisplays = Set(snapshot.layouts.keys)
        spaceRevision &+= 1
        layoutRevision &+= 1
        membershipRevision &+= 1
        cancelTransfers()
        activeSpaceChange.send()
        revokeHeightMemberships()
        publish(snapshot.recordingSpaceChange(requests: liveUtilityRequests(requests)))
        requestLayout(source: .activeSpace)
    }

    func updateTopology(_ snapshot: ScreenTopologySnapshot) {
        guard screenTopology != snapshot else { return }
        screenTopology = snapshot
        layoutRevision &+= 1
        membershipRevision &+= 1
        cancelTransfers()
        revokeHeightMemberships()
        publish(self.snapshot.clearingConfirmedTransfers())
        let identifiers = Set(snapshot.identifiedDisplayUUIDs)
        attachedDisplays = snapshot.physicalDisplayCount > 0 &&
            identifiers.count == snapshot.physicalDisplayCount ? identifiers : nil
        requestLayout(source: .interfaceTopology)
    }

    private func updateWindows(from source: DockSnapshot) {
        let next = StripItem.openWindows(from: source).compactMap { item -> WindowSpaceRequest? in
            guard let identity = item.spaceIdentity else { return nil }
            let isUtility = switch item.source {
            case .utility: true
            case .external: false
            }
            return WindowSpaceRequest(identity: identity,
                isParked: item.status == WindowStatus.minimized.rawValue || item.status == WindowStatus.hidden.rawValue,
                isOnDesktop: item.isOnDesktop, displayUUID: item.displayUUID, isUtility: isUtility)
        }
        guard !receivedInventory || next != requests else { return }
        let previous = Dictionary(requests.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(next.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let changedRequests = next.filter { previous[$0.identity] != $0 }
        windowRevisions = windowRevisions.filter { current[$0.key] != nil }
        revise(changedRequests.map(\.identity))
        discardTransfers { current[$0.identity] != $0 }
        receivedInventory = true
        requests = next
        let updated = snapshot.updating(with: nil, requests: liveUtilityRequests(next),
                                        afterSpaceChange: confirmedSpaceRevision != spaceRevision)
        publish(updated)
        let transfers = updated.transfers(in: next, attachedDisplays: attachedDisplays)
        requestTransfers(transfers)
        let transferring = Set(transfers.map(\.identity))
        let changed = changedRequests.filter { !transferring.contains($0.identity) }
        if readLayouts == nil {
            if !changed.isEmpty || !needsMembershipRead && snapshot.layouts.isEmpty && transfers.isEmpty {
                requestMembership(Set(next.lazy.map(\.identity).filter { !transferring.contains($0) }))
            } else {
                beginMembership()
            }
        } else {
            if activeLayouts.isEmpty && !layoutInFlight || confirmedSpaceRevision != spaceRevision {
                requestLayout(source: .windowInventory)
            }
            if !changed.isEmpty { requestMembership(Set(changed.map(\.identity))) }
            beginMembership()
        }
    }

    private func windowChanged(_ id: CGWindowID) {
        if confirmedSpaceRevision != spaceRevision || activeLayouts.isEmpty { requestLayout(source: .windowEvent) }
        let matching = requests.filter { $0.identity.windowID == id }
        var next = snapshot
        for request in matching {
            next.heightMembershipStamps[request.identity] = nil
        }
        revise(matching.map(\.identity))
        publish(next)
        refreshExactMemberships(matching)
    }

    private func refreshExactMemberships(_ matching: [WindowSpaceRequest]) {
        let transfers = snapshot.transfers(in: matching, attachedDisplays: attachedDisplays)
        pendingTransferEvents.formUnion(transfers.lazy.map(\.identity).filter { self.activeTransfers[$0] != nil })
        requestTransfers(transfers)
        let transferring = Set(transfers.map(\.identity))
        let ordinary = Set(matching.lazy.map(\.identity).filter { !transferring.contains($0) })
        if !ordinary.isEmpty { requestMembership(ordinary) }
    }

    private func revise(_ identities: [WindowSpaceIdentity]) {
        guard !identities.isEmpty else { return }
        nextWindowRevision &+= 1
        for identity in identities { windowRevisions[identity] = nextWindowRevision }
    }

    private func beginWindowRead(_ requested: [WindowSpaceRequest]) -> UInt64 {
        revise(requested.map(\.identity))
        var next = snapshot
        for request in requested { next.heightMembershipStamps[request.identity] = nil }
        publish(next)
        return nextWindowRevision
    }

    private func currentIdentities(_ sampled: [WindowSpaceRequest], windowRevision: UInt64) -> Set<WindowSpaceIdentity> {
        let current = Dictionary(requests.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(sampled.lazy.filter {
            current[$0.identity] == $0 && self.windowRevisions[$0.identity] == windowRevision
        }.map(\.identity))
    }

    private nonisolated static func sampleMemberships(_ requested: [WindowSpaceRequest], layouts: Layouts,
        cancellation: OperationCancellation, readMemberships: MembershipRead?,
        readSnapshot: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)?) -> MembershipSample {
        if let readMemberships {
            return readMemberships(requested, layouts, cancellation).map {
                (WindowSpaceSnapshot(layouts: layouts, memberships: $0.memberships), $0.failures)
            }
        }
        return .success((readSnapshot?(requested), []))
    }

    private func acceptSample(_ sample: MembershipSample?, source: String) -> WindowSpaceSnapshot? {
        guard let sample else { return nil }
        switch sample {
        case let .failure(failure):
            report(failure, source: source, reportToUser: true)
            return nil
        case let .success((observation, failures)):
            for failure in failures {
                let incompatible: Bool
                switch failure.reason {
                case .libraryUnavailable, .symbolUnavailable, .connectionUnavailable, .invalidType, .untestedSystemVersion:
                    incompatible = true
                default: incompatible = false
                }
                report(failure, source: source, reportToUser: incompatible)
            }
            return observation
        }
    }

    private func cancelTransfers() {
        transferReads.values.forEach { $0.cancel() }
        transferReads.removeAll()
        activeTransfers.removeAll()
        pendingTransferEvents.removeAll()
    }

    private func discardTransfers(where invalid: (WindowSpaceRequest) -> Bool) {
        let obsolete = activeTransfers.filter { invalid($0.value.request) }
        guard !obsolete.isEmpty else { return }
        for identity in obsolete.keys {
            activeTransfers.removeValue(forKey: identity)
            pendingTransferEvents.remove(identity)
        }
        let remaining = Set(activeTransfers.values.map(\.batch))
        for batch in Set(obsolete.values.map(\.batch)).subtracting(remaining) {
            transferReads.removeValue(forKey: batch)?.cancel()
        }
    }

    private func requestTransfers(_ candidates: [WindowSpaceRequest]) {
        guard confirmedSpaceRevision == spaceRevision, readLayouts == nil || !activeLayouts.isEmpty else { return }
        let transfers = candidates.filter { activeTransfers[$0.identity] == nil }
        guard !transfers.isEmpty else { return }
        transferRevision &+= 1
        let batch = transferRevision
        for request in transfers { activeTransfers[request.identity] = .init(request: request, batch: batch) }
        let windowRevision = beginWindowRead(transfers)
        let layouts = activeLayouts
        let requestedLayout = layoutRevision
        let readMemberships = readMemberships
        let readSnapshot = readSnapshot
        let cancellation = OperationCancellation()
        transferReads[batch] = work.launch(priority: .userInitiated) { [weak self] generation in
            let sample = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                Self.sampleMemberships(transfers, layouts: layouts, cancellation: cancellation,
                                       readMemberships: readMemberships, readSnapshot: readSnapshot)
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.transferReads.removeValue(forKey: batch) != nil else { return }
                let completed = transfers.filter { self.activeTransfers[$0.identity]?.batch == batch }
                let identities = Set(completed.map(\.identity))
                for identity in identities { self.activeTransfers.removeValue(forKey: identity) }
                let deferred = self.pendingTransferEvents.intersection(identities)
                self.pendingTransferEvents.subtract(deferred)
                defer {
                    if !deferred.isEmpty {
                        self.refreshExactMemberships(self.requests.filter { deferred.contains($0.identity) })
                    }
                }
                guard let observation = self.acceptSample(sample, source: "display-transfer") else { return }
                let current = self.currentIdentities(completed, windowRevision: windowRevision)
                let liveLayouts = self.activeLayouts.isEmpty ? observation.layouts : self.activeLayouts
                let eligible = self.snapshot.transfers(in: completed.filter {
                    current.contains($0.identity) &&
                        Self.effectiveLayout(for: $0, in: liveLayouts) == Self.effectiveLayout(for: $0, in: observation.layouts)
                }, attachedDisplays: self.attachedDisplays)
                guard !eligible.isEmpty else { return }
                let accepted = Set(eligible.map(\.identity))
                let relevant = WindowSpaceSnapshot(layouts: liveLayouts,
                    memberships: observation.memberships.filter { accepted.contains($0.key) })
                if self.readLayouts == nil { self.acceptLayouts(liveLayouts) }
                var updated = self.snapshot.updating(with: relevant, requests: self.liveUtilityRequests(self.requests),
                    afterSpaceChange: self.readLayouts != nil && self.snapshot.layouts.isEmpty,
                    attachedDisplays: self.attachedDisplays, targetedTransferRead: true)
                if self.layoutRevision == requestedLayout {
                    self.recordHeightMemberships(relevant, requested: eligible, windowRevision: windowRevision,
                                                 layoutRevision: requestedLayout, into: &updated)
                }
                self.publish(updated)
            }
        }
    }

    private static func effectiveLayout(for request: WindowSpaceRequest, in layouts: Layouts) -> SpaceLayoutSnapshot? {
        request.displayUUID.flatMap { layouts[$0] } ?? layouts["Main"]
    }

    private func requestLayout(source: LayoutTrigger) {
        guard isRunning else { return }
        guard let readLayouts else {
            requestMembership(Set(requests.map(\.identity)))
            return
        }
        if layoutInFlight {
            if nextLayoutSource?.corroboratesLayout != true || source.corroboratesLayout {
                nextLayoutSource = source
            }
            return
        }
        layoutInFlight = true
        let requestedRevision = layoutRevision
        let queue = layoutQueue
        work.launch(priority: .userInitiated) { [weak self] generation in
            let result = await AsyncWorkScope.performBlocking(on: queue) {
                readLayouts()
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.isRunning else { return }
                self.layoutInFlight = false
                if requestedRevision == self.layoutRevision, let result {
                    self.applyLayoutResult(result, source: source)
                }
                if let pending = self.nextLayoutSource {
                    self.nextLayoutSource = nil
                    self.requestLayout(source: pending)
                }
            }
        }
    }

    private func applyLayoutResult(_ result: Result<Layouts, SpaceReadFailure>, source: LayoutTrigger) {
        switch result {
        case let .failure(failure):
            verifiedHeightFallbackLayout = nil
            if !activeLayouts.isEmpty {
                spaceRevision &+= 1
                minimumProjectionRevision = spaceRevision
                membershipRevision &+= 1
                invalidatedDisplays = Set(snapshot.layouts.keys)
                cancelTransfers()
                activeSpaceChange.send()
                revokeHeightMemberships()
                activeLayouts = [:]
            }
            report(failure, source: source.rawValue, reportToUser: true)
        case let .success(layouts):
            let prior = activeLayouts
            if source.corroboratesLayout {
                corroboratedSpaceRevision = spaceRevision
            }
            let changed = Set(prior.keys).union(layouts.keys).filter { prior[$0] != layouts[$0] }
            if !layouts.isEmpty && (!changed.isEmpty || source.corroboratesLayout) {
                verifiedHeightFallbackLayout = layoutRevision
            }
            if !changed.isEmpty {
                membershipRevision &+= 1
                if !prior.isEmpty {
                    discardTransfers { Self.effectiveLayout(for: $0, in: prior) != Self.effectiveLayout(for: $0, in: layouts) }
                }
                if confirmedSpaceRevision != spaceRevision, confirmedSpaceRevision >= minimumProjectionRevision {
                    invalidatedDisplays = changed
                }
                acceptLayouts(layouts)
            }
            if !changed.isEmpty || confirmedSpaceRevision != spaceRevision {
                let relevant = requests.filter { request in
                    request.displayUUID.map { changed.isEmpty || changed.contains($0) || changed.contains("Main") } ?? true
                }
                requestMembership(Set(relevant.map(\.identity)))
            }
            requestTransfers(snapshot.transfers(in: requests, attachedDisplays: attachedDisplays))
            if needsMembershipRead { beginMembership() }
        }
    }

    private func acceptLayouts(_ layouts: Layouts) {
        let prior = activeLayouts
        guard prior != layouts else { return }
        var next = snapshot
        for request in requests where Self.effectiveLayout(for: request, in: prior)
            != Self.effectiveLayout(for: request, in: layouts) {
            next.heightMembershipStamps[request.identity] = nil
        }
        publish(next)
        activeLayouts = layouts
        let returned = Set(layouts.compactMap { display, current in
            guard let previous = prior[display], previous.fullscreenSpaceIDs.contains(previous.currentSpaceID),
                  !current.fullscreenSpaceIDs.contains(current.currentSpaceID) else { return nil as String? }
            return display
        })
        if !returned.isEmpty { desktopReturn.send(returned) }
    }

    private func requestMembership(_ identities: Set<WindowSpaceIdentity>) {
        guard isRunning else { return }
        pendingMemberships.formUnion(identities)
        needsMembershipRead = true
        beginMembership()
    }

    private func beginMembership() {
        guard needsMembershipRead, !membershipInFlight, receivedInventory,
              readLayouts == nil || !activeLayouts.isEmpty else { return }
        membershipInFlight = true
        needsMembershipRead = false
        let requested = requests.filter { pendingMemberships.contains($0.identity) && activeTransfers[$0.identity] == nil }
        let windowRevision = beginWindowRead(requested)
        let expectedLayouts = activeLayouts
        let requestedRevision = membershipRevision
        let requestedLayout = layoutRevision
        let eventRevision = spaceRevision
        let readMemberships = readMemberships
        let readSnapshot = readSnapshot
        let queue = membershipQueue
        pendingMemberships.removeAll()
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let sampled = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                Self.sampleMemberships(requested, layouts: expectedLayouts, cancellation: cancellation,
                                       readMemberships: readMemberships, readSnapshot: readSnapshot)
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.isRunning else { return }
                self.membershipInFlight = false
                if self.membershipRevision == requestedRevision {
                    let observation = self.acceptSample(sampled, source: "window-membership")
                    self.applyMembership(observation, requested: requested, windowRevision: windowRevision,
                                         eventRevision: eventRevision, requestedLayout: requestedLayout)
                } else {
                    self.pendingMemberships.formUnion(requested.lazy.map(\.identity))
                    self.needsMembershipRead = true
                }
                self.beginMembership()
            }
        }
    }

    private func applyMembership(_ observation: WindowSpaceSnapshot?, requested: [WindowSpaceRequest], windowRevision: UInt64,
                                 eventRevision: UInt64, requestedLayout: UInt64) {
        guard let observation, !observation.layouts.isEmpty else { return }
        let changed = confirmedSpaceRevision != eventRevision
        let priorLayouts = snapshot.layouts
        if changed, invalidatedDisplays.isEmpty { invalidatedDisplays = Set(observation.layouts.keys) }
        let unchangedWithoutEvidence = changed && observation.layouts == priorLayouts &&
            confirmedSpaceRevision >= minimumProjectionRevision && corroboratedSpaceRevision != eventRevision
        let stillCurrent = currentIdentities(requested, windowRevision: windowRevision).subtracting(pendingMemberships)
        let relevant = WindowSpaceSnapshot(layouts: observation.layouts,
            memberships: observation.memberships.filter { stillCurrent.contains($0.key) })
        if readLayouts == nil {
            if !unchangedWithoutEvidence, requestedLayout == layoutRevision, eventRevision == spaceRevision {
                verifiedHeightFallbackLayout = requestedLayout
            }
            acceptLayouts(observation.layouts)
        }
        var updated = snapshot.updating(with: relevant, requests: liveUtilityRequests(requests),
            afterSpaceChange: changed || (readLayouts != nil && priorLayouts.isEmpty), attachedDisplays: attachedDisplays)
        if requestedLayout == layoutRevision && eventRevision == spaceRevision {
            recordHeightMemberships(relevant, requested: requested.filter { stillCurrent.contains($0.identity) },
                                    windowRevision: windowRevision, layoutRevision: requestedLayout, into: &updated)
        }
        publish(updated)
        if changed && !unchangedWithoutEvidence { confirmedSpaceRevision = eventRevision }
    }

    private func report(_ failure: SpaceReadFailure, source: String, reportToUser: Bool) {
        guard !failure.isInterruption else {
            return
        }
        let detail = failure.description
        let code = failure.diagnosticCode
        if reportToUser, reportedFailures.insert(code).inserted {
            onCompatibilityFailure?(code, "\(detail) [\(source), revision=\(spaceRevision)]")
        }
    }

    private func liveUtilityRequests(_ requests: [WindowSpaceRequest]) -> [WindowSpaceRequest] {
        requests.map { request in
            guard request.isUtility, !request.isParked else { return request }
            return WindowSpaceRequest(identity: request.identity, isParked: false, isOnDesktop: request.isOnDesktop,
                displayUUID: request.displayUUID, isUtility: true,
                isOnActiveSpace: utilityOnActiveSpace(request.identity.actionIdentity.windowID))
        }
    }

    private func publish(_ next: WindowSpaceSnapshot) {
        guard snapshot != next else { return }
        snapshot = next
    }

    #if DESKMOTE_TEST
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    isolated deinit { stop() }
}
