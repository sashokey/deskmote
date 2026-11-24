import Foundation
import IOKit
import XCTest
import Testing
@testable import NaturalSwitch

@Test(arguments: ["USB", "Bluetooth", "BluetoothLowEnergy"])
func externalMouseUsesSupportedTransports(_ transport: String) {
    let device = HIDDevice(properties: ["Transport": transport, "PrimaryUsagePage": 1, "PrimaryUsage": 2])
    #expect(device.isExternalMouse)
}

@Test func compoundDeviceUsesUsagePairs() {
    let device = HIDDevice(properties: [
        "Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 6,
        "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 6], ["DeviceUsagePage": 1, "DeviceUsage": 2]]
    ])
    #expect(device.isExternalMouse)
}

@Test(arguments: ["SPI", "I2C", "Virtual", ""])
func internalAndVirtualTransportsAreExcluded(_ transport: String) {
    #expect(!HIDDevice(properties: ["Transport": transport, "PrimaryUsagePage": 1, "PrimaryUsage": 2]).isExternalMouse)
}

@Test func builtInAndVirtualFlagsAreExcluded() {
    for flag in ["Built-In", "HIDVirtualDevice", "VirtualHIDDevice"] {
        #expect(!HIDDevice(properties: ["Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 2, flag: true]).isExternalMouse)
    }
}

@Test func keyboardAndMalformedDevicesAreExcluded() {
    #expect(!HIDDevice(properties: ["Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 6]).isExternalMouse)
    #expect(!HIDDevice(properties: [:]).isExternalMouse)
}

@Test func touchpadUsageIsExcluded() {
    let device = HIDDevice(properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 2], ["DeviceUsagePage": 13, "DeviceUsage": 5]]
    ])
    #expect(!device.isExternalMouse)
}

@Test func systemPointerClassificationOverridesAmbiguousUsages() {
    let mouse = HIDDevice(properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "HIDPointerAccelerationType": "HIDMouseAcceleration",
        "DeviceUsagePairs": [["DeviceUsagePage": 13, "DeviceUsage": 5]]
    ])
    let trackpad = HIDDevice(properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "HIDPointerAccelerationType": "HIDTrackpadAcceleration"
    ])
    #expect(mouse.isExternalMouse)
    #expect(!trackpad.isExternalMouse)
}

final class NaturalSwitchDeviceMonitorTests: XCTestCase {
    func testMissingRunLoopSourceDestroysTheNewPortBeforeRegistering() throws {
        try MainActor.assumeIsolated {
            let fixture = try NotificationFixture()
            fixture.sourceAvailable = false
            let monitor = DeviceMonitor(notifications: fixture.notifications)
            XCTAssertThrowsError(try monitor.start())
            XCTAssertEqual(fixture.sourceReads, 1)
            XCTAssertEqual(fixture.destroyedPorts, [fixture.port])
            XCTAssertTrue(fixture.registrations.isEmpty)
            monitor.stop()
            XCTAssertEqual(fixture.destroyedPorts, [fixture.port])
        }
    }

    func testRegistrationFailureReleasesTheEarlierIteratorAndAttachedSource() throws {
        try MainActor.assumeIsolated {
            let fixture = try NotificationFixture()
            fixture.failedRegistration = kIOTerminatedNotification
            let monitor = DeviceMonitor(notifications: fixture.notifications)
            XCTAssertThrowsError(try monitor.start())
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
            XCTAssertEqual(fixture.sourceReads, 1)
            XCTAssertEqual(fixture.released, [101, 1])
            XCTAssertEqual(fixture.destroyedPorts, [fixture.port])
        }
    }

    func testDetachesTheAttachedSourceWithoutLookingItUpAgain() throws {
        try MainActor.assumeIsolated {
            let fixture = try NotificationFixture()
            let monitor = DeviceMonitor(notifications: fixture.notifications)
            try monitor.start()
            XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
            monitor.stop()
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
            XCTAssertEqual(fixture.sourceReads, 1)
            XCTAssertEqual(fixture.released, [101, 102, 1, 2])
            XCTAssertEqual(fixture.destroyedPorts, [fixture.port])
        }
    }

    func testRegistrationDrainsWithoutSchedulingAnotherScan() throws {
        try MainActor.assumeIsolated {
            let fixture = try NotificationFixture()
            let monitor = DeviceMonitor(notifications: fixture.notifications)
            let startupChange = XCTestExpectation(description: "No notification for the initial iterator drain")
            startupChange.isInverted = true
            monitor.onChange = { startupChange.fulfill() }
            defer { monitor.stop() }
            try monitor.start()
            XCTAssertEqual(fixture.released, [101, 102])
            XCTAssertEqual(XCTWaiter.wait(for: [startupChange], timeout: 0.25), .completed)

            let changed = XCTestExpectation(description: "One refresh for two notifications")
            changed.assertForOverFulfill = true
            var changes = 0
            monitor.onChange = { changes += 1; changed.fulfill() }
            try fixture.deliver(1, objects: [201])
            try fixture.deliver(2, objects: [202])
            XCTAssertEqual(fixture.released, [101, 102, 201, 202])
            XCTAssertEqual(changes, 0)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
            XCTAssertEqual(changes, 1)
        }
    }
}

@MainActor
private final class NotificationFixture {
    let port = OpaquePointer(bitPattern: 1)!
    let source: CFRunLoopSource
    var sourceReads = 0
    var sourceAvailable = true
    var failedRegistration: String?
    var registrations: [String] = []
    var released: [io_object_t] = []
    var destroyedPorts: [IONotificationPortRef] = []
    private var objects: [io_iterator_t: [io_object_t]] = [1: [101], 2: [102]]
    private var callback: IOServiceMatchingCallback?
    private var context: UnsafeMutableRawPointer?

    init() throws {
        var sourceContext = CFRunLoopSourceContext()
        sourceContext.perform = { _ in }
        source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &sourceContext))
    }

    var notifications: DeviceMonitor.Notifications {
        .init(
            create: { self.port },
            getSource: { _ in
                self.sourceReads += 1
                return self.sourceAvailable ? self.source : nil
            },
            destroy: { self.destroyedPorts.append($0) },
            register: { _, kind, callback, context in
                self.registrations.append(kind)
                if kind == self.failedRegistration { throw TestFailure.unavailable }
                self.callback = callback
                self.context = context
                return kind == kIOMatchedNotification ? 1 : 2
            },
            next: { iterator in
                guard self.objects[iterator]?.isEmpty == false else { return 0 }
                return self.objects[iterator]?.removeFirst() ?? 0
            },
            release: { self.released.append($0) }
        )
    }

    func deliver(_ iterator: io_iterator_t, objects: [io_object_t]) throws {
        self.objects[iterator] = objects
        try XCTUnwrap(callback)(context, iterator)
    }
}
