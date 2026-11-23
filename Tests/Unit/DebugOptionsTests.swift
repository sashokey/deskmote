import XCTest

final class DebugSwitchTests: XCTestCase {
    func testKillSwitchIsOnUnlessExplicitlyZero() {
        let s = DebugSwitch.axElementCache
        XCTAssertEqual(s.kind, .killSwitch)
        XCTAssertTrue(s.isEnabled(in: [:]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "false"]), "Only the literal \"0\" disables this option")
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "0"]))
    }

    func testTraceIsOffUnlessExplicitlyOne() {
        let s = DebugSwitch.hoverTrace
        XCTAssertEqual(s.kind, .trace)
        XCTAssertFalse(s.isEnabled(in: [:]))
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "true"]), "Only the literal \"1\" enables this option")
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
    }

    func testValueReturnsRawStringOrNil() {
        let s = DebugSwitch.reconcileAxTimeoutMs
        XCTAssertEqual(s.kind, .value)
        XCTAssertNil(s.value(in: [:]))
        XCTAssertEqual(s.value(in: [s.rawValue: " 250 "]), " 250 ")
    }

    func testEveryCaseHasDockPrefixAndUniqueRawValue() {
        let raws = DebugSwitch.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for raw in raws { XCTAssertTrue(raw.hasPrefix("DOCK_"), raw) }
    }
}
