import AppKit
import XCTest
@testable import DeskMoteApps

@MainActor
final class AppsMenuViewTests: XCTestCase {
    private final class PointerPanel: NSPanel {
        var pointer = CGPoint.zero
        var simulatedBackingScale: CGFloat?
        var simulatesVisibility = false

        override func orderFrontRegardless() {}
        override func makeKey() {}
        override var isKeyWindow: Bool { true }
        override var isVisible: Bool { simulatesVisibility || super.isVisible }
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
        var terminateRequests = 0
        var acceptsTermination = true
        var terminatedState = false
        var activeState = false
        var hiddenState = false
        var pid: pid_t = 50_101
        var name = "Running Fixture"
        var identifier = "test.running.fixture"
        var location: URL? = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        override var processIdentifier: pid_t { pid }
        override var localizedName: String? { name }
        override var bundleIdentifier: String? { identifier }
        override var activationPolicy: NSApplication.ActivationPolicy { .regular }
        override var isTerminated: Bool { terminatedState }
        override var isHidden: Bool { hiddenState }
        override var isActive: Bool { activeState }
        override var icon: NSImage? { suppliedIcon }
        override var bundleURL: URL? { location }
        override func hide() -> Bool { hideRequests += 1; return true }
        override func activate(options: NSApplication.ActivationOptions) -> Bool { activateRequests += 1; return true }
        override func terminate() -> Bool { terminateRequests += 1; return acceptsTermination }
        override func isEqual(_ object: Any?) -> Bool { self === (object as? RunningFixture) }
        override var hash: Int { ObjectIdentifier(self).hashValue }
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {
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
        XCTAssertEqual(makeAppsFixtureStore(defaults: fixture.defaults).pins, fixture.store.pins)
    }

    func testDraggingPinnedTileSlidesItsNeighborIntoTheVacatedSlot() async throws {
        let fixture = try makeCatalog(names: ["One", "Three", "Two"])
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { false }) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
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

