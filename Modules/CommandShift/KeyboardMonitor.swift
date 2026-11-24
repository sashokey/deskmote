import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

@MainActor
final class KeyboardMonitor {
    enum State {
        case running
        case permissionRequired
        case unavailable
    }

    typealias TapFactory = (
        CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions,
        CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?
    ) -> CFMachPort?

    private let hasPermission: () -> Bool
    private let makeTap: TapFactory
    private let enableTap: (CFMachPort, Bool) -> Void
    private let isTapEnabled: (CFMachPort) -> Bool
    private let readTaps: @MainActor () -> [CGEventTapInformation]?
    private let readInput: () -> ShortcutRecognizer
    private let onShortcut: () -> Void
    var onInterruption: ((State) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var shortcut = ShortcutRecognizer()
    private var generation = 0
    private var tapLifetime = 0

    init(
        hasPermission: @escaping () -> Bool = AXIsProcessTrusted,
        makeTap: @escaping TapFactory = CGEvent.tapCreate,
        enableTap: @escaping (CFMachPort, Bool) -> Void = CGEvent.tapEnable,
        isTapEnabled: @escaping (CFMachPort) -> Bool = CGEvent.tapIsEnabled,
        readTaps: @escaping @MainActor () -> [CGEventTapInformation]? = KeyboardMonitor.installedTaps,
        readInput: @escaping () -> ShortcutRecognizer = { .init() },
        onShortcut: @escaping () -> Void
    ) {
        self.hasPermission = hasPermission
        self.makeTap = makeTap
        self.enableTap = enableTap
        self.isTapEnabled = isTapEnabled
        self.readTaps = readTaps
        self.readInput = readInput
        self.onShortcut = onShortcut
    }

    isolated deinit {
        stop()
    }

    func start() -> State {
        guard hasPermission() else {
            stop()
            return .permissionRequired
        }
        if let tap, CFMachPortIsValid(tap), isTapEnabled(tap) { return .running }
        stop()
        guard let existingTaps = readTaps() else { return .unavailable }
        let existingIDs = Set(existingTaps.map(\.eventTapID))
        let events: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = makeTap(
            .cgSessionEventTap, .tailAppendEventTap, .defaultTap, mask,
            { _, type, event, context in
                if let context {
                    MainActor.assumeIsolated {
                        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                        monitor.receive(type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            Unmanaged.passUnretained(self).toOpaque()
        ) else { return .unavailable }
        guard let installedMask = installedMask(of: tap, excluding: existingIDs), installedMask & mask == mask,
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .unavailable
        }
        self.tap = tap
        self.source = source
        let lifetime = tapLifetime
        guard TapInvalidation.observe(tap, notify: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tapLifetime == lifetime else { return }
                self.stopForInterruption(self.hasPermission() ? .unavailable : .permissionRequired)
            }
        }), CFMachPortIsValid(tap) else {
            stop()
            return .unavailable
        }
        sampleCurrentInput()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return .running
    }

    func stop() {
        generation &+= 1
        tapLifetime &+= 1
        shortcut = ShortcutRecognizer()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
        tap = nil
    }

    private func receive(_ type: CGEventType, event: CGEvent) {
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let tap, checkPermission() else { return }
            recover(tap)
            return
        }
        if shortcut.handle(
            type, flags: event.flags, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            mouseButton: event.getIntegerValueField(.mouseEventButtonNumber), eventTime: event.timestamp,
            receivedAt: receivedAt, readPressedInput: readInput
        ) {
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, let tap = self.tap,
                      self.checkPermission() else { return }
                guard CFMachPortIsValid(tap), self.isTapEnabled(tap) else {
                    self.recover(tap)
                    return
                }
                self.onShortcut()
            }
        }
    }

    private func checkPermission() -> Bool {
        guard hasPermission() else {
            stopForInterruption(.permissionRequired)
            return false
        }
        return true
    }

    private func recover(_ tap: CFMachPort) {
        generation &+= 1
        guard reenable(tap) else {
            stopForInterruption(.unavailable)
            return
        }
        sampleCurrentInput()
    }

    private func sampleCurrentInput() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        shortcut = readInput()
        shortcut.markInputSample(startedAt: startedAt, completedAt: DispatchTime.now().uptimeNanoseconds)
    }

    private func reenable(_ tap: CFMachPort) -> Bool {
        guard CFMachPortIsValid(tap) else { return false }
        enableTap(tap, true)
        return isTapEnabled(tap)
    }

    private func installedMask(of tap: CFMachPort, excluding existingIDs: Set<UInt32>) -> CGEventMask? {
        guard CFMachPortIsValid(tap) else { return nil }
        if isTapEnabled(tap) { enableTap(tap, false) }
        guard !isTapEnabled(tap), let disabled = matchingTaps(excluding: existingIDs),
              reenable(tap), let enabled = matchingTaps(excluding: existingIDs) else { return nil }

        let previouslyDisabled = Set(disabled.filter { !$0.enabled }.map(\.eventTapID))
        let activated = enabled.filter { $0.enabled && previouslyDisabled.contains($0.eventTapID) }
        guard activated.count == 1 else { return nil }
        return activated[0].eventsOfInterest
    }

    private func matchingTaps(excluding existingIDs: Set<UInt32>) -> [CGEventTapInformation]? {
        let process = getpid()
        return readTaps()?.filter {
            $0.tappingProcess == process && $0.processBeingTapped == 0 &&
                $0.tapPoint == .cgSessionEventTap && $0.options == .defaultTap &&
                !existingIDs.contains($0.eventTapID)
        }
    }

    private static func installedTaps() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        for _ in 0..<3 {
            let (capacity, overflow) = count.addingReportingOverflow(8)
            guard !overflow else { return nil }
            var taps = Array(repeating: CGEventTapInformation(), count: Int(capacity))
            guard CGGetEventTapList(capacity, &taps, &count) == .success else { return nil }
            if count < capacity { return Array(taps.prefix(Int(count))) }
        }
        return nil
    }

    private func stopForInterruption(_ state: State) {
        stop()
        onInterruption?(state)
    }
}

private enum TapInvalidation {
    private struct Handler: Sendable {
        let original: CFMachPortInvalidationCallBack?
        let notify: @Sendable () -> Void
    }

    private static let handlers = Mutex<[ObjectIdentifier: Handler]>([:])

    private static let callback: CFMachPortInvalidationCallBack = { port, context in
        guard let port, let handler = handlers.withLock({ $0.removeValue(forKey: ObjectIdentifier(port)) }) else {
            return
        }
        handler.original?(port, context)
        handler.notify()
    }

    static func observe(_ tap: CFMachPort, notify: @escaping @Sendable () -> Void) -> Bool {
        let identifier = ObjectIdentifier(tap)
        let original = CFMachPortGetInvalidationCallBack(tap)
        handlers.withLock { $0[identifier] = Handler(original: original, notify: notify) }
        CFMachPortSetInvalidationCallBack(tap, callback)
        guard let installed = CFMachPortGetInvalidationCallBack(tap),
              unsafeBitCast(installed, to: UInt.self) == unsafeBitCast(callback, to: UInt.self) else {
            _ = handlers.withLock { $0.removeValue(forKey: identifier) }
            return false
        }
        return true
    }
}
