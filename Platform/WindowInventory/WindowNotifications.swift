import ApplicationServices
import Foundation
import Synchronization

@MainActor
final class AppWindowObserver {
    typealias Factory = @Sendable (pid_t, @escaping @Sendable (AXElementKey, String) -> Void) -> (any WindowObservationSession)?
    let pid: pid_t
    private var session: (any WindowObservationSession)?
    private struct CleanupRequest: Sendable {
        let element: AXElementKey
        var items = WindowSubscriptionItem.allCases
        var retriesRemaining = 2
        var queued = true
    }

    private final class CleanupSession: Sendable {
        let session: any WindowObservationSession
        let cancellation = OperationCancellation()
        let pending = Mutex<[UUID: CleanupRequest]>([:])

        init(session: any WindowObservationSession) { self.session = session }

        func stop() {
            cancellation.cancel()
            pending.withLock { $0.removeAll() }
        }
    }
    private var cleanupSession: CleanupSession?
    private let accessibilityAccess: RuntimeAccessibilityAccess
    private let makeSession: Factory
    private let queue = DispatchQueue(label: "io.github.sashokey.deskmote.window-subscriptions", qos: .utility)
    private let work = AsyncWorkScope()
    private var isRunning = false
    private var isStarting = false
    private var applicationItems: [String: WindowSubscriptionItemState] = [:]
    private var applicationRetryAt: TimeInterval = 0
    private var applicationRetryStep = 0
    private var movementAttempts = 0
    private var waitingWindows: [CGWindowID: AXElementKey] = [:]
    private struct RegistrationWork {
        let id = UUID()
        let cancellation = OperationCancellation()
        var task: Task<Void, Never>?
    }
    private var inFlight: [AXElementKey: RegistrationWork] = [:]
    private var subscriptions = WindowSubscriptionLedger<AXElementKey>(instanceIDs: AppWindowObserver.instanceIDs)
    private static let instanceIDs = WindowSubscriptionInstanceIDs()
    private let clock: @Sendable () -> TimeInterval

    var isActive: Bool {
        session != nil && Self.applicationNotifications.allSatisfy { applicationItems[$0] == .done }
    }
    private var canReceiveWindowCreated: Bool {
        session != nil && applicationItems[kAXWindowCreatedNotification] == .done
    }
    var onWindowCreationReady: ((pid_t) -> Void)?
    var onWindowCreated: ((pid_t, AXElementKey) -> Void)?
    var onWindowDestroyed: ((pid_t, CGWindowID, AXUIElement) -> Void)?
    var onWindowMinimized: ((pid_t, CGWindowID) -> Void)?
    var onWindowDeminiaturized: ((pid_t, CGWindowID) -> Void)?
    var onFocusedWindowChanged: ((pid_t) -> Void)?
    var onTitleChanged: ((pid_t, CGWindowID) -> Void)?
    var onWindowMoved: ((pid_t, CGWindowID, AXElementKey) -> Void)?
    #if DESKMOTE_TEST
    var onSubscriptionAttempt: ((CGWindowID, Bool) -> Void)?
    #endif

    enum Registration {
        case none
        case scheduled
        case retryDue(WindowSubscriptionRetryCandidate<AXElementKey>)
    }

