import XCTest

final class InventoryPhantomOwnerTests: XCTestCase {
    func testPhantomOwnerRequiresExactlyOneCandidate() {
        let first = InventoryPhantomOwner(seatActiveWindowNumber: 10)
        let second = InventoryPhantomOwner(seatActiveWindowNumber: 20)

        XCTAssertNil(InventoryPhantomOwnerResolution.uniqueOwner(from: []))
        XCTAssertEqual(InventoryPhantomOwnerResolution.uniqueOwner(from: [first]), first)
        XCTAssertNil(InventoryPhantomOwnerResolution.uniqueOwner(from: [first, second]))
    }
}
