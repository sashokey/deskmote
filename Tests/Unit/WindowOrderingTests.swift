import AppKit
import ApplicationServices
import XCTest

@MainActor
final class WindowOrderingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var clock = Date(timeIntervalSince1970: 100)
    private var wallClockOffset: TimeInterval = 0

    @MainActor
    override func setUp() async throws {
        suite = "deskmote-order-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        clock = Date(timeIntervalSince1970: 100)
        wallClockOffset = 0
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(boot: Int = 1, legacyBoot: Int? = nil, hasBootSession: Bool = true) -> StripOrderStore {
        let session = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", boot))
        return StripOrderStore(defaults: defaults, now: { [unowned self] in self.clock.addingTimeInterval(self.wallClockOffset) },
                               bootTimeProvider: { legacyBoot ?? boot }, bootSessionProvider: { hasBootSession ? session : nil },
                               elapsed: { [unowned self] in self.clock.timeIntervalSince1970 })
    }

    func testManualReorderSurvivesSnapshotOrderChanges() {
        let store = makeStore()
        store.sync(current: ["a", "b", "c"])
        store.reorderGroup("c", relativeTo: "a", after: false, current: ["a", "b", "c"])
        store.sync(current: ["b", "a", "c"])
        XCTAssertEqual(store.liveOrder, ["c", "a", "b"])
    }

    func testNewWindowJoinsItsLastSiblingWithoutMovingExistingWindows() {
        let store = makeStore()
        let keys = ["a": "editor", "b": "browser", "c": "editor"]
        store.sync(current: ["a", "b"], appKeyOf: keys)
        store.sync(current: ["a", "b", "c"], appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["a", "c", "b"])
    }

    func testUnrelatedNewWindowAppendsAtTheEnd() {
        XCTAssertEqual(StripOrdering.reconcile(remembered: ["b", "a"], current: ["a", "b", "c"]),
                       ["b", "a", "c"])
    }

    func testBrieflyMissingWindowKeepsItsManualPosition() {
        let store = makeStore()
        store.sync(current: ["a", "b", "c"])
        store.reorderGroup("c", relativeTo: "a", after: false, current: ["a", "b", "c"])
        store.sync(current: ["a", "b"])
        XCTAssertEqual(store.reconciled(current: ["a", "b"]), ["a", "b"])
        clock.addTimeInterval(4)
        XCTAssertEqual(store.reconciled(current: ["a", "b", "c"]), ["c", "a", "b"])
        store.sync(current: ["a", "b", "c"])
        XCTAssertEqual(store.liveOrder, ["c", "a", "b"])
    }

    func testReorderingVisibleGroupsRetainsAnAbsentGroupWithinTheGracePeriod() {
        let store = makeStore()
        let all = ["tabgrp-a", "tabgrp-x", "tabgrp-b", "tabgrp-c"]
        let visible = ["tabgrp-a", "tabgrp-b", "tabgrp-c"]
        let keys = ["tabgrp-a": "first", "tabgrp-x": "missing", "tabgrp-b": "second", "tabgrp-c": "third"]
        store.sync(current: all, appKeyOf: keys)
        store.sync(current: visible, appKeyOf: keys)

        clock.addTimeInterval(2)
        store.reorderGroup("third", relativeTo: "second", after: false, current: visible)
        XCTAssertEqual(store.reconciled(current: visible, appKeyOf: keys), ["tabgrp-a", "tabgrp-c", "tabgrp-b"])

        clock.addTimeInterval(2)
        store.sync(current: all, appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["tabgrp-a", "tabgrp-x", "tabgrp-c", "tabgrp-b"])
    }

    func testClosedWindowOrderExpiresAfterGracePeriod() {
        let store = makeStore()
        store.sync(current: ["a", "b"])
        store.sync(current: ["b"])
        clock.addTimeInterval(6)
        store.sync(current: ["b"])
        XCTAssertEqual(store.liveOrder, ["b"])
        store.sync(current: ["a", "b"])
        XCTAssertEqual(store.liveOrder, ["b", "a"])
    }

    func testSameBootRestoresWindowOrderAndNewBootStartsFresh() {
        let store = makeStore()
        let ids = ["tabgrp-1-s1", "tabgrp-2-s1"]
        store.sync(current: ids)
        store.reorderGroup(ids[1], relativeTo: ids[0], after: false, current: ids)
        XCTAssertEqual(makeStore().reconciled(current: ids), Array(ids.reversed()))
        XCTAssertEqual(makeStore(boot: 2).reconciled(current: ids), ids)
    }

    func testSavedOrderUsesTheBootSessionWhenTheCalendarChanges() {
        let seats = ["tabgrp-100-s1", "tabgrp-200-s2"]
        let saved = Array(seats.reversed())
        makeStore(boot: 1, legacyBoot: 50).sync(current: saved)
        wallClockOffset = 3_600
        XCTAssertEqual(makeStore(boot: 1, legacyBoot: 3_650).reconciled(current: seats), saved)
        XCTAssertEqual(makeStore(boot: 2, legacyBoot: 50).reconciled(current: seats), seats)

        let withoutIdentity = makeStore(boot: 1, legacyBoot: 50, hasBootSession: false)
        XCTAssertEqual(withoutIdentity.reconciled(current: seats), seats)
        withoutIdentity.sync(current: seats)
        XCTAssertEqual(makeStore(boot: 1, legacyBoot: 3_650).reconciled(current: seats), saved)
    }

    func testCorroboratedLegacyOrderMigratesToTheStableBootSession() {
        let seats = ["tabgrp-100-s1", "tabgrp-200-s2"]
        let saved = Array(seats.reversed())
        defaults.set(saved, forKey: "deskmote.windowOrder")
        defaults.set(50, forKey: "deskmote.windowOrderBootTime")

        XCTAssertEqual(makeStore(boot: 1, legacyBoot: 51).reconciled(current: seats), seats)
        XCTAssertEqual(makeStore(boot: 1, legacyBoot: 50).reconciled(current: seats), saved)
        wallClockOffset = -3_600
        XCTAssertEqual(makeStore(boot: 1, legacyBoot: -3_550).reconciled(current: seats), saved)
        XCTAssertEqual(makeStore(boot: 2, legacyBoot: 50).reconciled(current: seats), seats)
    }

    func testNativeBootSessionIdentityIsUsedByDefaultStore() throws {
        var buffer = [CChar](repeating: 0, count: 37)
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0) }
        let queryError = errno
        try XCTSkipIf(status != 0, "Native boot-session sysctl unavailable (errno \(queryError)).")
        let decoded = String(decoding: buffer.prefix(36).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let bootSession = UUID(uuidString: decoded)
        XCTAssertTrue(bootSession != nil)
        let seats = ["tabgrp-100-s1", "tabgrp-200-s2"]
        let saved = Array(seats.reversed())
        StripOrderStore(defaults: defaults).sync(current: saved)
        let writtenSession = defaults.string(forKey: "deskmote.windowOrderBootSession").flatMap(UUID.init(uuidString:))
        XCTAssertTrue(writtenSession != nil && writtenSession == bootSession)
        XCTAssertEqual(StripOrderStore(defaults: defaults).reconciled(current: seats), saved)
    }

    func testDefaultStorePersistsDisplacedRankWithNativeElapsedClock() throws {
        let seats = ["tabgrp-100-s1", "tabgrp-200-s2"]
        let reusedSeat = seats[0]
        let stableSeat = seats[1]
        let displacedApp = "bundle:/Applications/A.app"
        let stableApp = "bundle:/Applications/C.app"
        StripOrderStore(defaults: defaults).sync(current: seats, appKeyOf: [reusedSeat: displacedApp, stableSeat: stableApp])
        let store = StripOrderStore(defaults: defaults)

        let before = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        store.sync(current: seats, appKeyOf: [reusedSeat: "bundle:/Applications/B.app", stableSeat: stableApp])
        let after = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000

        let ranks = try XCTUnwrap(defaults.dictionary(forKey: "deskmote.windowOrderApplications") as? [String: String])
        let retiredSeat = try XCTUnwrap(ranks.first(where: { $0.value == displacedApp })?.key)
        XCTAssertNotEqual(retiredSeat, reusedSeat)
        let markers = try XCTUnwrap(defaults.dictionary(forKey: "deskmote.windowOrderRetiredElapsed") as? [String: TimeInterval])
        let marker = try XCTUnwrap(markers[retiredSeat])
        XCTAssertGreaterThan(before, 0)
        XCTAssertTrue(marker >= before && marker <= after, "Persisted marker falls outside the native elapsed clock bracket")
    }

    func testApplicationOrderSurvivesTrackerRelaunchWithDifferentSeatAllocation() throws {
        let firstTracker = AppTracker(onScreenWindowIDsProvider: { [] })
        let secondTracker = AppTracker(onScreenWindowIDsProvider: { [] })
        defer { firstTracker.stop(); secondTracker.stop() }
        for tracker in [firstTracker, secondTracker] {
            for (pid, name) in [(Int32(-51000), "Editor"), (Int32(-52000), "Browser")] {
                tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: "test.\(name)", appName: name,
                    activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [], isHidden: false,
                    applicationOrigin: ApplicationOrigin(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"))))
            }
        }
        let editorA = orderSnapshot(pid: -51000, id: 51001)
        let editorB = orderSnapshot(pid: -51000, id: 51002)
        let browser = orderSnapshot(pid: -52000, id: 52001)
        let cg = AppTrackerCGWindowSnapshot(allWindowIDs: [51001, 51002, 52001], onScreenWindowIDs: [51001, 51002, 52001],
            windowIDsByPID: [-51000: [51001, 51002], -52000: [52001]], alphaByWindowID: [:])
        func reconcile(_ tracker: AppTracker, pid: Int32, snapshots: [AXWindowSnapshot]) {
            tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cg, now: clock, eligible: snapshots,
                readOutcome: .success)
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [51001, 51002, 52001])
        }
        reconcile(firstTracker, pid: -51000, snapshots: [editorA])
        reconcile(firstTracker, pid: -52000, snapshots: [browser])
        reconcile(firstTracker, pid: -51000, snapshots: [editorA, editorB])
        let initial = StripItem.openWindows(from: firstTracker.snapshot)
        XCTAssertEqual(initial.map(\.id), ["tabgrp--51000-s1", "tabgrp--51000-s3", "tabgrp--52000-s2"])
        let initialKeys = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.applicationKey) })
        let store = makeStore()
        store.sync(current: initial.map(\.id), appKeyOf: initialKeys)
        store.reorderGroup(try XCTUnwrap(initial.last?.applicationKey), relativeTo: try XCTUnwrap(initial.first?.applicationKey),
            after: false, current: initial.map(\.id))
        reconcile(secondTracker, pid: -51000, snapshots: [editorA, editorB])
        reconcile(secondTracker, pid: -52000, snapshots: [browser])
        let current = StripItem.openWindows(from: secondTracker.snapshot)
        XCTAssertEqual(current.map(\.id), ["tabgrp--51000-s1", "tabgrp--51000-s2", "tabgrp--52000-s3"])
        let keys = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.applicationKey) })
        let restored = makeStore()
        restored.sync(current: current.map(\.id), appKeyOf: keys)
        let order = restored.reconciled(current: current.map(\.id), appKeyOf: keys)
        XCTAssertEqual(order, ["tabgrp--52000-s3", "tabgrp--51000-s1", "tabgrp--51000-s2"])
        XCTAssertEqual(makeStore(boot: 2).reconciled(current: current.map(\.id), appKeyOf: keys), current.map(\.id))
    }

    func testRestoredApplicationRanksSurviveEmptyAndPartialStartupSnapshots() {
        let store = makeStore()
        let old = ["tabgrp-a-old", "tabgrp-b-old"]
        let oldKeys = [old[0]: "bundle:/Applications/A.app", old[1]: "bundle:/Applications/B.app"]
        store.sync(current: old, appKeyOf: oldKeys)
        store.reorderGroup("bundle:/Applications/B.app", relativeTo: "bundle:/Applications/A.app", after: false, current: old)
        let restored = makeStore()
        restored.sync(current: [])
        let current = ["tabgrp-a-new", "tabgrp-b-new"]
        let keys = [current[0]: "bundle:/Applications/A.app", current[1]: "bundle:/Applications/B.app"]
        restored.sync(current: [current[0]], appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: [current[0]], appKeyOf: keys), [current[0]])
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), [current[1], current[0]])
        restored.sync(current: [current[0]], appKeyOf: keys)
        clock.addTimeInterval(6)
        restored.sync(current: [current[0]], appKeyOf: keys)
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), current)
    }

    func testReusedStartupSeatDoesNotStealTheSavedApplicationRank() {
        let oldA = "tabgrp-100-s1"
        let newA = "tabgrp-300-s3"
        let c = "tabgrp-200-s2"
        let keyA = "bundle:/Applications/A.app"
        let keyB = "bundle:/Applications/B.app"
        let keyC = "bundle:/Applications/C.app"
        makeStore().sync(current: [oldA, c], appKeyOf: [oldA: keyA, c: keyC])

        let restored = makeStore()
        let partial = [oldA, c]
        let partialKeys = [oldA: keyB, c: keyC]
        XCTAssertEqual(restored.reconciled(current: partial, appKeyOf: partialKeys), [c, oldA])
        restored.sync(current: partial, appKeyOf: partialKeys)
        XCTAssertEqual(restored.reconciled(current: partial, appKeyOf: partialKeys), [c, oldA])

        clock.addTimeInterval(4)
        let current = [oldA, c, newA]
        let keys = [oldA: keyB, c: keyC, newA: keyA]
        let expected = [newA, c, oldA]
        XCTAssertEqual(makeStore().reconciled(current: current, appKeyOf: keys), expected)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), expected)
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), expected)
        XCTAssertEqual(makeStore().reconciled(current: current, appKeyOf: keys), expected)
        XCTAssertEqual(makeStore(boot: 2).reconciled(current: current, appKeyOf: keys), current)
    }

    func testDisplacedSavedRankExpiresAtItsOriginalDeadlineAcrossStoreRestarts() {
        let b = "tabgrp-100-s1"
        let c = "tabgrp-200-s2"
        let a = "tabgrp-300-s3"
        let keyA = "bundle:/Applications/A.app"
        let keyB = "bundle:/Applications/B.app"
        let keyC = "bundle:/Applications/C.app"
        makeStore().sync(current: [b, c], appKeyOf: [b: keyA, c: keyC])
        let partial = [b, c]
        let partialKeys = [b: keyB, c: keyC]
        makeStore().sync(current: partial, appKeyOf: partialKeys)
        let current = [b, c, a]
        let keys = [b: keyB, c: keyC, a: keyA]

        clock.addTimeInterval(4)
        let beforeExpiry = makeStore()
        XCTAssertEqual(beforeExpiry.reconciled(current: current, appKeyOf: keys), [a, c, b])
        beforeExpiry.sync(current: partial, appKeyOf: partialKeys)

        clock.addTimeInterval(2)
        XCTAssertEqual(beforeExpiry.reconciled(current: current, appKeyOf: keys), [c, b, a])
        let afterExpiry = makeStore()
        XCTAssertEqual(afterExpiry.reconciled(current: current, appKeyOf: keys), [c, b, a])
        afterExpiry.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(afterExpiry.reconciled(current: current, appKeyOf: keys), [c, b, a])
        XCTAssertEqual(makeStore().reconciled(current: current, appKeyOf: keys), [c, b, a])
    }

    func testDisplacedRankGraceUsesElapsedTimeAcrossClockCorrectionsAndRestarts() {
        let b = "tabgrp-100-s1"
        let c = "tabgrp-200-s2"
        let a = "tabgrp-300-s3"
        let partial = [b, c]
        let current = [b, c, a]
        let keys = [b: "browser", c: "calendar", a: "editor"]
        makeStore().sync(current: partial, appKeyOf: [b: "editor", c: "calendar"])
        let displaced = makeStore()
        displaced.sync(current: partial, appKeyOf: keys)

        clock.addTimeInterval(4)
        wallClockOffset = 3_600
        XCTAssertEqual(displaced.reconciled(current: current, appKeyOf: keys), [a, c, b])
        XCTAssertEqual(makeStore(legacyBoot: 3_601).reconciled(current: current, appKeyOf: keys), [a, c, b])

        clock.addTimeInterval(2)
        wallClockOffset = -3_600
        XCTAssertEqual(displaced.reconciled(current: current, appKeyOf: keys), [c, b, a])
        let restored = makeStore(legacyBoot: -3_599)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: keys), [c, b, a])
        restored.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(makeStore(legacyBoot: -3_599).reconciled(current: current, appKeyOf: keys), [c, b, a])
    }

    func testCorroboratedLegacyRetirementMigratesWithoutRenewingItsGrace() {
        let retired = "tabgrp-retired-legacy"
        let b = "tabgrp-100-s1"
        let c = "tabgrp-200-s2"
        let a = "tabgrp-300-s3"
        let current = [b, c, a]
        let keys = [b: "browser", c: "calendar", a: "editor"]
        defaults.set([retired, c, b], forKey: "deskmote.windowOrder")
        defaults.set([retired: "editor", c: "calendar", b: "browser"], forKey: "deskmote.windowOrderApplications")
        defaults.set([retired: clock.addingTimeInterval(-4)], forKey: "deskmote.windowOrderRetiredAbsence")
        defaults.set(50, forKey: "deskmote.windowOrderBootTime")

        XCTAssertEqual(makeStore(legacyBoot: 50).reconciled(current: current, appKeyOf: keys), [a, c, b])
        clock.addTimeInterval(2)
        wallClockOffset = -3_600
        XCTAssertEqual(makeStore(legacyBoot: 50).reconciled(current: current, appKeyOf: keys), [c, b, a])
    }

    func testLearningApplicationKeysPersistsWithoutAnOrderChange() {
        let ids = ["tabgrp-a", "tabgrp-b"]
        let initial = makeStore()
        initial.sync(current: ids)
        initial.reorderGroup(ids[1], relativeTo: ids[0], after: false, current: ids)
        let keys = [ids[0]: "bundle:/Applications/A.app", ids[1]: "bundle:/Applications/B.app"]
        makeStore().sync(current: ids, appKeyOf: keys)
        let current = ["tabgrp-a-new", "tabgrp-b-new"]
        let newKeys = [current[0]: keys[ids[0]]!, current[1]: keys[ids[1]]!]
        let restored = makeStore()
        restored.sync(current: current, appKeyOf: newKeys)
        XCTAssertEqual(restored.reconciled(current: current, appKeyOf: newKeys), [current[1], current[0]])
    }

    func testExpiredApplicationRankDoesNotReturnWithANewSeatWithoutAnIntermediateSync() {
        let store = makeStore()
        let keys = ["a-old": "editor", "b": "browser", "a-new": "editor"]
        store.sync(current: ["a-old", "b"], appKeyOf: keys)
        store.sync(current: ["b"], appKeyOf: keys)
        clock.addTimeInterval(6)
        XCTAssertEqual(store.reconciled(current: ["b", "a-new"], appKeyOf: keys), ["b", "a-new"])
        store.sync(current: ["b", "a-new"], appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["b", "a-new"])
        XCTAssertEqual(makeStore().reconciled(current: ["b", "a-new"], appKeyOf: keys), ["b", "a-new"])
    }

    func testExpiredSeatDoesNotRecoverItsRankWhenItReturnsDirectly() {
        let store = makeStore()
        let keys = ["a": "editor", "b": "browser"]
        store.sync(current: ["a", "b"], appKeyOf: keys)
        store.sync(current: ["b"], appKeyOf: keys)
        clock.addTimeInterval(6)
        XCTAssertEqual(store.reconciled(current: ["b", "a"], appKeyOf: keys), ["b", "a"])
        store.sync(current: ["b", "a"], appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["b", "a"])
    }

    private func orderSnapshot(pid: Int32, id: UInt32) -> AXWindowSnapshot {
        AXWindowSnapshot(pid: pid, cgWindowID: id, titleRead: .value("Window \(id)"),
            bounds: CGRect(x: CGFloat(id % 100) * 50, y: 100, width: 600, height: 400),
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
            isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(pid))
    }

    func testReorderingOneDisplayKeepsOtherDisplayWindowsInGlobalOrder() {
        let store = makeStore()
        let ids = ["a-left", "b-right", "c-left", "d-right"]
        store.sync(current: ids)
        store.reorderGroup("c-left", relativeTo: "a-left", after: false, current: ids)
        XCTAssertEqual(store.liveOrder, ["c-left", "a-left", "b-right", "d-right"])
        XCTAssertEqual(store.liveOrder.filter { $0.hasSuffix("right") }, ["b-right", "d-right"])
    }

    func testInvalidGroupDragTargetsDoNotChangeOrder() {
        let order = ["a1", "a2", "b1", "b2"]
        let keys = ["a1": "a", "a2": "a", "b1": "b", "b2": "b"]
        for pair in [("a", "a"), ("missing", "a"), ("a", "missing")] {
            XCTAssertEqual(TaskbarGroupOrdering.moving(pair.0, relativeTo: pair.1, after: true,
                                                       order: order, appKeys: keys), order)
        }
    }
}
