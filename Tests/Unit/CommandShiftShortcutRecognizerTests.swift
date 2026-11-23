import CoreGraphics
import XCTest
@testable import CommandShift

final class ShortcutRecognizerTests: XCTestCase {
    func testAdditionalModifiersCancelTheWholeGesture() {
        for modifier: CGEventFlags in [.maskControl, .maskAlternate, .maskSecondaryFn] {
            for beforeChord in [true, false] {
                var shortcut = ShortcutRecognizer()
                if beforeChord {
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, modifier]))
                }
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift, modifier]))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift]))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: []), "\(modifier)")
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift]))
                XCTAssertTrue(shortcut.handle(.flagsChanged, flags: []))
            }
        }
    }

    func testOtherInputCancelsChordUntilBothModifiersAreReleased() {
        let inputs: [CGEventType] = [
            .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        let releases: [CGEventType: CGEventType] = [
            .keyDown: .keyUp, .leftMouseDown: .leftMouseUp,
            .rightMouseDown: .rightMouseUp, .otherMouseDown: .otherMouseUp
        ]
        for input in inputs {
            var shortcut = ShortcutRecognizer()
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift]))
            XCTAssertFalse(shortcut.handle(input, flags: [.maskCommand, .maskShift]))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: .maskCommand), "\(input)")
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift]))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: .maskShift), "\(input)")
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: []))
            if let release = releases[input] { XCTAssertFalse(shortcut.handle(release, flags: [])) }
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskCommand, .maskShift]))
            XCTAssertTrue(shortcut.handle(.flagsChanged, flags: []))
        }
    }

    func testInputAlreadyHeldWhenTheModifiersArePressedCancelsTheChord() {
        for (down, up) in [(CGEventType.keyDown, CGEventType.keyUp), (.leftMouseDown, .leftMouseUp)] {
            var shortcut = ShortcutRecognizer()
            XCTAssertFalse(shortcut.handle(down, flags: [], keyCode: 0))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand]))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: []))
            XCTAssertFalse(shortcut.handle(up, flags: [], keyCode: 0))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand]))
            XCTAssertTrue(shortcut.handle(.flagsChanged, flags: []))
        }
    }

    func testStartupReadsTheFullPressedMouseButtonMask() {
        for button in [0, 2, 3, 31] {
            var shortcut = ShortcutRecognizer.currentInput(mouseButtonMask: 1 << button, keyIsPressed: { _ in false })
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand]))
            XCTAssertFalse(shortcut.handle(.flagsChanged, flags: []), "Button \(button) is still held")
        }
    }

    func testSwitchesOnceWhenCommandShiftIsReleased() {
        var shortcut = ShortcutRecognizer()
        XCTAssertFalse(shortcut.handle(.flagsChanged, flags: .maskShift))
        XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand]))
        XCTAssertTrue(shortcut.handle(.flagsChanged, flags: .maskCommand))
        XCTAssertFalse(shortcut.handle(.flagsChanged, flags: []))
    }
}
