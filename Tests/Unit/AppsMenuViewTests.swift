import AppKit
import XCTest

@MainActor
final class AppsMenuViewTests: XCTestCase {
    private final class PointerPanel: NSPanel {
        var pointer = CGPoint.zero
        var simulatedBackingScale: CGFloat?

        override var isKeyWindow: Bool { true }
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var backingScaleFactor: CGFloat { simulatedBackingScale ?? super.backingScaleFactor }
    }

    private final class SizeSensitiveIcon: NSImage {
        override func draw(in rect: NSRect) {
            (rect.width == 38 ? NSColor.green : NSColor.red).setFill()
            rect.fill()
        }
    }

    private final class RunningFixture: NSRunningApplication, @unchecked Sendable {
        let suppliedIcon = NSImage(size: CGSize(width: 16, height: 16))
        var hideRequests = 0
        var activateRequests = 0
        var hiddenState = false
        var pid: pid_t = 50_101
        var name = "Running Fixture"
        var identifier = "test.running.fixture"
        var location: URL? = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        override var processIdentifier: pid_t { pid }
        override var localizedName: String? { name }
        override var bundleIdentifier: String? { identifier }
        override var activationPolicy: NSApplication.ActivationPolicy { .regular }
        override var isTerminated: Bool { false }
        override var isHidden: Bool { hiddenState }
        override var isActive: Bool { false }
        override var icon: NSImage? { suppliedIcon }
        override var bundleURL: URL? { location }
        override func hide() -> Bool { hideRequests += 1; return true }
        override func activate(options: NSApplication.ActivationOptions) -> Bool { activateRequests += 1; return true }
    }

