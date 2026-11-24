import AppKit
import Combine

@MainActor
final class TaskbarSpaceStore: ObservableObject {
    @Published private(set) var snapshot = WindowSpaceSnapshot()
    @Published private(set) var confirmedSpaceRevision: UInt64 = 0
    private let activeSpaceChange = PassthroughSubject<Void, Never>()
    var activeSpaceChanges: AnyPublisher<Void, Never> { activeSpaceChange.eraseToAnyPublisher() }
    private let read: @Sendable ([WindowSpaceRequest], OperationCancellation) -> WindowSpaceSnapshot?
    private let readTransfers: @Sendable ([WindowSpaceRequest], OperationCancellation) -> WindowSpaceSnapshot?
    private let notifications: NotificationCenter
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.sashokey.deskmote.window-spaces", qos: .utility)
    private let work = AsyncWorkScope()
    private var subscriptions = Set<AnyCancellable>()
    private var spaceObserver: NSObjectProtocol?
    private var timer: Timer?
    private var requests: [WindowSpaceRequest] = []
    private var utilityOnActiveSpace: (WindowID) -> Bool? = { _ in nil }
    private var revision: UInt64 = 0
    private var spaceRevision: UInt64 = 0
    private var minimumProjectionRevision: UInt64 = 0
    private var invalidatedDisplays: Set<String> = []
    private var inFlight = false
    private var needsRefresh = false
    private var isRunning = false
    private var receivedInventory = false
    private var unchangedLayoutDeadline: ContinuousClock.Instant?
    private var attachedDisplays: Set<String>?
    private var screenTopology: ScreenTopologySnapshot?
    private var transferRead: Task<Void, Never>?

    init(read: (@Sendable ([WindowSpaceRequest]) -> WindowSpaceSnapshot?)? = nil,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pollInterval: TimeInterval = 5) {
        self.read = { requests, cancellation in
            if let read { return read(requests) }
            return WindowSpaceObservation.capture(requests, cancellation: cancellation, mode: .live)
        }
        self.readTransfers = { requests, cancellation in
            if let read { return read(requests) }
            return WindowSpaceObservation.capture(requests, cancellation: cancellation, maximumDuration: 0.2)
        }
        self.notifications = notifications
        self.pollInterval = pollInterval
    }

