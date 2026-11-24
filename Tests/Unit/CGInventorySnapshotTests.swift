import CoreGraphics
import Synchronization
import XCTest

final class CGWindowSnapshotTests: XCTestCase {
    func testSignedWindowNumberPreservesTheNativeBitPattern() {
        let normal = windowInfo(id: Int(Int32.min), layer: 0, isOnScreen: true, pid: 100)
        let lower = windowInfo(id: Int(Int32.min) + 1, layer: -1, isOnScreen: true, pid: 200)
        let invalid = windowInfo(id: Int(UInt32.max) + 1, layer: 0, isOnScreen: true, pid: 100)
        let snapshot = AppTrackerCGWindowSnapshot.parse([normal, lower, invalid])
        XCTAssertEqual(snapshot.allWindowIDs, [0x80000000])
        XCTAssertEqual(snapshot.windowIDsByPID[100], [0x80000000])
        XCTAssertEqual(snapshot.belowNormalLayerWindowIDs, [0x80000001])
    }

    func testNativeRootEvidenceRequiresSameOwnerNormalLayerAndKnownParent() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 12, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 13, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 14, layer: 3, isOnScreen: true, pid: 100)
        ], parentWindowIDs: [11: 0, 12: 11, 14: 0, 99: 0])
        XCTAssertTrue(snapshot.isNormalRoot(windowID: 11, pid: 100))
        XCTAssertFalse(snapshot.isNormalRoot(windowID: 11, pid: 200))
        XCTAssertFalse(snapshot.isNormalRoot(windowID: 12, pid: 100))
        XCTAssertFalse(snapshot.isNormalRoot(windowID: 13, pid: 100))
        XCTAssertFalse(snapshot.isNormalRoot(windowID: 14, pid: 100))
        XCTAssertEqual(snapshot.parentWindowIDs, [11: 0, 12: 11])
        XCTAssertFalse(AppTrackerCGWindowSnapshot.failed.isNormalRoot(windowID: 11, pid: 100))
    }

    func testParseSeparatesAllAndOnScreenLayerZeroWindows() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100),
            windowInfo(id: 13, layer: 1, isOnScreen: true, pid: 100),
        ])

        XCTAssertEqual(snapshot.allWindowIDs, [11, 12])
        XCTAssertEqual(snapshot.onScreenWindowIDs, [11])
    }

    func testParseGroupsLayerZeroWindowsByOwnerPID() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100),
            windowInfo(id: 21, layer: 0, isOnScreen: false, pid: 200),
            windowInfo(id: 22, layer: 1, isOnScreen: true, pid: 200),
            windowInfo(id: 31, layer: 0, isOnScreen: false, pid: nil),
        ])

        XCTAssertEqual(snapshot.windowIDsByPID[100], [11, 12])
        XCTAssertEqual(snapshot.windowIDsByPID[200], [21])
        XCTAssertEqual(snapshot.allWindowIDs, [11, 12, 21, 31])
    }

    func testParseCapturesAlphaByLayerZeroWindowID() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, alpha: 1),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100, alpha: 0),
            windowInfo(id: 13, layer: 0, isOnScreen: false, pid: 100, alpha: nil),
            windowInfo(id: 14, layer: 1, isOnScreen: true, pid: 100, alpha: 0.5),
        ])

        XCTAssertEqual(snapshot.alphaByWindowID, [11: 1, 12: 0])
    }

    func testParseCapturesBoundsByLayerZeroWindowID() {
        let rect = CGRect(x: 1200, y: 40, width: 800, height: 600)
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, bounds: rect),
            windowInfo(id: 12, layer: 0, isOnScreen: false, pid: 100, bounds: nil),
            windowInfo(id: 13, layer: 1, isOnScreen: true, pid: 100, bounds: rect),
        ])

        XCTAssertEqual(snapshot.boundsByWindowID, [11: rect])
        XCTAssertTrue(AppTrackerCGWindowSnapshot.failed.boundsByWindowID.isEmpty)
    }

    func testParseTreatsMissingOnScreenFlagAsNotOnScreen() {
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 21, layer: 0, isOnScreen: nil, pid: 100),
        ])

        XCTAssertEqual(snapshot.allWindowIDs, [21])
        XCTAssertTrue(snapshot.onScreenWindowIDs.isEmpty)
    }

    func testExactCaptureUsesExplicitVisibilityWithoutAnOnScreenList() {
        let rect = CGRect(x: 1200, y: 40, width: 800, height: 600)
        let current = windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, bounds: rect)
        for flag in [false, true] {
            let exact = windowInfo(id: 11, layer: 0, isOnScreen: flag, pid: 100, bounds: rect)
            let system = ExactSnapshotSystem(descriptions: [exact], onScreenDescriptions: [current])
            let snapshot = AppTrackerCGWindowSnapshot.capture(windowID: 11, system: system)
            XCTAssertEqual(snapshot.onScreenWindowIDs, flag ? [11] : [])
            XCTAssertEqual(snapshot.ownerPIDByWindowID, [11: 100])
            XCTAssertEqual(snapshot.boundsByWindowID, [11: rect])
            XCTAssertEqual(system.onScreenRequests.withLock { $0 }, 0)
        }
    }

    func testExactCaptureUsesTheMatchingOnScreenRecordWhenVisibilityIsOmitted() {
        let oldBounds = CGRect(x: 120, y: 40, width: 800, height: 600)
        let newBounds = CGRect(x: 1200, y: 40, width: 800, height: 600)
        let old = windowInfo(id: 11, layer: 0, isOnScreen: nil, pid: 100, alpha: 0.5, bounds: oldBounds)
        let unrelated = windowInfo(id: 22, layer: 0, isOnScreen: nil, pid: 100, bounds: oldBounds)
        let current = windowInfo(id: 11, layer: 0, isOnScreen: nil, pid: 100, alpha: 1, bounds: newBounds)
        let system = ExactSnapshotSystem(descriptions: [old], onScreenDescriptions: [unrelated, current])

        let snapshot = AppTrackerCGWindowSnapshot.capture(windowID: 11, system: system)

        XCTAssertEqual(system.onScreenRequests.withLock { $0 }, 1)
        XCTAssertEqual(snapshot.allWindowIDs, [11])
        XCTAssertEqual(snapshot.onScreenWindowIDs, [11])
        XCTAssertEqual(snapshot.ownerPIDByWindowID, [11: 100])
        XCTAssertEqual(snapshot.boundsByWindowID, [11: newBounds])
        XCTAssertEqual(snapshot.alphaByWindowID, [11: 1])
    }

    func testExactCaptureDoesNotConfirmAbsentReusedOrIneligibleOnScreenRecords() {
        let bounds = CGRect(x: 1200, y: 40, width: 800, height: 600)
        let old = windowInfo(id: 11, layer: 0, isOnScreen: nil, pid: 100, bounds: bounds)
        let current = windowInfo(id: 11, layer: 0, isOnScreen: nil, pid: 100, bounds: bounds)
        let reused = windowInfo(id: 11, layer: 0, isOnScreen: nil, pid: 200, bounds: bounds)
        let candidates: [[[String: Any]]?] = [
            nil,
            [],
            [windowInfo(id: 22, layer: 0, isOnScreen: nil, pid: 100, bounds: bounds)],
            [reused],
            [current, reused],
            [windowInfo(id: 11, layer: 1, isOnScreen: nil, pid: 100, bounds: bounds)],
            [windowInfo(id: 11, layer: 0, isOnScreen: false, pid: 100, bounds: bounds)],
        ]
        for records in candidates {
            let system = ExactSnapshotSystem(descriptions: [old], onScreenDescriptions: records)

            let snapshot = AppTrackerCGWindowSnapshot.capture(windowID: 11, system: system)

            XCTAssertEqual(system.onScreenRequests.withLock { $0 }, 1)
            XCTAssertTrue(snapshot.onScreenWindowIDs.isEmpty)
        }
    }

    func testParseIgnoresMalformedEntriesAndHandlesEmptyInput() {
        let malformed: [[String: Any]] = [
            [kCGWindowLayer as String: 0],
            [kCGWindowNumber as String: 31],
            [kCGWindowLayer as String: "0", kCGWindowNumber as String: 32],
        ]

        let empty = AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:]
        )
        XCTAssertEqual(AppTrackerCGWindowSnapshot.parse(malformed), empty)
        XCTAssertEqual(AppTrackerCGWindowSnapshot.parse([]), empty)
    }

    func testParseNeverMarksCaptureFailed() {
        XCTAssertFalse(AppTrackerCGWindowSnapshot.parse([]).captureFailed)
        XCTAssertFalse(AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100),
        ]).captureFailed)
    }

    func testFailedFactoryIsEmptyAndMarksCaptureFailed() {
        let failed = AppTrackerCGWindowSnapshot.failed
        XCTAssertTrue(failed.captureFailed)
        XCTAssertTrue(failed.allWindowIDs.isEmpty)
        XCTAssertTrue(failed.onScreenWindowIDs.isEmpty)
        XCTAssertTrue(failed.windowIDsByPID.isEmpty)
        XCTAssertTrue(failed.alphaByWindowID.isEmpty)
    }

    func testParseCollectsBelowNormalLayerWindowIDsSeparately() {
        let rect = CGRect(x: 16, y: 30, width: 344, height: 359)
        let snapshot = AppTrackerCGWindowSnapshot.parse([
            windowInfo(id: 11, layer: 0, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
            windowInfo(id: 12, layer: -20, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
            windowInfo(id: 13, layer: 3, isOnScreen: true, pid: 100, alpha: 1, bounds: rect),
        ])

        XCTAssertEqual(snapshot.belowNormalLayerWindowIDs, [12])
        XCTAssertEqual(snapshot.allWindowIDs, [11])
        XCTAssertEqual(snapshot.onScreenWindowIDs, [11])
        XCTAssertEqual(snapshot.windowIDsByPID, [100: [11]])
        XCTAssertEqual(snapshot.alphaByWindowID, [11: 1])
        XCTAssertEqual(snapshot.boundsByWindowID, [11: rect])
        XCTAssertTrue(AppTrackerCGWindowSnapshot.failed.belowNormalLayerWindowIDs.isEmpty)
    }

    func testFailedDiffersFromGenuinelyEmptyCapture() {
        XCTAssertNotEqual(AppTrackerCGWindowSnapshot.failed, AppTrackerCGWindowSnapshot.parse([]))
    }

    private func windowInfo(
        id: Int,
        layer: Int,
        isOnScreen: Bool?,
        pid: Int?,
        alpha: Double? = nil,
        bounds: CGRect? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
        ]
        if let isOnScreen {
            info[kCGWindowIsOnscreen as String] = isOnScreen
        }
        if let pid {
            info[kCGWindowOwnerPID as String] = pid
        }
        if let alpha {
            info[kCGWindowAlpha as String] = alpha
        }
        if let bounds {
            info[kCGWindowBounds as String] = bounds.dictionaryRepresentation
        }
        return info
    }
}

private final class ExactSnapshotSystem: WindowSystemAccess, @unchecked Sendable {
    let descriptions: [[String: Any]]
    let onScreenDescriptions: [[String: Any]]?
    let onScreenRequests = Mutex(0)

    init(descriptions: [[String: Any]], onScreenDescriptions: [[String: Any]]?) {
        self.descriptions = descriptions
        self.onScreenDescriptions = onScreenDescriptions
    }

    func generation(_ pid: pid_t) -> ProcessGeneration? { nil }
    func app(_ pid: pid_t) -> WindowApplicationState? { nil }
    func activate(_ pid: pid_t) -> Bool { false }
    func unhide(_ pid: pid_t) {}
    func terminate(_ pid: pid_t, generation: ProcessGeneration, origin: ApplicationOrigin?) -> Bool { false }
    func windowInfo(_ options: CGWindowListOption, _ relative: CGWindowID) -> [[String: Any]]? {
        onScreenRequests.withLock { $0 += 1 }
        guard options == [.optionOnScreenOnly, .excludeDesktopElements], relative == kCGNullWindowID else { return nil }
        return onScreenDescriptions
    }

    func windowDescriptions(for ids: [CGWindowID]) -> [[String: Any]]? { ids == [11] ? descriptions : [] }
}
