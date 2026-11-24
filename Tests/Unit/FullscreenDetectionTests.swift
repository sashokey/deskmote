import Synchronization
import XCTest

@MainActor
final class FullscreenProbeWorkerCancellationTests: XCTestCase {
    func testStoppedWindowedProbeSkipsTheSeparateSpaceRead() async {
        let enteredAX = Mutex(false)
        let releaseAX = DispatchSemaphore(value: 0)
        let spaceReads = Mutex(0)
        let worker = FullscreenProbeWorker(read: { _ in
            enteredAX.withLock { $0 = true }
            _ = releaseAX.wait(timeout: .now() + 3)
            return FullscreenAXProbe(verdict: .windowed, overlayWindowID: nil)
        }, readSpace: { _ in
            spaceReads.withLock { $0 += 1 }
            return false
        }, deliver: { _, _ in XCTFail("Stopped probe delivered a result") })
        defer { releaseAX.signal(); worker.stop() }
        worker.request(FullscreenProbeRequest(pid: -51230, screenFrame: .zero, generation: 1,
                                              spaceGeneration: nil, finalConfirmation: false, source: "test"))
        let deadline = ContinuousClock.now + .seconds(2)
        while !enteredAX.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(enteredAX.withLock { $0 })
        let pending = worker.pendingWorkForTesting
        worker.stop()
        releaseAX.signal()
        for task in pending { await task.value }

        XCTAssertEqual(spaceReads.withLock { $0 }, 0)
    }
}

final class FullscreenClassificationTests: XCTestCase {
    private func isFullscreen(role: String?, isAXFullscreen: Bool, windowFrame: CGRect?,
                              windowLayer: Int?, displayWindowServerFrame: CGRect) -> Bool {
        FullscreenWindowClassifier.classify(role: role, isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame, windowLayer: windowLayer, displayWindowServerFrame: displayWindowServerFrame) == .fullscreen
    }

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testScreenSizedOverlayWithoutAXFlagIsFullscreen() {
        XCTAssertEqual(FullscreenWindowClassifier.classify(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen, windowLayer: 1000, displayWindowServerFrame: screen),
            .fullscreen)
    }

    func testOverlayWatchKeepsWaitingWhileTheWindowStillCoversTheScreen() {
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: screen, displayWindowServerFrame: screen))
        let nudged = screen.insetBy(dx: 2, dy: 2)
        XCTAssertFalse(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nudged, displayWindowServerFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowIsGoneOrOrderedOut() {
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: nil, bounds: nil, displayWindowServerFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: false, bounds: screen, displayWindowServerFrame: screen))
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: nil, displayWindowServerFrame: screen))
    }

    func testOverlayWatchRechecksWhenTheWindowStopsCoveringTheScreen() {
        let shrunk = CGRect(x: 100, y: 80, width: 1200, height: 800)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: shrunk, displayWindowServerFrame: screen))
        let moved = screen.offsetBy(dx: 1512, dy: 0)
        XCTAssertTrue(OverlayWindowWatch.shouldRecheck(isOnscreen: true, bounds: moved, displayWindowServerFrame: screen))
    }

    func testDesktopPseudoWindowWithExactScreenFrameIsNotFullscreen() {
        XCTAssertFalse(isFullscreen(
            role: "AXScrollArea", isAXFullscreen: false, windowFrame: screen, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithExactScreenFrame() {
        XCTAssertFalse(isFullscreen(
            role: nil, isAXFullscreen: false, windowFrame: screen, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithAXFullscreenFlag() {
        XCTAssertFalse(isFullscreen(
            role: nil, isAXFullscreen: true, windowFrame: nil, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testNativeFullscreenWindowIsFullscreen() {
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testNativeFullscreenWithUnreadableFrameIsFullscreen() {
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: nil, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testNativeFullscreenOnAnotherScreenIsNotFullscreenHere() {
        let otherScreen = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: otherScreen, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testSplitViewTileOnThisScreenIsFullscreen() {
        let leftTile = CGRect(x: 0, y: 20, width: 754, height: 962)
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: leftTile, windowLayer: 0, displayWindowServerFrame: screen))
        let rightTile = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: rightTile, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testFullscreenWindowMostlyOnNeighborScreenIsNotFullscreenHere() {
        let mostlyElsewhere = CGRect(x: 1480, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: mostlyElsewhere, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testDesktopTiledHalfWindowIsNotFullscreen() {
        let tiled = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: tiled, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testBorderlessScreenSizedWindowIsFullscreen() {
        let nearScreen = screen.insetBy(dx: 2, dy: 2)
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nearScreen, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testScreenSizedWindowBelowNormalLayerIsNotFullscreen() {
        let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: desktopIconLayer, displayWindowServerFrame: screen))
        XCTAssertEqual(
            FullscreenWindowClassifier.classify(
                role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
                windowLayer: -1, displayWindowServerFrame: screen),
            .windowed)
    }

    func testScreenSizedWindowWithUnknownOrRaisedLayerIsFullscreen() {
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: nil, displayWindowServerFrame: screen))
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: screen,
            windowLayer: Int(CGWindowLevelForKey(.screenSaverWindow)), displayWindowServerFrame: screen))
    }

    func testNativeFullscreenFlagIgnoresLayer() {
        XCTAssertTrue(isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen,
            windowLayer: -1, displayWindowServerFrame: screen))
    }

    func testOrdinaryWindowIsNotFullscreen() {
        let partial = CGRect(x: 253, y: 125, width: 1127, height: 689)
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: partial, windowLayer: 0, displayWindowServerFrame: screen))
    }

    func testRealWindowWithUnreadableFrameIsNotFullscreen() {
        XCTAssertFalse(isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nil, windowLayer: 0, displayWindowServerFrame: screen))
    }


    func testMembershipIsHealthyWhenWindowCoversEveryDesktop() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1020], desktopSpaceIDs: [1, 3, 1020]),
            [])
    }

    func testMembershipCollapsedToCurrentDesktopIsReported() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: [1, 3, 1020]),
            [3, 1020])
    }

    func testExtraFullscreenSpaceMembershipIsNotAProblem() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1013], desktopSpaceIDs: [1, 3]),
            [])
    }

    func testSingleDesktopNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [], desktopSpaceIDs: [1]),
            [])
    }

    func testEmptyDesktopListNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: []),
            [])
    }

    func testRepairRetriesAreBounded() {
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 0))
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 2))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 3))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 4))
    }
}
