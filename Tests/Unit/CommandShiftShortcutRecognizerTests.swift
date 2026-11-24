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

    func testMissedReleasesAreReconciledInEitherModifierOrder() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, held) in [
                (CGEventType.keyDown, ShortcutRecognizer(keysDown: [0])),
                (.leftMouseDown, ShortcutRecognizer(mouseButtonsDown: [0]))
            ] {
                for stillHeld in [false, true] {
                    var shortcut = ShortcutRecognizer()
                    let readInput = { stillHeld ? held : ShortcutRecognizer() }
                    XCTAssertFalse(shortcut.handle(down, flags: [], keyCode: 0))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand], readPressedInput: readInput))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [], readPressedInput: readInput))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                    XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand], readPressedInput: readInput))
                    XCTAssertEqual(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput), !stillHeld)
                }
            }
        }
    }

    func testQueuedReleaseCannotRetroactivelyClearInputDuringTheChord() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, up) in [
                (CGEventType.keyDown, CGEventType.keyUp),
                (.leftMouseDown, .leftMouseUp)
            ] {
                var shortcut = ShortcutRecognizer()
                let readInput = { ShortcutRecognizer() }
                XCTAssertFalse(shortcut.handle(down, flags: [], keyCode: 0))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand], readPressedInput: readInput))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                XCTAssertFalse(shortcut.handle(up, flags: first, keyCode: 0))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [], readPressedInput: readInput))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
                XCTAssertFalse(shortcut.handle(.flagsChanged, flags: [.maskShift, .maskCommand], readPressedInput: readInput))
                XCTAssertTrue(shortcut.handle(.flagsChanged, flags: first, readPressedInput: readInput))
            }
        }
    }

    func testInputSampleCannotAuthorizeAnOlderQueuedChord() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, up) in [
                (CGEventType.keyDown, CGEventType.keyUp),
                (.leftMouseDown, .leftMouseUp)
            ] {
                for receiveRelease in [true, false] {
                    var shortcut = ShortcutRecognizer()
                    func send(_ type: CGEventType, flags: CGEventFlags, time: CGEventTimestamp) -> Bool {
                        shortcut.handle(type, flags: flags, keyCode: 0, eventTime: time,
                                        receivedAt: max(100, time), readPressedInput: { .init() }, readUptime: { 100 })
                    }

                    XCTAssertFalse(send(down, flags: [], time: 10))
                    XCTAssertFalse(send(.flagsChanged, flags: first, time: 20))
                    XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 30))
                    XCTAssertFalse(send(.flagsChanged, flags: [], time: 40))
                    XCTAssertFalse(send(.flagsChanged, flags: first, time: 50))
                    XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 60))
                    XCTAssertFalse(send(.flagsChanged, flags: first, time: 70))
                    if receiveRelease { XCTAssertFalse(send(up, flags: first, time: 80)) }
                    XCTAssertFalse(send(.flagsChanged, flags: [], time: 90))
                    XCTAssertFalse(send(.flagsChanged, flags: first, time: 110))
                    XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 120))
                    XCTAssertTrue(send(.flagsChanged, flags: first, time: 130))
                }
            }
        }
    }

    func testPressDuringTheInputSampleStillBlocksTheNextChord() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, up) in [
                (CGEventType.keyDown, CGEventType.keyUp),
                (.leftMouseDown, .leftMouseUp)
            ] {
                var shortcut = ShortcutRecognizer(keysDown: [42])
                var sampleClock: CGEventTimestamp = 0
                func send(_ type: CGEventType, flags: CGEventFlags, time: CGEventTimestamp) -> Bool {
                    shortcut.handle(type, flags: flags, keyCode: 0, eventTime: time, receivedAt: 400,
                                    readPressedInput: { .init() }, readUptime: { sampleClock += 100; return sampleClock })
                }

                XCTAssertFalse(send(.flagsChanged, flags: [], time: 90))
                XCTAssertFalse(send(down, flags: [], time: 150))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 210))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 220))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 230))
                XCTAssertFalse(send(up, flags: first, time: 240))
                XCTAssertFalse(send(.flagsChanged, flags: [], time: 250))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 260))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 270))
                XCTAssertTrue(send(.flagsChanged, flags: first, time: 280))
            }
        }
    }

    func testPairedPressAndReleaseInsideTheSampleAllowOnlyTheNextChord() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, up) in [
                (CGEventType.keyDown, CGEventType.keyUp),
                (.leftMouseDown, .leftMouseUp)
            ] {
                var shortcut = ShortcutRecognizer()
                shortcut.markInputSample(startedAt: 100, completedAt: 200)
                func send(_ type: CGEventType, flags: CGEventFlags, time: CGEventTimestamp) -> Bool {
                    shortcut.handle(type, flags: flags, keyCode: 0, eventTime: time, receivedAt: 400)
                }

                XCTAssertFalse(send(down, flags: [], time: 100))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 125))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 150))
                XCTAssertFalse(send(.flagsChanged, flags: [], time: 175))
                XCTAssertFalse(send(up, flags: [], time: 200))

                XCTAssertFalse(send(.flagsChanged, flags: first, time: 210))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 220))
                XCTAssertTrue(send(.flagsChanged, flags: first, time: 230))
            }
        }
    }

    func testOlderReleaseCannotClearTheLatestPressInsideTheSample() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (down, up) in [
                (CGEventType.keyDown, CGEventType.keyUp),
                (.leftMouseDown, .leftMouseUp)
            ] {
                var shortcut = ShortcutRecognizer()
                shortcut.markInputSample(startedAt: 100, completedAt: 200)
                func send(_ type: CGEventType, flags: CGEventFlags, time: CGEventTimestamp) -> Bool {
                    shortcut.handle(type, flags: flags, keyCode: 0, eventTime: time, receivedAt: 400)
                }

                XCTAssertFalse(send(down, flags: [], time: 180))
                XCTAssertFalse(send(down, flags: [], time: 150))
                XCTAssertFalse(send(up, flags: [], time: 160))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 210))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 220))
                XCTAssertFalse(send(.flagsChanged, flags: [], time: 230))

                XCTAssertFalse(send(up, flags: [], time: 190))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 240))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 250))
                XCTAssertTrue(send(.flagsChanged, flags: first, time: 260))
            }
        }
    }

    func testFutureTaggedReleaseAndChordCannotOverrideSampledInput() {
        for first: CGEventFlags in [.maskCommand, .maskShift] {
            for (up, initial) in [
                (CGEventType.keyUp, ShortcutRecognizer(keysDown: [0])),
                (.leftMouseUp, ShortcutRecognizer(mouseButtonsDown: [0]))
            ] {
                var shortcut = initial
                shortcut.markInputSample(startedAt: 100, completedAt: 200)
                func send(_ type: CGEventType, flags: CGEventFlags, time: CGEventTimestamp, receipt: CGEventTimestamp) -> Bool {
                    shortcut.handle(type, flags: flags, keyCode: 0, eventTime: time, receivedAt: receipt)
                }

                XCTAssertFalse(send(up, flags: [], time: 900, receipt: 205))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 910, receipt: 207))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 920, receipt: 209))
                XCTAssertFalse(send(.flagsChanged, flags: [], time: 930, receipt: 211))

                XCTAssertFalse(send(.flagsChanged, flags: first, time: 220, receipt: 222))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 230, receipt: 232))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 240, receipt: 242))
                XCTAssertFalse(send(up, flags: first, time: 250, receipt: 252))
                XCTAssertFalse(send(.flagsChanged, flags: [], time: 260, receipt: 262))
                XCTAssertFalse(send(.flagsChanged, flags: first, time: 270, receipt: 272))
                XCTAssertFalse(send(.flagsChanged, flags: [.maskShift, .maskCommand], time: 280, receipt: 282))
                XCTAssertTrue(send(.flagsChanged, flags: first, time: 290, receipt: 292))
            }
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
