import AppKit
import ApplicationServices
import Combine
import Synchronization
import XCTest

final class ObservationFixture: WindowObservationSession, Sendable {
    let calls = Mutex<[Bool]>([])
    let windowCalls = Mutex(0)
    let windowNames = Mutex<[String]>([])
    let windowResults = Mutex<[String: [AXError]]>([:])
    let removals = Mutex(0)
    let transientRemovalFailures = Mutex(0)
    let blockNextRemoval = Mutex(false)
    let removalGate = DispatchSemaphore(value: 0)
    let transientFailures = Mutex(0)
    let registered = Mutex<[AXElementKey: Set<String>]>([:])
    let applicationNotifications = Mutex<Set<String>>([])
    let applicationCalls = Mutex<[String]>([])
    let applicationResults = Mutex<[String: [AXError]]>([:])
    let beforeMovementRegistration = Mutex<(@Sendable () -> Void)?>(nil)
    let blockedApplicationNotification = Mutex<String?>(nil)
    let gate = DispatchSemaphore(value: 0)
    let blockWindows: Bool
    @MainActor var attachments = 0
    @MainActor var detachments = 0

    init(blockWindows: Bool = false) { self.blockWindows = blockWindows }
    func add(_ notification: String, element: AXElementKey?) -> AXError {
        calls.withLock { $0.append(Thread.isMainThread) }
        if let element {
            windowCalls.withLock { $0 += 1 }
            windowNames.withLock { $0.append(notification) }
            let result = windowResults.withLock { results -> AXError in
                guard var values = results[notification], !values.isEmpty else { return .success }
                let result = values.removeFirst()
                results[notification] = values
                return result
            }
            if result != .success && result != .notificationAlreadyRegistered { return result }
            if blockWindows { _ = gate.wait(timeout: .now() + 2) }
            let failed = transientFailures.withLock { value in
                guard value > 0 else { return false }
                value -= 1
                return true
            }
            if failed { return .cannotComplete }
            _ = registered.withLock { $0[element, default: []].insert(notification) }
        } else {
            applicationCalls.withLock { $0.append(notification) }
            if notification == kAXWindowMovedNotification { beforeMovementRegistration.withLock { $0 }?() }
            let blocked = blockedApplicationNotification.withLock { value in
                guard value == notification else { return false }
                value = nil
                return true
            }
            if blocked { _ = gate.wait(timeout: .now() + 2) }
            let result = applicationResults.withLock { values -> AXError in
                guard var remaining = values[notification], !remaining.isEmpty else { return .success }
                let result = remaining.removeFirst()
                values[notification] = remaining
                return result
            }
            if result == .success || result == .notificationAlreadyRegistered {
                _ = applicationNotifications.withLock { $0.insert(notification) }
            }
            return result
        }
        return .success
    }
    func remove(_ notification: String, element: AXElementKey) -> AXError {
        calls.withLock { $0.append(Thread.isMainThread) }
        removals.withLock { $0 += 1 }
        let blocked = blockNextRemoval.withLock { value in
            let blocked = value
            value = false
            return blocked
        }
        if blocked { _ = removalGate.wait(timeout: .now() + 2) }
        let failed = transientRemovalFailures.withLock { value in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
        if failed { return .cannotComplete }
        let removed = registered.withLock { $0[element]?.remove(notification) }
        return removed == nil ? .notificationNotRegistered : .success
    }
    @MainActor func attach() { attachments += 1 }
    @MainActor func detach() { detachments += 1 }
}

@MainActor
final class WindowObservationLifecycleTests: XCTestCase {
    func testApplicationObserverSubscribesToWindowMovementAndResize() async {
        let fixture = ObservationFixture()
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }

        XCTAssertTrue(fixture.applicationNotifications.withLock { $0.contains(kAXWindowMovedNotification) })
        XCTAssertTrue(fixture.applicationNotifications.withLock { $0.contains(kAXWindowResizedNotification) })
    }

