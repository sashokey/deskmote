import Carbon
import XCTest
@testable import CommandShift

final class SystemInputSourcesTests: XCTestCase {
    func testSwitchPassesTheChosenMappedSourceAndForwardsSystemFailure() {
        MainActor.assumeIsolated {
            var selected: [Fixture] = []
            let current = Fixture(id: "first", value: 1)
            let unidentifiable = Fixture(id: nil, value: 2)
            let next = Fixture(id: "next", value: 3)
            let later = Fixture(id: "later", value: 4)
            let status = SystemInputSources.selectNext(
                readSources: { _ in [current, unidentifiable, next, later] },
                readCurrent: { Fixture(id: "first", value: 5) },
                identifier: \.id,
                select: { selected.append($0); return -50 }
            )
            XCTAssertEqual(selected, [next])
            XCTAssertEqual(status, -50)
        }
    }

    func testQueryRequestsOnlyEnabledSelectableKeyboardSources() {
        MainActor.assumeIsolated {
            var query: [String: Any]?
            let status = SystemInputSources.selectNext(
                readSources: { filter -> [Fixture] in query = filter as? [String: Any]; return [] },
                readCurrent: { nil },
                identifier: \.id,
                select: { _ in XCTFail("Selected a source from an empty catalog"); return -50 }
            )
            XCTAssertEqual(query?.count, 3)
            XCTAssertEqual(
                query?[kTISPropertyInputSourceCategory as String] as? String,
                kTISCategoryKeyboardInputSource as String
            )
            XCTAssertEqual(query?[kTISPropertyInputSourceIsEnabled as String] as? Bool, true)
            XCTAssertEqual(query?[kTISPropertyInputSourceIsSelectCapable as String] as? Bool, true)
            XCTAssertEqual(status, noErr)
        }
    }

    func testUnlistedCurrentUsesTheFirstIdentifiableSource() {
        MainActor.assumeIsolated {
            let first = Fixture(id: "first", value: 1)
            var selected: [Fixture] = []
            let status = SystemInputSources.selectNext(
                readSources: { _ in [Fixture(id: nil, value: 0), first] },
                readCurrent: { Fixture(id: "unlisted", value: 2) },
                identifier: \.id,
                select: { selected.append($0); return noErr }
            )
            XCTAssertEqual(selected, [first])
            XCTAssertEqual(status, noErr)
        }
    }

    private struct Fixture: Equatable {
        let id: String?
        let value: Int
    }
}
