import CoreGraphics
import XCTest
@testable import CommandShift

final class KeyboardMonitorTests: XCTestCase {
    func testStopOrRevocationCancelsAnAlreadyQueuedSwitch() throws {
        try MainActor.assumeIsolated {
            for revoke in [true, false] {
                let fixture = try TapFixture()
                var granted = true
                var count = 0
                let monitor = fixture.makeMonitor(hasPermission: { granted }, onShortcut: { count += 1 })
                defer { monitor.stop() }
                XCTAssertEqual(monitor.start(), .running)
                try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
                try fixture.send(.flagsChanged, flags: [])
                if revoke { granted = false } else { monitor.stop() }
                Self.drainQueue()
                XCTAssertEqual(count, 0)
            }
        }
    }

    func testStartRejectsAnInstalledTapMissingRequiredEvents() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            fixture.includeExistingTap = true
            let monitor = fixture.makeMonitor()
            fixture.removedEvents = [CGEventType.flagsChanged]
            XCTAssertEqual(monitor.start(), .unavailable)
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
        }
    }

    func testUnreportedTapCannotBorrowACompetingTapMask() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            fixture.reportsCompetingTapOnly = true
            let monitor = fixture.makeMonitor()
            XCTAssertEqual(monitor.start(), .unavailable)
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
        }
    }

    func testInvalidatedTapReportsOneInterruptionAndKeepsTheOriginalCallback() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            let counter = fixture.invalidationCounter
            CFMachPortSetInvalidationCallBack(fixture.port) { _, context in
                guard let context else { return }
                Unmanaged<TapFixture.InvalidationCounter>.fromOpaque(context).takeUnretainedValue().calls += 1
            }
            var observed: [KeyboardMonitor.State] = []
            let monitor = fixture.makeMonitor()
            monitor.onInterruption = { observed.append($0) }
            XCTAssertEqual(monitor.start(), .running)
            CFMachPortInvalidate(fixture.port)
            Self.drainQueue()
            XCTAssertEqual(counter.calls, 1)
            XCTAssertEqual(observed, [.unavailable])
            monitor.stop()
            Self.drainQueue()
            XCTAssertEqual(observed, [.unavailable])
        }
    }

    func testQueuedShortcutReportsAnUnavailablePortOrDisabledTap() throws {
        try MainActor.assumeIsolated {
            for invalidate in [true, false] {
                let fixture = try TapFixture()
                var observed: [KeyboardMonitor.State] = []
                let monitor = fixture.makeMonitor(onShortcut: { XCTFail("Switched with an unusable tap") })
                monitor.onInterruption = { observed.append($0) }
                XCTAssertEqual(monitor.start(), .running)
                try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
                try fixture.send(.flagsChanged, flags: [])
                if invalidate {
                    CFMachPortInvalidate(fixture.port)
                } else {
                    fixture.enabled = false
                    fixture.canEnable = false
                }
                Self.drainQueue()
                XCTAssertEqual(observed, [.unavailable])
            }
        }
    }

    func testDisabledTapRecoversBeforeQuartzNotificationWithoutSwitchingTheOldChord() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            var switches = 0
            var interruptions: [KeyboardMonitor.State] = []
            let monitor = fixture.makeMonitor(onShortcut: { switches += 1 })
            monitor.onInterruption = { interruptions.append($0) }
            XCTAssertEqual(monitor.start(), .running)

            for _ in 0..<2 {
                try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
                try fixture.send(.flagsChanged, flags: [])
            }
            fixture.enabled = false
            Self.drainQueue()
            XCTAssertTrue(fixture.enabled)
            XCTAssertTrue(CFMachPortIsValid(fixture.port))
            XCTAssertEqual(switches, 0)
            XCTAssertTrue(interruptions.isEmpty)

            try fixture.send(.tapDisabledByTimeout, flags: [])
            try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
            try fixture.send(.flagsChanged, flags: [])
            Self.drainQueue()
            XCTAssertEqual(switches, 1)
            XCTAssertTrue(interruptions.isEmpty)
        }
    }

    func testExplicitStopDoesNotReportATapInterruption() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            let monitor = fixture.makeMonitor()
            monitor.onInterruption = { _ in XCTFail("Reported an explicit stop as an interruption") }
            XCTAssertEqual(monitor.start(), .running)
            monitor.stop()
            Self.drainQueue()
        }
    }

    func testStartRejectsATapThatCannotBeEnabled() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            fixture.enabled = false
            fixture.canEnable = false
            let monitor = fixture.makeMonitor()
            XCTAssertEqual(monitor.start(), .unavailable)
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
        }
    }

    func testFailedReenableInvalidatesThePortAndCancelsTheQueuedSwitch() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            var count = 0
            var interruptions: [KeyboardMonitor.State] = []
            let monitor = fixture.makeMonitor(onShortcut: { count += 1 })
            monitor.onInterruption = { interruptions.append($0) }
            XCTAssertEqual(monitor.start(), .running)
            try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
            try fixture.send(.flagsChanged, flags: [])
            fixture.enabled = false
            fixture.canEnable = false
            try fixture.send(.tapDisabledByTimeout, flags: [])
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
            XCTAssertEqual(interruptions, [.unavailable])
            Self.drainQueue()
            XCTAssertEqual(count, 0)
        }
    }

    func testAnAlreadyHeldButtonAtStartupCancelsTheFirstChord() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            var count = 0
            let monitor = fixture.makeMonitor(
                readInput: { ShortcutRecognizer(mouseButtonsDown: [0]) }, onShortcut: { count += 1 }
            )
            defer { monitor.stop() }
            XCTAssertEqual(monitor.start(), .running)
            try fixture.send(.flagsChanged, flags: [.maskShift, .maskCommand])
            try fixture.send(.flagsChanged, flags: [])
            Self.drainQueue()
            XCTAssertEqual(count, 0)
            try fixture.send(.leftMouseUp, flags: [])
            try fixture.send(.flagsChanged, flags: [.maskShift, .maskCommand])
            try fixture.send(.flagsChanged, flags: [])
            Self.drainQueue()
            XCTAssertEqual(count, 1)
        }
    }

    func testTimeoutDiscardsTheOldChordBeforeReenablingTap() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            var count = 0
            let monitor = fixture.makeMonitor(onShortcut: { count += 1 })
            defer { monitor.stop() }
            XCTAssertEqual(monitor.start(), .running)
            try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
            fixture.enabled = false
            try fixture.send(.tapDisabledByTimeout, flags: [])
            XCTAssertEqual(fixture.enableAttempts, [false, true, true])
            try fixture.send(.flagsChanged, flags: [])
            Self.drainQueue()
            XCTAssertEqual(count, 0)
            try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
            try fixture.send(.flagsChanged, flags: [])
            Self.drainQueue()
            XCTAssertEqual(count, 1)
        }
    }

    func testDisabledTapIsInvalidatedWhenPermissionWasRevoked() throws {
        try MainActor.assumeIsolated {
            for disabledEvent in [true, false] {
                let fixture = try TapFixture()
                var granted = true
                var interruptions: [KeyboardMonitor.State] = []
                let monitor = fixture.makeMonitor(hasPermission: { granted })
                monitor.onInterruption = { interruptions.append($0) }
                defer { monitor.stop() }
                XCTAssertEqual(monitor.start(), .running)
                if disabledEvent {
                    granted = false
                    try fixture.send(.tapDisabledByUserInput, flags: [])
                } else {
                    try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
                    try fixture.send(.flagsChanged, flags: [])
                    granted = false
                    Self.drainQueue()
                }
                XCTAssertEqual(fixture.enableAttempts, [false, true])
                XCTAssertFalse(CFMachPortIsValid(fixture.port))
                XCTAssertEqual(interruptions, [.permissionRequired])
            }
        }
    }

    @MainActor private static func drainQueue() {
        let drained = XCTestExpectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [drained], timeout: 1), .completed)
    }

    func testCallbackPassesEventsThroughAndDefersOneSwitch() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            let switched = XCTestExpectation(description: "Source switched")
            var count = 0
            let monitor = fixture.makeMonitor(onShortcut: {
                count += 1
                switched.fulfill()
            })
            defer { monitor.stop() }
            XCTAssertEqual(monitor.start(), .running)
            try fixture.send(.flagsChanged, flags: [.maskCommand, .maskShift])
            try fixture.send(.flagsChanged, flags: .maskCommand)
            try fixture.send(.flagsChanged, flags: [])
            XCTAssertEqual(count, 0)
            XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 1), .completed)
            XCTAssertEqual(count, 1)
        }
    }

    func testReleasingMonitorInvalidatesItsPort() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            var monitor: KeyboardMonitor? = fixture.makeMonitor()
            XCTAssertEqual(monitor?.start(), .running)
            monitor = nil
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
            CFMachPortInvalidate(fixture.port)
        }
    }

    func testStartIsIdempotentAndStopInvalidatesTheOwnedPort() throws {
        try MainActor.assumeIsolated {
            let fixture = try TapFixture()
            let monitor = fixture.makeMonitor()
            XCTAssertEqual(monitor.start(), .running)
            XCTAssertEqual(monitor.start(), .running)
            XCTAssertEqual(fixture.creations, 1)
            monitor.stop()
            XCTAssertFalse(CFMachPortIsValid(fixture.port))
            monitor.stop()
        }
    }

    func testMissingPermissionDoesNotCreateAnEventTap() {
        MainActor.assumeIsolated {
            var attempted = false
            let monitor = KeyboardMonitor(
                hasPermission: { false },
                makeTap: { _, _, _, _, _, _ in attempted = true; return nil },
                onShortcut: {}
            )
            XCTAssertEqual(monitor.start(), .permissionRequired)
            XCTAssertFalse(attempted)
        }
    }

    func testRegistersAnAccessibilitySessionTapWithOnlyRequiredEvents() {
        MainActor.assumeIsolated {
            var location: CGEventTapLocation?
            var options: CGEventTapOptions?
            var mask: CGEventMask = 0
            let monitor = KeyboardMonitor(
                hasPermission: { true },
                makeTap: { tap, _, mode, events, _, _ in
                    location = tap
                    options = mode
                    mask = events
                    return nil
                },
                readTaps: { [] }, onShortcut: {}
            )
            XCTAssertEqual(monitor.start(), .unavailable)
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(options, .defaultTap)
            let required: [CGEventType] = [
                .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
            ]
            for type in required { XCTAssertNotEqual(mask & (1 << type.rawValue), 0, "\(type)") }
            XCTAssertEqual(mask & (1 << CGEventType.mouseMoved.rawValue), 0)
        }
    }
}

