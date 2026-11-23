import XCTest

final class TaskbarDisplaySetTests: XCTestCase {
    func testSeparateUnitsFollowDisplayOrder() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["A", "B"], physicalDisplayCount: 2), ["A", "B"])
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["B"], physicalDisplayCount: 1), ["B"])
    }

    func testMissingUUIDKeepsAPrimaryUnitOnlyWhenAScreenExists() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: [], physicalDisplayCount: 1), [nil])
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: [], physicalDisplayCount: 0), [])
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["stale"], physicalDisplayCount: 0), [])
    }

    func testUnidentifiedPrimaryKeepsItsPanelAlongsideAnIdentifiedSecondary() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(connectedKeys: ["B"], physicalDisplayCount: 2,
                                                         hasIdentifiedPrimary: false), [nil, "B"])
        let primary = StripDisplayFilter(scope: nil, connectedUUIDs: ["B"], primaryUUID: nil)
        let secondary = StripDisplayFilter(scope: "B", connectedUUIDs: ["B"], primaryUUID: nil)
        XCTAssertTrue(primary.shows(displayUUID: nil))
        XCTAssertFalse(primary.shows(displayUUID: "B"))
        XCTAssertFalse(secondary.shows(displayUUID: nil))
        XCTAssertTrue(secondary.shows(displayUUID: "B"))
    }
}