    func start(snapshots: AnyPublisher<DockSnapshot, Never>,
               utilityOnActiveSpace: @escaping (WindowID) -> Bool? = { _ in nil }) {
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
                guard let self, self.work.isCurrent(generation) else { return }
                self.refresh()
            }.store(in: &subscriptions)
        snapshots.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.work.isCurrent(generation) else { return }
            self.updateWindows(from: $0)
        }.store(in: &subscriptions)
        if pollInterval > 0 {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            timer.tolerance = min(0.5, pollInterval / 10)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        if isRunning {
            spaceRevision &+= 1
            minimumProjectionRevision = spaceRevision
            unchangedLayoutDeadline = nil
        }
        isRunning = false
        work.stop()
        transferRead = nil
        if let spaceObserver { notifications.removeObserver(spaceObserver) }
        spaceObserver = nil
        subscriptions.removeAll()
        timer?.invalidate()
        timer = nil
        inFlight = false
        needsRefresh = false
        receivedInventory = false
        utilityOnActiveSpace = { _ in nil }
    }

    func refresh() {
        guard isRunning else { return }
        revision &+= 1
        if inFlight { needsRefresh = true; return }
        beginRead()
    }

    func canUseProjection(on displayUUID: String?, renderedSpaceRevision: UInt64) -> Bool {
        guard renderedSpaceRevision >= minimumProjectionRevision,
              confirmedSpaceRevision >= minimumProjectionRevision,
              snapshot.permitsProjection(on: displayUUID) else { return false }
        if renderedSpaceRevision == spaceRevision { return true }
        guard let displayUUID else { return invalidatedDisplays.isEmpty }
        return !invalidatedDisplays.contains(displayUUID) && !invalidatedDisplays.contains("Main")
    }

    private func activeSpaceChanged() {
        transferRead?.cancel()
        invalidatedDisplays = Set(snapshot.layouts.keys)
        spaceRevision &+= 1
        unchangedLayoutDeadline = nil
        activeSpaceChange.send()
        publish(snapshot.recordingSpaceChange(requests: liveUtilityRequests(requests)))
        refresh()
    }

    func updateTopology(_ snapshot: ScreenTopologySnapshot) {
        if screenTopology != snapshot {
            screenTopology = snapshot
            publish(self.snapshot.clearingConfirmedTransfers())
        }
        let identifiers = Set(snapshot.identifiedDisplayUUIDs)
        attachedDisplays = snapshot.physicalDisplayCount > 0 &&
            identifiers.count == snapshot.physicalDisplayCount ? identifiers : nil
        beginTransferRead(self.snapshot.transfers(in: requests, attachedDisplays: attachedDisplays))
        refresh()
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
        let previous = requests
        let hadInventory = receivedInventory
        let oldTransfers = hadInventory ? snapshot.transfers(in: previous, attachedDisplays: attachedDisplays) : []
        receivedInventory = true
        requests = next
        let updated = snapshot.updating(with: nil, requests: liveUtilityRequests(next),
                                        afterSpaceChange: confirmedSpaceRevision != spaceRevision)
        publish(updated)
        let transfers = updated.transfers(in: next, attachedDisplays: attachedDisplays)
        if transfers != oldTransfers {
            beginTransferRead(transfers)
            let moved = Set(transfers.filter { !oldTransfers.contains($0) }.map(\.identity))
            if hadInventory, !inFlight, !updated.layouts.isEmpty, confirmedSpaceRevision == spaceRevision, !moved.isEmpty,
               previous.filter({ !moved.contains($0.identity) }) == next.filter({ !moved.contains($0.identity) }) {
                return
            }
        }
        refresh()
    }

    private func beginTransferRead(_ requests: [WindowSpaceRequest]) {
        transferRead?.cancel()
        transferRead = nil
        guard !requests.isEmpty, confirmedSpaceRevision == spaceRevision else { return }
        let spaceRevision = spaceRevision
        let startingLayouts = snapshot.layouts
        let read = readTransfers
        transferRead = work.launch(priority: .userInitiated) { [weak self] generation in
            var outstanding = requests
            var layouts = startingLayouts
            for delay in [Duration.zero, .milliseconds(80), .milliseconds(160)] {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) }
                    catch { return }
                }
                let pending = outstanding
                let expectedLayouts = layouts
                let cancellation = OperationCancellation()
                let observation = await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                    read(pending, cancellation)
                } ?? nil
                let next = await MainActor.run { [weak self] () -> ([WindowSpaceRequest], [String: SpaceLayoutSnapshot])? in
                    guard let self, !Task.isCancelled, self.work.isCurrent(generation),
                          self.spaceRevision == spaceRevision, self.snapshot.layouts == expectedLayouts else { return nil }
                    let pending = self.snapshot.transfers(in: pending)
                    guard !pending.isEmpty, let observation else { return (pending, expectedLayouts) }
                    guard observation.layouts == expectedLayouts || expectedLayouts.isEmpty else {
                        self.refresh()
                        return nil
                    }
                    let updated = self.snapshot.updating(with: observation, requests: self.liveUtilityRequests(self.requests),
                                                         attachedDisplays: self.attachedDisplays, targetedTransferRead: true)
                    let remaining = updated.transfers(in: pending)
                    if remaining != pending {
                        if self.inFlight { self.refresh() }
                        self.publish(updated)
                        return (remaining, updated.layouts)
                    }
                    return (remaining, expectedLayouts)
                }
                guard let next, !next.0.isEmpty else { return }
                (outstanding, layouts) = next
            }
        }
    }

    private func beginRead() {
        inFlight = true
        let requests = requests
        let revision = revision
        let read = read
        let queue = queue
        work.launch { [weak self] generation in
            let cancellation = OperationCancellation()
            let observation = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                read(requests, cancellation)
            } ?? nil
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.isRunning else { return }
                self.inFlight = false
                if self.revision == revision {
                    let spaceRevision = self.spaceRevision
                    self.applyRead(observation, requests: requests, spaceRevision: spaceRevision)
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.beginRead()
                }
            }
        }
    }

    private func applyRead(_ observation: WindowSpaceSnapshot?, requests: [WindowSpaceRequest], spaceRevision: UInt64) {
        let changed = confirmedSpaceRevision != spaceRevision
        let priorLayouts = snapshot.layouts
        if changed, let observation, !observation.layouts.isEmpty, observation.layouts == snapshot.layouts {
            if let deadline = unchangedLayoutDeadline {
                guard ContinuousClock.now >= deadline else { return }
            } else {
                let deadline = ContinuousClock.now + .milliseconds(150)
                unchangedLayoutDeadline = deadline
                work.launch { [weak self] generation in
                    try? await ContinuousClock().sleep(until: deadline)
                    await MainActor.run { [weak self] in
                        guard let self, self.work.isCurrent(generation), self.spaceRevision == spaceRevision,
                              self.confirmedSpaceRevision != spaceRevision else { return }
                        self.refresh()
                    }
                }
                return
            }
        }
        if changed, invalidatedDisplays.isEmpty, let observation {
            invalidatedDisplays = Set(observation.layouts.keys)
        }
        publish(snapshot.updating(with: observation, requests: liveUtilityRequests(requests),
                                   afterSpaceChange: changed, attachedDisplays: attachedDisplays))
        if changed, let observation, !observation.layouts.isEmpty {
            confirmedSpaceRevision = spaceRevision
        }
        if priorLayouts != snapshot.layouts || (changed && confirmedSpaceRevision == spaceRevision) {
            beginTransferRead(snapshot.transfers(in: requests, attachedDisplays: attachedDisplays))
        }
    }

    private func liveUtilityRequests(_ requests: [WindowSpaceRequest]) -> [WindowSpaceRequest] {
        requests.map { request in
            guard request.isUtility, !request.isParked else { return request }
            let visible = utilityOnActiveSpace(request.identity.actionIdentity.windowID)
            return WindowSpaceRequest(identity: request.identity, isParked: false, isOnDesktop: request.isOnDesktop,
                                      displayUUID: request.displayUUID, isUtility: true, isOnActiveSpace: visible)
        }
    }

    private func publish(_ next: WindowSpaceSnapshot) {
        if snapshot != next { snapshot = next }
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    isolated deinit { stop() }
}