@MainActor
private final class TapFixture {
    final class InvalidationCounter {
        var calls = 0
    }

    let port: CFMachPort
    let invalidationCounter = InvalidationCounter()
    var enabled = true
    var canEnable = true
    private(set) var enableAttempts: [Bool] = []
    var reportsCompetingTapOnly = false
    var includeExistingTap = false
    private(set) var creations = 0
    var removedEvents: [CGEventType] = []
    private var tap: CGEventTapInformation?
    private var callback: CGEventTapCallBack?
    private var context: UnsafeMutableRawPointer?

    init() throws {
        var context = CFMachPortContext()
        context.info = Unmanaged.passUnretained(invalidationCounter).toOpaque()
        port = try XCTUnwrap(CFMachPortCreate(nil, { _, _, _, _ in }, &context, nil))
    }

    func makeMonitor(
        hasPermission: @escaping () -> Bool = { true },
        readInput: @escaping () -> ShortcutRecognizer = { .init() },
        onShortcut: @escaping () -> Void = {}
    ) -> KeyboardMonitor {
        KeyboardMonitor(
            hasPermission: hasPermission, makeTap: makeTap, enableTap: setEnabled,
            isTapEnabled: { _ in self.enabled }, readTaps: installedTaps,
            readInput: readInput, onShortcut: onShortcut
        )
    }

