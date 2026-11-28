import AppKit
import XCTest
@testable import DeskMoteApps

@MainActor
final class AppsTaskbarTests: XCTestCase {
    private func makePopup() -> AppsPopupController {
        AppsPopupController(makePanel: {
            RecordingPopupPanel(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: true)
        }, reduceMotion: { true })
    }

    private func installApps(on content: TaskbarContentView, popup: AppsPopupController? = nil, store: AppsMenuStore) {
        let popup = popup ?? makePopup()
        let module = AppsModule(store: store, appearance: appsTaskbarAppearance, makePanel: { _ in
            preconditionFailure("The recording popup must supply the panel")
        }, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
           observeWorkspace: false, reduceMotion: { true }, makePopup: { popup })
        content.installLeadingSlot(makeFullLeadingSlotFactory(module: module))
    }

    private func group(_ id: String, count: Int, width: CGFloat = 140) -> TaskbarLayoutGroup {
        TaskbarLayoutGroup(id: id, desiredWidth: 90,
                           windows: (0..<count).map { TaskbarLayoutWindow(id: "\(id)-\($0)", desiredWidth: width) })
    }

    private final class RecordingPopupPanel: NonConstrainingPanel {
        var frontRequests = 0
        var keyRequests = 0
        var pointer = CGPoint.zero
        var frameAtFront: CGRect?
        var alphaAtFront: CGFloat?
        override var canBecomeKey: Bool { true }
        override func orderFrontRegardless() {
            frontRequests += 1
            frameAtFront = frame
            alphaAtFront = alphaValue
        }
        override func makeKey() { keyRequests += 1 }
    }