    func testAppSelectionDismissesBeforeForegroundRequest() async throws {
        let running = RunningFixture()
        running.identifier = "test.apps.0"
        running.location = nil
        var opened: [URL] = []
        var intents: [AppsMenuStore.OpenIntent] = []
        var effects: [String] = []
        let fixture = try makeCatalog(runningApplications: [running], openApplication: { url, intent in
            opened.append(url)
            intents.append(intent)
            effects.append("open")
        })
        defer { fixture.cleanUp() }
        let applications = fixture.store.installedApplications()
        let viewer = try XCTUnwrap(applications.first { $0.id == running.identifier })
        let calculator = try XCTUnwrap(applications.first { $0.id == "test.apps.1" })
        fixture.store.pin(viewer)
        fixture.store.pin(calculator)
        let pin = try XCTUnwrap(fixture.store.pins.first { $0.applicationIDs == [viewer.id] })
        let folder = try XCTUnwrap(fixture.store.createFolder(from: XCTUnwrap(fixture.store.pins.last?.id)))
        fixture.store.renameFolder(folder, to: "Tools")
        var dismissals = 0
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store,
                                reduceMotion: { true }) { dismissals += 1; effects.append("dismiss") }
        try await waitForButton(calculator.name, in: view)
        func invoke(_ identifier: String) throws {
            let target = try XCTUnwrap(descendants(of: view, as: NSButton.self).first {
                $0.identifier?.rawValue == identifier
            })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(target.action), to: target.target, from: target))
        }
        try invoke("catalog-app-\(viewer.id)")
        view.prepareForPresentation(size: view.frame.size)
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        search.stringValue = viewer.name
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try invoke("catalog-app-\(viewer.id)")
        view.prepareForPresentation(size: view.frame.size)
        try invoke("pin-\(pin.id)")
        view.prepareForPresentation(size: view.frame.size)
        try invoke("pin-\(folder)")
        try invoke("folder-app-\(calculator.id)")
        XCTAssertEqual(opened, [viewer.url, viewer.url, viewer.url, calculator.url])
        XCTAssertEqual(intents, [.foreground, .foreground, .foreground, .foreground])
        XCTAssertEqual(effects, Array(repeating: ["dismiss", "open"], count: 4).flatMap { $0 })
        XCTAssertEqual(dismissals, 4)
        XCTAssertEqual(running.activateRequests, 0)

        view.prepareForPresentation(size: view.frame.size)
        try invoke("running-\(running.pid)")
        XCTAssertEqual(dismissals, 5)
        XCTAssertEqual(running.activateRequests, 1)
    }

    #if DESKMOTE_APPS_TEST_HOOKS
    func testRetiredOrReboundButtonCannotOpenReplacement() async throws {
        var opened: [URL] = []
        let fixture = try makeCatalog(names: ["Anchor", "After Reopen"], openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var dismissals = 0
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
                                frame: frame, store: fixture.store) { dismissals += 1 }
        panel.contentView = view
        try await waitForButton("Anchor", in: view)
        view.prepareForPresentation(size: frame.size)
        let control = try XCTUnwrap(button("Anchor", in: view))
        let selector = try XCTUnwrap(control.action)
        let target = try XCTUnwrap(control.target as AnyObject?)
        var tracked = false
        view.withTrackedPressForTest(on: control) {
            tracked = true
            view.stopMenuActions()
            view.prepareForPresentation(size: frame.size)
            XCTAssertTrue(NSApp.sendAction(selector, to: target, from: control))
        }
        XCTAssertTrue(tracked)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(dismissals, 0)
        let current = try XCTUnwrap(button("Anchor", in: view))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(dismissals, 1)
    }

    #endif

    func testRetainedAccessibilityElementCannotLaunchInReopenedMenu() async throws {
        var opened: [URL] = []
        let names = (0..<70).map { String(format: "Fixture %03d", $0) }
        let fixture = try makeCatalog(names: names, openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let app = try XCTUnwrap(fixture.store.installedApplications().first { $0.name == names[0] })
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        var dismissals = 0
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
                                frame: frame, store: fixture.store) { dismissals += 1 }
        try await waitForButton(app.name, in: view)
        view.prepareForPresentation(size: frame.size)
        let host = try XCTUnwrap(catalogButton(app.id, in: view)?.superview)
        func lastElement() throws -> NSAccessibilityElement {
            try XCTUnwrap(host.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
                .first { $0.accessibilityLabel() == names.last })
        }
        let stale = try lastElement()
        view.stopMenuActions()
        view.prepareForPresentation(size: frame.size)
        XCTAssertFalse(stale.accessibilityPerformPress())
        XCTAssertEqual(opened, [])
        XCTAssertEqual(dismissals, 0)
        let current = try lastElement()
        XCTAssertFalse(current === stale)
        XCTAssertTrue(current.accessibilityPerformPress())
        let expectedURL = try XCTUnwrap(fixture.store.installedApplications().first { $0.name == names.last }?.url)
        XCTAssertEqual(opened, [expectedURL])
        XCTAssertEqual(dismissals, 1)
    }

    func testIndependentExitRemovesTileWithoutClosingApps() throws {
        for focusFirst in [false, true] {
            let exiting = RunningFixture()
            let survivor = RunningFixture()
            survivor.pid = 50_102
            survivor.name = "Survivor"
            survivor.identifier = "test.survivor"
            let finder = RunningFixture()
            finder.pid = 50_103
            finder.name = "Fixture Finder"
            finder.identifier = "test.finder"
            let fixed = AppsMenuApplication(id: finder.identifier, name: finder.name,
                                            url: try XCTUnwrap(finder.location), category: "utilities")
            var inventory = [exiting, survivor, finder]
            let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
            let store = makeAppsFixtureStore(runningApplicationSnapshot: { inventory }, systemFileManager: fixed)
            let menu = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
                                   frame: frame, store: store) {}
            let popup = AppsPopupController(makePanel: {
                PointerPanel(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: true)
            }, reduceMotion: { true })
            defer { popup.dismissImmediately() }
            popup.present(content: menu, frame: frame, anchorWindow: nil)
            let panel = try XCTUnwrap(popup.panel)
            let oldFinder = try XCTUnwrap(button(finder.name, in: menu))
            let survivorButton = try XCTUnwrap(button(survivor.name, in: menu))
            XCTAssertNotNil(button(exiting.name, in: menu))
            let runningSubviewCount = oldFinder.subviews.count
            if focusFirst { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel) }
            inventory = [survivor]
            menu.refreshRunningApps()
            if !focusFirst { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel) }

            XCTAssertTrue(popup.panel === panel)
            XCTAssertNil(button(exiting.name, in: menu))
            XCTAssertTrue(button(survivor.name, in: menu) === survivorButton)
            XCTAssertTrue(button(finder.name, in: menu) === oldFinder)
            XCTAssertEqual(oldFinder.subviews.count, runningSubviewCount - 1)
        }
    }

    func testRunningQuitWaitsForObservedRemoval() throws {
        for accepts in [true, false] {
            let app = RunningFixture()
            app.acceptsTermination = accepts
            var running = [app]
            let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { running })
            var dismissals = 0
            let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) { dismissals += 1 }
            let target = try XCTUnwrap(button(app.name, in: view))
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let quit = try XCTUnwrap(target.menu(for: click)?.items.first { $0.title == "Quit" })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quit.action), to: quit.target, from: quit))
            XCTAssertEqual(app.terminateRequests, 1)
            XCTAssertEqual(dismissals, 0)
            view.refreshRunningApps()
            XCTAssertTrue(button(app.name, in: view) === target)
            running = []
            view.refreshRunningApps()
            XCTAssertNil(button(app.name, in: view))
            XCTAssertEqual(dismissals, 0)
        }
    }

    func testRunningFooterKeepsDocumentButtonsAndScrollPosition() throws {
        let fixtures = makeRunningFixtures(count: 12)
        let manager = AppsMenuApplication(id: "test.file.manager", name: "File Manager Fixture",
            url: URL(fileURLWithPath: "/fixture/Finder.app"), category: "utilities")
        var running = Array(fixtures.prefix(11))
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 430, height: 676),
            store: makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { running },
                                 systemFileManager: manager), reduceMotion: { true }) {}
        let survivor = try XCTUnwrap(button(fixtures[0].name, in: view))
        let fixed = try XCTUnwrap(button(manager.name, in: view))
        let scroll = try XCTUnwrap(survivor.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 60, y: 0))
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.x, 60)

        running.append(fixtures[11])
        view.refreshRunningApps()
        running.remove(at: 2)
        running.swapAt(0, 1)
        view.refreshRunningApps()
        view.refreshRunningApps()
        XCTAssertTrue(scroll.documentView === document)
        XCTAssertTrue(button(fixtures[0].name, in: view) === survivor)
        XCTAssertTrue(button(manager.name, in: view) === fixed)
        XCTAssertEqual(clip.bounds.origin.x, 60)
        XCTAssertNil(button(fixtures[2].name, in: view))
        XCTAssertNotNil(button(fixtures[11].name, in: view))

        running = [fixtures[0]]
        view.refreshRunningApps()
        XCTAssertTrue(button(fixtures[0].name, in: view) === survivor)
        XCTAssertEqual(clip.bounds.origin.x, 0)
        running = []
        view.refreshRunningApps()
        XCTAssertTrue(scroll.documentView === document)
        XCTAssertTrue(button(manager.name, in: view) === fixed)
    }

    func testRunningFooterRebindsDuplicateToCurrentProcess() throws {
        let first = RunningFixture()
        first.name = "First copy"
        first.location = nil
        let second = RunningFixture()
        second.pid += 1
        second.name = "Second copy"
        second.location = nil
        var running = [first, second]
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { running })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) {}
        let original = try XCTUnwrap(button(first.name, in: view))
        second.activeState = true
        view.refreshRunningApps()
        let current = try XCTUnwrap(button(second.name, in: view))
        XCTAssertTrue(current === original)
        XCTAssertEqual(current.accessibilityLabel(), second.name)
        XCTAssertTrue(current.subviews.compactMap { $0 as? NSImageView }.first?.image === second.suppliedIcon)
        XCTAssertNil(button(first.name, in: view))
        let quit = try runningMenuItem("Quit", on: current)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quit.action), to: quit.target, from: quit))
        XCTAssertEqual(first.terminateRequests, 0)
        XCTAssertEqual(second.terminateRequests, 1)
        running = [first]
        view.refreshRunningApps()
        XCTAssertTrue(button(first.name, in: view) === original)
    }

    func testStaleFooterMenuCannotQuitReplacement() throws {
        let first = RunningFixture()
        first.name = "Old process"
        let replacement = RunningFixture()
        replacement.name = "New process"
        replacement.pid += 1
        var running = [first]
        var opens = 0
        var dismissals = 0
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { running },
            openApplication: { _, _ in opens += 1 })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) { dismissals += 1 }
        let oldButton = try XCTUnwrap(button(first.name, in: view))
        let oldQuit = try runningMenuItem("Quit", on: oldButton)
        running = [replacement]
        view.refreshRunningApps()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(oldQuit.action), to: oldQuit.target, from: oldQuit))
        XCTAssertEqual(first.terminateRequests, 0)
        XCTAssertEqual(replacement.terminateRequests, 0)
        let replacementButton = try XCTUnwrap(button(replacement.name, in: view))
        let currentQuit = try runningMenuItem("Quit", on: replacementButton)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(currentQuit.action), to: currentQuit.target, from: currentQuit))
        XCTAssertEqual(replacement.terminateRequests, 1)
        running = []
        view.refreshRunningApps()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(replacementButton.action), to: replacementButton.target,
                                       from: replacementButton))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(currentQuit.action), to: currentQuit.target, from: currentQuit))
        XCTAssertEqual(replacement.terminateRequests, 1)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(dismissals, 0)
    }

    func testRunningFooterMembershipAnimationHonorsReduceMotion() throws {
        let fixtures = makeRunningFixtures(count: 5)
        var running = [fixtures[0]]
        var reduceMotion = false
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.simulatesVisibility = true
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [],
            runningApplicationSnapshot: { running }), reduceMotion: { reduceMotion }) {}
        view.prepareForPresentation(size: frame.size)
        panel.contentView = view
        func appearance(_ app: RunningFixture) throws -> CAAnimation? {
            try XCTUnwrap(button(app.name, in: view)).layer?.animation(forKey: "apps-running-appear")
        }

        running.append(fixtures[1])
        view.refreshRunningApps()
        XCTAssertNil(try appearance(fixtures[1]))
        view.presentedOpeningFinished()

        running.reverse()
        view.refreshRunningApps()
        XCTAssertNil(try appearance(fixtures[0]))
        XCTAssertNil(try appearance(fixtures[1]))
        running.append(fixtures[2])
        view.refreshRunningApps()
        let fade = try XCTUnwrap(try appearance(fixtures[2]) as? CABasicAnimation)
        XCTAssertEqual(fade.keyPath, "opacity")
        XCTAssertEqual(fade.duration, TaskbarMotion.reorderTransition, accuracy: 0.001)
        view.refreshRunningApps()
        XCTAssertNil(try appearance(fixtures[0]))

        reduceMotion = true
        running.removeLast()
        running.append(fixtures[3])
        view.refreshRunningApps()
        XCTAssertNil(try appearance(fixtures[3]))
        let remaining = try XCTUnwrap(button(fixtures[3].name, in: view))
        let footer = try XCTUnwrap(remaining.enclosingScrollView?.superview)
        XCTAssertTrue(footer.subviews.compactMap { $0 as? NSImageView }.isEmpty)
        XCTAssertNil(button(fixtures[2].name, in: view))

        reduceMotion = false
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        search.stringValue = "search"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        running.append(fixtures[4])
        view.refreshRunningApps()
        XCTAssertNil(try appearance(fixtures[4]))
    }

    func testRunningFooterAnimationUsesOldClipAndClearsOnDismiss() throws {
        let fixtures = makeRunningFixtures(count: 12)
        var running = fixtures
        let frame = CGRect(x: 0, y: 0, width: 430, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.simulatesVisibility = true
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: makeAppsFixtureStore(applicationDirectories: [],
            runningApplicationSnapshot: { running }), reduceMotion: { false }) {}
        view.prepareForPresentation(size: frame.size)
        panel.contentView = view
        view.presentedOpeningFinished()
        let first = try XCTUnwrap(button(fixtures[0].name, in: view))
        let scroll = try XCTUnwrap(first.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let footer = try XCTUnwrap(scroll.superview)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 20, y: 0))
        scroll.reflectScrolledClipView(clip)
        let region = first.bounds.intersection(first.convert(scroll.documentVisibleRect, from: document))
        XCTAssertGreaterThan(region.width, 0)
        XCTAssertLessThan(region.width, first.bounds.width)
        let formerClip = footer.convert(region, from: first)
        func exitImages() -> [NSImageView] { footer.subviews.compactMap { $0 as? NSImageView } }

        running.removeFirst()
        view.refreshRunningApps()
        XCTAssertNil(button(fixtures[0].name, in: view))
        XCTAssertNil(first.superview)
        let departing = try XCTUnwrap(exitImages().first)
        XCTAssertEqual(departing.frame, formerClip)
        XCTAssertFalse(departing.isAccessibilityElement())
        XCTAssertNil(departing.hitTest(CGPoint(x: formerClip.midX, y: formerClip.midY)))
        XCTAssertNotNil(departing.layer?.animation(forKey: "apps-running-exit"))

        running.insert(fixtures[0], at: 0)
        view.refreshRunningApps()
        XCTAssertNil(departing.superview)
        XCTAssertNotNil(button(fixtures[0].name, in: view))
        running = [fixtures[0]]
        view.refreshRunningApps()
        view.stopMenuActions()
        XCTAssertTrue(exitImages().isEmpty)
        view.prepareForPresentation(size: frame.size)
        view.presentedOpeningFinished()
        running = []
        view.refreshRunningApps()
        XCTAssertEqual(scroll.frame.width, 0)
        XCTAssertEqual(exitImages().count, 1)
        view.stopMenuActions()
        XCTAssertTrue(exitImages().isEmpty)
    }

    private func makeRunningFixtures(count: Int) -> [RunningFixture] {
        (0..<count).map { index in
            let app = RunningFixture()
            app.pid += pid_t(index)
            app.name = "Running \(index)"
            app.identifier += ".\(index)"
            app.location = nil
            return app
        }
    }

    private func runningMenuItem(_ title: String, on button: NSButton) throws -> NSMenuItem {
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        return try XCTUnwrap(button.menu(for: click)?.items.first { $0.title == title })
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
        var intents: [AppsMenuStore.OpenIntent] = []
        let store = makeAppsFixtureStore(defaults: defaults, applicationDirectories: [],
                                  runningApplicationSnapshot: { runningApplications },
                                  systemFileManager: application, openApplication: { url, intent in
            opened.append(url)
            intents.append(intent)
        })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) {}
        let leading = try XCTUnwrap(button(manager.name, in: view))
        let running = try XCTUnwrap(button(other.name, in: view))
        XCTAssertNil(leading.enclosingScrollView)
        XCTAssertLessThan(leading.convert(leading.bounds, to: view).minX,
                          running.convert(running.bounds, to: view).minX)
        XCTAssertEqual(descendants(of: view, as: NSButton.self).filter { $0.title == manager.name }.count, 1)
        runningApplications = [other]
        var dismissed = false
        let reopened = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: view.frame, store: store) { dismissed = true }
        let stoppedManager = try XCTUnwrap(button(manager.name, in: reopened))
        XCTAssertNil(stoppedManager.enclosingScrollView)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stoppedManager.action), to: stoppedManager.target, from: stoppedManager))
        XCTAssertEqual(opened, [application.url])
        XCTAssertEqual(intents, [.foreground])
        XCTAssertTrue(dismissed)
    }

    func testRunningApplicationClickUsesOpeningInsteadOfOnlyActivation() throws {
        let app = RunningFixture()
        app.location = URL(fileURLWithPath: "/nonexistent/DeskMote Test Fixture.app")
        var dismissed = false
        var opened: [URL] = []
        var intents: [AppsMenuStore.OpenIntent] = []
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [app] },
                                  openApplication: { url, intent in
            opened.append(url)
            intents.append(intent)
        })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) { dismissed = true }
        let target = try XCTUnwrap(button(app.name, in: view))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(target.action), to: target.target, from: target))
        XCTAssertTrue(dismissed)
        XCTAssertEqual(app.activateRequests, 0)
        XCTAssertEqual(opened, [try XCTUnwrap(app.location)])
        XCTAssertEqual(intents, [.foreground])
    }

    func testRunningAppsHoverShowsOnlyNameAndUsesTheBundleIcon() async throws {
        let app = RunningFixture()
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [app] })
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: store) {}
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
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
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
        let finderIcon = try XCTUnwrap(NSImage(contentsOfFile: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"))
        let fixture = try makeCatalog(names: ["Pinned Fixture"], runningApplications: [app], readIcon: { _ in finderIcon })
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().forEach(fixture.store.pin)
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [app] })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
        window.contentView = view
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        search.stringValue = "Test App"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitForButton("Test App 1", in: view)
        let first = try XCTUnwrap(button("Test App 1", in: view))
        let second = try XCTUnwrap(button("Test App 2", in: view))
        func hasHover(_ button: NSButton) -> Bool { hoverGlass(in: button) != nil }
        let scroll = try XCTUnwrap(first.enclosingScrollView)
        let pointer = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: pointer, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime + 2, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        first.mouseEntered(with: enter)
        XCTAssertTrue(hasHover(first))

        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + second.frame.minY - first.frame.minY))
        scroll.reflectScrolledClipView(clip)

        XCTAssertFalse(hasHover(first))
        XCTAssertTrue(hasHover(second))

        let outside = CGPoint(x: -1, y: -1)
        let staleExit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: outside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, trackingNumber: 1, userData: nil))
        first.mouseExited(with: staleExit)
        XCTAssertTrue(hasHover(second))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: outside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 3, windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, trackingNumber: 1, userData: nil))
        second.mouseExited(with: exit)
        scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(hasHover(second))
    }

    func testViewModeCentersItsCaptionAndChevronWithRoomAtBothEdges() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
        panel.contentView = view
        let mode = try XCTUnwrap(button("View: List", in: view))
        let selection = try XCTUnwrap(mode.subviews.compactMap { $0 as? NSBox }.first)
        XCTAssertTrue(panel.makeFirstResponder(mode))
        XCTAssertEqual(selection.borderWidth, 0)
    }

    func testAllShowsNoticeWhenSpotlightCatalogIsUnavailable() async {
        let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] }, readIndex: { _ in nil })
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: store, dismiss: {})
        _ = await store.loadCatalog()
        view.prepareForPresentation(size: frame.size)

        let notice = String(localized: "macOS app catalog is unavailable.")
        XCTAssertTrue(descendants(of: view, as: NSTextField.self).contains { $0.stringValue == notice })
    }

    func testAllCatalogKeepsHorizontalOriginWhenViewportIsNarrowerThanDocument() async throws {
        let fixture = try makeCatalog(names: (1...25).map { "Test App \($0)" })
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let started = ContinuousClock.now
        try await waitForButton(names[0], in: view)
        let first = try XCTUnwrap(button(names[0], in: view))
        let scroller = try XCTUnwrap(first.enclosingScrollView)
        let rows = descendants(of: scroller, as: NSButton.self).filter { $0.title.hasPrefix("Test App") }
        func hasIcon(_ row: NSButton) -> Bool { row.subviews.contains { $0 is NSImageView } }
        XCTAssertTrue(hasIcon(first))
        XCTAssertNil(button(names[names.count - 1], in: view))
        XCTAssertLessThan(rows.filter(hasIcon).count, 38)
        print("Catalog first viewport: \(started.duration(to: .now)); rendered \(rows.filter(hasIcon).count) rows")

        let clip = scroller.contentView
        let document = try XCTUnwrap(scroller.documentView)
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: document.frame.height)).origin)
        scroller.reflectScrolledClipView(clip)
        let last = try XCTUnwrap(button(names[names.count - 1], in: view))
        XCTAssertTrue(hasIcon(last))
    }

    func testExpandingAndPinningKeepTheExistingAllRows() async throws {
        let names = (0..<30).map { String(format: "Test App %02d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        fixture.store.installedApplications().suffix(16).forEach(fixture.store.pin)
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let name = names[0]
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

    #if DESKMOTE_APPS_TEST_HOOKS
    func testAllModesPrepareBeforeTheFirstSwitch() async throws {
        let names = (0..<180).map { String(format: "Test App %03d", $0) }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        XCTAssertNil(button("Test App 179", in: view))
    }
    #endif

    func testAlphabeticalGeometryRevealsUninstantiatedTarget() throws {
        let apps = (0..<90).map { index in
            AppsMenuApplication(id: "fixture.app.\(index)", name: index == 89 ? "Zebra" : "Apple \(index)",
                url: URL(fileURLWithPath: "/fixture/\(index).app"), category: "utilities")
        }
        let last = NSUserInterfaceItemIdentifier("catalog-app-fixture.app.89")
        let first = NSUserInterfaceItemIdentifier("catalog-app-fixture.app.0")
        let firstClip = CGRect(x: 0, y: 0, width: 642, height: 520)
        for width in [642.0, 600.0] as [CGFloat] {
            let store = makeAppsFixtureStore(applicationDirectories: [], runningApplicationSnapshot: { [] })
            let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: width, height: 676), store: store) {}
            let scale = width / 642
            for grid in [false, true] {
                let layout = view.makeAlphabeticalLayout(apps, grid: grid, top: 44.5)
                let sections = layout.items.map(\.identifier.rawValue).filter { $0.hasPrefix("section-") }
                XCTAssertEqual(sections, ["section-A", "section-Z"])
                XCTAssertEqual(layout.height, grid ? 1500.5 : 3924.5)
                let firstFrame = try XCTUnwrap(layout.frame(for: first))
                let lastFrame = try XCTUnwrap(layout.frame(for: last))
                if grid {
                    XCTAssertEqual(firstFrame.midX, 81 * scale, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.width, 96 * scale - 2, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.minY, 77.5)
                    XCTAssertEqual(lastFrame.minY, 1393.5)
                } else {
                    XCTAssertEqual(firstFrame.minX, 62 * scale, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.width, width - 124 * scale, accuracy: 0.001)
                    XCTAssertEqual(firstFrame.minY, 78.5)
                    XCTAssertEqual(lastFrame.minY, 3866.5)
                }
                XCTAssertTrue(layout.items(intersecting: firstClip).contains { $0.identifier == first })
                XCTAssertFalse(layout.items(intersecting: firstClip).contains { $0.identifier == last })
            }
        }
    }

    #if DESKMOTE_APPS_TEST_HOOKS
    func testListGridSwitchFixtureTiming() async throws {
        let names = (0..<180).map { String(format: "Catalog Fixture %03d", $0) }
        for scale in [1.0, 2.0] as [CGFloat] {
            let fixture = try makeCatalog(names: names, readIcon: { _ in NSImage(size: CGSize(width: 64, height: 64)) })
            defer { fixture.cleanUp() }
            var selected = "Grid"
            let frame = CGRect(x: 0, y: 0, width: scale == 1 ? 642 : 600, height: 676)
            let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.simulatedBackingScale = scale
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, presentViewModes: { menu, _ in
                guard let item = menu.items.first(where: { $0.title == selected }), let action = item.action else {
                    return XCTFail("Missing mode \(selected)")
                }
                XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            }, reduceMotion: { true }) {}
            panel.contentView = view
            try await waitForButton(names[0], in: view)
            let readyDeadline = ContinuousClock.now + .seconds(2)
            while view.preparedViewModes.count < AppsMenuCatalogMode.allCases.count,
                  ContinuousClock.now < readyDeadline { await Task.yield() }
            XCTAssertEqual(view.preparedViewModes, Set(AppsMenuCatalogMode.allCases))
            for iteration in 0..<12 {
                let from = iteration.isMultiple(of: 2) ? "List" : "Grid"
                selected = iteration.isMultiple(of: 2) ? "Grid" : "List"
                let control = try XCTUnwrap(button("View: \(from)", in: view))
                let start = ContinuousClock.now
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control))
                let deadline = start + .seconds(2)
                while button("View: \(selected)", in: view) == nil, ContinuousClock.now < deadline { await Task.yield() }
                view.layoutSubtreeIfNeeded()
                let duration = start.duration(to: .now).components
                XCTAssertNotNil(button("View: \(selected)", in: view))
                XCTAssertNotNil(button(names[0], in: view))
                let elapsed = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                let mounted = descendants(of: view, as: NSButton.self).filter {
                    $0.identifier?.rawValue.hasPrefix("catalog-app-") == true
                }.count
                print("list-grid-fixture scale=\(scale) step=\(iteration) mode=\(selected) ms=\(elapsed) controls=\(mounted)")
            }
        }
    }
    #endif

    func testListGridKeepsOneAllHostAndBoundsMaterializedRows() async throws {
        let names = (0..<90).map { String(format: "Catalog App %03d", $0) }
        var opened: [URL] = []
        let fixture = try makeCatalog(names: names, openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let apps = fixture.store.installedApplications()
        let first = try XCTUnwrap(apps.first { $0.name == names[0] })
        let last = try XCTUnwrap(apps.first { $0.name == names[89] })
        fixture.store.pin(first)
        let pin = try XCTUnwrap(fixture.store.pins.first)
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store,
                                presentViewModes: { menu, _ in
            if let item = menu.items.first(where: { $0.title == "Grid" }), let action = item.action {
                XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            } else {
                XCTFail("Missing Grid menu item")
            }
        }) {}
        try await waitForButton("View: List", in: view)
        let deadline = ContinuousClock.now + .seconds(2)
        while catalogButton(first.id, in: view) == nil, ContinuousClock.now < deadline { await Task.yield() }
        let listHost = try XCTUnwrap(catalogButton(first.id, in: view)?.superview)
        let pinned = try XCTUnwrap(descendants(of: view, as: NSButton.self).first {
            $0.identifier?.rawValue == "pin-\(pin.id)"
        })
        let toggle = try XCTUnwrap(button("View: List", in: view))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        try await waitForButton("View: Grid", in: view)
        let gridHost = try XCTUnwrap(catalogButton(first.id, in: view)?.superview)
        XCTAssertTrue(listHost === gridHost)
        XCTAssertTrue(pinned.superview != nil)
        XCTAssertLessThan(gridHost.subviews.compactMap { $0 as? NSButton }.count, names.count)
        XCTAssertNil(catalogButton(last.id, in: view))

        let offscreen = try XCTUnwrap(gridHost.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
            .first { $0.accessibilityLabel() == last.name })
        XCTAssertTrue(offscreen.accessibilityPerformPress())
        let revealed = try XCTUnwrap(catalogButton(last.id, in: view))
        let scroll = try XCTUnwrap(revealed.enclosingScrollView)
        XCTAssertTrue(revealed.convert(revealed.bounds, to: scroll.documentView).intersects(scroll.documentVisibleRect))
        XCTAssertEqual(opened, [last.url])
    }

    func testReusedRowIgnoresPriorIconAndRoutesCurrentAction() async throws {
        let names = (0..<90).map { String(format: "Catalog App %03d", $0) }
        let artwork = NSImage(size: CGSize(width: 64, height: 64))
        var delayed: CheckedContinuation<NSImage, Never>?
        var awaitingOld = true
        var opened: [URL] = []
        let fixture = try makeCatalog(names: names, readIcon: { url in
            if awaitingOld, url.deletingPathExtension().lastPathComponent == names[0] {
                return await withCheckedContinuation { delayed = $0 }
            }
            return artwork
        }, openApplication: { url, _ in opened.append(url) })
        defer {
            delayed?.resume(returning: artwork)
            fixture.cleanUp()
        }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton(names[0], in: view)
        let original = try XCTUnwrap(button(names[0], in: view))
        let oldIcon = try XCTUnwrap(original.subviews.compactMap { $0 as? NSImageView }.first)
        let stalePin = try runningMenuItem("Pin", on: original)
        let deadline = ContinuousClock.now + .seconds(2)
        while delayed == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(delayed)

        let scroll = try XCTUnwrap(original.enclosingScrollView)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 2000))
        scroll.reflectScrolledClipView(clip)
        XCTAssertNil(button(names[0], in: view))
        let current = try XCTUnwrap(descendants(of: view, as: NSButton.self).first { $0 === original })
        let application = try XCTUnwrap(fixture.store.installedApplications().first { $0.name == current.title })
        XCTAssertNotEqual(application.name, names[0])
        XCTAssertEqual(current.accessibilityLabel(), application.name)
        XCTAssertNil(oldIcon.superview)
        let imageView = try XCTUnwrap(current.subviews.compactMap { $0 as? NSImageView }.first)
        let iconDeadline = ContinuousClock.now + .seconds(2)
        while imageView.image == nil, ContinuousClock.now < iconDeadline { await Task.yield() }
        let image = try XCTUnwrap(imageView.image)
        awaitingOld = false
        delayed?.resume(returning: NSImage(size: CGSize(width: 24, height: 24)))
        delayed = nil
        await Task.yield()
        XCTAssertTrue(imageView.image === image)

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stalePin.action), to: stalePin.target, from: stalePin))
        await Task.yield()
        XCTAssertTrue(fixture.store.pins.isEmpty)
        let revealedPosition = clip.bounds.origin
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        XCTAssertEqual(opened, [application.url])
        view.prepareForPresentation(size: view.frame.size)
        clip.scroll(to: revealedPosition)
        scroll.reflectScrolledClipView(clip)
        let reopenedRow = try XCTUnwrap(catalogButton(application.id, in: view))
        let currentPin = try runningMenuItem("Pin", on: reopenedRow)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(currentPin.action), to: currentPin.target, from: currentPin))
        let pinDeadline = ContinuousClock.now + .seconds(1)
        while fixture.store.pins.isEmpty, ContinuousClock.now < pinDeadline { await Task.yield() }
        XCTAssertEqual(fixture.store.pins.first?.applicationIDs, [application.id])
    }

    private func catalogButton(_ id: String, in view: NSView) -> NSButton? {
        descendants(of: view, as: NSButton.self).first { $0.identifier?.rawValue == "catalog-app-\(id)" }
    }

    func testRetainedAccessibilityItemKeepsItsTargetWhenAControlIsReused() async throws {
        let names = (0..<90).map { String(format: "Catalog App %03d", $0) }
        var opened: [URL] = []
        let fixture = try makeCatalog(names: names, openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let first = try XCTUnwrap(fixture.store.installedApplications().first { $0.name == names[0] })
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton(first.name, in: view)
        let original = try XCTUnwrap(catalogButton(first.id, in: view))
        let host = try XCTUnwrap(original.superview)
        func firstAccessibilityItem() -> AnyObject? {
            host.accessibilityChildren()?.first { item in
                if let button = item as? NSButton { return button.accessibilityLabel() == first.name }
                return (item as? NSAccessibilityElement)?.accessibilityLabel() == first.name
            }.map { $0 as AnyObject }
        }
        let retained = try XCTUnwrap(firstAccessibilityItem())
        let scroll = try XCTUnwrap(original.enclosingScrollView)
        let clip = scroll.contentView
        func scrollAway() {
            clip.scroll(to: CGPoint(x: 0, y: 2000))
            scroll.reflectScrolledClipView(clip)
        }
        scrollAway()
        XCTAssertNotEqual(original.title, first.name)
        XCTAssertTrue(firstAccessibilityItem() === retained)
        let element = try XCTUnwrap(retained as? NSAccessibilityElement)
        _ = element.accessibilityPerformShowMenu()
        let revealed = try XCTUnwrap(catalogButton(first.id, in: view))
        XCTAssertTrue(revealed.convert(revealed.bounds, to: scroll.documentView).intersects(scroll.documentVisibleRect))
        XCTAssertEqual(try runningMenuItem("Pin", on: revealed).title, "Pin")
        scrollAway()
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(opened, [first.url])
    }

    func testCachedAllExposesItsHeadingModeAndUnavailableNoticeToAccessibility() async throws {
        let fixture = try makeCatalog(names: ["Fixture App"])
        defer { fixture.cleanUp() }
        let application = try XCTUnwrap(fixture.store.installedApplications().first)
        let roots = [application.url.deletingLastPathComponent()]
        let indexed = AppsMenuIndexedApplication(url: application.url, displayName: application.name, hiddenBySystem: false)
        let warm = makeAppsFixtureStore(defaults: fixture.defaults, applicationDirectories: roots, readIndex: { _ in [indexed] })
        _ = await warm.loadCatalog()
        let failing = makeAppsFixtureStore(defaults: fixture.defaults, applicationDirectories: roots, readIndex: { _ in nil })
        let snapshot = await failing.loadCatalog()
        XCTAssertTrue(snapshot.allUnavailable)
        XCTAssertEqual(snapshot.all?.map(\.id), [application.id])
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: failing) {}
        let host = try XCTUnwrap(catalogButton(application.id, in: view)?.superview)
        let accessible = (host.accessibilityChildren() ?? []).compactMap { item -> String? in
            if let text = item as? NSTextField { return text.stringValue }
            if let button = item as? NSButton { return button.accessibilityLabel() }
            return (item as? NSAccessibilityElement)?.accessibilityLabel()
        }
        XCTAssertTrue(accessible.contains("All"))
        XCTAssertTrue(accessible.contains("View: List"))
        XCTAssertTrue(accessible.contains("macOS app catalog is unavailable."))
    }

    func testReopenedMenuShowsCachedApplicationsImmediately() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let first = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
        try await waitForButton("Calculator", in: first)
        let reopened = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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

    func testListIconKeepsItsRetinaBitmapAcrossDetachmentAndReattachment() async throws {
        let source = SizeSensitiveIcon(size: CGSize(width: 64, height: 64))
        let fixture = try makeCatalog(names: ["Test App"], readIcon: { _ in source })
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.simulatedBackingScale = 2
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
        view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        panel.contentView = view
        try await waitForButton("Test App", in: view)
        let row = try XCTUnwrap(button("Test App", in: view))
        let icon = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first)
        let deadline = ContinuousClock.now + .seconds(1)
        while icon.image == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        let retina = try XCTUnwrap(icon.image)
        XCTAssertEqual(retina.representations.first?.pixelsWide, 76)

        panel.contentView = NSView(frame: frame)
        XCTAssertNil(icon.window)
        icon.viewDidChangeBackingProperties()
        icon.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(icon.image === retina)

        panel.contentView = view
        XCTAssertTrue(icon.window === panel)
        XCTAssertTrue(icon.image === retina)

        panel.simulatedBackingScale = 1
        icon.viewDidChangeBackingProperties()
        let standard = try XCTUnwrap(icon.image)
        XCTAssertFalse(standard === retina)
        XCTAssertEqual(standard.representations.first?.pixelsWide, 38)

        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        icon.viewDidChangeEffectiveAppearance()
        XCTAssertFalse(icon.image === standard)
        XCTAssertEqual(icon.image?.representations.first?.pixelsWide, 38)
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { reduced }) {}
        panel.contentView = view
        try await waitForButton("Test App 00", in: view)
        let first = try XCTUnwrap(fixture.store.installedApplications().first { $0.name == "Test App 00" })
        let all = try XCTUnwrap(catalogButton(first.id, in: view)?.superview)
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { false }) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store,
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
        let all = try XCTUnwrap(originalRow.superview)

        try XCTUnwrap(button("View: List", in: view)).performClick(nil)
        try await waitForButton("View: Grid", in: view)
        let gridTile = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertFalse(originalRow === gridTile)
        XCTAssertTrue(gridTile.superview === all)

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

    #if DESKMOTE_APPS_TEST_HOOKS
    func testModeSwitchReconcilesVisibleCatalogOnlyOnce() async throws {
        let fixture = try makeCatalog(names: (0..<90).map { "Catalog App \($0)" })
        defer { fixture.cleanUp() }
        var selectedMode = "Category"
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store,
                                presentViewModes: { menu, _ in
            guard let item = menu.items.first(where: { $0.title == selectedMode }), let action = item.action else {
                XCTFail("Missing \(selectedMode) menu item")
                return
            }
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }) {}
        try await waitForButton("Catalog App 0", in: view)
        let listButton = try XCTUnwrap(button("View: List", in: view))
        let scroll = try XCTUnwrap(listButton.enclosingScrollView)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 550))
        scroll.reflectScrolledClipView(clip)

        for (from, to) in [("List", "Category"), ("Category", "Grid"), ("Grid", "List")] {
            selectedMode = to
            let before = view.catalogClipReconciliationCount
            try XCTUnwrap(button("View: \(from)", in: view)).performClick(nil)
            try await waitForButton("View: \(to)", in: view)
            XCTAssertEqual(view.catalogClipReconciliationCount - before, 1, "\(from) → \(to)")
        }
    }
    #endif

    func testSearchUsesApplicationRowsAndReclaimsFooterSpace() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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

    func testEquivalentSearchResetsScrollWithoutReplacingRows() async throws {
        let fixture = try makeCatalog(names: (0..<32).map { String(format: "Sample App %02d", $0) })
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Sample App 00", in: view)
        try editSearch("sample", in: view)
        let first = try XCTUnwrap(button("Sample App 00", in: view))
        let scroll = try XCTUnwrap(first.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 160))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        try editSearch("SAMPLE", in: view)
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertTrue(button("Sample App 00", in: view) === first)
        let title = try XCTUnwrap(first.subviews.compactMap { $0 as? NSTextField }.first)
        let oldTitleWidth = title.frame.width
        view.setFrameSize(NSSize(width: 520, height: 676))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(button("Sample App 00", in: view) === first)
        XCTAssertLessThan(title.frame.width, oldTitleWidth)
    }

    func testSearchRefreshRebindsSameIdentityWithNewURL() async throws {
        var now = ContinuousClock.now
        var opened: [URL] = []
        let fixture = try makeCatalog(names: ["Sample"], catalogNow: { now },
                                      openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let size = NSSize(width: 642, height: 676)
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(origin: .zero, size: size), store: fixture.store) {}
        try await waitForButton("Sample", in: view)
        view.prepareForPresentation(size: size)
        try editSearch("sample", in: view)
        let row = try XCTUnwrap(button("Sample", in: view))
        let old = try XCTUnwrap(view.searchResults.first)
        let newURL = old.url.deletingLastPathComponent().appendingPathComponent("Moved Sample.app", isDirectory: true)
        try FileManager.default.moveItem(at: old.url, to: newURL)
        now += .seconds(6)
        view.presentedOpeningFinished()
        let deadline = ContinuousClock.now + .seconds(3)
        while view.searchResults.first?.url != newURL, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.searchResults.first?.url, newURL)
        XCTAssertEqual(view.searchResults.first?.id, old.id)
        row.performClick(nil)
        XCTAssertTrue(opened.isEmpty)
        try XCTUnwrap(button("Sample", in: view)).performClick(nil)
        XCTAssertEqual(opened, [newURL])
    }

    func testSearchRejectsRetainedObsoleteRow() async throws {
        var opened: [URL] = []
        let fixture = try makeCatalog(openApplication: { url, _ in opened.append(url) })
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Café Viewer", in: view)
        try editSearch("cafe", in: view)
        let removed = try XCTUnwrap(button("Café Viewer", in: view))
        try editSearch("calculator", in: view)
        removed.performClick(nil)
        XCTAssertTrue(opened.isEmpty)
        let current = try XCTUnwrap(button("Calculator", in: view))
        let app = try XCTUnwrap(view.searchResults.first)
        current.performClick(nil)
        XCTAssertEqual(opened, [app.url])
        try editSearch("", in: view)
        current.performClick(nil)
        XCTAssertEqual(opened, [app.url])
    }

    func testSearchRejectsRetainedObsoleteContextMenu() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        try await waitForButton("Café Viewer", in: view)
        try editSearch("cafe", in: view)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                    clickCount: 1, pressure: 1))
        let row = try XCTUnwrap(button("Café Viewer", in: view))
        let menu = try XCTUnwrap(row.menu(for: event))
        let stalePin = try XCTUnwrap(menu.items.first { $0.title == "Pin" })
        try editSearch("calculator", in: view)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stalePin.action), to: stalePin.target, from: stalePin))
        XCTAssertTrue(fixture.store.pins.isEmpty)
        let current = try XCTUnwrap(button("Calculator", in: view))
        let currentMenu = try XCTUnwrap(current.menu(for: event))
        let currentPin = try XCTUnwrap(currentMenu.items.first { $0.title == "Pin" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(currentPin.action), to: currentPin.target, from: currentPin))
        XCTAssertEqual(fixture.store.pins.flatMap(\.applicationIDs), view.searchResults.map(\.id))
    }

    private func editSearch(_ value: String, in view: AppsMenuView) throws {
        let field = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        field.stringValue = value
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testSearchSeparatesPlaceholderAndEditorFromNativeButtons() throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
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

    func testCategoryBackCentersTheChevronAboveTheHoverGlass() async throws {
        let fixture = try makeCatalog(names: ["Apple"])
        defer { fixture.cleanUp() }
        fixture.store.catalogMode = .category
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let panel = PointerPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
        view.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        try await waitForButton("Other", in: view)
        try XCTUnwrap(button("Other", in: view)).performClick(nil)
        let back = try XCTUnwrap(descendants(of: view, as: NSButton.self).first {
            $0.identifier?.rawValue == "category-back"
        })
        let arrow = try XCTUnwrap(back.subviews.compactMap { $0 as? NSImageView }.first)
        let label = try XCTUnwrap(back.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(back.accessibilityLabel(), "Back")
        XCTAssertEqual(back.bounds.height, 26)
        XCTAssertEqual(arrow.frame.midY, back.bounds.midY)
        let caption = label.alignmentRect(forFrame: label.frame)
        XCTAssertEqual(caption.minX - arrow.frame.maxX, 8)
        XCTAssertEqual((arrow.frame.minX + caption.maxX) / 2, back.bounds.midX)

        panel.pointer = back.convert(CGPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: panel.pointer, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                                        eventNumber: 1, trackingNumber: 1, userData: nil))
        back.mouseEntered(with: event)
        let glass = try XCTUnwrap(hoverGlass(in: back))
        let hover = try XCTUnwrap(glass.superview)
        XCTAssertEqual(glass.frame, back.bounds)
        let hoverDepth = try XCTUnwrap(back.subviews.firstIndex { $0 === hover })
        XCTAssertLessThan(hoverDepth, try XCTUnwrap(back.subviews.firstIndex { $0 === arrow }))
        XCTAssertLessThan(hoverDepth, try XCTUnwrap(back.subviews.firstIndex { $0 === label }))

        for scale in [1, 2] {
            let width = Int(arrow.bounds.width) * scale
            let height = Int(arrow.bounds.height) * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = arrow.bounds.size
            arrow.effectiveAppearance.performAsCurrentDrawingAppearance { arrow.cacheDisplay(in: arrow.bounds, to: bitmap) }
            let inkRows = (0..<height).filter { y in
                (0..<width).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return color.alphaComponent > 0.4 && color.redComponent > 0.55
                }
            }
            let top = try XCTUnwrap(inkRows.first)
            let bottom = try XCTUnwrap(inkRows.last)
            XCTAssertEqual(CGFloat(top + bottom + 1) / 2, CGFloat(height) / 2, accuracy: 1)
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
            let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { true }) {}
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
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store, reduceMotion: { false }) {}
        panel.contentView = view
        try await waitForButton("Apple", in: view)
        let row = try XCTUnwrap(button("Apple", in: view))
        panel.pointer = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: panel.pointer, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
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
        let view = AppsMenuView(observeWorkspace: false, makeMenuItem: TaskbarNativeMenuFactory.actionItem, frame: frame, store: fixture.store) {}
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
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
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
                             readIcon: (@MainActor (URL) async -> NSImage)? = nil,
                             catalogNow: @escaping () -> ContinuousClock.Instant = { .now },
                             openApplication: (@MainActor (URL, AppsMenuStore.OpenIntent) -> Void)? = nil)
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
        let store = makeAppsFixtureStore(defaults: defaults, applicationDirectories: [directory],
                                  runningApplicationSnapshot: { runningApplications }, readIcon: readIcon,
                                  catalogNow: catalogNow, openApplication: openApplication)
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
