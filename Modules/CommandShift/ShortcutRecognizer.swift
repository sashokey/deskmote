import AppKit
import Carbon.HIToolbox
import CoreGraphics

struct ShortcutRecognizer {
    private var armed = false
    private var cancelled = false
    private var keysDown: Set<Int64> = []
    private var mouseButtonsDown: Set<Int64> = []

    init(keysDown: Set<Int64> = [], mouseButtonsDown: Set<Int64> = []) {
        self.keysDown = keysDown
        self.mouseButtonsDown = mouseButtonsDown
    }

    static func currentInput(mouseButtonMask: Int = NSEvent.pressedMouseButtons,
                             keyIsPressed: (CGKeyCode) -> Bool = {
                                 CGEventSource.keyState(.combinedSessionState, key: $0)
                             }) -> Self {
        let modifiers = Set([kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                             kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_CapsLock, kVK_Function])
        let keys = (0..<128).filter {
            !modifiers.contains($0) && keyIsPressed(CGKeyCode($0))
        }
        let buttons = (0..<Int.bitWidth).filter {
            mouseButtonMask & (1 << $0) != 0
        }
        return .init(keysDown: Set(keys.map { Int64($0) }), mouseButtonsDown: Set(buttons.map { Int64($0) }))
    }

    mutating func handle(_ type: CGEventType, flags: CGEventFlags, keyCode: Int64? = nil, mouseButton: Int64 = 2) -> Bool {
        guard type == .flagsChanged else {
            switch type {
            case .keyDown: keysDown.insert(keyCode ?? -1)
            case .keyUp: keysDown.remove(keyCode ?? -1)
            case .leftMouseDown: mouseButtonsDown.insert(0)
            case .leftMouseUp: mouseButtonsDown.remove(0)
            case .rightMouseDown: mouseButtonsDown.insert(1)
            case .rightMouseUp: mouseButtonsDown.remove(1)
            case .otherMouseDown: mouseButtonsDown.insert(mouseButton)
            case .otherMouseUp: mouseButtonsDown.remove(mouseButton)
            default: break
            }
            if armed || !flags.intersection([.maskCommand, .maskShift]).isEmpty {
                cancelled = true
            }
            return false
        }
        if !keysDown.isEmpty || !mouseButtonsDown.isEmpty || keyCode == Int64(kVK_CapsLock) ||
            !flags.intersection([.maskControl, .maskAlternate, .maskSecondaryFn, .maskHelp]).isEmpty {
            cancelled = true
        }
        let pressed = flags.contains([.maskShift, .maskCommand])
        let shouldSwitch = armed && !pressed && !cancelled
        armed = pressed
        if flags.intersection([.maskCommand, .maskShift]).isEmpty {
            cancelled = false
        }
        return shouldSwitch
    }
}