    nonisolated static let retryTimeLimit: TimeInterval = 0.05
    private static let applicationNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification
    ]
    private static let geometryNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification]

    init(pid: pid_t, accessibilityAccess: RuntimeAccessibilityAccess = .shared,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeSession: @escaping Factory = { AXWindowObservationSession(pid: $0, receive: $1) }) {
        self.pid = pid
        self.accessibilityAccess = accessibilityAccess
        self.clock = clock
        self.makeSession = makeSession
    }

    isolated deinit { stop() }

    private struct ApplicationAttemptResult: Sendable {
        let session: (any WindowObservationSession)?
        let results: [String: AXError]
    }

    private var pendingApplicationNotifications: [String] {
        var names = Self.applicationNotifications
        if movementAttempts < 3 { names.append(contentsOf: Self.geometryNotifications) }
        return names.filter { applicationItems[$0] != .done && applicationItems[$0] != .unsupported }
    }

    func start() {
        let access = accessibilityAccess
        let axGeneration = access.trustGeneration
        guard access.acceptsResult(for: axGeneration) else { return }
        if !isRunning {
            isRunning = true
            work.restart()
        }
        retryPendingRemovals()
        guard !isStarting, clock() >= applicationRetryAt else { return }
        let notifications = pendingApplicationNotifications
        guard session == nil || !notifications.isEmpty else { return }
        let geometry = notifications.filter { Self.geometryNotifications.contains($0) }
        let required = notifications.filter { !Self.geometryNotifications.contains($0) }
        isStarting = true
        let currentSession = session
        let makeSession = makeSession
        let pid = pid
        let queue = queue
        let generation = work.generation
        let receive: @Sendable (AXElementKey, String) -> Void = { [weak self] element, name in
            Task { @MainActor [weak self] in
                guard let self, self.work.isCurrent(generation), access.acceptsResult(for: axGeneration) else { return }
                self.handleNotification(element: element.e, notification: name)
            }
        }
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let created = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                let session = currentSession ?? makeSession(pid, receive)
                var results: [String: AXError] = [:]
                for notification in required {
                    guard !cancellation.isCancelled, access.acceptsResult(for: axGeneration) else { break }
                    if let session { results[notification] = session.add(notification, element: nil) }
                }
                return ApplicationAttemptResult(session: session, results: results)
            }
            let pendingRegistrations = await MainActor.run { [weak self] () -> [Task<Void, Never>] in
                guard let self, self.work.isCurrent(generation), access.acceptsResult(for: axGeneration),
                      let created else { return [] }
                let wasReady = self.canReceiveWindowCreated
                for (notification, result) in created.results {
                    self.recordApplicationRegistration(notification, result: result)
                }
                if let session = created.session, self.session == nil {
                    self.session = session
                    self.cleanupSession = CleanupSession(session: session)
                    session.attach()
                    guard access.acceptsResult(for: axGeneration) else {
                        self.stop()
                        return []
                    }
                    let windows = self.waitingWindows
                    self.waitingWindows.removeAll()
                    for (id, key) in windows { _ = self.registerWindow(key.e, cgWindowID: id) }
                }
                if !wasReady, self.canReceiveWindowCreated { self.onWindowCreationReady?(pid) }
                return geometry.isEmpty ? [] : self.inFlight.values.compactMap(\.task)
            }
            let geometryResults: [String: AXError]
            if !geometry.isEmpty, let session = created?.session {
                for task in pendingRegistrations {
                    if Task.isCancelled { return }
                    await task.value
                }
                guard !Task.isCancelled else { return }
                geometryResults = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                    var results: [String: AXError] = [:]
                    for notification in geometry {
                        guard !cancellation.isCancelled, access.acceptsResult(for: axGeneration) else { break }
                        results[notification] = session.add(notification, element: nil)
                    }
                    return results
                } ?? [:]
            } else {
                geometryResults = [:]
            }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.isStarting = false
                guard access.acceptsResult(for: axGeneration) else { return }
                if !geometryResults.isEmpty {
                    self.movementAttempts += 1
                    for (notification, result) in geometryResults {
                        self.recordApplicationRegistration(notification, result: result)
                    }
                }
                let needsRetry = self.session == nil || !self.pendingApplicationNotifications.isEmpty
                if needsRetry {
                    let delays = WindowSubscriptionLedger<AXElementKey>.backoff
                    self.applicationRetryAt = self.clock() + delays[min(self.applicationRetryStep, delays.count - 1)]
                    self.applicationRetryStep = min(self.applicationRetryStep + 1, delays.count - 1)
                } else {
                    self.applicationRetryAt = 0
                    self.applicationRetryStep = 0
                }
            }
        }
    }

    private func recordApplicationRegistration(_ notification: String, result: AXError) {
        switch result {
        case .success, .notificationAlreadyRegistered: applicationItems[notification] = .done
        case .notificationUnsupported: applicationItems[notification] = .unsupported
        default: applicationItems[notification] = .failed
        }
    }

    func stop() {
        for registration in inFlight.values { registration.cancellation.cancel() }
        work.stop()
        cleanupSession?.stop()
        cleanupSession = nil
        session?.detach()
        session = nil
        isRunning = false
        isStarting = false
        applicationItems.removeAll()
        applicationRetryAt = 0
        applicationRetryStep = 0
        movementAttempts = 0
        waitingWindows.removeAll()
        inFlight.removeAll()
        subscriptions.removeAll()
    }

    func registerWindow(_ element: AXUIElement, cgWindowID: CGWindowID) -> Registration {
        guard accessibilityAccess.allowsCalls else { return .none }
        let key = AXElementKey(e: element)
        guard session != nil else {
            if isRunning {
                if let previousID = waitingWindows.first(where: { $0.value == key })?.key {
                    waitingWindows.removeValue(forKey: previousID)
                }
                waitingWindows[cgWindowID] = key
            }
            return .none
        }
        if let replaced = subscriptions.rebind(element: key, to: cgWindowID) { retire(replaced.element) }
        guard inFlight[key] == nil else { return .none }
        let now = clock()
        guard let kind = subscriptions.attemptKind(cgWindowID: cgWindowID, element: key, now: now) else { return .none }
        if kind == .retry {
            return .retryDue(WindowSubscriptionRetryCandidate(pid: pid, cgWindowID: cgWindowID, element: key,
                                                               retryAt: subscriptions.record(for: cgWindowID)?.retryAt ?? now))
        }
        schedule(key: key, cgWindowID: cgWindowID, kind: kind)
        return .scheduled
    }

    func isRetryValid(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>) -> Bool {
        guard accessibilityAccess.allowsCalls, session != nil, inFlight[candidate.element] == nil,
              candidate.pid == pid else { return false }
        return subscriptions.attemptKind(cgWindowID: candidate.cgWindowID, element: candidate.element, now: clock()) == .retry
    }

    func performRetry(_ candidate: WindowSubscriptionRetryCandidate<AXElementKey>) {
        guard isRetryValid(candidate) else { return }
        schedule(key: candidate.element, cgWindowID: candidate.cgWindowID, kind: .retry)
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool { subscriptions.isCovered(cgWindowID: cgWindowID) }

    func subscribedElement(cgWindowID: CGWindowID) -> (element: AXUIElement, instanceID: UInt64)? {
        subscriptions.record(for: cgWindowID).map { ($0.element.e, $0.instanceID) }
    }

    func retainSubscriptions(keep: Set<CGWindowID>) {
        waitingWindows = waitingWindows.filter { keep.contains($0.key) }
        for (id, record) in subscriptions.records where !keep.contains(id) {
            retire(record.element)
        }
        subscriptions.retain(keep: keep)
    }

    private func retire(_ key: AXElementKey) {
        inFlight.removeValue(forKey: key)?.cancellation.cancel()
        guard let cleanupSession else { return }
        let id = UUID()
        cleanupSession.pending.withLock { $0[id] = CleanupRequest(element: key) }
        enqueueRemoval(id, session: cleanupSession)
    }

    private func retryPendingRemovals() {
        guard let cleanupSession else { return }
        let retries = cleanupSession.pending.withLock { pending in
            let ids = Array(pending.lazy.filter { !$0.value.queued }.prefix(4)).map(\.key)
            for id in ids {
                pending[id]?.queued = true
                pending[id]?.retriesRemaining -= 1
            }
            return ids
        }
        for id in retries { enqueueRemoval(id, session: cleanupSession) }
    }

    private func enqueueRemoval(_ id: UUID, session cleanupSession: CleanupSession) {
        queue.async { [weak cleanupSession] in
            guard let cleanupSession, !cleanupSession.cancellation.isCancelled,
                  var request = cleanupSession.pending.withLock({ $0[id] }) else { return }
            var failed: [WindowSubscriptionItem] = []
            for item in request.items {
                guard !cleanupSession.cancellation.isCancelled,
                      cleanupSession.pending.withLock({ $0[id] != nil }) else { return }
                let result = cleanupSession.session.remove(item.notificationName, element: request.element)
                if result == .cannotComplete || result == .failure { failed.append(item) }
            }
            cleanupSession.pending.withLock { pending in
                guard pending[id] != nil else { return }
                let retryCount = pending.values.lazy.filter { !$0.queued }.prefix(32).count
                if failed.isEmpty || request.retriesRemaining == 0 || retryCount == 32 {
                    pending.removeValue(forKey: id)
                } else {
                    request.items = failed
                    request.queued = false
                    pending[id] = request
                }
            }
        }
    }

    private struct AttemptResult: Sendable {
        let results: [WindowSubscriptionItem: AXError]
        let sawFailure: Bool
    }

    private func schedule(key: AXElementKey, cgWindowID: CGWindowID, kind: WindowSubscriptionAttemptKind) {
        guard let session else { return }
        if let old = subscriptions.record(for: cgWindowID), old.element != key { retire(old.element) }
        cleanupSession?.pending.withLock { $0 = $0.filter { $0.value.element != key } }
        let begun = subscriptions.beginAttempt(cgWindowID: cgWindowID, element: key, kind: kind, now: clock())
        let registration = RegistrationWork()
        let token = registration.id
        inFlight[key] = registration
        let queue = queue
        let clock = clock
        let cancellation = registration.cancellation
        let access = accessibilityAccess
        let axGeneration = access.trustGeneration
        let task = work.launch { [weak self] generation in
            let result = await AsyncWorkScope.performBlocking(on: queue, cancellation: cancellation) {
                let start = clock()
                var results: [WindowSubscriptionItem: AXError] = [:]
                var sawTimeout = false
                var sawFailure = false
                attempt: for (index, item) in begun.items.enumerated() {
                    guard !cancellation.isCancelled, access.acceptsResult(for: axGeneration) else { break }
                    switch WindowSubscriptionAttemptPolicy.step(item: item, index: index, sawTimeout: sawTimeout,
                        elapsed: clock() - start, timeLimit: kind == .retry ? Self.retryTimeLimit : nil) {
                    case .send: break
                    case .skip: continue attempt
                    case .stop: break attempt
                    }
                    let result = session.add(item.notificationName, element: key)
                    results[item] = result
                    if result == .invalidUIElement {
                        break
                    }
                    if result == .cannotComplete { sawTimeout = true }
                    switch result {
                    case .success, .notificationAlreadyRegistered, .notificationUnsupported: break
                    default: sawFailure = true
                    }
                }
                return AttemptResult(results: results, sawFailure: sawFailure)
            }
            guard let result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation), self.inFlight[key]?.id == token,
                      let cgWindowID = self.subscriptions.cgWindowID(forElement: key),
                      self.subscriptions.record(for: cgWindowID)?.instanceID == begun.instanceID else { return }
                self.inFlight[key] = nil
                guard access.acceptsResult(for: axGeneration) else { return }
                for (item, error) in result.results { self.subscriptions.record(cgWindowID: cgWindowID, item: item, result: error) }
                self.subscriptions.finishAttempt(cgWindowID: cgWindowID, now: clock(), sawFailure: result.sawFailure)
                #if DESKMOTE_TEST
                self.onSubscriptionAttempt?(cgWindowID, self.subscriptions.isCovered(cgWindowID: cgWindowID))
                #endif
            }
        }
        inFlight[key]?.task = task
    }

    #if DESKMOTE_TEST
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    fileprivate func handleNotification(element: AXUIElement, notification notifStr: String) {
        if notifStr == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(pid, AXElementKey(e: element))
        } else if notifStr == (kAXFocusedWindowChangedNotification as String)
                    || notifStr == (kAXMainWindowChangedNotification as String) {
            onFocusedWindowChanged?(pid)
        } else if notifStr == (kAXUIElementDestroyedNotification as String) {
            let key = AXElementKey(e: element)
            if let hit = subscriptions.noteDestroyed(element: key) {
                if hit.removedInstanceID != nil {
                    inFlight.removeValue(forKey: key)?.cancellation.cancel()
                }
                if hit.removedInstanceID != nil { onWindowDestroyed?(pid, hit.cgWindowID, element) }
            }
        } else if notifStr == (kAXWindowMiniaturizedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowMinimized?(pid, cgID)
            }
        } else if notifStr == (kAXWindowDeminiaturizedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onWindowDeminiaturized?(pid, cgID)
            }
        } else if notifStr == (kAXTitleChangedNotification as String) {
            if let cgID = subscriptions.cgWindowID(forElement: AXElementKey(e: element)) {
                onTitleChanged?(pid, cgID)
            }
        } else if Self.geometryNotifications.contains(notifStr) {
            let key = AXElementKey(e: element)
            if let cgID = subscriptions.cgWindowID(forElement: key) {
                onWindowMoved?(pid, cgID, key)
            }
        }
    }
}

extension WindowSubscriptionItem {
    var notificationName: String {
        switch self {
        case .destroyed: return kAXUIElementDestroyedNotification
        case .miniaturized: return kAXWindowMiniaturizedNotification
        case .deminiaturized: return kAXWindowDeminiaturizedNotification
        case .titleChanged: return kAXTitleChangedNotification
        }
    }
}
