import Testing
import XCTest
@testable import NaturalSwitch

enum TestFailure: Error {
    case unavailable
}

@MainActor
final class MonitorFixture: DeviceMonitoring {
    var onChange: (() -> Void)?
    var devices: [HIDDevice] = []
    var startError: Error?
    var snapshotError: Error?
    var starts = 0
    var stops = 0
    var snapshots = 0

    func start() throws {
        starts += 1
        if let startError { throw startError }
    }

    func snapshot() throws -> [HIDDevice] {
        snapshots += 1
        if let snapshotError { throw snapshotError }
        return devices
    }

    func stop() { stops += 1 }

    func connectMice(_ count: Int) {
        let mouse = HIDDevice(properties: ["Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 2])
        devices = Array(repeating: mouse, count: count)
        onChange?()
    }
}

@MainActor
final class ScrollingFixture: ScrollControlling {
    var natural: Bool
    var writes: [Bool] = []
    var readError: Error?
    var writeError: Error?

    init(_ natural: Bool) { self.natural = natural }

    func isNatural() throws -> Bool {
        if let readError { throw readError }
        return natural
    }

    func setNatural(_ enabled: Bool) throws {
        if let writeError { throw writeError }
        natural = enabled
        writes.append(enabled)
    }
}

final class NaturalSwitchStartupTests: XCTestCase {
    func testFailedStartupReportsAnErrorOnlyWhenRequested() {
        MainActor.assumeIsolated {
            var reports = 0
            let module = NaturalSwitchModule(makeScrolling: { throw TestFailure.unavailable },
                                             presentFailure: { _ in reports += 1 })
            XCTAssertFalse(module.start(presentStartupError: false))
            XCTAssertEqual(reports, 0)
            XCTAssertFalse(module.start(presentStartupError: true))
            XCTAssertEqual(reports, 1)
        }
    }
}

@Suite @MainActor
struct ScrollCoordinatorTests {
    @Test func startupWithoutMouseEnablesNaturalScrolling() {
        let monitor = MonitorFixture()
        let scroll = ScrollingFixture(false)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        #expect(scroll.writes == [true])
    }

    @Test func mousePresenceStaysDisabledUntilLastDisconnects() {
        let monitor = MonitorFixture()
        monitor.connectMice(1)
        let scroll = ScrollingFixture(true)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        monitor.connectMice(2)
        monitor.connectMice(1)
        #expect(scroll.writes == [false])
        monitor.connectMice(0)
        #expect(scroll.writes == [false, true])
    }

    @Test func repeatedChecksDoNotRewriteMatchingState() {
        let monitor = MonitorFixture()
        let scroll = ScrollingFixture(true)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        coordinator.start()
        monitor.onChange?()
        #expect(scroll.writes.isEmpty)
        #expect(monitor.starts == 1)
        scroll.natural = false
        monitor.onChange?()
        #expect(scroll.writes == [true])
    }

    @Test func trackpadDoesNotDisableNaturalScrolling() {
        let monitor = MonitorFixture()
        monitor.devices = [HIDDevice(properties: ["Transport": "Bluetooth", "PrimaryUsagePage": 13, "PrimaryUsage": 5])]
        let scroll = ScrollingFixture(false)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        #expect(scroll.writes == [true])
    }

    @Test func sleepAndInactiveSessionSuspendUntilBothResume() {
        let monitor = MonitorFixture()
        let scroll = ScrollingFixture(true)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        coordinator.setSleeping(true)
        coordinator.setSessionActive(false)
        monitor.connectMice(1)
        coordinator.setSleeping(false)
        #expect(scroll.writes.isEmpty)
        coordinator.setSessionActive(true)
        #expect(scroll.writes == [false])
        #expect(monitor.starts == 2)
    }

    @Test func quitLeavesSettingAndStopsFutureWrites() {
        let monitor = MonitorFixture()
        monitor.connectMice(1)
        let scroll = ScrollingFixture(true)
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in Issue.record("Unexpected failure") })
        coordinator.start()
        coordinator.stop()
        monitor.connectMice(0)
        coordinator.setSleeping(false)
        #expect(scroll.writes == [false])
        #expect(monitor.starts == 1)
        #expect(monitor.onChange == nil)
    }

    @Test func enumerationFailureNeverMeansNoMouse() {
        let monitor = MonitorFixture()
        monitor.snapshotError = TestFailure.unavailable
        let scroll = ScrollingFixture(false)
        var failures = 0
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in failures += 1 })
        coordinator.start()
        monitor.onChange?()
        coordinator.start()
        #expect(scroll.writes.isEmpty)
        #expect(failures == 1)
        #expect(monitor.onChange == nil)
    }

    @Test func unavailableMonitorDoesNotReadOrWriteSettings() {
        let monitor = MonitorFixture()
        monitor.startError = TestFailure.unavailable
        let scroll = ScrollingFixture(false)
        var failures = 0
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in failures += 1 })
        coordinator.start()
        #expect(monitor.snapshots == 0)
        #expect(scroll.writes.isEmpty)
        #expect(failures == 1)
    }

    @Test(arguments: [true, false]) func settingsFailureStopsMonitoring(_ reading: Bool) {
        let monitor = MonitorFixture()
        let scroll = ScrollingFixture(false)
        if reading { scroll.readError = TestFailure.unavailable } else { scroll.writeError = TestFailure.unavailable }
        var failures = 0
        let coordinator = ScrollCoordinator(monitor: monitor, scrolling: scroll, onFailure: { _ in failures += 1 })
        coordinator.start()
        monitor.onChange?()
        #expect(failures == 1)
        #expect(scroll.writes.isEmpty)
        #expect(monitor.onChange == nil)
    }
}