    func testDraggingPinnedTilePersistsItsNewPositionWithoutLaunchingIt() async throws {
        let fixture = try makeCatalog(names: ["One", "Three", "Two"])
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let original = fixture.store.pins.map(\.id)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {
            XCTFail("Dragging must not launch a pinned app")
        }
        panel.contentView = view
        try await waitForButton("One", in: view)
        let source = try XCTUnwrap(button("One", in: view))
        let destination = try XCTUnwrap(button("Two", in: view))
        let start = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = destination.convert(CGPoint(x: destination.bounds.maxX - 1, y: destination.bounds.midY), to: nil)
        func event(_ kind: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1))
        }
        let up = try event(.leftMouseUp, end)
        NSApp.postEvent(up, atStart: true)
        source.mouseDown(with: try event(.leftMouseDown, start))
        source.mouseDragged(with: try event(.leftMouseDragged, end))
        XCTAssertNil(destination.layer?.animation(forKey: "apps-pin-shift"))
        source.mouseUp(with: up)
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertEqual(fixture.store.pins.map(\.id), [original[1], original[2], original[0]])
    }

    func testDroppingPinnedAppOnIconCreatesFolderAndDroppingOnFolderAddsApp() async throws {
        let fixture = try makeCatalog(names: ["One", "Two", "Three", "Four"])
        defer { fixture.cleanUp() }
        let catalog = fixture.store.installedApplications()
        let applications = try ["One", "Two", "Three", "Four"].map { name in
            try XCTUnwrap(catalog.first { $0.name == name })
        }
        applications.forEach(fixture.store.pin)
        let original = fixture.store.pins
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {
            XCTFail("A completed drag must not launch an app")
        }
        panel.contentView = view
        try await waitForButton("One", in: view)

        func drop(_ sourceID: UUID, on targetID: UUID) throws {
            let buttons = descendants(of: view, as: NSButton.self)
            let source = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "pin-\(sourceID)" })
            let destination = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "pin-\(targetID)" })
            let targetFrame = destination.frame
            let selection = try XCTUnwrap(destination.subviews.compactMap { $0 as? NSBox }.first)
            let start = source.convert(CGPoint(x: source.bounds.midX, y: 26), to: nil)
            let end = destination.convert(CGPoint(x: destination.bounds.midX, y: 26), to: nil)
            func event(_ kind: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1))
            }
            source.mouseDown(with: try event(.leftMouseDown, start))
            source.mouseDragged(with: try event(.leftMouseDragged, end))
            XCTAssertEqual(destination.frame, targetFrame)
            XCTAssertGreaterThan(selection.fillColor.alphaComponent, 0)
            source.mouseUp(with: try event(.leftMouseUp, end))
        }

        try drop(original[0].id, on: original[2].id)
        XCTAssertEqual(fixture.store.pins.map(\.id), [original[1].id, original[2].id, original[3].id])
        XCTAssertEqual(fixture.store.pins[1].applicationIDs, [applications[2].id, applications[0].id])
        XCTAssertEqual(fixture.store.pins[1].name, "")
        try drop(original[3].id, on: original[2].id)
        XCTAssertEqual(fixture.store.pins.map(\.id), [original[1].id, original[2].id])
        XCTAssertEqual(fixture.store.pins[1].applicationIDs, [applications[2].id, applications[0].id, applications[3].id])
        XCTAssertEqual(AppsMenuStore(defaults: fixture.defaults).pins, fixture.store.pins)
    }

    func testDraggingPinnedTileSlidesItsNeighborIntoTheVacatedSlot() async throws {
        let fixture = try makeCatalog(names: ["One", "Three", "Two"])
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { false }) {}
        panel.contentView = view
        try await waitForButton("One", in: view)
        let source = try XCTUnwrap(button("One", in: view))
        let neighbor = try XCTUnwrap(button("Three", in: view))
        let unaffected = try XCTUnwrap(button("Two", in: view))
        let vacatedFrame = source.frame
        let start = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = neighbor.convert(CGPoint(x: neighbor.bounds.maxX - 1, y: neighbor.bounds.midY), to: nil)
        func event(_ kind: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1))
        }

        source.mouseDown(with: try event(.leftMouseDown, start))
        source.mouseDragged(with: try event(.leftMouseDragged, end))

        XCTAssertEqual(neighbor.frame, vacatedFrame)
        XCTAssertEqual(source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil), end)
        XCTAssertNil(source.layer?.animation(forKey: "apps-pin-shift"))
        XCTAssertNil(unaffected.layer?.animation(forKey: "apps-pin-shift"))
        let movement = try XCTUnwrap(neighbor.layer?.animation(forKey: "apps-pin-shift") as? CABasicAnimation)
        let from = try XCTUnwrap((movement.fromValue as? NSValue)?.pointValue)
        let to = try XCTUnwrap((movement.toValue as? NSValue)?.pointValue)
        XCTAssertEqual(to.x - from.x, -96, accuracy: 0.01)
        XCTAssertEqual(to.y, from.y, accuracy: 0.01)
        XCTAssertGreaterThan(movement.duration, 0)
    }

    func testDraggingPinnedTileOverAClippedSlotCancelsReorder() async throws {
        let fixture = try makeCatalog(names: (0..<12).map { String(format: "App %02d", $0) })
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let order = fixture.store.pins.map(\.id)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {}
        panel.contentView = view
        try await waitForButton("App 07", in: view)
        let source = try XCTUnwrap(button("App 07", in: view))
        let destination = try XCTUnwrap(button("App 00", in: view))
        let scroll = try XCTUnwrap(source.enclosingScrollView)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 130))
        scroll.reflectScrolledClipView(clip)
        let start = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = destination.convert(CGPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
        XCTAssertTrue(clip.bounds.contains(clip.convert(start, from: nil)))
        XCTAssertFalse(clip.bounds.contains(clip.convert(end, from: nil)))
        func event(_ kind: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1))
        }
        source.mouseDown(with: try event(.leftMouseDown, start))
        source.mouseDragged(with: try event(.leftMouseDragged, end))
        source.mouseUp(with: try event(.leftMouseUp, end))
        XCTAssertEqual(fixture.store.pins.map(\.id), order)
    }

    func testSystemFileManagerOccupiesTheLeadingSlotOutsideTheRunningScroller() throws {
        let suite = "DeskMote.AppsMenuViewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = RunningFixture()
        let manager = RunningFixture()
        manager.pid = 50_102
        manager.name = "File Manager Fixture"
        manager.identifier = "test.file.manager"
        let application = AppsMenuApplication(id: manager.identifier, name: manager.name,
            url: try XCTUnwrap(manager.location), category: "utilities")
        var runningApplications = [other, manager]
        var opened: [URL] = []
        let store = AppsMenuStore(defaults: defaults, applicationDirectories: [],
                                  runningApplicationSnapshot: { runningApplications },
                                  systemFileManager: application, openApplication: { opened.append($0) })
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) {}
        let leading = try XCTUnwrap(button(manager.name, in: view))
        let running = try XCTUnwrap(button(other.name, in: view))
        XCTAssertNil(leading.enclosingScrollView)
        XCTAssertLessThan(leading.convert(leading.bounds, to: view).minX,
                          running.convert(running.bounds, to: view).minX)
        XCTAssertEqual(descendants(of: view, as: NSButton.self).filter { $0.title == manager.name }.count, 1)
        runningApplications = [other]
        let reopened = AppsMenuView(frame: view.frame, store: store) {}
        let stoppedManager = try XCTUnwrap(button(manager.name, in: reopened))
        XCTAssertNil(stoppedManager.enclosingScrollView)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stoppedManager.action), to: stoppedManager.target, from: stoppedManager))
        XCTAssertEqual(opened, [application.url])
    }

    func testRunningApplicationClickUsesOpeningInsteadOfOnlyActivation() throws {
        let app = RunningFixture()
        app.location = URL(fileURLWithPath: "/nonexistent/DeskMote Test Fixture.app")
        var dismissed = false
        var opened: [URL] = []
        let store = AppsMenuStore(applicationDirectories: [], runningApplicationSnapshot: { [app] },
                                  openApplication: { opened.append($0) })
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) { dismissed = true }
        let target = try XCTUnwrap(button(app.name, in: view))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(target.action), to: target.target, from: target))
        XCTAssertTrue(dismissed)
        XCTAssertEqual(app.activateRequests, 0)
        XCTAssertEqual(opened, [try XCTUnwrap(app.location)])
    }

    func testRunningAppsHoverShowsOnlyNameAndUsesTheBundleIcon() async throws {
        let app = RunningFixture()
        let store = AppsMenuStore(applicationDirectories: [], runningApplicationSnapshot: { [app] })
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: store) {}
        window.contentView = view
        let button = try XCTUnwrap(button("Running Fixture", in: view))
        let selection = try XCTUnwrap(button.subviews.compactMap { $0 as? NSBox }.first)
        let imageView = try XCTUnwrap(button.subviews.compactMap { $0 as? NSImageView }.first)
        let deadline = ContinuousClock.now + .seconds(1)
        while imageView.image == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(imageView.image)
        XCTAssertFalse(imageView.image === app.suppliedIcon)
        func tooltip() -> NSTextField? {
            descendants(of: view, as: NSTextField.self).first {
                $0.stringValue == app.localizedName && !$0.isDescendant(of: button)
            }
        }
        func hoverEvent(_ kind: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: kind, location: window.pointer, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 1, trackingNumber: 1, userData: nil))
        }
        XCTAssertNil(tooltip())
        window.pointer = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.mouseEntered(with: try hoverEvent(.mouseEntered))
        let title = try XCTUnwrap(tooltip())
        let titleFrame = title.convert(title.bounds, to: nil)
        let iconFrame = imageView.convert(imageView.bounds, to: nil)
        XCTAssertGreaterThan(titleFrame.minY, iconFrame.maxY)
        XCTAssertEqual(titleFrame.midX, iconFrame.midX, accuracy: 0.5)
        XCTAssertEqual(selection.fillColor.alphaComponent, 0)
        XCTAssertFalse(window.isVisible)
        window.pointer = .zero
        button.mouseExited(with: try hoverEvent(.mouseExited))
        XCTAssertNil(tooltip())
    }

    func testRunningIconMatchesPinnedSizeAndCentersWithItsDot() async throws {
        let app = RunningFixture()
        let fixture = try makeCatalog(names: ["Pinned Fixture"], runningApplications: [app])
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        panel.contentView = view
        try await waitForButton("Pinned Fixture", in: view)
        let pinned = try XCTUnwrap(button("Pinned Fixture", in: view))
        let running = try XCTUnwrap(button("Running Fixture", in: view))
        let icon = try XCTUnwrap(running.subviews.compactMap { $0 as? NSImageView }.first)
        let pinnedIcon = try XCTUnwrap(pinned.subviews.compactMap { $0 as? NSImageView }.first)
        let footer = try XCTUnwrap(running.enclosingScrollView?.superview)
        let deadline = ContinuousClock.now + .seconds(1)
        while icon.image == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.frame.size, pinnedIcon.frame.size)

        let renderModes = [NSAppearance.Name.aqua, .darkAqua].flatMap { appearance in
            [1, 2].map { (appearance, $0) }
        }
        for (appearance, scale) in renderModes {
            view.appearance = NSAppearance(named: appearance)
            let pixelsWide = Int(footer.bounds.width) * scale
            let pixelsHigh = Int(footer.bounds.height) * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = footer.bounds.size
            footer.effectiveAppearance.performAsCurrentDrawingAppearance { footer.cacheDisplay(in: footer.bounds, to: bitmap) }
            if appearance == .darkAqua, scale == 1, let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Apps running footer"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let center = Int(icon.convert(icon.bounds, to: footer).midX) * scale
            let rows = (2 * scale..<(pixelsHigh - 2 * scale)).filter { y in
                ((center - 5 * scale)...(center + 5 * scale)).contains { x in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4
                }
            }
            let first = try XCTUnwrap(rows.first)
            let last = try XCTUnwrap(rows.last)
            XCTAssertGreaterThan(last - first, 36 * scale)
            XCTAssertEqual(CGFloat(first + last + 1) / CGFloat(2 * scale), footer.bounds.midY, accuracy: 1)
        }
    }

    func testRunningAppContextMenuShowsNativeActionsAndRoutesHideToTheApp() throws {
        let app = RunningFixture()
        let store = AppsMenuStore(applicationDirectories: [], runningApplicationSnapshot: { [app] })
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) {}
        let button = try XCTUnwrap(button("Running Fixture", in: view))
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                         clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(button.menu(for: rightClick))
        XCTAssertEqual(menu.items.first { $0.title == "Options" }?.submenu?.items.map(\.title), ["Show in Finder"])
        XCTAssertNotNil(menu.items.first { $0.title == "Quit" })
        let hide = try XCTUnwrap(menu.items.first { $0.title == "Hide" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide))
        XCTAssertEqual(app.hideRequests, 1)
        app.hiddenState = true
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide))
        XCTAssertEqual(app.activateRequests, 0)
    }

    func testScrollKeepsHoverOnOnlyTheRowUnderTheStationaryPointer() async throws {
        let fixture = try makeCatalog(names: (1...25).map { "Test App \($0)" })
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {}
        window.contentView = view
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        search.stringValue = "Test App"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitForButton("Test App 1", in: view)
        let first = try XCTUnwrap(button("Test App 1", in: view))
        let second = try XCTUnwrap(button("Test App 2", in: view))
        func hasHover(_ button: NSButton) -> Bool { hoverGlass(in: button) != nil }
        let scroll = try XCTUnwrap(first.enclosingScrollView)
        window.pointer = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        first.mouseEntered(with: enter)
        XCTAssertTrue(hasHover(first))

        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + second.frame.minY - first.frame.minY))
        scroll.reflectScrolledClipView(clip)

        XCTAssertFalse(hasHover(first))
        XCTAssertTrue(hasHover(second))

        window.pointer = CGPoint(x: -1, y: -1)
        scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(hasHover(second))
    }

    func testViewModeCentersItsCaptionAndChevronWithRoomAtBothEdges() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let mode = try XCTUnwrap(button("View: List", in: view))
        let label = try XCTUnwrap(mode.subviews.compactMap { $0 as? NSTextField }.first)
        let chevron = try XCTUnwrap(mode.subviews.compactMap { $0 as? NSImageView }.first)
        let caption = label.alignmentRect(forFrame: label.frame)
        XCTAssertEqual(label.stringValue, mode.title)
        XCTAssertNotNil(chevron.image)
        XCTAssertEqual(caption.midY, chevron.frame.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(chevron.frame.minX - caption.maxX, 5)
        XCTAssertGreaterThanOrEqual(caption.minX, 8)
        XCTAssertGreaterThanOrEqual(mode.bounds.maxX - chevron.frame.maxX, 8)
        let selection = try XCTUnwrap(mode.subviews.compactMap { $0 as? NSBox }.first)
        XCTAssertEqual(selection.fillColor.alphaComponent, 0)
    }

    func testViewSelectorDoesNotDrawAStrokeForProgrammaticFocus() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        panel.contentView = view
        let mode = try XCTUnwrap(button("View: List", in: view))
        let selection = try XCTUnwrap(mode.subviews.compactMap { $0 as? NSBox }.first)
        XCTAssertTrue(panel.makeFirstResponder(mode))
        XCTAssertEqual(selection.borderWidth, 0)
    }

    func testAllShowsNoticeWhenSpotlightCatalogIsUnavailable() async {
        let store = AppsMenuStore(applicationDirectories: [], runningApplicationSnapshot: { [] }, readIndex: { _ in nil })
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let view = AppsMenuView(frame: frame, store: store, dismiss: {})
        _ = await store.loadCatalog()
        view.prepareForPresentation(size: frame.size)

        let notice = String(localized: "macOS app catalog is unavailable.")
        XCTAssertTrue(descendants(of: view, as: NSTextField.self).contains { $0.stringValue == notice })
    }

    func testAllCatalogKeepsHorizontalOriginWhenViewportIsNarrowerThanDocument() async throws {
        let fixture = try makeCatalog(names: (1...25).map { "Test App \($0)" })
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Test App 1", in: view)
        let scroller = try XCTUnwrap(button("Test App 1", in: view)?.enclosingScrollView)
        let document = try XCTUnwrap(scroller.documentView)
        let clip = scroller.contentView
        clip.frame.size.width -= 36
        XCTAssertGreaterThan(document.frame.width, clip.bounds.width)

        let origin = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 24, dy: 100)).origin
        clip.scroll(to: origin)
        scroller.reflectScrolledClipView(clip)

        XCTAssertEqual(clip.bounds.minX, 0)
        XCTAssertEqual(clip.bounds.minY, 100)
    }

    func testLargeCatalogRendersIconsOnlyNearTheViewport() async throws {
        let names = (0..<180).map { String(format: "Test App %03d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let started = ContinuousClock.now
        try await waitForButton(names[0], in: view)
        let first = try XCTUnwrap(button(names[0], in: view))
        let last = try XCTUnwrap(button(names[names.count - 1], in: view))
        let scroller = try XCTUnwrap(first.enclosingScrollView)
        let rows = descendants(of: scroller, as: NSButton.self).filter { $0.title.hasPrefix("Test App") }
        func hasIcon(_ row: NSButton) -> Bool { row.subviews.contains { $0 is NSImageView } }
        XCTAssertTrue(hasIcon(first))
        XCTAssertFalse(hasIcon(last))
        XCTAssertLessThan(rows.filter(hasIcon).count, 38)
        print("Catalog first viewport: \(started.duration(to: .now)); rendered \(rows.filter(hasIcon).count) rows")

        let clip = scroller.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: last.frame.minY)).origin)
        scroller.reflectScrolledClipView(clip)
        XCTAssertTrue(hasIcon(last))
    }

    func testExpandingAndPinningKeepTheExistingAllRows() async throws {
        let names = (0..<30).map { String(format: "Test App %02d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().prefix(16).forEach(fixture.store.pin)
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let name = try XCTUnwrap(names.last)
        try await waitForButton(name, in: view)
        let row = try XCTUnwrap(button(name, in: view))

        try XCTUnwrap(button("Show all", in: view)).performClick(nil)
        XCTAssertTrue(row === button(name, in: view))
        try XCTUnwrap(button("Show less", in: view)).performClick(nil)
        XCTAssertTrue(row === button(name, in: view))

        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                    clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: event))
        let pin = try XCTUnwrap(menu.items.first { $0.title == "Pin" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(pin.action), to: pin.target, from: pin))
        let deadline = ContinuousClock.now + .seconds(1)
        while fixture.store.pins.count < 17, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.store.pins.count, 17)
        let allRow = descendants(of: view, as: NSButton.self).first {
            $0.title == name && $0.identifier?.rawValue.hasPrefix("catalog-app-") == true
        }
        XCTAssertTrue(row === allRow)
    }

    func testAllModesPrepareBeforeTheFirstSwitch() async throws {
        let names = (0..<180).map { String(format: "Test App %03d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Test App 000", in: view)
        let listRow = try XCTUnwrap(button("Test App 000", in: view))
        let expected = Set(AppsMenuCatalogMode.allCases)
        let deadline = ContinuousClock.now + .seconds(1)
        while view.preparedViewModes != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.preparedViewModes, expected)
        XCTAssertEqual(fixture.store.catalogMode, .list)
        XCTAssertTrue(button("Test App 000", in: view) === listRow)
    }

    func testReopenedMenuShowsCachedApplicationsImmediately() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let first = AppsMenuView(frame: frame, store: fixture.store) {}
        try await waitForButton("Calculator", in: first)
        let reopened = AppsMenuView(frame: frame, store: fixture.store) {}
        XCTAssertNotNil(button("Calculator", in: reopened))
        XCTAssertFalse(descendants(of: reopened, as: NSTextField.self).contains { $0.stringValue == "Loading apps…" })
    }

    func testCatalogShowsRowsBeforeRequestedIconsArrive() async throws {
        let icon = NSImage(size: CGSize(width: 48, height: 48))
        var waiting: [CheckedContinuation<Void, Never>] = []
        var ready = false
        let fixture = try makeCatalog(names: ["Test App"], readIcon: { _ in
            if !ready { await withCheckedContinuation { waiting.append($0) } }
            return icon
        })
        defer {
            ready = true
            waiting.forEach { $0.resume() }
            fixture.cleanUp()
        }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Test App", in: view)
        let row = try XCTUnwrap(button("Test App", in: view))
        let image = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertTrue(row.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Test App" })
        XCTAssertNil(image.image)
        ready = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
        let deadline = ContinuousClock.now + .seconds(1)
        while image.image == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(image.image)
    }

    func testListIconUsesArtworkRenderedAtPinnedSize() async throws {
        let source = SizeSensitiveIcon(size: CGSize(width: 64, height: 64))
        let fixture = try makeCatalog(names: ["Test App"], readIcon: { _ in source })
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        panel.contentView = view
        try await waitForButton("Test App", in: view)
        let row = try XCTUnwrap(button("Test App", in: view))
        let icon = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first)
        let deadline = ContinuousClock.now + .seconds(1)
        while icon.image == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(icon.frame.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(try XCTUnwrap(icon.image).size, icon.frame.size)
        XCTAssertFalse(icon.image === source)
        for scale in [1, 2] {
            panel.simulatedBackingScale = CGFloat(scale)
            icon.viewDidChangeBackingProperties()
            let bitmap = try XCTUnwrap(icon.image?.representations.first as? NSBitmapImageRep)
            XCTAssertEqual(bitmap.pixelsWide, 38 * scale)
            XCTAssertEqual(bitmap.size, icon.frame.size)
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            XCTAssertGreaterThan(center.greenComponent, center.redComponent)
        }
    }

    func testPinnedExpansionRelayoutsAllImmediatelyAndFadesOnlyRevealedTiles() async throws {
        let names = (0..<20).map { String(format: "Test App %02d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().prefix(16).forEach(fixture.store.pin)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var reduced = false
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { reduced }) {}
        panel.contentView = view
        try await waitForButton("Test App 19", in: view)
        let all = try XCTUnwrap(button("Test App 19", in: view)?.superview)
        let initial = all.frame.minY

        try XCTUnwrap(button("Show all", in: view)).performClick(nil)
        XCTAssertEqual(all.frame.minY - initial, 84)
        XCTAssertNil(all.layer?.animation(forKey: "apps-catalog-move"))
        let revealed = try XCTUnwrap(descendants(of: view, as: NSButton.self).first {
            $0.title == "Test App 12" && $0.identifier?.rawValue.hasPrefix("pin-") == true
        })
        let fade = try XCTUnwrap(revealed.layer?.animation(forKey: "apps-pin-fade"))
        XCTAssertEqual(fade.duration, 0.35, accuracy: 0.001)

        reduced = true
        try XCTUnwrap(button("Show less", in: view)).performClick(nil)
        XCTAssertEqual(all.frame.minY, initial)
        XCTAssertNil(all.layer?.animation(forKey: "apps-catalog-move"))
        XCTAssertNil(revealed.superview?.superview)
        XCTAssertFalse(panel.isVisible)
    }

    func testPinAndUnpinFadeOnlyTheChangedTile() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { false }) {}
        panel.contentView = view
        try await waitForButton("Calculator", in: view)
        let row = try XCTUnwrap(button("Calculator", in: view))
        let contextEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                           timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                           eventNumber: 1, clickCount: 1, pressure: 1))
        func choose(_ title: String, from button: NSButton) throws {
            let item = try XCTUnwrap(button.menu(for: contextEvent)?.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        try choose("Pin", from: row)
        let tile = try XCTUnwrap(descendants(of: view, as: NSButton.self).first {
            $0.title == "Calculator" && $0.identifier?.rawValue.hasPrefix("pin-") == true
        })
        let pin = try XCTUnwrap(tile.layer?.animation(forKey: "apps-pin-fade"))
        XCTAssertEqual(pin.duration, 0.35, accuracy: 0.001)
        XCTAssertNil(tile.superview?.layer?.animation(forKey: "apps-catalog-fade"))
        try choose("Unpin", from: tile)
        XCTAssertTrue(fixture.store.pins.isEmpty)
        XCTAssertFalse(tile.isEnabled)
        let unpin = try XCTUnwrap(tile.layer?.animation(forKey: "apps-pin-fade"))
        XCTAssertEqual(unpin.duration, 0.13, accuracy: 0.001)
        XCTAssertFalse(panel.isVisible)
    }

    func testCatalogRowsRemainVisibleAfterLayoutRebuild() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        window.contentView = view
        try await waitForButton("Café Viewer", in: view)
        let original = try XCTUnwrap(button("Café Viewer", in: view))
        window.setContentSize(CGSize(width: 600, height: 676))
        view.layoutSubtreeIfNeeded()

        let replacement = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertFalse(original === replacement)
        XCTAssertGreaterThan(replacement.frame.width, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testPreparedAppsMenuUsesModeChangedBeforeFirstPresentation() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        fixture.store.catalogMode = .list
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        try await waitForButton("Calculator", in: view)
        XCTAssertNotNil(button("View: List", in: view))

        fixture.store.catalogMode = .grid
        view.prepareForPresentation(size: frame.size)
        XCTAssertNotNil(button("View: Grid", in: view))
    }

    func testViewModeDefersLayoutUntilAfterTrackingAndReusesList() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        var selectedMode = "Grid"
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store,
                                presentViewModes: { menu, anchor in
            guard let item = menu.items.first(where: { $0.title == selectedMode }), let action = item.action else {
                XCTFail("Missing menu item")
                return
            }
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            XCTAssertNotNil(anchor.superview)
            XCTAssertNotEqual(fixture.store.catalogMode.rawValue, selectedMode.lowercased())
        }) {}
        try await waitForButton("Café Viewer", in: view)
        let originalRow = try XCTUnwrap(button("Café Viewer", in: view))

        try XCTUnwrap(button("View: List", in: view)).performClick(nil)
        try await waitForButton("View: Grid", in: view)
        XCTAssertFalse(originalRow === button("Café Viewer", in: view))

        selectedMode = "List"
        try XCTUnwrap(button("View: Grid", in: view)).performClick(nil)
        try await waitForButton("View: List", in: view)
        XCTAssertTrue(originalRow === button("Café Viewer", in: view))

        let app = try XCTUnwrap(fixture.store.installedApplications().first)
        fixture.store.pin(app)
        selectedMode = "Grid"
        try XCTUnwrap(button("View: List", in: view)).performClick(nil)
        try await waitForButton("View: Grid", in: view)
        XCTAssertTrue(descendants(of: view, as: NSButton.self).contains {
            $0.identifier?.rawValue.hasPrefix("pin-") == true
        })
    }

    func testSearchUsesApplicationRowsAndReclaimsFooterSpace() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        XCTAssertFalse(search.drawsBackground)
        try await waitForButton("Café Viewer", in: view)
        let regularRow = try XCTUnwrap(button("Café Viewer", in: view))
        let regularScroll = try XCTUnwrap(regularRow.enclosingScrollView)
        XCTAssertEqual(regularScroll.frame.maxY, 611)

        search.stringValue = "cafe"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))

        let searchRow = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertEqual(searchRow.frame.width, regularRow.frame.width)
        XCTAssertEqual(searchRow.frame.height, regularRow.frame.height)
        XCTAssertEqual(searchRow.enclosingScrollView?.frame.maxY, 676)
        XCTAssertNil(button("Calculator", in: view))
        XCTAssertEqual(view.frame.size, CGSize(width: 642, height: 676))

        search.stringValue = ""
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let restoredRow = try XCTUnwrap(button("Calculator", in: view))
        XCTAssertEqual(restoredRow.enclosingScrollView?.frame.maxY, 611)
    }

    func testSearchSeparatesPlaceholderAndEditorFromNativeButtons() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        window.contentView = view
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
        XCTAssertFalse(search.drawsBackground)
        XCTAssertFalse(search.isBezeled)
        XCTAssertTrue(search.isEditable)
        let glyph = cell.searchButtonRect(forBounds: search.bounds)
        XCTAssertGreaterThan(glyph.width, 0)
        XCTAssertGreaterThanOrEqual(cell.searchTextRect(forBounds: search.bounds).minX, glyph.maxX + 5)
        search.stringValue = "Cafe"
        let clear = cell.cancelButtonRect(forBounds: search.bounds)
        XCTAssertGreaterThan(clear.width, 0)
        let text = cell.searchTextRect(forBounds: search.bounds)
        XCTAssertGreaterThanOrEqual(text.minX, glyph.maxX + 5)
        XCTAssertLessThanOrEqual(text.maxX, clear.minX - 5)
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        let editorOrigin = editor.convert(editor.textContainerOrigin, to: search)
        XCTAssertGreaterThanOrEqual(editorOrigin.x, glyph.maxX + 5)
        XCTAssertFalse(window.isVisible)
    }

    func testSearchPlaceholderIsVerticallyCenteredBesideTheLoupe() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        view.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        XCTAssertTrue(panel.makeFirstResponder(search))
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(search.bounds.width * scale),
                                                   pixelsHigh: Int(search.bounds.height * scale), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = search.bounds.size
        search.effectiveAppearance.performAsCurrentDrawingAppearance { search.cacheDisplay(in: search.bounds, to: bitmap) }
        func centerY(_ columns: Range<Int>) throws -> CGFloat {
            let rows = (0..<bitmap.pixelsHigh).filter { y in
                columns.contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return color.alphaComponent > 0.4 && color.redComponent > 0.43
                }
            }
            return CGFloat(try XCTUnwrap(rows.first) + XCTUnwrap(rows.last) + 1) / (2 * scale)
        }
        XCTAssertEqual(try centerY(4..<56), try centerY(74..<220), accuracy: 0.75)
    }

    func testAlphabeticalHeadingOpensIndexAndJumpsToAnAvailableLetter() async throws {
        let names = (0..<30).map { "Apple \($0)" } + ["Zebra Browser"]
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {}
        panel.contentView = view
        try await waitForButton("Apple 0", in: view)
        try XCTUnwrap(button("A", in: view)).performClick(nil)
        XCTAssertNotNil(button("Back", in: view))
        XCTAssertEqual(button("B", in: view)?.isEnabled, false)
        try XCTUnwrap(button("Z", in: view)).performClick(nil)
        XCTAssertNil(button("Back", in: view))
        let last = try XCTUnwrap(button("Zebra Browser", in: view))
        let scroll = try XCTUnwrap(last.enclosingScrollView)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0)
        XCTAssertTrue(last.convert(last.bounds, to: scroll.documentView).intersects(scroll.documentVisibleRect))
    }

    func testAlphabetBackCentersItsChevronAndCaptionWithinTheHoverBounds() async throws {
        let fixture = try makeCatalog(names: ["Apple"])
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {}
        view.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        try await waitForButton("Apple", in: view)
        try XCTUnwrap(button("A", in: view)).performClick(nil)
        let back = try XCTUnwrap(button("Back", in: view))

        for scale in [1, 2] {
            let width = Int(back.bounds.width) * scale
            let height = Int(back.bounds.height) * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = back.bounds.size
            back.layoutSubtreeIfNeeded()
            back.effectiveAppearance.performAsCurrentDrawingAppearance { back.cacheDisplay(in: back.bounds, to: bitmap) }
            let ink = (0..<width).filter { x in
                (0..<height).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return color.alphaComponent > 0.4 && color.redComponent > 0.55
                }
            }
            let leftInset = try XCTUnwrap(ink.first)
            let rightInset = width - 1 - (try XCTUnwrap(ink.last))
            XCTAssertGreaterThanOrEqual(leftInset, 8 * scale)
            XCTAssertEqual(leftInset, rightInset, accuracy: 3 * scale)
            let gap = try XCTUnwrap(zip(ink, ink.dropFirst()).map { $1 - $0 - 1 }.max())
            XCTAssertGreaterThanOrEqual(gap, 7 * scale)
            XCTAssertLessThanOrEqual(gap, 14 * scale)
        }
    }

    func testPinnedHeadingAndAllFollowVisiblePinRows() async throws {
        let names = (1...16).map { "Test App \($0)" }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let apps = fixture.store.installedApplications()
        XCTAssertEqual(apps.count, 16)
        let cases: [(pins: Int, expanded: Bool, allY: CGFloat, toggle: String?)] = [
            (0, false, 103, nil), (3, false, 187, nil),
            (16, false, 271, "Show all"), (16, true, 355, "Show less"),
        ]
        for entry in cases {
            apps.prefix(entry.pins).forEach(fixture.store.pin)
            fixture.store.expanded = entry.expanded
            let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
            try await waitForButton("Test App 1", in: view)
            let labels = descendants(of: view, as: NSTextField.self)
            let pinned = try XCTUnwrap(labels.first { $0.stringValue == "Pinned" })
            let all = try XCTUnwrap(labels.first { $0.stringValue == "All" })
            XCTAssertEqual(pinned.frame.minY, 31)
            let scroller = try XCTUnwrap(all.enclosingScrollView)
            XCTAssertEqual(all.convert(all.bounds, to: scroller.documentView).minY, entry.allY)
            let toggle = ["Show all", "Show less"].first { button($0, in: view) != nil }
            XCTAssertEqual(toggle, entry.toggle)
        }
    }

    func testPinnedTileUsesExpansionTooltipOnlyWhenItsTitleIsClipped() async throws {
        let fixture = try makeCatalog(names: ["TV"])
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("TV", in: view)
        let tile = try XCTUnwrap(button("TV", in: view))
        let label = try XCTUnwrap(tile.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, "TV")
        XCTAssertNil(tile.toolTip)
        XCTAssertTrue(label.allowsExpansionToolTips)
    }

    func testAlphabetHeadingUsesWindowsInsetsAndTheSameHoverAsAppRows() async throws {
        let fixture = try makeCatalog(names: ["Apple"])
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { true }) {}
        panel.contentView = view
        try await waitForButton("A", in: view)
        let heading = try XCTUnwrap(button("A", in: view))
        let label = try XCTUnwrap(heading.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(heading.frame.minX, 53)
        XCTAssertEqual(heading.frame.width, 536)
        XCTAssertEqual(heading.frame.height, 40)
        XCTAssertEqual(label.frame.minX, 12)
        panel.pointer = heading.convert(CGPoint(x: heading.bounds.midX, y: heading.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: panel.pointer, modifierFlags: [],
                                                        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        heading.mouseEntered(with: event)
        let glass = try XCTUnwrap(hoverGlass(in: heading))
        XCTAssertEqual(glass.frame, heading.bounds)
        XCTAssertEqual(glass.style, view.style)
    }

    func testHoverFadesInWhenMotionIsEnabled() async throws {
        let fixture = try makeCatalog(names: ["Apple"])
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store, reduceMotion: { false }) {}
        panel.contentView = view
        try await waitForButton("Apple", in: view)
        let row = try XCTUnwrap(button("Apple", in: view))
        panel.pointer = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: panel.pointer, modifierFlags: [],
                                                        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        row.mouseEntered(with: event)
        let glass = try XCTUnwrap(hoverGlass(in: row))
        XCTAssertEqual(glass.frame, row.bounds)
        XCTAssertEqual(glass.style, view.style)
        let fade = try XCTUnwrap(glass.superview?.layer?.animation(forKey: "apps-hover-opacity") as? CABasicAnimation)
        XCTAssertEqual((fade.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((fade.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertGreaterThan(fade.duration, 0)
    }

    func testPinnedHoverStaysInsideTileWithoutMovingItsIcon() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let app = try XCTUnwrap(fixture.store.installedApplications().first)
        fixture.store.pin(app)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        window.contentView = view
        try await waitForButton(app.name, in: view)
        let pin = try XCTUnwrap(button(app.name, in: view))
        let selection = try XCTUnwrap(pin.subviews.compactMap { $0 as? NSBox }.first)
        let icon = try XCTUnwrap(pin.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(pin.frame, CGRect(x: 33, y: 64, width: 96, height: 84))
        XCTAssertEqual(selection.cornerRadius, 4)
        XCTAssertEqual(icon.convert(icon.bounds, to: pin.superview).midX, 81)
        XCTAssertEqual(icon.convert(icon.bounds, to: pin.superview).minY, 73)
        window.pointer = pin.convert(CGPoint(x: pin.bounds.midX, y: pin.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        pin.mouseEntered(with: event)
        let glass = try XCTUnwrap(hoverGlass(in: pin))
        let decoration = try XCTUnwrap(glass.superview)
        XCTAssertTrue(decoration.superview === pin)
        XCTAssertEqual(decoration.frame, pin.bounds)
        XCTAssertEqual(glass.frame, decoration.bounds)
        XCTAssertEqual(glass.cornerRadius, 4)
        XCTAssertEqual(glass.style, view.style)
        XCTAssertEqual(selection.fillColor.alphaComponent, 0)
    }

    private func hoverGlass(in button: NSButton) -> NSGlassEffectView? {
        descendants(of: button, as: NSGlassEffectView.self).first
    }

    private func makeCatalog(names: [String] = ["Café Viewer", "Calculator"],
                             runningApplications: [NSRunningApplication] = [],
                             readIcon: (@MainActor (URL) async -> NSImage)? = nil)
        throws -> (store: AppsMenuStore, defaults: UserDefaults, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "DeskMote.AppsMenuViewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for (id, name) in names.enumerated() {
            let contents = directory.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let properties = ["CFBundleIdentifier": "test.apps.\(id)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let store = AppsMenuStore(defaults: defaults, applicationDirectories: [directory],
                                  runningApplicationSnapshot: { runningApplications }, readIcon: readIcon)
        return (store, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func waitForButton(_ name: String, in view: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while button(name, in: view) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(button(name, in: view))
    }

    private func button(_ name: String, in view: NSView) -> NSButton? {
        descendants(of: view, as: NSButton.self).first { $0.title == name }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, as: type)
        }
    }
}
