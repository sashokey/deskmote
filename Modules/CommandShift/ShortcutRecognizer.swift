import AppKit
import Carbon.HIToolbox
import CoreGraphics

struct ShortcutRecognizer {
    private enum Input: Hashable {
        case key(Int64)
        case mouseButton(Int64)
    }

    private enum InputEdge {
        case down(Input)
        case up(Input)
    }

    private var armed = false
    private var cancelled = false
    private var inputsDown: Set<Input>
    private var inputsPressedDuringSample: [Input: CGEventTimestamp] = [:]
    private var inputSample: (startedAt: CGEventTimestamp, completedAt: CGEventTimestamp)?
    private var hasInputDown: Bool { !inputsDown.isEmpty || !inputsPressedDuringSample.isEmpty }

    init(keysDown: Set<Int64> = [], mouseButtonsDown: Set<Int64> = []) {
        inputsDown = Set(keysDown.map(Input.key)).union(mouseButtonsDown.map(Input.mouseButton))
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

    mutating func markInputSample(startedAt: CGEventTimestamp, completedAt: CGEventTimestamp) {
        inputSample = (startedAt, completedAt)
        inputsPressedDuringSample.removeAll()
    }

    mutating func handle(
        _ type: CGEventType, flags: CGEventFlags, keyCode: Int64? = nil, mouseButton: Int64 = 2,
        eventTime: CGEventTimestamp = DispatchTime.now().uptimeNanoseconds,
        receivedAt: CGEventTimestamp = DispatchTime.now().uptimeNanoseconds,
        readPressedInput: (() -> Self)? = nil,
        readUptime: () -> CGEventTimestamp = { DispatchTime.now().uptimeNanoseconds }
    ) -> Bool {
        let modifierFlags = flags.intersection([.maskCommand, .maskShift])
        let trustedTime = inputSample == nil || eventTime <= receivedAt
        let followsInputSample = trustedTime && (inputSample.map { eventTime > $0.completedAt } ?? true)
        guard type == .flagsChanged, trustedTime else {
            if inputSample.map({ eventTime >= $0.startedAt }) ?? true,
               let edge = Self.inputEdge(type, keyCode: keyCode, mouseButton: mouseButton) {
                switch edge {
                case .down(let input):
                    if trustedTime, !followsInputSample {
                        let previousTime = inputsPressedDuringSample[input, default: eventTime]
                        inputsPressedDuringSample[input] = max(previousTime, eventTime)
                    } else {
                        inputsDown.insert(input)
                    }
                case .up(let input) where trustedTime:
                    if let pressedAt = inputsPressedDuringSample[input], pressedAt < eventTime {
                        inputsPressedDuringSample.removeValue(forKey: input)
                    }
                    if followsInputSample { inputsDown.remove(input) }
                default: break
                }
            }
            if armed || !modifierFlags.isEmpty { cancelled = true }
            return false
        }
        if !followsInputSample || hasInputDown || keyCode == Int64(kVK_CapsLock) ||
            !flags.intersection([.maskControl, .maskAlternate, .maskSecondaryFn, .maskHelp]).isEmpty {
            cancelled = true
        }
        let pressed = modifierFlags == [.maskShift, .maskCommand]
        let shouldSwitch = armed && !pressed && !cancelled
        armed = pressed
        if modifierFlags.isEmpty {
            cancelled = false
            if followsInputSample, hasInputDown, let readPressedInput {
                let startedAt = readUptime()
                inputsDown = readPressedInput().inputsDown
                markInputSample(startedAt: startedAt, completedAt: readUptime())
            }
        }
        return shouldSwitch
    }

    private static func inputEdge(_ type: CGEventType, keyCode: Int64?, mouseButton: Int64) -> InputEdge? {
        switch type {
        case .keyDown: .down(.key(keyCode ?? -1))
        case .keyUp: .up(.key(keyCode ?? -1))
        case .leftMouseDown: .down(.mouseButton(0))
        case .leftMouseUp: .up(.mouseButton(0))
        case .rightMouseDown: .down(.mouseButton(1))
        case .rightMouseUp: .up(.mouseButton(1))
        case .otherMouseDown: .down(.mouseButton(mouseButton))
        case .otherMouseUp: .up(.mouseButton(mouseButton))
        default: nil
        }
    }
}