    func testBlockedMovementRegistrationLeavesRequiredObserverReadyAndAttached() async {
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        fixture.blockedApplicationNotification.withLock { $0 = kAXWindowMovedNotification }
        let observer = AppWindowObserver(pid: 42, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        var createdPIDs: [pid_t] = []
        observer.onWindowCreated = { pid, _ in createdPIDs.append(pid) }
        defer { fixture.gate.signal(); observer.stop() }
        observer.start()
        await waitUntil { fixture.applicationCalls.withLock { $0.contains(kAXWindowMovedNotification) } }

        XCTAssertTrue(observer.isActive)
        XCTAssertEqual(fixture.attachments, 1)
        XCTAssertFalse(fixture.applicationNotifications.withLock { $0.contains(kAXWindowMovedNotification) })
        if fixture.applicationNotifications.withLock({ $0.contains(kAXWindowCreatedNotification) }) {
            callback.withLock { $0 }?(AXElementKey(e: AXUIElementCreateApplication(42)), kAXWindowCreatedNotification)
        }
        await waitUntil { createdPIDs == [42] }
        fixture.gate.signal()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(fixture.applicationNotifications.withLock { $0.contains(kAXWindowMovedNotification) })
    }

    func testMovementRegistrationWaitsForQueuedRequiredWindows() async {
        let fixture = ObservationFixture()
        fixture.blockedApplicationNotification.withLock { $0 = kAXMainWindowChangedNotification }
        let completed = Mutex<Set<CGWindowID>>([])
        let completedAtMovement = Mutex<Set<CGWindowID>>([])
        fixture.beforeMovementRegistration.withLock { callback in
            callback = {
                let required = completed.withLock { $0 }
                completedAtMovement.withLock { $0 = required }
            }
        }
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        observer.onSubscriptionAttempt = { id, covered in
            if covered { _ = completed.withLock { $0.insert(id) } }
        }
        defer { fixture.gate.signal(); observer.stop() }
        observer.start()
        await waitUntil { fixture.applicationCalls.withLock { $0.contains(kAXMainWindowChangedNotification) } }
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        _ = observer.registerWindow(AXUIElementCreateApplication(43), cgWindowID: 2)
        fixture.gate.signal()

        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(fixture.applicationNotifications.withLock { $0.contains(kAXWindowMovedNotification) })
        XCTAssertEqual(completedAtMovement.withLock { $0 }, [1, 2])
    }

    func testUnsupportedMovementDoesNotDowngradeRequiredApplicationCoverage() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock { $0[kAXWindowMovedNotification] = [.notificationUnsupported] }
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        for _ in 0..<3 {
            now.withLock { $0 += 60 }
            observer.start()
            for task in observer.pendingWorkForTesting { await task.value }
        }

        XCTAssertTrue(observer.isActive)
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.filter { $0 == kAXWindowMovedNotification }.count }, 1)
    }

    func testTransientMovementRegistrationKeepsRequiredCoverageAndStopsRetrying() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock { $0[kAXWindowMovedNotification] = Array(repeating: .cannotComplete, count: 10) }
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(observer.isActive)
        for _ in 0..<10 {
            observer.start()
            for task in observer.pendingWorkForTesting { await task.value }
        }
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.filter { $0 == kAXWindowMovedNotification }.count }, 1)
        for _ in 0..<10 {
            now.withLock { $0 += 60 }
            observer.start()
            for task in observer.pendingWorkForTesting { await task.value }
            XCTAssertTrue(observer.isActive)
        }
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.filter { $0 == kAXWindowMovedNotification }.count }, 3)
    }

    func testApplicationObserverFactoryFailureBacksOffThenRecoversOnFallback() async {
        let fixture = ObservationFixture()
        let attempts = Mutex(0)
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? nil : fixture
        })
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertFalse(observer.isActive)
        for _ in 0..<20 { observer.start() }
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertEqual(fixture.attachments, 0)
        now.withLock { $0 = 101 }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(observer.isActive)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(fixture.attachments, 1)
        XCTAssertEqual(fixture.applicationNotifications.withLock { $0 }, [
            kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
            kAXWindowMovedNotification, kAXWindowResizedNotification
        ])
        observer.stop()
    }

    func testWindowRegistrationSurvivesApplicationObserverFactoryBackoff() async {
        let fixture = ObservationFixture()
        let attempts = Mutex(0)
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? nil : fixture
        })
        defer { observer.stop() }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertFalse(observer.isActive)

        let window = AXElementKey(e: AXUIElementCreateApplication(42))
        _ = observer.registerWindow(window.e, cgWindowID: 1)
        now.withLock { $0 = 101 }
        observer.start()

        await waitUntil { observer.isCovered(cgWindowID: 1) }
        XCTAssertEqual(fixture.registered.withLock { $0[window]?.count }, 4)
    }

    func testApplicationObserverRetriesOnlyTransientApplicationNotifications() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock { $0[kAXWindowCreatedNotification] = [.cannotComplete, .success] }
        let now = Mutex<TimeInterval>(100)
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        var createdPIDs: [pid_t] = []
        observer.onWindowCreated = { pid, _ in createdPIDs.append(pid) }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertFalse(observer.isActive)
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(observer.isCovered(cgWindowID: 1))
        let instance = observer.subscribedElement(cgWindowID: 1)?.instanceID
        for _ in 0..<20 { observer.start() }
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.count }, 5)
        now.withLock { $0 = 101 }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(observer.isActive)
        XCTAssertEqual(fixture.applicationCalls.withLock { $0 }, [
            kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
            kAXWindowCreatedNotification
        ])
        XCTAssertEqual(fixture.attachments, 1)
        XCTAssertTrue(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(observer.subscribedElement(cgWindowID: 1)?.instanceID, instance)
        if fixture.applicationNotifications.withLock({ $0.contains(kAXWindowCreatedNotification) }) {
            callback.withLock { $0 }?(AXElementKey(e: AXUIElementCreateApplication(42)), kAXWindowCreatedNotification)
        }
        await waitUntil { createdPIDs == [42] }
        observer.stop()
    }

    func testUnsupportedApplicationNotificationKeepsFallbackWithoutRetryLoop() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock { $0[kAXWindowCreatedNotification] = [.notificationUnsupported] }
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in fixture })
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertFalse(observer.isActive)
        for _ in 0..<20 {
            now.withLock { $0 += 60 }
            observer.start()
            for task in observer.pendingWorkForTesting { await task.value }
        }
        XCTAssertFalse(observer.isActive)
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.count }, 5)
        XCTAssertEqual(fixture.attachments, 1)
        observer.stop()
    }

    func testAlreadyRegisteredApplicationNotificationsProvideEventCoverage() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock {
            $0[kAXWindowCreatedNotification] = [.notificationAlreadyRegistered]
            $0[kAXFocusedWindowChangedNotification] = [.notificationAlreadyRegistered]
            $0[kAXMainWindowChangedNotification] = [.notificationAlreadyRegistered]
        }
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertTrue(observer.isActive)
        XCTAssertEqual(fixture.attachments, 1)
        observer.stop()
    }

    func testStopDuringApplicationFactoryRecoveryRejectsLateSessionAndCallbacks() async {
        let fixture = ObservationFixture()
        let attempts = Mutex(0)
        let now = Mutex<TimeInterval>(100)
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, receive in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            guard attempt > 1 else { return nil }
            callback.withLock { $0 = receive }
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return fixture
        })
        var created = 0
        observer.onWindowCreated = { _, _ in created += 1 }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        now.withLock { $0 = 101 }
        observer.start()
        await waitUntil { entered.withLock { $0 } }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        gate.signal()
        for task in pending { await task.value }
        callback.withLock { $0 }?(AXElementKey(e: AXUIElementCreateApplication(42)), kAXWindowCreatedNotification)
        await Task.yield()
        XCTAssertFalse(observer.isActive)
        XCTAssertEqual(fixture.attachments, 0)
        XCTAssertTrue(fixture.applicationCalls.withLock { $0.isEmpty })
        XCTAssertEqual(created, 0)
    }

    func testStopDuringApplicationNotificationRecoveryDoesNotReattachSession() async {
        let fixture = ObservationFixture()
        fixture.applicationResults.withLock { $0[kAXWindowCreatedNotification] = [.cannotComplete, .success] }
        let now = Mutex<TimeInterval>(100)
        let observer = AppWindowObserver(pid: 42, clock: { now.withLock { $0 } }, makeSession: { _, _ in fixture })
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertFalse(observer.isActive)
        fixture.blockedApplicationNotification.withLock { $0 = kAXWindowCreatedNotification }
        now.withLock { $0 = 101 }
        observer.start()
        await waitUntil { fixture.applicationCalls.withLock { $0.count } == 6 }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        fixture.gate.signal()
        for task in pending { await task.value }
        XCTAssertFalse(observer.isActive)
        XCTAssertEqual(fixture.attachments, 1)
        XCTAssertEqual(fixture.detachments, 1)
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.count }, 6)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    func testWindowRegistrationQueuedDuringStartupRunsOffMain() async {
        let fixture = ObservationFixture()
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        observer.start()
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { observer.isCovered(cgWindowID: 1) }
        for task in observer.pendingWorkForTesting { await task.value }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 4)
        XCTAssertEqual(fixture.applicationCalls.withLock { $0.count }, 5)
        XCTAssertEqual(fixture.calls.withLock { $0.count }, 9)
        XCTAssertFalse(fixture.calls.withLock { $0.contains(true) })
        observer.stop()
        XCTAssertEqual(fixture.detachments, 1)
    }

    func testStopDuringRegistrationRejectsLateCompletion() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        var reports = 0
        observer.onSubscriptionAttempt = { _, _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } > 0 }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        for _ in 0..<4 { fixture.gate.signal() }
        for task in pending { await task.value }
        XCTAssertFalse(observer.isActive)
        XCTAssertFalse(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 1)
        XCTAssertFalse(fixture.calls.withLock { $0.contains(true) })
    }
    func testCancelledStartupNeverAttachesOrRegistersASession() async {
        let fixture = ObservationFixture()
        let entered = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 2)
            return fixture
        })
        observer.start()
        await waitUntil { entered.withLock { $0 } }
        let pending = observer.pendingWorkForTesting
        observer.stop()
        gate.signal()
        for task in pending { await task.value }
        XCTAssertEqual(fixture.attachments, 0)
        XCTAssertTrue(fixture.calls.withLock { $0.isEmpty })
    }

    func testRetiringWindowDuringRegistrationStopsFurtherSubscriptions() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        var reports = 0
        observer.onSubscriptionAttempt = { _, _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(AXUIElementCreateApplication(42), cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 1 }
        let pending = observer.pendingWorkForTesting
        _ = observer.retainSubscriptions(keep: [])
        for _ in 0..<4 { fixture.gate.signal() }
        for task in pending { await task.value }
        await waitUntil { fixture.removals.withLock { $0 } == 4 }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 1)
        XCTAssertTrue(fixture.registered.withLock { $0.values.allSatisfy(\.isEmpty) })
        XCTAssertFalse(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(reports, 0)
        observer.stop()
    }

    func testStopCancelsCleanupQueuedBehindABlockedRemoval() async {
        let old = ObservationFixture()
        let replacement = ObservationFixture()
        let factoryCalls = Mutex(0)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in
            factoryCalls.withLock { calls in
                calls += 1
                return calls == 1 ? old : replacement
            }
        })
        observer.start()
        await waitUntil { observer.isActive }
        for id in CGWindowID(1)...3 {
            _ = observer.registerWindow(AXUIElementCreateApplication(pid_t(41 + id)), cgWindowID: id)
        }
        await waitUntil { (CGWindowID(1)...3).allSatisfy { observer.isCovered(cgWindowID: $0) } }
        old.blockNextRemoval.withLock { $0 = true }
        _ = observer.retainSubscriptions(keep: [2, 3])
        await waitUntil { old.removals.withLock { $0 } == 1 }
        _ = observer.retainSubscriptions(keep: [])
        observer.stop()
        old.removalGate.signal()
        observer.start()
        await waitUntil { replacement.attachments == 1 }
        XCTAssertEqual(old.removals.withLock { $0 }, 1)
        XCTAssertEqual(old.detachments, 1)
        XCTAssertFalse(old.calls.withLock { $0.contains(true) })
        XCTAssertTrue(observer.isActive)
        observer.stop()
    }

    func testRetiredWindowRetriesOnlyTransientRemovalOnTheNextObservationTick() async {
        let fixture = ObservationFixture()
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(key.e, cgWindowID: 1)
        await waitUntil { observer.isCovered(cgWindowID: 1) }
        fixture.transientRemovalFailures.withLock { $0 = 1 }

        _ = observer.retainSubscriptions(keep: [])
        _ = observer.registerWindow(AXUIElementCreateApplication(43), cgWindowID: 2)
        await waitUntil { observer.isCovered(cgWindowID: 2) }
        XCTAssertEqual(fixture.registered.withLock { $0[key]?.count }, 1)
        XCTAssertFalse(observer.isCovered(cgWindowID: 1))
        XCTAssertEqual(fixture.removals.withLock { $0 }, 4)

        observer.start()
        await waitUntil { fixture.registered.withLock { $0[key]?.isEmpty == true } }
        XCTAssertEqual(fixture.removals.withLock { $0 }, 5)
        XCTAssertFalse(fixture.calls.withLock { $0.contains(true) })
    }

    func testReplacingWindowDuringRegistrationReleasesOldElementSubscriptions() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        let old = AXElementKey(e: AXUIElementCreateApplication(42))
        let replacement = AXElementKey(e: AXUIElementCreateApplication(43))
        var reports = 0
        observer.onSubscriptionAttempt = { _, _ in reports += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        _ = observer.registerWindow(old.e, cgWindowID: 1)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 1 }
        _ = observer.registerWindow(replacement.e, cgWindowID: 1)
        for _ in 0..<5 { fixture.gate.signal() }
        await waitUntil { observer.isCovered(cgWindowID: 1) }
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 5)
        XCTAssertTrue(fixture.registered.withLock { $0[old]?.isEmpty == true })
        XCTAssertEqual(fixture.registered.withLock { $0[replacement]?.count }, 4)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(observer.subscribedElement(cgWindowID: 1).map { AXElementKey(e: $0.element) }, replacement)
        observer.stop()
    }

    func testRetainingNewCGWindowIDPreservesAXSubscriptions() async {
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        defer { observer.stop() }
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        let equalKey = AXElementKey(e: AXUIElementCreateApplication(42))
        XCTAssertEqual(key, equalKey)
        var minimized: [CGWindowID] = []
        observer.onWindowMinimized = { minimized.append($1) }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        _ = observer.registerWindow(key.e, cgWindowID: 77)
        for task in observer.pendingWorkForTesting { await task.value }
        let originalInstance = observer.subscribedElement(cgWindowID: 77)?.instanceID
        XCTAssertTrue(observer.isCovered(cgWindowID: 77))

        _ = observer.registerWindow(equalKey.e, cgWindowID: 88)
        for task in observer.pendingWorkForTesting { await task.value }
        _ = observer.retainSubscriptions(keep: [88])
        _ = observer.registerWindow(AXUIElementCreateApplication(43), cgWindowID: 99)
        for task in observer.pendingWorkForTesting { await task.value }

        XCTAssertTrue(observer.isCovered(cgWindowID: 88))
        XCTAssertNil(observer.subscribedElement(cgWindowID: 77))
        XCTAssertEqual(observer.subscribedElement(cgWindowID: 88)?.instanceID, originalInstance)
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 8)
        XCTAssertEqual(fixture.removals.withLock { $0 }, 0)
        XCTAssertEqual(fixture.registered.withLock { $0[key]?.count }, 4)
        callback.withLock { $0 }?(equalKey, kAXWindowMiniaturizedNotification)
        await waitUntil { minimized == [88] }
    }

    func testReassigningCGWindowIDKeepsRegistrationInFlight() async {
        let fixture = ObservationFixture(blockWindows: true)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        var registeredIDs: [CGWindowID] = []
        observer.onSubscriptionAttempt = { id, _ in registeredIDs.append(id) }
        observer.start()
        for task in observer.pendingWorkForTesting { await task.value }
        _ = observer.registerWindow(key.e, cgWindowID: 77)
        await waitUntil { fixture.windowCalls.withLock { $0 } == 1 }
        let originalInstance = observer.subscribedElement(cgWindowID: 77)?.instanceID

        _ = observer.registerWindow(key.e, cgWindowID: 88)
        _ = observer.retainSubscriptions(keep: [88])
        for _ in 0..<8 { fixture.gate.signal() }
        for task in observer.pendingWorkForTesting { await task.value }

        XCTAssertEqual(registeredIDs, [88])
        XCTAssertNil(observer.subscribedElement(cgWindowID: 77))
        XCTAssertEqual(observer.subscribedElement(cgWindowID: 88)?.instanceID, originalInstance)
        XCTAssertTrue(observer.isCovered(cgWindowID: 88))
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 4)
        XCTAssertEqual(fixture.removals.withLock { $0 }, 0)
        XCTAssertEqual(fixture.registered.withLock { $0[key]?.count }, 4)
    }

    func testWaitingRegistrationUsesLatestCGWindowID() async {
        let fixture = ObservationFixture()
        let observer = AppWindowObserver(pid: 42, makeSession: { _, _ in fixture })
        defer { observer.stop() }
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        observer.start()
        _ = observer.registerWindow(key.e, cgWindowID: 77)
        _ = observer.registerWindow(key.e, cgWindowID: 88)
        for task in observer.pendingWorkForTesting { await task.value }
        for task in observer.pendingWorkForTesting { await task.value }

        XCTAssertNil(observer.subscribedElement(cgWindowID: 77))
        XCTAssertTrue(observer.isCovered(cgWindowID: 88))
        XCTAssertEqual(fixture.windowCalls.withLock { $0 }, 4)
    }

    func testMainWindowChangeDeliversAFocusRefreshThroughItsRegisteredSession() async {
        let fixture = ObservationFixture()
        let callback = Mutex<(@Sendable (AXElementKey, String) -> Void)?>(nil)
        let observer = AppWindowObserver(pid: 42, makeSession: { _, receive in
            callback.withLock { $0 = receive }
            return fixture
        })
        var focusedPIDs: [pid_t] = []
        observer.onFocusedWindowChanged = { focusedPIDs.append($0) }
        observer.start()
        await waitUntil { observer.isActive }
        if fixture.applicationNotifications.withLock({ $0.contains(kAXMainWindowChangedNotification) }) {
            callback.withLock { $0 }?(AXElementKey(e: AXUIElementCreateApplication(42)), kAXMainWindowChangedNotification)
        }
        await waitUntil { focusedPIDs == [42] }
        XCTAssertEqual(focusedPIDs, [42])
        observer.stop()
    }

    func testNotificationsFromAnOldSessionCannotAffectARestartedObserver() async {
        let fixture = ObservationFixture()
        let callbacks = Mutex<[@Sendable (AXElementKey, String) -> Void]>([])
        let observer = AppWindowObserver(pid: 42, makeSession: { _, receive in
            callbacks.withLock { $0.append(receive) }
            return fixture
        })
        var focusChanges = 0
        observer.onFocusedWindowChanged = { _ in focusChanges += 1 }
        observer.start()
        await waitUntil { observer.isActive }
        observer.stop()
        observer.start()
        await waitUntil { observer.isActive }
        let receivers = callbacks.withLock { $0 }
        XCTAssertEqual(receivers.count, 2)
        let key = AXElementKey(e: AXUIElementCreateApplication(42))
        receivers[0](key, kAXFocusedWindowChangedNotification)
        receivers[1](key, kAXFocusedWindowChangedNotification)
        await waitUntil { focusChanges > 0 }
        XCTAssertEqual(focusChanges, 1)
        observer.stop()
    }

}