    private func sendTrackingEvent(_ type: NSEvent.EventType, at point: CGPoint, to view: NSView,
                                   timestamp: TimeInterval = 0) throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + timestamp, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        if type == .mouseEntered { view.mouseEntered(with: event) }
        else { view.mouseExited(with: event) }
    }

    func testOutsidePrimaryClickDismissesAppsAndReturnsTheSameEvent() throws {
        let hostFrame = CGRect(x: 0, y: 0, width: 400, height: 32)
        let host = RecordingPopupPanel(contentRect: hostFrame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let content = TaskbarContentView(frame: hostFrame, popup: BehaviorPopup(), contextMenu: BehaviorMenu())
        host.contentView = content
        var local: ((NSEvent) -> NSEvent?)?
        var mask: NSEvent.EventTypeMask?
        var closeCount = 0
        let popup = AppsPopupController(makePanel: {
            RecordingPopupPanel(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: false)
        }, reduceMotion: { true }, mouseDownSource: { eventMask, receive, _ in
            mask = eventMask
            local = receive
            return {}
        })
        installApps(on: content, popup: popup, store: makeAppsFixtureStore())
        let dismissed = popup.onDismiss
        popup.onDismiss = {
            closeCount += 1
            dismissed?()
        }
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        closeCount = 0
        let receive = try XCTUnwrap(local)
        XCTAssertEqual(mask, .leftMouseDown)
        let panel = try XCTUnwrap(popup.panel)
        let inside = try primaryDown(window: panel, point: CGPoint(x: 10, y: 10))
        XCTAssertTrue(receive(inside) === inside)
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(closeCount, 0)
        let child = RecordingPopupPanel(contentRect: hostFrame, styleMask: .borderless, backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.parent = panel
        defer { child.parent = nil; child.close() }
        let childClick = try primaryDown(window: child, point: CGPoint(x: 10, y: 10))
        XCTAssertTrue(receive(childClick) === childClick)
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(closeCount, 0)

        let togglePoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let toggle = try primaryDown(window: host, point: togglePoint)
        XCTAssertTrue(receive(toggle) === toggle)
        XCTAssertTrue(popup.isPresented)
        button.performClick(nil)
        XCTAssertFalse(popup.isPresented)
        XCTAssertEqual(closeCount, 1)

        button.performClick(nil)
        closeCount = 0
        let outside = try primaryDown(window: host, point: CGPoint(x: 100, y: 5))
        XCTAssertTrue(try XCTUnwrap(local)(outside) === outside)
        var ordinaryActionCount = 0
        content.onBackgroundClick = { ordinaryActionCount += 1 }
        content.mouseDown(with: outside)
        XCTAssertFalse(popup.isPresented)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(ordinaryActionCount, 1)
    }

    func testMonitorRetiresWithItsPresentation() throws {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        var observations = 0
        var removals = 0
        var foreign: [(NSEvent) -> Void] = []
        var local: [(NSEvent) -> NSEvent?] = []
        let popup = AppsPopupController(makePanel: {
            RecordingPopupPanel(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: true)
        }, reduceMotion: { true }, mouseDownSource: { mask, receiveLocal, receive in
            XCTAssertEqual(mask, .leftMouseDown)
            observations += 1
            local.append(receiveLocal)
            foreign.append(receive)
            return { removals += 1 }
        })
        let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
                               frame: frame, store: makeAppsFixtureStore()) {}
        popup.present(content: menu, frame: frame, anchorWindow: nil)
        XCTAssertEqual(observations, 1)
        popup.dismissImmediately()
        XCTAssertEqual(removals, 1)

        popup.present(content: menu, frame: frame, anchorWindow: nil)
        let event = try primaryDown(window: nil, point: .zero)
        XCTAssertTrue(try XCTUnwrap(local.first)(event) === event)
        try XCTUnwrap(foreign.first)(event)
        XCTAssertTrue(popup.isPresented)
        try XCTUnwrap(foreign.last)(event)
        XCTAssertFalse(popup.isPresented)
        try XCTUnwrap(foreign.last)(event)
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(removals, 2)
        popup.dismissImmediately()
        XCTAssertEqual(removals, 2)
    }

    private func primaryDown(window: NSWindow?, point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                        timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    func testAppsButtonHoverMatchesTaskbarButtonGeometry() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 600, height: 32))
        let panel = RecordingPopupPanel(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        defer { panel.close() }
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        XCTAssertEqual(button.convert(selection.frame, to: content), AppsMenuGeometry.buttonFrame)
        XCTAssertEqual(selection.cornerRadius, TaskbarMetrics.buttonCornerRadius)
        XCTAssertEqual(selection.alphaValue, 0)
        let reference = TaskbarButtonView(frame: button.frame)
        reference.reduceMotion = { true }

        for (eventType, highlighted) in [(NSEvent.EventType.mouseEntered, true), (.mouseExited, false)] {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            try sendTrackingEvent(eventType, at: highlighted ? point : .zero, to: button)
            try sendTrackingEvent(eventType, at: .zero, to: reference)
            XCTAssertEqual(selection.alphaValue > 0, highlighted)
            XCTAssertEqual(selection.alphaValue, reference.selectionView.alphaValue)
            XCTAssertEqual(selection.borderColor, reference.selectionView.borderColor)
        }
    }

    func testAppsIconIsMonochromeUntilHoveredOrActive() throws {
        let frame = CGRect(x: 0, y: 0, width: 260, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = TaskbarContentView(frame: frame)
        content.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        func chromaticPixels() throws -> Int {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 58, pixelsHigh: 56,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = selection.bounds.size
            button.layoutSubtreeIfNeeded()
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.cacheDisplay(in: selection.frame, to: bitmap)
            }
            var count = 0
            for y in 10..<46 {
                for x in 11..<47 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.6 else { continue }
                    let components = [color.redComponent, color.greenComponent, color.blueComponent]
                    if components.max()! - components.min()! > 0.24 { count += 1 }
                }
            }
            return count
        }
        XCTAssertEqual(try chromaticPixels(), 0)
        panel.pointer = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)
        XCTAssertGreaterThan(try chromaticPixels(), 15)
        panel.pointer = .zero
        try sendTrackingEvent(.mouseExited, at: panel.pointer, to: button)
        XCTAssertEqual(try chromaticPixels(), 0)
        button.state = .on
        XCTAssertGreaterThan(try chromaticPixels(), 15)
        button.state = .off
        XCTAssertEqual(try chromaticPixels(), 0)
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsButtonDetectsPointerWhenTrackingStartsBeforeFirstClick() throws {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = TaskbarContentView(frame: frame)
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        panel.pointer = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.updateTrackingAreas()
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)
        XCTAssertGreaterThan(selection.alphaValue, 0)
        XCTAssertEqual(button.state, .off)
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsButtonHoversAtTheBottomScreenPixelAtBothScales() throws {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = TaskbarContentView(frame: frame, popup: BehaviorPopup())
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        content.layoutSubtreeIfNeeded()

        for scale: CGFloat in [1, 2] {
            let point = CGPoint(x: button.frame.midX, y: 32 - 0.5 / scale)
            panel.pointer = content.convert(point, to: nil)
            button.updateTrackingAreas()
            let area = try XCTUnwrap(button.trackingAreas.first {
                $0.options.contains([.mouseEnteredAndExited, .activeAlways, .inVisibleRect])
            })
            let trackingRect = area.options.contains(.inVisibleRect) ? button.visibleRect : area.rect
            XCTAssertTrue(trackingRect.contains(button.convert(point, from: content)), "\(trackingRect) at \(button.convert(point, from: content))")
            XCTAssertFalse(trackingRect.contains(button.convert(CGPoint(x: 40, y: point.y), from: content)))
            XCTAssertTrue(content.hitTest(panel.pointer) === button)
            try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)
            XCTAssertGreaterThan(selection.alphaValue, 0)
            XCTAssertEqual(button.convert(selection.frame, to: content), CGRect(x: 10, y: 2, width: 29, height: 28))
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsButtonOpensAtTheBottomLeftCorner() throws {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let popup = makePopup()
        let content = TaskbarContentView(frame: frame)
        panel.contentView = content
        installApps(on: content, popup: popup, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        content.layoutSubtreeIfNeeded()

        let points = [CGPoint(x: 0, y: frame.maxY - 1),
                      CGPoint(x: 0.5, y: frame.maxY - 0.5),
                      CGPoint(x: 0.25, y: frame.maxY - 0.25)]
        for point in points {
            panel.pointer = content.convert(point, to: nil)
            button.updateTrackingAreas()
            try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)
            XCTAssertGreaterThan(selection.alphaValue, 0)
            let target = try XCTUnwrap(content.hitTest(panel.pointer) as? NSButton, "Corner \(point)")
            XCTAssertTrue(target === button)
            target.performClick(nil)
            XCTAssertTrue(popup.panel?.contentView?.subviews.first is AppsMenuView)
            content.dismissLeadingSlot()
            XCTAssertFalse(popup.isPresented)
            XCTAssertEqual(button.convert(selection.frame, to: content), CGRect(x: 10, y: 2, width: 29, height: 28))
        }
        let neighboringGap = content.convert(CGPoint(x: 40, y: frame.maxY - 0.5), to: nil)
        XCTAssertFalse(content.hitTest(neighboringGap) === button)
    }

    func testAppsButtonHoverFollowsTheCurrentPointerWhenTrackingEventsArriveLate() throws {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = TaskbarContentView(frame: frame, popup: BehaviorPopup())
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        let inside = content.convert(CGPoint(x: 24, y: 15), to: nil)
        let outside = content.convert(CGPoint(x: 90, y: 15), to: nil)

        try sendTrackingEvent(.mouseEntered, at: inside, to: button, timestamp: 2)
        XCTAssertGreaterThan(selection.alphaValue, 0)
        try sendTrackingEvent(.mouseExited, at: outside, to: button, timestamp: 1)
        XCTAssertGreaterThan(selection.alphaValue, 0)
        try sendTrackingEvent(.mouseExited, at: outside, to: button, timestamp: 3)
        try sendTrackingEvent(.mouseEntered, at: inside, to: button, timestamp: 2)
        XCTAssertEqual(selection.alphaValue, 0)

        try sendTrackingEvent(.mouseEntered, at: inside, to: button, timestamp: 4)
        button.state = .on
        try sendTrackingEvent(.mouseExited, at: outside, to: button, timestamp: 5)
        button.state = .off
        XCTAssertEqual(selection.alphaValue, 0)

        try sendTrackingEvent(.mouseEntered, at: inside, to: button, timestamp: 6)
        XCTAssertGreaterThan(selection.alphaValue, 0)
        button.isHidden = true
        button.isHidden = false
        XCTAssertEqual(selection.alphaValue, 0)
    }

    func testQueuedPointerMoveCannotReenterAfterButtonGeometryChanges() throws {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = TaskbarContentView(frame: frame)
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore())
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func pointerMove() throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 0, pressure: 0))
        }
        let queued = try pointerMove()
        let original = button.frame
        button.frame = original.offsetBy(dx: 40, dy: 0)
        button.frame = original
        button.mouseMoved(with: queued)
        XCTAssertEqual(selection.alphaValue, 0)
        button.mouseMoved(with: try pointerMove())
        XCTAssertGreaterThan(selection.alphaValue, 0)
    }

    func testAppsButtonGlyphIsCenteredInTheRenderedHoverAtBothScales() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
        content.appearance = NSAppearance(named: .darkAqua)
        let panel = RecordingPopupPanel(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = content
        installApps(on: content, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }))
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        panel.pointer = button.convert(CGPoint(x: selection.frame.midX, y: selection.frame.midY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)
        button.layoutSubtreeIfNeeded()
        for scale in [1.0, 2.0] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(29 * scale),
                                                       pixelsHigh: Int(28 * scale), bitsPerSample: 8,
                                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = selection.bounds.size
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.cacheDisplay(in: selection.frame, to: bitmap)
            }
            var glyph = CGRect.null
            var weightedX = 0.0
            var weightedY = 0.0
            var totalWeight = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let weight = max(0, pixel.redComponent - 0.45) * pixel.alphaComponent
                    weightedX += (Double(x) + 0.5) * weight / scale
                    weightedY += (Double(y) + 0.5) * weight / scale
                    totalWeight += weight
                    guard pixel.alphaComponent > 0.5, pixel.redComponent > 0.58 else { continue }
                    glyph = glyph.union(CGRect(x: Double(x) / scale, y: Double(y) / scale,
                                               width: 1 / scale, height: 1 / scale))
                }
            }
            XCTAssertGreaterThan(glyph.width, 12, "\(scale)×")
            XCTAssertLessThan(glyph.width, 18, "\(scale)×")
            XCTAssertEqual(weightedX / totalWeight, 14.5, accuracy: 0.25, "\(scale)×: \(glyph)")
            XCTAssertEqual(weightedY / totalWeight, 14, accuracy: 0.25, "\(scale)×: \(glyph)")
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsButtonOpensAndDismissesAnExplicitPopupWithoutWindowGroups() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let popup = makePopup()
        let content = TaskbarContentView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = content
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeskMoteTests.AppsPopup.\(UUID())"))
        installApps(on: content, popup: popup, store: makeAppsFixtureStore(defaults: defaults, applicationDirectories: [],
                                                   runningApplicationSnapshot: { [] }))
        var admissions: [Bool] = []
        content.admitWindowList = { explicit in admissions.append(explicit); return true }
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        XCTAssertEqual(button.convert(selection.frame, to: content), AppsMenuGeometry.buttonFrame)
        button.performClick(nil)
        let firstMenu = try XCTUnwrap(popup.panel?.contentView?.subviews.first as? AppsMenuView)
        XCTAssertEqual(admissions, [true])
        XCTAssertTrue(content.hasExplicitPopup)
        XCTAssertEqual(button.state, .on)
        XCTAssertGreaterThan(selection.alphaValue, 0)
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                                       eventNumber: 1, trackingNumber: 1, userData: nil))
        button.mouseExited(with: exit)
        XCTAssertGreaterThan(selection.alphaValue, 0)

        let otherDisplay = TaskbarContentView(frame: content.frame)
        otherDisplay.onBackgroundClick = { content.dismissLeadingSlot() }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                    clickCount: 1, pressure: 1))
        otherDisplay.mouseDown(with: click)
        XCTAssertFalse(content.hasExplicitPopup)
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(selection.alphaValue, 0)

        button.performClick(nil)
        XCTAssertTrue(popup.panel?.contentView?.subviews.first === firstMenu)
        XCTAssertTrue(content.hasExplicitPopup)
        content.prepareForHiding()
        XCTAssertFalse(content.hasExplicitPopup)
        XCTAssertFalse(popup.isPresented)
        XCTAssertEqual(button.state, .off)
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsPopupSlidesAndStopsInterceptingClicksWhileClosing() async throws {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        let animatedFrame = CGRect(x: 12, y: 32, width: 642, height: 688)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        var tick: (@MainActor (TimeInterval) -> Void)?
        let controller = AppsPopupController(makePanel: { _ in panel }, reduceMotion: { false },
                                                appsFrameSource: { _, update in
            tick = update
            return { tick = nil }
        })
        defer { controller.dismissImmediately() }
        let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [],
            runningApplicationSnapshot: { [] }), deferCatalog: true) {}
        controller.present(content: menu, frame: frame, anchorWindow: nil)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.frameAtFront, animatedFrame)
        let viewport = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(viewport.clipsToBounds)
        XCTAssertEqual(panel.convertToScreen(menu.convert(menu.bounds, to: nil)),
                       frame.offsetBy(dx: 0, dy: -animatedFrame.height))
        XCTAssertNil(viewport.hitTest(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(menu.catalogDeferredUntilFrame)

        let search = try XCTUnwrap(menu.contentView?.subviews.compactMap { $0 as? NSSearchField }.first)
        tick?(0.19 * 0.84)
        XCTAssertTrue(menu.catalogDeferredUntilFrame)
        let searchPoint = search.convert(CGPoint(x: search.bounds.midX, y: search.bounds.midY), to: viewport.superview)
        let hit = try XCTUnwrap(viewport.hitTest(searchPoint))
        XCTAssertTrue(hit === search || hit.isDescendant(of: search))

        let movedFrame = frame.offsetBy(dx: 24, dy: 40)
        let movedAnimatedFrame = animatedFrame.offsetBy(dx: 24, dy: 40)
        controller.updateFrame(movedFrame)
        XCTAssertEqual(panel.frame, movedAnimatedFrame)
        tick?(0.18)
        XCTAssertFalse(menu.catalogDeferredUntilFrame)
        XCTAssertNotEqual(panel.convertToScreen(menu.convert(menu.bounds, to: nil)), movedFrame)
        XCTAssertTrue(panel.makeFirstResponder(search))
        XCTAssertNotNil(search.currentEditor())

        tick?(0.19)
        XCTAssertNil(tick)
        XCTAssertEqual(panel.frame, movedFrame)
        XCTAssertEqual(panel.convertToScreen(menu.convert(menu.bounds, to: nil)), movedFrame)

        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertNil(search.currentEditor())
        XCTAssertEqual(panel.frame, movedAnimatedFrame)
        let closing = try XCTUnwrap(menu.layer?.animation(forKey: "apps-popup-slide") as? CAKeyframeAnimation)
        XCTAssertEqual(closing.duration, 0.19, accuracy: 0.001)
        XCTAssertEqual((closing.values?.first as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((closing.values?.last as? NSNumber)?.doubleValue, -animatedFrame.height)
        let deadline = ContinuousClock.now + .seconds(1)
        while panel.contentView != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(panel.contentView)
        XCTAssertFalse(panel.isVisible)
    }

    func testWarmAppsRefreshWaitsForOpeningAndSkipsEarlyClose() async throws {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        for (reduceMotion, closeEarly) in [(false, false), (false, true), (true, false)] {
            var now = ContinuousClock.now
            var reads = 0
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeskMoteTests.WarmApps.\(UUID())"))
            let store = makeAppsFixtureStore(defaults: defaults, applicationDirectories: [],
                                      runningApplicationSnapshot: { [] }, readIndex: { _ in
                reads += 1
                return nil
            }, catalogNow: { now })
            _ = await store.loadCatalog()
            XCTAssertEqual(reads, 1)
            now = now.advanced(by: .seconds(6))

            let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            var tick: (@MainActor (TimeInterval) -> Void)?
            let controller = AppsPopupController(makePanel: { _ in panel }, reduceMotion: { reduceMotion },
                                                    appsFrameSource: { _, update in
                tick = update
                return { tick = nil }
            })
            defer { controller.dismissImmediately() }
            let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: store) {}
            menu.prepareForPresentation(size: frame.size)
            controller.present(content: menu, frame: frame, anchorWindow: nil)

            if !reduceMotion {
                try XCTUnwrap(tick)(0.15)
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(reads, 1)
                if closeEarly {
                    controller.dismissImmediately()
                    XCTAssertNil(tick)
                    try await Task.sleep(for: .milliseconds(50))
                    XCTAssertEqual(reads, 1)
                    continue
                }
                try XCTUnwrap(tick)(0.19)
            }

            let deadline = ContinuousClock.now + .seconds(1)
            while reads < 2 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(reads, 2)
        }
    }

    func testClosingAppsDuringOpeningStartsFromItsVisiblePositionAndCanReopenImmediately() throws {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        var panels: [RecordingPopupPanel] = []
        var tick: (@MainActor (TimeInterval) -> Void)?
        let controller = AppsPopupController(makePanel: { frame in
            let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            panels.append(panel)
            return panel
        }, reduceMotion: { false }, appsFrameSource: { _, update in
            tick = update
            return { tick = nil }
        })
        defer { controller.dismissImmediately() }
        let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [],
            runningApplicationSnapshot: { [] })) {}
        controller.present(content: menu, frame: frame, anchorWindow: nil)
        let panel = try XCTUnwrap(panels.last)
        tick?(0.095)
        let offset = panel.convertToScreen(menu.convert(menu.bounds, to: nil)).minY - frame.minY

        controller.dismiss()
        XCTAssertNil(tick)
        let closing = try XCTUnwrap(menu.layer?.animation(forKey: "apps-popup-slide") as? CAKeyframeAnimation)
        let start = try XCTUnwrap(closing.values?.first as? NSNumber)
        XCTAssertEqual(start.doubleValue, offset, accuracy: 0.001)

        menu.prepareForPresentation(size: frame.size)
        controller.present(content: menu, frame: frame, anchorWindow: nil)
        XCTAssertNil(panel.contentView)
        XCTAssertNotNil(tick)
        tick?(0.19)
        XCTAssertEqual(panels.last?.frame, frame)
        XCTAssertTrue(controller.isPresented)
    }

    func testAppsPopupClipsItsMaterialToRoundedCornersInHiddenPanel() throws {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let controller = AppsPopupController(makePanel: { _ in panel }, reduceMotion: { true })
        defer { controller.dismissImmediately() }
        let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] })) {}
        controller.present(content: menu, frame: frame, anchorWindow: nil)
        let viewport = try XCTUnwrap(panel.contentView)
        viewport.layoutSubtreeIfNeeded()
        let glassLayer = try XCTUnwrap(menu.layer)
        let materialSample = CALayer()
        materialSample.frame = glassLayer.bounds
        materialSample.backgroundColor = NSColor(white: 0.53, alpha: 1).cgColor
        glassLayer.addSublayer(materialSample)
        defer { materialSample.removeFromSuperlayer() }

        for scale in [1, 2] {
            let width = Int(frame.width) * scale
            let height = Int(frame.height) * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            glassLayer.render(in: context)
            for (x, y) in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
                let corner = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                XCTAssertLessThan(corner.alphaComponent, 0.05, "Corner at \(x), \(y) at \(scale)x")
            }
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: width / 2, y: 2 * scale)).alphaComponent, 0.95)
            if let path = ProcessInfo.processInfo.environment["DESKMOTE_RENDER_PATH"] {
                let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("apps-corners-\(scale)x.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsPopupPresentsAndDismissesImmediatelyWithReduceMotion() {
        let frame = CGRect(x: 12, y: 44, width: 642, height: 676)
        let panel = RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let controller = AppsPopupController(makePanel: { _ in panel }, reduceMotion: { true })
        let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] })) {}
        controller.present(content: menu, frame: frame, anchorWindow: nil)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.frameAtFront, frame)
        XCTAssertEqual(panel.alphaAtFront, 1)
        XCTAssertNil(menu.layer?.animation(forKey: "apps-popup-slide"))
        controller.dismiss()
        XCTAssertNil(panel.contentView)
        XCTAssertFalse(panel.isVisible)
    }

    func testAppsButtonReservesSpaceWithoutChangingWindowButtonMetrics() {
        let apps = AppsMenuGeometry.buttonFrame
        let result = TaskbarLayout.resolve(groups: [group("editor", count: 1, width: 100)],
                                           width: 1024, leadingInset: AppsMenuGeometry.windowLeadingInset)
        XCTAssertEqual(apps, CGRect(x: 10, y: 2, width: 29, height: 28))
        XCTAssertEqual(result.buttons.first?.frame, CGRect(x: 41, y: 2, width: 100, height: 28))
        XCTAssertEqual(AppsMenuGeometry.windowLeadingInset - apps.maxX, 2)

        let crowded = TaskbarLayout.resolve(groups: [group("editor", count: 2)], width: 181,
                                            leadingInset: AppsMenuGeometry.windowLeadingInset)
        XCTAssertEqual(crowded.buttons.first?.frame.minX, 41)
        XCTAssertTrue(crowded.buttons.first?.isCombined == true)
    }

    func testAppsMenuUsesMeasuredFrameAndStaysOnItsDisplay() {
        let reference = CGRect(x: 0, y: 0, width: 1024, height: 768)
        XCTAssertEqual(AppsMenuGeometry.popupFrame(taskbar: TaskbarMetrics.panelFrame(on: reference),
                                                  screen: reference, visibleTop: reference.maxY),
                       CGRect(x: 12, y: 44, width: 642, height: 676))

        let smaller = CGRect(x: -530, y: -150, width: 530, height: 560)
        XCTAssertEqual(AppsMenuGeometry.popupFrame(taskbar: TaskbarMetrics.panelFrame(on: smaller),
                                                  screen: smaller, visibleTop: 385),
                       CGRect(x: -518, y: -106, width: 506, height: 483))
    }

}
