import ApplicationServices
import CoreGraphics
import XCTest

final class AXElementCacheTests: XCTestCase {
    func testOldFailedLookupCannotEvictANewerElement() throws {
        let cache = AXElementCache()
        let first = AXUIElementCreateApplication(45)
        let replacement = AXUIElementCreateApplication(46)
        cache.store(pid: 45, cgWindowID: 100, element: first)
        cache.store(pid: 45, cgWindowID: 100, element: replacement)
        cache.remove(pid: 45, cgWindowID: 100, matching: first)
        let retained = try XCTUnwrap(cache.element(pid: 45, cgWindowID: 100))
        XCTAssertTrue(CFEqual(retained, replacement))
        cache.remove(pid: 45, cgWindowID: 100, matching: replacement)
        XCTAssertNil(cache.element(pid: 45, cgWindowID: 100))
    }

    func testElementIdentitySurvivesTransferFromABackgroundTask() async {
        let key = await Task.detached {
            AXElementKey(e: AXUIElementCreateApplication(getpid()))
        }.value
        let returned = await Task.detached { key }.value

        XCTAssertEqual(key, returned)
        XCTAssertEqual(key.hashValue, returned.hashValue)
        XCTAssertEqual(CFGetTypeID(returned.e), AXUIElementGetTypeID())
    }

    func testWindowStillInCGListSurvivesEvenWhenAXNoLongerReportsIt() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 7, element: element)
        cache.retain(pid: 42, liveCGWindowIDs: [7])
        XCTAssertEqual(cache.element(pid: 42, cgWindowID: 7).map { CFEqual($0, element) }, true)
    }

    func testSuccessfulEmptyLiveListExpiresAllHandlesForOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 43, cgWindowID: 3, element: element)
        cache.retain(pid: 42, liveCGWindowIDs: [])
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 1))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 2))
        XCTAssertNotNil(cache.element(pid: 43, cgWindowID: 3))
    }


    func testStoreAndLookupIsKeyedByPidAndWindow() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 42, cgWindowID: 7, element: element)

        XCTAssertNotNil(cache.element(pid: 42, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 8), "Windows in one process keep separate handles")
        XCTAssertNil(cache.element(pid: 43, cgWindowID: 7), "A reused window number cannot cross process boundaries")
    }

    func testInvalidIdentitiesAreRejectedOnStoreAndLookup() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 0, cgWindowID: 7, element: element)
        cache.store(pid: -1, cgWindowID: 7, element: element)
        cache.store(pid: 42, cgWindowID: 0, element: element)

        XCTAssertEqual(cache.countForTesting, 0)
        XCTAssertNil(cache.element(pid: 0, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 0))
    }

    func testRemoveAllDropsOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 3, element: element)

        cache.removeAll(pid: 42)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 2))
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 3))
    }

    func testRetainOnlyPrunesTheGivenProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 1, element: element)

        cache.retain(pid: 42, liveCGWindowIDs: [2])

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1), "Remove the handle when the window disappears from Core Graphics")
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2), "Keep the handle when the window remains in Core Graphics")
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 1), "Leave other processes untouched")
    }

    func testRemoveDropsExactlyOneEntry() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)

        cache.remove(pid: 42, cgWindowID: 1)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2))
    }
}
