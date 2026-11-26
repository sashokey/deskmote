import XCTest

final class PanelVisibilityStateTests: XCTestCase {
    func testOnlyConfirmedDesktopShowsThePanel() {
        XCTAssertFalse(PanelVisibilityState.unknown.isVisible)
        XCTAssertTrue(PanelVisibilityState.desktop.isVisible)
        XCTAssertFalse(PanelVisibilityState.fullscreen.isVisible)
    }
}
