import ApplicationServices
import CoreGraphics
import Foundation

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
    private let initialInput: () -> ShortcutRecognizer
    private let onShortcut: () -> Void
    var onPermissionLoss: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var shortcut = ShortcutRecognizer()
    private var generation = 0

    init(
        hasPermission: @escaping () -> Bool = AXIsProcessTrusted,
        makeTap: @escaping TapFactory = CGEvent.tapCreate,
        enableTap: @escaping (CFMachPort, Bool) -> Void = CGEvent.tapEnable,
        initialInput: @escaping () -> ShortcutRecognizer = { .init() },
        onShortcut: @escaping () -> Void
    ) {
        self.hasPermission = hasPermission
        self.makeTap = makeTap
        self.enableTap = enableTap
        self.initialInput = initialInput
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
        if let tap, CFMachPortIsValid(tap) { return .running }
        stop()
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
                        monitor.receive(type, flags: event.flags, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                        mouseButton: event.getIntegerValueField(.mouseEventButtonNumber))
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            Unmanaged.passUnretained(self).toOpaque()
        ) else { return .unavailable }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .unavailable
        }
        self.tap = tap
        self.source = source
        shortcut = initialInput()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return .running
    }

    func stop() {
        generation &+= 1
        shortcut = ShortcutRecognizer()
        if let source { CFRunLoopSourceInvalidate(source) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func receive(_ type: CGEventType, flags: CGEventFlags, keyCode: Int64, mouseButton: Int64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            generation &+= 1
            if hasPermission(), let tap {
                shortcut = initialInput()
                enableTap(tap, true)
            } else {
                stopForPermissionLoss()
            }
            return
        }
        if shortcut.handle(type, flags: flags, keyCode: keyCode, mouseButton: mouseButton) {
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, let tap = self.tap,
                      CFMachPortIsValid(tap) else { return }
                guard self.hasPermission() else {
                    self.stopForPermissionLoss()
                    return
                }
                self.onShortcut()
            }
        }
    }

    private func stopForPermissionLoss() {
        stop()
        onPermissionLoss?()
    }
}