    func makeTap(
        _ location: CGEventTapLocation, _ placement: CGEventTapPlacement, _ options: CGEventTapOptions,
        _ mask: CGEventMask, _ callback: CGEventTapCallBack, _ context: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        creations += 1
        tap = CGEventTapInformation()
        tap?.eventTapID = 1
        tap?.tapPoint = location
        tap?.options = options
        tap?.tappingProcess = getpid()
        tap?.eventsOfInterest = removedEvents.reduce(mask) { $0 & ~(1 << $1.rawValue) }
        tap?.enabled = enabled
        self.callback = callback
        self.context = context
        return port
    }

    func setEnabled(_ port: CFMachPort, _ enabled: Bool) {
        XCTAssertEqual(port, self.port)
        enableAttempts.append(enabled)
        if !enabled || canEnable { self.enabled = enabled }
    }

    func installedTaps() -> [CGEventTapInformation]? {
        var taps: [CGEventTapInformation] = tap.map { tap in
            var reported = tap
            reported.enabled = reportsCompetingTapOnly || enabled
            return [reported]
        } ?? []
        if includeExistingTap {
            var existing = CGEventTapInformation()
            existing.eventTapID = 2
            existing.tappingProcess = getpid()
            existing.tapPoint = .cgSessionEventTap
            existing.options = .defaultTap
            existing.eventsOfInterest = .max
            taps.append(existing)
        }
        return taps
    }

    func send(_ type: CGEventType, flags: CGEventFlags) throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.flags = flags
        let callback = try XCTUnwrap(callback)
        let result = callback(OpaquePointer(bitPattern: 1)!, type, event, context)
        XCTAssertTrue(result?.takeUnretainedValue() === event)
        XCTAssertEqual(event.flags, flags)
    }
}
