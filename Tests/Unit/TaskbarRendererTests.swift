import AppKit
import XCTest

@MainActor
extension TaskbarButtonView {
    func clickForTesting() {
        let point = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let number = window?.windowNumber ?? 0
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                     windowNumber: number, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 2,
                                   windowNumber: number, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        mouseDown(with: down)
        mouseUp(with: up)
    }
}

@MainActor
extension TaskbarWindowListView {
    func clickRowForTesting(at index: Int) throws {
        let application = NSApplication.shared
        let detached = window == nil
        let panel = window ?? NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        if detached {
            panel.isReleasedWhenClosed = false
            panel.contentView = self
        }
        defer {
            if detached {
                panel.contentView = nil
                panel.close()
            }
        }
        panel.layoutIfNeeded()
        tableView.scrollRowToVisible(index)
        layoutSubtreeIfNeeded()
        let row = tableView.rect(ofRow: index)
        let location = tableView.convert(CGPoint(x: 60, y: row.midY), to: nil)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 2,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        application.postEvent(up, atStart: true)
        tableView.mouseDown(with: down)
    }
}

@MainActor
final class TaskbarRendererTests: XCTestCase {
    private final class Popup: TaskbarPopupPresenting {
        var panel: NSPanel? { nil }
        var isPresented: Bool { content != nil }
        var onPresent: ((NSPanel) -> Void)?
        var onDismiss: (() -> Void)?
        var content: NSView?
        var presentations = 0
        var keyRequests = 0

        func makeKey() { keyRequests += 1 }

        func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
            dismiss()
            self.content = content
            presentations += 1
        }

        func dismiss() {
            (content as? TaskbarWindowListView)?.cancelPendingActions()
            content = nil
            onDismiss?()
        }
    }

    private final class ContextMenu: TaskbarContextMenuPresenting {
        var visibilityChanged: ((Bool) -> Void)?
        var menu: NSMenu?
        func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {
            menu = TaskbarNativeMenuFactory.menu(entries: entries)
        }
        func dismiss() { menu = nil }
    }

    func testAppsButtonOpensAndDismissesAnExplicitPopupWithoutWindowGroups() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(origin: .zero, size: frame.size),
                                         popup: popup, contextMenu: ContextMenu())
        panel.contentView = content
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeskMoteTests.AppsPopup.\(UUID())"))
        content.enableAppsMenu(store: AppsMenuStore(defaults: defaults, applicationDirectories: [],
                                                   runningApplicationSnapshot: { [] }))
        var admissions: [Bool] = []
        content.admitWindowList = { explicit in admissions.append(explicit); return true }
        let button = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        XCTAssertEqual(button.frame, AppsMenuGeometry.buttonFrame)
        button.performClick(nil)
        XCTAssertTrue(popup.content is AppsMenuView)
        XCTAssertEqual(admissions, [true])
        XCTAssertTrue(content.hasExplicitPopup)
        XCTAssertEqual(button.state, .on)

        let otherDisplay = TaskbarContentView(frame: content.frame, popup: Popup(), contextMenu: ContextMenu())
        otherDisplay.onBackgroundClick = { content.dismissAppsMenu() }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                    clickCount: 1, pressure: 1))
        otherDisplay.mouseDown(with: click)
        XCTAssertFalse(content.hasExplicitPopup)
        XCTAssertEqual(button.state, .off)

        button.performClick(nil)
        XCTAssertTrue(content.hasExplicitPopup)
        content.prepareForHiding()
        XCTAssertFalse(content.hasExplicitPopup)
        XCTAssertFalse(popup.isPresented)
        XCTAssertEqual(button.state, .off)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    private final class FileDrag: NSObject, NSDraggingInfo {
        weak var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation = CGPoint.zero
        var draggedImageLocation: NSPoint { draggingLocation }
        nonisolated var draggedImage: NSImage? { nil }
        let draggingPasteboard = NSPasteboard.withUniqueName()
        var draggingSource: Any? { nil }
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(location: NSPoint = .zero, sequence: Int = 1) {
            draggingLocation = location
            draggingSequenceNumber = sequence
            super.init()
            draggingPasteboard.declareTypes([.fileURL], owner: nil)
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    private func sendTerminalDrag(_ drag: FileDrag, to destination: NSView) {
        let callback = #selector(NSDraggingDestination.draggingEnded(_:))
        guard let method = class_getInstanceMethod(type(of: destination), callback),
              method != class_getInstanceMethod(NSView.self, callback) else { return }
        (destination as any NSDraggingDestination).draggingEnded?(drag)
    }

    private final class RecordingPopupPanel: NonConstrainingPanel {
        var frontRequests = 0
        var keyRequests = 0
        var pointer = CGPoint.zero
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var canBecomeKey: Bool { true }
        override func orderFrontRegardless() { frontRequests += 1 }
        override func makeKey() { keyRequests += 1 }
    }

    @MainActor
    private final class Clock {
        var waiters: [(duration: Duration?, continuation: CheckedContinuation<Void, Never>)] = []
        var requestedDelays: [Duration] = []
        var completed = 0
        func sleep(_ duration: Duration) async {
            requestedDelays.append(duration)
            await withCheckedContinuation { waiters.append((duration, $0)) }
            completed += 1
        }
        func advance(_ duration: Duration? = nil, allowIdle: Bool = false) async {
            func matches(_ wait: Duration?) -> Bool { duration == nil || wait == duration }
            var pulse: Task<Void, Never>?
            if allowIdle {
                await withCheckedContinuation { ready in
                    pulse = Task {
                        await withCheckedContinuation { waiter in
                            waiters.append((duration, waiter))
                            ready.resume()
                        }
                        completed += 1
                    }
                }
            }
            let deadline = ContinuousClock.now + .seconds(1)
            while !waiters.contains(where: { matches($0.duration) }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            let pending = waiters.filter { matches($0.duration) }
            XCTAssertFalse(pending.isEmpty)
            let completionCount = completed + pending.count
            waiters.removeAll { matches($0.duration) }
            for waiter in pending { waiter.continuation.resume() }
            while completed < completionCount, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(completed, completionCount)
            await pulse?.value
            await Task.yield()
        }
    }

    private func groups(count: Int = 3, generation: ProcessGeneration? = nil) -> [TaskbarGroupPresentation] {
        let windows = (0..<count).map { index in
            let record = WindowRecord(id: WindowID(rawValue: "window-\(index)"), appID: AppID(rawValue: "editor"), pid: 100,
                                      bundleIdentifier: "test.editor", title: ["Project — Editor", "Notes — Editor", "A long document title — Editor"][index % 3],
                                      bounds: CGRect(x: 0, y: 0, width: 1430, height: 760), status: index == 0 ? .active : .inactive,
                                      cgWindowID: UInt32(index + 1), groupID: "window-\(index)", displayUUID: "left", processGeneration: generation)
            return TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: index == 0)
        }
        return [TaskbarGroupPresentation(id: "test.editor", name: "Editor", windows: windows)]
    }

    private func makeView(width: CGFloat = 800) -> TaskbarView {
        _ = NSApplication.shared
        let view = TaskbarView(frame: CGRect(x: 0, y: 0, width: width, height: 32))
        view.taskbarContent.iconProvider = { _ in NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) }
        return view
    }

    func testSurfaceUsesThePublicGlassContentHierarchy() {
        let view = makeView()
        XCTAssertEqual(view.style, .regular)
        XCTAssertEqual(view.cornerRadius, 0)
        XCTAssertNil(view.tintColor)
        XCTAssertTrue(view.contentView === view.taskbarContent)
    }

    func testRendererGivesEveryUncombinedWindowItsOwnButtonAndTitle() {
        let view = makeView()
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertEqual(view.taskbarContent.buttonViews["window:window-0"]?.title, "Project — Editor")
        XCTAssertEqual(view.taskbarContent.buttonViews["window:window-0"]?.frame.minX, 10)
        XCTAssertTrue(view.taskbarContent.buttonViews["window:window-0"]?.isActiveWindow == true)
    }

    func testMultilineCaptionUsesTheWidthOfItsSingleLinePresentation() throws {
        let rawTitle = "Find in page\nYour Repositories"
        let record = WindowRecord(id: WindowID(rawValue: "multiline"), appID: AppID(rawValue: "chrome"), pid: 42,
            bundleIdentifier: "test.chrome", title: rawTitle, bounds: nil, status: .active,
            cgWindowID: 77, groupID: "multiline", displayUUID: "left")
        let item = StripItem(record: record)
        let presentation = TaskbarPresentation.groups(items: [item], order: [item.id],
            filter: StripDisplayFilter(scope: "left", connectedUUIDs: ["left"], primaryUUID: "left"),
            activeItemID: item.id, appName: { _ in "Chrome" })
        let view = makeView()
        view.taskbarContent.update(groups: presentation)
        let button = try XCTUnwrap(view.taskbarContent.buttonViews["window:multiline"])
        XCTAssertEqual(button.frame.width, 164)
        XCTAssertEqual(button.titleLabel.stringValue, "Find in page Your Repositories")
        XCTAssertEqual(button.accessibilityLabel(), rawTitle)
        XCTAssertEqual(record.title, rawTitle)
    }

    func testRepeatedUpdatesReuseViewsAndDoNotDuplicateButtons() {
        let view = makeView()
        view.taskbarContent.update(groups: groups())
        let original = view.taskbarContent.buttonViews["window:window-0"]
        for _ in 0..<20 { view.taskbarContent.update(groups: groups()) }
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertTrue(view.taskbarContent.buttonViews["window:window-0"] === original)
    }

    func testCrowdingAndFreedSpaceReplaceTheGroupWithTheCorrectLiveButtons() {
        let view = makeView(width: 200)
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 1)
        XCTAssertEqual(view.taskbarContent.buttonViews["group:test.editor"]?.title, "Editor")
        XCTAssertEqual(view.taskbarContent.buttonViews["group:test.editor"]?.accessibilityLabel(), "Editor")
        view.frame.size.width = 800
        view.taskbarContent.frame.size.width = 800
        view.taskbarContent.update(groups: groups())
        XCTAssertEqual(view.taskbarContent.buttonViews.count, 3)
        XCTAssertNil(view.taskbarContent.buttonViews["group:test.editor"])
    }

    func testTaskbarButtonRespondsToPointerClicksWithoutKeyboardOrAccessibilityActions() throws {
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), contextMenu: context)
        var toggled: [String] = []
        content.actions.toggle = { toggled.append($0.windowID.rawValue) }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["window:window-1"])
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        let controlDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: button.convert(point, to: nil), modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        button.mouseDown(with: controlDown)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: button))
        XCTAssertNil(context.menu)
        toggled.removeAll()
        for code: UInt16 in [36, 49] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            button.keyDown(with: event)
        }
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertFalse(button.accessibilityPerformShowMenu())
        XCTAssertTrue(toggled.isEmpty)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: button))
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: button))
        XCTAssertEqual(toggled, ["window-1"])
    }

    func testClosingLastWindowRemovesTheApplicationGroup() {
        let view = makeView()
        view.taskbarContent.update(groups: groups(count: 1))
        view.taskbarContent.update(groups: [])
        XCTAssertTrue(view.taskbarContent.buttonViews.isEmpty)
        XCTAssertTrue(view.taskbarContent.layoutResult.buttons.isEmpty)
    }

    func testHoveringSeparateButtonsNeverShowsATitleOrPreviewPopup() async {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        content.buttonViews["window:window-0"]?.onHover?(true)
        await clock.advance(allowIdle: true)
        XCTAssertEqual(popup.presentations, 0)
        XCTAssertNil(content.buttonViews["window:window-0"]?.toolTip)
    }

    func testOpenListsDismissWhenTheSameSeatChangesItsActionIdentity() async throws {
        for width: CGFloat in [60, 200] {
            for replaceProcess in [false, true] {
                let clock = Clock()
                let popup = Popup()
                let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                                 delay: { await clock.sleep($0) })
                let initial = groups(generation: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 0)))
                var activated: [String] = []
                var closed: [String] = []
                content.actions.activate = { activated.append($0.windowID.rawValue) }
                content.actions.close = { closed.append($0.windowID.rawValue) }
                content.update(groups: initial)
                let button = width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"]
                try XCTUnwrap(button).clickForTesting()
                let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
                let oldRow = try XCTUnwrap(list.nativeRow(at: 0))
                oldRow.scheduleFileHover()
                let record = WindowRecord(id: WindowID(rawValue: replaceProcess ? "window-0" : "replacement-tab"),
                    appID: AppID(rawValue: "editor"), pid: 100, bundleIdentifier: "test.editor", title: "Replacement tab",
                    bounds: CGRect(x: 0, y: 0, width: 1430, height: 760), status: .active,
                    cgWindowID: replaceProcess ? 1 : 99, groupID: "window-0", displayUUID: "left",
                    processGeneration: ProcessGeneration(timeval(tv_sec: replaceProcess ? 20 : 10, tv_usec: 0)))
                let replacement = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: true)
                let updated = [TaskbarGroupPresentation(id: "test.editor", name: "Editor",
                    windows: [replacement] + Array(initial[0].windows.dropFirst()))]
                content.update(groups: updated)
                XCTAssertFalse(popup.isPresented)
                await clock.advance()
                try list.clickRowForTesting(at: 0)
                oldRow.close()
                XCTAssertTrue(activated.isEmpty)
                XCTAssertTrue(closed.isEmpty)
                let reopenedButton = width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"]
                try XCTUnwrap(reopenedButton).clickForTesting()
                let reopened = try XCTUnwrap(popup.content as? TaskbarWindowListView)
                XCTAssertEqual(reopened.nativeRow(at: 0)?.title, "Replacement tab")
                try reopened.clickRowForTesting(at: 0)
                XCTAssertEqual(activated, [replaceProcess ? "window-0" : "replacement-tab"])
            }
        }
    }

    func testDismissedListCannotDispatchActionsForItsSurvivingWindow() async throws {
        for width: CGFloat in [60, 200] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            let editor = groups()[0]
            var activated: [String] = []
            var closed: [String] = []
            content.actions.activate = { activated.append($0.windowID.rawValue) }
            content.actions.close = { closed.append($0.windowID.rawValue) }
            content.update(groups: [editor])
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
            button.clickForTesting()
            let dismissed = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            let oldRow = try XCTUnwrap(dismissed.nativeRow(at: 0))
            let replacement = WindowRecord(id: WindowID(rawValue: "replacement"), appID: AppID(rawValue: "editor"),
                pid: 100, bundleIdentifier: "test.editor", title: "Replacement", bounds: nil,
                status: .inactive, cgWindowID: 99, groupID: "window-1", displayUUID: "left")
            let newWindow = TaskbarWindowPresentation(item: StripItem(record: replacement), title: replacement.title, isActive: false)
            content.update(groups: [TaskbarGroupPresentation(id: editor.id, name: editor.name,
                windows: [editor.windows[0], newWindow, editor.windows[2]])])
            XCTAssertFalse(popup.isPresented)

            button.clickForTesting()
            let current = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            try dismissed.clickRowForTesting(at: 0)
            oldRow.close()
            oldRow.scheduleFileHover()
            await clock.advance()
            XCTAssertTrue(activated.isEmpty)
            XCTAssertTrue(closed.isEmpty)
            XCTAssertTrue(popup.content === current)

            try XCTUnwrap(current.nativeRow(at: 0)).close()
            try current.clickRowForTesting(at: 0)
            XCTAssertEqual(closed, ["window-0"])
            XCTAssertEqual(activated, ["window-0"])
        }
    }

    func testCombinedButtonOpensAnOrderedIconAndTitleListWithoutActivatingAWindow() throws {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        let icon = NSImage(size: CGSize(width: 16, height: 16))
        content.iconProvider = { _ in icon }
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.clickForTesting()
        let list = popup.content as? TaskbarWindowListView
        XCTAssertEqual(list?.nativeRows.map(\.item.title), groups()[0].windows.map(\.title))
        XCTAssertTrue(list?.nativeRows.allSatisfy { $0.icon === icon } == true)
        XCTAssertEqual(list.map { value in (0..<value.tableView.numberOfRows).map { value.tableView.rect(ofRow: $0).minY } }, [0, 40, 80])
        XCTAssertTrue(activated.isEmpty)
        try XCTUnwrap(list).clickRowForTesting(at: 1)
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(popup.isPresented)
    }

    func testTitleOnlyUpdateKeepsTheOpenListAndItsWindowActions() throws {
        for width: CGFloat in [60, 200] {
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup)
            let initial = groups()
            var activated: [String] = []
            content.actions.activate = { activated.append($0.windowID.rawValue) }
            content.update(groups: initial)
            let button = width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"]
            try XCTUnwrap(button).clickForTesting()
            let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            let record = WindowRecord(id: WindowID(rawValue: "window-0"), appID: AppID(rawValue: "editor"), pid: 100,
                bundleIdentifier: "test.editor", title: "Renamed document", bounds: CGRect(x: 0, y: 0, width: 1430, height: 760),
                status: .active, cgWindowID: 1, groupID: "window-0", displayUUID: "left")
            let renamed = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: true)
            content.update(groups: [TaskbarGroupPresentation(id: "test.editor", name: "Editor",
                windows: [renamed] + Array(initial[0].windows.dropFirst()))])
            XCTAssertTrue(popup.content === list)
            XCTAssertEqual(popup.presentations, 1)
            XCTAssertEqual(list.nativeRow(at: 0)?.title, "Renamed document")
            try list.clickRowForTesting(at: 0)
            XCTAssertEqual(activated, ["window-0"])
        }
    }

    func testFreedSpaceDismissesTheNowUnnecessaryGroupList() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.clickForTesting()
        XCTAssertTrue(popup.isPresented)
        content.frame.size.width = 800
        content.update(groups: groups())
        XCTAssertFalse(popup.isPresented)
    }

    func testCombinedWindowListDismissesWhenItsButtonMovesToOverflow() async throws {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 170, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let initial = unequalGroups(shortFirst: true)
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: initial)
        let button = try XCTUnwrap(content.buttonViews["group:test.wide"])
        button.clickForTesting()
        XCTAssertTrue(content.hasClickedWindowList)
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        row.scheduleFileHover()

        content.update(groups: initial + groups(count: 1))

        XCTAssertTrue(content.layoutResult.overflowGroups.contains("test.wide"))
        XCTAssertNil(content.buttonViews["group:test.wide"])
        XCTAssertFalse(popup.isPresented)
        XCTAssertFalse(content.hasClickedWindowList)
        await clock.advance()
        withExtendedLifetime(list) {
            XCTAssertTrue(activated.isEmpty)
        }
    }

    func testClickPromotesAHoverListWithoutRecreatingIt() async {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        let button = content.buttonViews["group:test.editor"]!
        button.onHover?(true)
        await clock.advance()
        XCTAssertEqual(popup.presentations, 1)
        XCTAssertEqual(popup.keyRequests, 0)
        let original = popup.content
        button.clickForTesting()
        XCTAssertTrue(popup.content === original)
        XCTAssertEqual(popup.presentations, 1)
        XCTAssertEqual(popup.keyRequests, 1)
    }

    func testOverflowClickMakesTheListKeyForOutsideClickDismissal() {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 60, height: 32), popup: popup)
        content.update(groups: twoGroups())
        content.overflowButton?.clickForTesting()
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(popup.keyRequests, 1)
    }

    func testPopupListIgnoresKeyboardAndAccessibilityActions() throws {
        _ = NSApplication.shared
        let panel = RecordingPopupPanel(contentRect: CGRect(x: 0, y: 0, width: 216, height: 120),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let controller = TaskbarPopupController(makePanel: { _ in panel })
        defer { controller.dismiss() }
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { _ in }, fileHover: { _ in })
        controller.present(content: list, frame: list.bounds, anchorWindow: nil)
        XCTAssertEqual(panel.frontRequests, 1)
        XCTAssertEqual(panel.keyRequests, 0)
        controller.makeKey()
        XCTAssertEqual(panel.keyRequests, 1)
        XCTAssertFalse(list.acceptsFirstResponder)
        XCTAssertFalse(list.tableView.acceptsFirstResponder)
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        XCTAssertFalse(row.accessibilityPerformPress())
        XCTAssertTrue(row.accessibilityCustomActions()?.isEmpty ?? true)
        for code: UInt16 in [125, 125, 36, 53] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
        XCTAssertTrue(activated.isEmpty)
        XCTAssertEqual(list.tableView.selectedRow, -1)
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    func testFileHoverRestoresOnlyTheExactSeparateWindow() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "window:window-1")
        await clock.advance()
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertEqual(popup.presentations, 0)
    }

    func testPendingFileHoverRejectsAReplacementWindowAndAllowsAFreshHover() async {
        for replaceProcess in [false, true] {
            let clock = Clock()
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            var activated: [String] = []
            content.actions.activate = { activated.append($0.windowID.rawValue) }
            content.update(groups: groups(count: 1, generation: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 0))))
            content.scheduleFileHover(buttonID: "window:window-0")
            let record = WindowRecord(id: WindowID(rawValue: replaceProcess ? "window-0" : "replacement-tab"),
                appID: AppID(rawValue: "editor"), pid: 100, bundleIdentifier: "test.editor", title: "Replacement tab",
                bounds: CGRect(x: 0, y: 0, width: 1430, height: 760), status: .active,
                cgWindowID: replaceProcess ? 1 : 99, groupID: "window-0", displayUUID: "left",
                processGeneration: ProcessGeneration(timeval(tv_sec: replaceProcess ? 20 : 10, tv_usec: 0)))
            let replacement = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: true)
            content.update(groups: [TaskbarGroupPresentation(id: "test.editor", name: "Editor", windows: [replacement])])
            await clock.advance()
            XCTAssertTrue(activated.isEmpty)
            content.scheduleFileHover(buttonID: "window:window-0")
            await clock.advance()
            XCTAssertEqual(activated, [replaceProcess ? "window-0" : "replacement-tab"])
            XCTAssertEqual(popup.presentations, 0)
        }
    }

    func testReplacementButtonAcceptsFreshFileHoverBeforeOldDelayCompletes() async {
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup(),
                                         delay: { await clock.sleep($0) })
        let initial = ProcessGeneration(timeval(tv_sec: 10, tv_usec: 0))
        let replacement = ProcessGeneration(timeval(tv_sec: 20, tv_usec: 0))
        let buttonID = "window:window-0"
        var activated: [ProcessGeneration?] = []
        content.actions.activate = { activated.append($0.processGeneration) }
        content.update(groups: groups(count: 1, generation: initial))
        let button = content.buttonViews[buttonID]
        content.scheduleFileHover(buttonID: buttonID)

        content.update(groups: groups(count: 1, generation: replacement))
        XCTAssertNotNil(button)
        XCTAssertTrue(content.buttonViews[buttonID] === button)
        content.scheduleFileHover(buttonID: buttonID)
        await clock.advance()
        await clock.advance(allowIdle: true)

        XCTAssertEqual(activated, [replacement])
    }

    func testPopupClosesOnItsOwnFocusLossAndIgnoresOtherWindows() {
        let first = RecordingPopupPanel(contentRect: CGRect(x: 0, y: 0, width: 216, height: 120),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let second = RecordingPopupPanel(contentRect: first.frame,
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var panels = [first, second]
        let controller = TaskbarPopupController(makePanel: { _ in panels.removeFirst() })
        defer { controller.dismiss() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 216, height: 120))
        controller.present(content: content, frame: content.bounds, anchorWindow: nil)
        controller.makeKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertTrue(controller.isPresented)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertFalse(controller.isPresented)
        controller.present(content: content, frame: content.bounds, anchorWindow: nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertTrue(controller.isPresented)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
    }

    func testPopupOwnPointerStateKeepsTheListOpenAcrossTheButtonGap() async throws {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        button.onHover?(true)
        await clock.advance()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        list.mouseEntered(with: enter)
        XCTAssertTrue(list.isPointerInside)
        button.onHover?(false)
        await clock.advance(allowIdle: true)
        XCTAssertTrue(popup.isPresented)
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        list.mouseExited(with: exit)
        XCTAssertFalse(list.isPointerInside)
        await clock.advance()
        XCTAssertFalse(popup.isPresented)
    }

    func testPopupOwnFileDragPresencePreventsDismissalUntilTheDragLeaves() async throws {
        let clock = Clock()
        let popup = Popup()
        let drag = FileDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        button.onHover?(true)
        await clock.advance()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        drag.draggingLocation = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        XCTAssertEqual(row.draggingEntered(drag), .generic)
        XCTAssertTrue(list.isPointerInside)
        button.onHover?(false)
        await clock.advance()
        XCTAssertTrue(popup.isPresented)
        row.draggingExited(drag)
        XCTAssertFalse(list.isPointerInside)
        await clock.advance()
        XCTAssertFalse(popup.isPresented)
    }

    func testClosingAFileHoverTargetPreventsDelayedActivation() async {
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup(),
                                         delay: { await clock.sleep($0) })
        var activated = false
        content.actions.activate = { _ in activated = true }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "window:window-1")
        content.update(groups: groups(count: 1))
        await clock.advance()
        XCTAssertFalse(activated)
    }

    func testHidingThePanelCancelsPendingFileAndListHoverActions() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.onHover?(true)
        content.scheduleFileHover(buttonID: "group:test.editor")
        content.prepareForHiding()
        await clock.advance()
        XCTAssertEqual(popup.presentations, 0)
    }

    func testFileHoverOnCombinedButtonWaitsForTheUserToChooseAListRow() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        content.scheduleFileHover(buttonID: "group:test.editor")
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)
        XCTAssertEqual(popup.keyRequests, 0)
        let list = popup.content as? TaskbarWindowListView
        XCTAssertNotNil(list)
        list?.nativeRow(at: 2)?.scheduleFileHover()
        await clock.advance()
        XCTAssertEqual(activated, ["window-2"])
    }

    func testDismissedListCannotActivateAWindowFromItsDelayedFileHover() async {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated = false
        content.actions.activate = { _ in activated = true }
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.clickForTesting()
        let list = popup.content as? TaskbarWindowListView
        list?.nativeRow(at: 0)?.scheduleFileHover()
        content.prepareForHiding()
        await clock.advance()
        XCTAssertFalse(activated)
    }

    func testAnOpenContextMenuCannotTargetAReplacementProcess() throws {
        for width: CGFloat in [200, 800] {
            let context = ContextMenu()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), contextMenu: context)
            var closed: [String] = []
            var quits = 0
            content.actions.close = { closed.append($0.windowID.rawValue) }
            content.actions.quit = { _ in quits += 1 }
            content.update(groups: groups(generation: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 0))))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            content.buttonViews[width == 200 ? "group:test.editor" : "window:window-1"]?.onContextMenu?(event)
            let menu = try XCTUnwrap(context.menu)
            content.update(groups: groups(generation: ProcessGeneration(timeval(tv_sec: 20, tv_usec: 0))))
            menu.performActionForItem(at: 0)
            menu.performActionForItem(at: 1)
            XCTAssertTrue(closed.isEmpty)
            XCTAssertEqual(quits, 0)
        }
    }

    func testWindowMenuQuitsOnlyTheClickedApplicationInstance() throws {
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), contextMenu: context)
        let first = try XCTUnwrap(groups(count: 1).first?.windows.first)
        let otherRecord = WindowRecord(id: WindowID(rawValue: "other"), appID: AppID(rawValue: "editor"), pid: 101,
            bundleIdentifier: "test.editor", title: "Other Editor", bounds: nil, status: .inactive)
        let other = TaskbarWindowPresentation(item: StripItem(record: otherRecord), title: otherRecord.title, isActive: false)
        let group = TaskbarGroupPresentation(id: "test.editor", name: "Editor", windows: [first, other])
        var quitPIDs: [pid_t] = []
        content.actions.quit = { quitPIDs += $0.windows.map(\.item.pid) }
        content.update(groups: [group])
        let button = try XCTUnwrap(content.buttonViews["window:window-0"])
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        button.rightMouseDown(with: mouseEvent(.rightMouseDown, point: point, in: button))
        let menu = try XCTUnwrap(context.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Close window", "Quit"])
        menu.performActionForItem(at: 1)
        XCTAssertEqual(quitPIDs, [first.item.pid])
    }

    func testSeparateContextMenuClosesOneWindowAndThenOffersNormalQuit() {
        let popup = Popup()
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup, contextMenu: context)
        var closed: [String] = []
        var quit = false
        content.actions.close = { closed.append($0.windowID.rawValue) }
        content.actions.quit = { _ in quit = true }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = context.menu
        XCTAssertEqual(menu?.items.map(\.title), ["Close window", "Quit"])
        menu?.performActionForItem(at: 0)
        XCTAssertEqual(closed, ["window-1"])
        XCTAssertFalse(quit)
    }

    func testAStaleContextMenuCannotCloseAnAlreadyRemovedWindow() {
        let popup = Popup()
        let context = ContextMenu()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: popup, contextMenu: context)
        var closed: [String] = []
        content.actions.close = { closed.append($0.windowID.rawValue) }
        content.update(groups: groups())
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        content.buttonViews["window:window-1"]?.onContextMenu?(event)
        let menu = context.menu
        content.update(groups: groups(count: 1))
        menu?.performActionForItem(at: 0)
        XCTAssertTrue(closed.isEmpty)
    }

    func testStatusMenuKeepsHideIconBelowLoginAndQuitLast() {
        let login = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
        let hide = NSMenuItem(title: "Hide Status Bar Icon", action: nil, keyEquivalent: "")
        var quits = 0
        let menu = TaskbarNativeMenuFactory.statusMenu(launchAtLogin: login, hideStatusBarIcon: hide) { quits += 1 }
        XCTAssertTrue(menu.items.first === login)
        XCTAssertTrue(menu.items[1] === hide)
        XCTAssertEqual(menu.items.map(\.title), ["Open at Login", "Hide Status Bar Icon", "", "Quit"])
        XCTAssertEqual(menu.items.last?.title, "Quit")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertNil(menu.items.last?.view)
        menu.performActionForItem(at: menu.numberOfItems - 1)
        XCTAssertEqual(quits, 1)
    }

    func testContextMenuUsesSystemItemsInsteadOfCustomMenuViews() {
        var calls: [String] = []
        let menu = TaskbarNativeMenuFactory.menu(entries: [
            TaskbarMenuEntry(title: "Close window", symbol: "xmark") { calls.append("close") },
            TaskbarMenuEntry(title: "Quit", symbol: "power") { calls.append("quit") }
        ])
        XCTAssertEqual(menu.items.map(\.title), ["Close window", "Quit"])
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
        menu.performActionForItem(at: 1)
        XCTAssertEqual(calls, ["quit"])
    }

    private func mouseEvent(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testBottomScreenPixelRoutesHoverAndClickToTheExactWindowAtBothScales() throws {
        let panel = RecordingPopupPanel(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 64),
                                        styleMask: .borderless, backing: .buffered, defer: true)
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 64))
        panel.contentView = container
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        container.addSubview(content)
        var toggles: [String] = []
        content.actions.toggle = { toggles.append($0.windowID.rawValue) }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["window:window-1"])
        button.reduceMotion = { true }
        for scale: CGFloat in [1, 2] {
            container.bounds.size = CGSize(width: 1600 * panel.backingScaleFactor / scale,
                                           height: 64 * panel.backingScaleFactor / scale)
            content.layoutSubtreeIfNeeded()
            button.updateTrackingAreas()
            let point = CGPoint(x: button.frame.midX, y: 32 - 0.5 / scale)
            let hit = try XCTUnwrap(content.hitTest(content.convert(point, to: container)))
            XCTAssertTrue(hit === button)
            let local = button.convert(point, from: content)
            let area = try XCTUnwrap(button.trackingAreas.first { $0.options.contains(.mouseEnteredAndExited) })
            let trackingRect = area.options.contains(.inVisibleRect) ? button.visibleRect : area.rect
            XCTAssertTrue(trackingRect.contains(local))
            XCTAssertFalse(trackingRect.contains(button.convert(CGPoint(x: button.frame.maxX + 1, y: point.y), from: content)))
            XCTAssertFalse(trackingRect.contains(button.convert(CGPoint(x: point.x, y: 32.25), from: content)))
            XCTAssertTrue(area.options.contains(.activeAlways))
            panel.pointer = content.convert(point, to: nil)
            let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered,
                location: panel.pointer, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            (area.owner as? NSResponder)?.mouseEntered(with: entered)
            XCTAssertGreaterThan(button.selectionView.alphaValue, 0)
            hit.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: content))
            hit.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: content))
            XCTAssertEqual(toggles.last, "window-1")
            XCTAssertEqual(button.selectionView.frame.height, 28)
            XCTAssertEqual(button.convert(button.selectionView.frame, to: content).minY, 2)
            XCTAssertEqual(button.iconView.frame, CGRect(x: 6, y: 6, width: 16, height: 16))
        }
        XCTAssertEqual(toggles, ["window-1", "window-1"])
        XCTAssertFalse(panel.isVisible)
    }

    func testBottomEdgeClickOpensCombinedAndOverflowLists() throws {
        for width: CGFloat in [200, 60] {
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup)
            var toggles = 0
            content.actions.toggle = { _ in toggles += 1 }
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
            let point = CGPoint(x: button.frame.midX, y: 31.75)
            let hit = try XCTUnwrap(content.hitTest(content.convert(point, to: nil)))
            XCTAssertTrue(hit === button)
            hit.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: content))
            hit.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: content))
            XCTAssertEqual((popup.content as? TaskbarWindowListView)?.nativeRows.map(\.item.id), groups()[0].windows.map(\.id))
            XCTAssertEqual(popup.keyRequests, 1)
            XCTAssertEqual(toggles, 0)
        }
    }

    func testOverflowRightClickOpensTheSharedTaskbarMenu() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 60, height: 32), popup: Popup())
        var menus = 0
        content.actions.backgroundMenu = { _, _ in menus += 1 }
        content.update(groups: groups())
        let overflow = try XCTUnwrap(content.overflowButton)
        let point = CGPoint(x: overflow.frame.midX, y: 31.75)
        let hit = try XCTUnwrap(content.hitTest(content.convert(point, to: nil)))
        XCTAssertTrue(hit === overflow)
        hit.rightMouseDown(with: mouseEvent(.rightMouseDown, point: point, in: content))
        XCTAssertEqual(menus, 1)
    }

    func testBottomTargetsPreserveGapsAndCancelMouseUpOutside() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        content.update(groups: groups())
        let first = try XCTUnwrap(content.buttonViews["window:window-0"])
        let second = try XCTUnwrap(content.buttonViews["window:window-1"])
        for point in [CGPoint(x: 5, y: 31.75),
                      CGPoint(x: (first.frame.maxX + second.frame.minX) / 2, y: 31.75),
                      CGPoint(x: 790, y: 31.75), CGPoint(x: first.frame.midX, y: 1)] {
            XCTAssertTrue(content.hitTest(content.convert(point, to: nil)) === content)
        }
        var toggles = 0
        content.actions.toggle = { _ in toggles += 1 }
        let inside = CGPoint(x: first.frame.midX, y: 31.75)
        let outside = CGPoint(x: first.frame.midX, y: 32.25)
        XCTAssertNil(content.hitTest(content.convert(outside, to: nil)))
        first.mouseDown(with: mouseEvent(.leftMouseDown, point: inside, in: content))
        first.mouseUp(with: mouseEvent(.leftMouseUp, point: outside, in: content))
        XCTAssertEqual(toggles, 0)
        first.isHidden = true
        XCTAssertTrue(content.hitTest(content.convert(inside, to: nil)) === content)
    }

    func testFileHoverAtTheBottomEdgeUsesTheSameWindowGroupAndOverflowTargets() async throws {
        let drag = FileDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        for width: CGFloat in [800, 200, 60] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            var activated: [String] = []
            content.actions.activate = { activated.append($0.windowID.rawValue) }
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews[width == 200 ? "group:test.editor" : "window:window-1"])
            drag.draggingLocation = content.convert(CGPoint(x: button.frame.midX, y: 31.75), to: nil)
            XCTAssertEqual(content.draggingEntered(drag), .generic)
            await clock.advance()
            if width == 800 {
                XCTAssertEqual(activated, ["window-1"])
                XCTAssertFalse(popup.isPresented)
            } else {
                XCTAssertTrue(activated.isEmpty)
                XCTAssertEqual((popup.content as? TaskbarWindowListView)?.nativeRows.map(\.item.id), groups()[0].windows.map(\.id))
                XCTAssertEqual(popup.keyRequests, 0)
            }
            XCTAssertFalse(content.performDragOperation(drag))
            drag.draggingLocation = content.convert(CGPoint(x: button.frame.midX, y: 32.25), to: nil)
            XCTAssertEqual(content.draggingUpdated(drag), [])
            content.prepareForHiding()
        }
    }

    func testPendingNativeFileHoverRechecksTheButtonUnderThePointerAfterLayout() async throws {
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup(),
                                         delay: { await clock.sleep($0) })
        let initial = twoGroups()
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: initial)
        let button = try XCTUnwrap(content.buttonViews["window:window-0"])
        let point = CGPoint(x: button.frame.minX + 15, y: button.frame.midY)
        let drag = FileDrag(location: content.convert(point, to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(content.draggingEntered(drag), .generic)

        content.update(groups: Array(initial.reversed()))
        XCTAssertFalse(button.frame.contains(point))
        XCTAssertTrue(try XCTUnwrap(content.buttonViews["window:browser-window"]).frame.contains(point))
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)

        XCTAssertEqual(content.draggingUpdated(drag), .generic)
        await clock.advance()
        XCTAssertEqual(activated, ["browser-window"])
    }

    func testNativeTerminalDragCancelsPendingTaskbarFileHover() async throws {
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup(),
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["window:window-0"])
        let drag = FileDrag(location: content.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(content.draggingEntered(drag), .generic)
        await Task.yield()
        sendTerminalDrag(drag, to: content)
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)
    }

    func testNativeTerminalDragCancelsPendingListRowFileHover() async throws {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        try XCTUnwrap(content.buttonViews["group:test.editor"]).clickForTesting()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        let drag = FileDrag(location: row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(row.draggingEntered(drag), .generic)
        XCTAssertTrue(list.isPointerInside)
        await Task.yield()
        sendTerminalDrag(drag, to: row)
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)
        XCTAssertFalse(list.isPointerInside)
    }

    func testPendingNativeListFileHoverRechecksTheRowUnderThePointerAfterScrolling() async throws {
        let clock = Clock()
        var hovered: [String] = []
        let list = TaskbarWindowListView(windows: groups(count: 5)[0].windows, availableHeight: 80,
                                        delay: { await clock.sleep($0) }, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { hovered.append($0.id) })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        let first = try XCTUnwrap(list.nativeRow(at: 0))
        let drag = FileDrag(location: first.convert(CGPoint(x: 60, y: 30), to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(first.draggingEntered(drag), .generic)

        let clip = list.scrollView.contentView
        clip.scroll(to: CGPoint(x: 0, y: 20))
        list.scrollView.reflectScrolledClipView(clip)
        list.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.visibleRect.isEmpty)
        XCTAssertEqual(list.tableView.row(at: list.tableView.convert(drag.draggingLocation, from: nil)), 1)
        await clock.advance()
        XCTAssertTrue(hovered.isEmpty)
        XCTAssertFalse(list.isPointerInside)
    }

    func testNativeFileDragGapUsesOneDismissalGraceForTheOpenList() async throws {
        for width: CGFloat in [60, 200] {
            let clock = Clock()
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
            let drag = FileDrag(location: content.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
            defer { drag.draggingPasteboard.releaseGlobally() }
            XCTAssertEqual(content.draggingEntered(drag), .generic)
            await clock.advance()
            XCTAssertTrue(popup.isPresented)

            drag.draggingLocation = content.convert(CGPoint(x: 4, y: 16), to: nil)
            for _ in 0..<3 {
                XCTAssertEqual(content.draggingUpdated(drag), [])
                XCTAssertTrue(popup.isPresented)
                await Task.yield()
            }
            await clock.advance(allowIdle: true)
            XCTAssertEqual(clock.requestedDelays, [.milliseconds(600), .milliseconds(250)])
            XCTAssertFalse(popup.isPresented)
        }
    }

    func testNativeFileDragBetweenButtonsRetiresOnlyThePreviousList() async throws {
        for width: CGFloat in [150, 200] {
            let clock = Clock()
            let popup = Popup()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            let input = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
            content.update(groups: input)
            let a = try XCTUnwrap(width == 150 ? content.overflowButton : content.buttonViews["group:test.narrow"])
            let b = try XCTUnwrap(content.buttonViews[width == 150 ? "group:test.narrow" : "group:test.wide"])
            func location(_ button: TaskbarButtonView) -> CGPoint {
                content.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
            }
            let drag = FileDrag(location: location(a))
            defer { drag.draggingPasteboard.releaseGlobally() }
            XCTAssertEqual(content.draggingEntered(drag), .generic)
            await clock.advance(.milliseconds(600))
            let original = try XCTUnwrap(popup.content as? TaskbarWindowListView)

            drag.draggingLocation = content.convert(CGPoint(x: 4, y: 16), to: nil)
            XCTAssertEqual(content.draggingUpdated(drag), [])
            drag.draggingLocation = location(a)
            XCTAssertEqual(content.draggingUpdated(drag), .generic)
            await clock.advance(.milliseconds(250), allowIdle: true)
            XCTAssertTrue(popup.content === original)

            drag.draggingLocation = location(b)
            XCTAssertEqual(content.draggingUpdated(drag), .generic)
            await clock.advance(.milliseconds(250), allowIdle: true)
            XCTAssertFalse(popup.isPresented)
            await clock.advance(.milliseconds(600))
            let replacement = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            XCTAssertEqual(replacement.nativeRows.map(\.item.id), width == 150 ? ["narrow-0", "narrow-1"] : ["wide-0", "wide-1"])
        }
    }

    func testLatePopupExitRetiresOnlyTheListAndRespectsTheHoveredAnchor() async throws {
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        for returnsToAnchor in [true, false] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            let input = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
            content.update(groups: input)
            let a = try XCTUnwrap(content.buttonViews["group:test.narrow"])
            let button = try XCTUnwrap(content.buttonViews[returnsToAnchor ? "group:test.narrow" : "group:test.wide"])
            a.onHover?(true)
            await clock.advance(.milliseconds(400))
            let original = try XCTUnwrap(popup.content as? TaskbarWindowListView)

            a.onHover?(false)
            original.mouseEntered(with: enter)
            button.onHover?(true)
            original.mouseExited(with: exit)
            await clock.advance(.milliseconds(250), allowIdle: true)
            if returnsToAnchor { XCTAssertTrue(popup.content === original) }
            else { XCTAssertFalse(popup.isPresented) }
            await clock.advance(.milliseconds(400))
            if returnsToAnchor { XCTAssertTrue(popup.content === original) }
            else {
                let replacement = popup.content as? TaskbarWindowListView
                XCTAssertEqual(replacement?.nativeRows.map(\.item.id), ["wide-0", "wide-1"])
            }

            button.onHover?(false)
            await clock.advance(.milliseconds(250), allowIdle: true)
            XCTAssertFalse(popup.isPresented)
        }
    }

    func testTerminalNativeFileDragDismissesOnlyTransientLists() async throws {
        for width: CGFloat in [60, 200] {
            for useDrop in [false, true] {
                let clock = Clock()
                let popup = Popup()
                let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                                 delay: { await clock.sleep($0) })
                content.update(groups: groups())
                let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
                let drag = FileDrag(location: content.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
                defer { drag.draggingPasteboard.releaseGlobally() }
                XCTAssertEqual(content.draggingEntered(drag), .generic)
                await clock.advance()
                XCTAssertTrue(popup.isPresented)

                if useDrop { XCTAssertFalse(content.performDragOperation(drag)) }
                else { sendTerminalDrag(drag, to: content) }
                XCTAssertTrue(popup.isPresented)
                await clock.advance(allowIdle: true)
                XCTAssertFalse(popup.isPresented)

                button.clickForTesting()
                let clickedList = try XCTUnwrap(popup.content)
                XCTAssertEqual(content.draggingEntered(drag), .generic)
                if useDrop { XCTAssertFalse(content.performDragOperation(drag)) }
                else { sendTerminalDrag(drag, to: content) }
                await clock.advance(allowIdle: true)
                XCTAssertTrue(popup.content === clickedList)
            }
        }
    }

    func testRebindingAFileDragRowEndsItsOldPresenceAndAcceptsANewDrag() async throws {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let windows = groups()[0].windows
        content.update(groups: groups())
        try XCTUnwrap(content.buttonViews["group:test.editor"]).clickForTesting()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        let point = row.convert(CGPoint(x: 60, y: 20), to: nil)
        let old = FileDrag(location: point, sequence: 1)
        let current = FileDrag(location: point, sequence: 2)
        defer { old.draggingPasteboard.releaseGlobally(); current.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(row.draggingEntered(old), .generic)
        XCTAssertTrue(list.isPointerInside)

        var activated: [String] = []
        row.configure(window: windows[1], icon: nil, close: {}, fileHover: { activated.append(windows[1].id) })
        XCTAssertFalse(list.isPointerInside)
        XCTAssertEqual(row.draggingEntered(current), .generic)
        XCTAssertTrue(list.isPointerInside)
        sendTerminalDrag(old, to: row)
        XCTAssertTrue(list.isPointerInside)
        await clock.advance()
        XCTAssertEqual(activated, ["window-1"])
        sendTerminalDrag(current, to: row)
        XCTAssertFalse(list.isPointerInside)
    }

    func testRemovingAFileDragRowClearsItsPresence() async throws {
        let clock = Clock()
        let windows = groups()[0].windows
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80,
                                        delay: { await clock.sleep($0) }, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { activated.append($0.id) })
        let row = try XCTUnwrap(list.nativeRow(at: 0))
        let rowView = try XCTUnwrap(list.tableView.rowView(atRow: 0, makeIfNecessary: false))
        let drag = FileDrag(location: row.convert(CGPoint(x: 60, y: 20), to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(row.draggingEntered(drag), .generic)
        XCTAssertTrue(list.isPointerInside)

        list.tableView(list.tableView, didRemove: rowView, forRow: 0)
        XCTAssertFalse(list.isPointerInside)
        await clock.advance()
        XCTAssertTrue(activated.isEmpty)
    }

    func testOldRowExitAndFileDragEndPreserveCurrentPointerPresence() async throws {
        let clock = Clock()
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        var activated: [String] = []
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        let drag = FileDrag(location: content.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil))
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(content.draggingEntered(drag), .generic)
        await clock.advance()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let first = try XCTUnwrap(list.nativeRow(at: 0))
        let second = try XCTUnwrap(list.nativeRow(at: 1))
        content.draggingExited(drag)
        drag.draggingLocation = first.convert(CGPoint(x: 60, y: 20), to: nil)
        XCTAssertEqual(first.draggingEntered(drag), .generic)
        drag.draggingLocation = second.convert(CGPoint(x: 60, y: 20), to: nil)
        XCTAssertEqual(second.draggingEntered(drag), .generic)
        await clock.advance(.milliseconds(600))
        XCTAssertEqual(activated, ["window-1"])
        first.draggingExited(drag)
        XCTAssertTrue(list.isPointerInside)
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertTrue(popup.content === list)

        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        list.mouseEntered(with: enter)
        list.mouseExited(with: exit)
        XCTAssertTrue(list.isPointerInside)
        list.mouseEntered(with: enter)
        sendTerminalDrag(drag, to: second)
        XCTAssertTrue(list.isPointerInside)
        await clock.advance(allowIdle: true)
        XCTAssertTrue(popup.content === list)
        list.mouseExited(with: exit)
        await clock.advance()
        XCTAssertFalse(popup.isPresented)
    }

    func testDraggingOutsideCannotLiftAnyGroupButtonOutOfTheBarOrActivateAWindow() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var toggles = 0
        var moves = 0
        content.actions.toggle = { _ in toggles += 1 }
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.update(groups: groups())
        let button = content.buttonViews["window:window-0"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        for point in [CGPoint(x: -500, y: -400), CGPoint(x: 3000, y: 700)] {
            button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: point, in: content))
            for view in content.buttonViews.values {
                XCTAssertEqual(view.frame.minY, 2)
                XCTAssertEqual(view.frame.maxY, content.bounds.maxY)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.selectionView.frame.height, 28)
                XCTAssertGreaterThanOrEqual(view.frame.minX, 0)
                XCTAssertLessThanOrEqual(view.frame.maxX, content.bounds.width)
            }
        }
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: 3000, y: -400), in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(content.buttonViews["window:window-0"]?.frame.minX, 10)
    }

    func testDraggingInsideTheSameSlotMovesOnlyTheDraggedFramesWithoutReloadingIcons() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var iconRequests: [String] = []
        content.iconProvider = { iconRequests.append($0.id); return nil }
        content.update(groups: twoGroups())
        let button = try XCTUnwrap(content.buttonViews["window:window-0"])
        let neighbor = try XCTUnwrap(content.buttonViews["window:browser-window"])
        let start = CGPoint(x: button.frame.midX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: CGPoint(x: start.x + 10, y: 16), in: content))
        let layout = content.layoutResult
        let firstFrame = button.frame
        let neighborFrame = neighbor.frame
        iconRequests.removeAll()
        for offset in 11...30 {
            button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: CGPoint(x: start.x + CGFloat(offset), y: 16), in: content))
        }
        XCTAssertTrue(iconRequests.isEmpty, "Pointer-only movement must not reload button content")
        XCTAssertEqual(content.layoutResult, layout)
        XCTAssertEqual(button.frame.minX, firstFrame.minX + 20, accuracy: 0.001)
        XCTAssertEqual(button.frame.minY, 2)
        XCTAssertEqual(button.frame.maxY, 32)
        XCTAssertEqual(neighbor.frame, neighborFrame)
        button.cancelPendingPress()
        content.layoutSubtreeIfNeeded()
    }

    private func twoGroups() -> [TaskbarGroupPresentation] {
        let editor = groups(count: 2)[0]
        let record = WindowRecord(id: WindowID(rawValue: "browser-window"), appID: AppID(rawValue: "browser"), pid: 200,
                                  bundleIdentifier: "test.browser", title: "Browser window", bounds: .zero, status: .inactive,
                                  cgWindowID: 20, groupID: "browser-window", displayUUID: "left")
        let browser = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
        return [editor, TaskbarGroupPresentation(id: "test.browser", name: "Browser", windows: [browser])]
    }

    private func unequalGroups(shortFirst: Bool, shortTitles: [String] = ["Windows"]) -> [TaskbarGroupPresentation] {
        let specifications: [(String, [String])] = [
            ("narrow", shortTitles),
            ("wide", ["Release DeskMote 0.2.1", "New Tab — Google Chrome"])
        ]
        let result = specifications.enumerated().map { groupIndex, specification in
            let windows = specification.1.enumerated().map { index, title in
                let id = "\(specification.0)-\(index)"
                let record = WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: specification.0),
                                          pid: Int32(300 + groupIndex), bundleIdentifier: "test.\(specification.0)",
                                          title: title, bounds: .zero, status: .inactive,
                                          cgWindowID: UInt32(30 + groupIndex * 10 + index), groupID: id, displayUUID: "left")
                return TaskbarWindowPresentation(item: StripItem(record: record), title: title, isActive: false)
            }
            return TaskbarGroupPresentation(id: "test.\(specification.0)", name: specification.0, windows: windows)
        }
        return shortFirst ? result : result.reversed()
    }

    func testWideGroupSwapsWithANarrowNeighborFromEveryGrabPosition() throws {
        for shortFirst in [true, false] {
            for fraction in [CGFloat(0.02), 0.45, 0.98] {
                let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
                var moves: [String] = []
                var toggles = 0
                content.actions.reorder = { source, target, after in moves.append("\(source):\(target):\(after)") }
                content.actions.toggle = { _ in toggles += 1 }
                content.update(groups: unequalGroups(shortFirst: shortFirst))
                let original = content.layoutResult.buttons
                let wide = original.filter { $0.groupID == "test.wide" }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                let occupied = original.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                let offset = wide.width * fraction
                let start = CGPoint(x: wide.minX + offset, y: 16)
                let destinationX = shortFirst ? occupied.minX : occupied.maxX - wide.width
                let destination = CGPoint(x: destinationX + offset, y: 16)
                let button = try XCTUnwrap(content.buttonViews.values.first { $0.frame.contains(start) })
                button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
                let expected = shortFirst ? ["wide-0", "wide-1", "narrow-0"] : ["narrow-0", "wide-0", "wide-1"]
                for _ in 0..<5 {
                    button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
                    XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), expected,
                                   "shortFirst=\(shortFirst), grabFraction=\(fraction)")
                }
                button.mouseUp(with: mouseEvent(.leftMouseUp, point: destination, in: content))
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(moves, ["test.wide:test.narrow:\(!shortFirst)"])
                XCTAssertEqual(toggles, 0)
                XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), expected)
            }
        }
    }

    func testDraggingAWideGroupAwayAndBackDoesNotPersistOrToggleAnything() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves = 0
        var toggles = 0
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.actions.toggle = { _ in toggles += 1 }
        content.update(groups: unequalGroups(shortFirst: true))
        let original = content.layoutResult
        let button = try XCTUnwrap(content.buttonViews["window:wide-1"])
        let wide = original.buttons.filter { $0.groupID == "test.wide" }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let start = CGPoint(x: button.frame.midX, y: 16)
        let moved = CGPoint(x: 10 + start.x - wide.minX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: moved, in: content))
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["wide-0", "wide-1", "narrow-0"])
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: start, in: content))
        XCTAssertEqual(content.layoutResult, original)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: start, in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(content.layoutResult, original)
    }

    func testDraggingAcrossAnotherApplicationCommitsTheWholeGroupInMemberOrder() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves: [String] = []
        var toggles = 0
        content.actions.reorder = { source, target, after in moves.append("\(source):\(target):\(after)") }
        content.actions.toggle = { _ in toggles += 1 }
        content.update(groups: twoGroups())
        let button = content.buttonViews["window:window-0"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        let destination = CGPoint(x: content.buttonViews["window:browser-window"]!.frame.maxX - 4, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["browser-window", "window-0", "window-1"])
        XCTAssertEqual(content.buttonViews["window:window-1"]!.frame.minX - button.frame.maxX, 2)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: destination, in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(moves, ["test.editor:test.browser:true"])
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["browser-window", "window-0", "window-1"])
    }

    func testDraggingACombinedGroupCommitsWhenThePreviewChangesCollapsePriority() throws {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 260, height: 32), popup: Popup())
        var moves: [String] = []
        content.actions.reorder = { source, target, after in moves.append("\(source):\(target):\(after)") }
        content.update(groups: unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"]))
        XCTAssertEqual(content.layoutResult.buttons.map(\.id), ["group:test.narrow", "window:wide-0", "window:wide-1"])

        let button = try XCTUnwrap(content.buttonViews["group:test.narrow"])
        let lastButton = try XCTUnwrap(content.buttonViews["window:wide-1"])
        let start = CGPoint(x: button.frame.midX, y: 16)
        let destination = CGPoint(x: lastButton.frame.maxX - 4, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
        XCTAssertEqual(content.layoutResult.buttons.map(\.id), ["window:wide-0", "window:wide-1", "group:test.narrow"])

        button.mouseUp(with: mouseEvent(.leftMouseUp, point: destination, in: content))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(moves, ["test.narrow:test.wide:true"])
        XCTAssertEqual(content.layoutResult.buttons.map(\.id), ["group:test.wide", "window:narrow-0", "window:narrow-1"])
    }

    func testCancellingAReorderedGroupRestoresTheOriginalOrderWithoutPersisting() {
        for panelHides in [false, true] {
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
            var moves = 0
            var toggles = 0
            content.actions.reorder = { _, _, _ in moves += 1 }
            content.actions.toggle = { _ in toggles += 1 }
            content.update(groups: twoGroups())
            let button = content.buttonViews["window:window-0"]!
            let start = CGPoint(x: button.frame.midX, y: 16)
            let destination = CGPoint(x: content.buttonViews["window:browser-window"]!.frame.maxX - 4, y: 16)
            button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
            button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: destination, in: content))
            if panelHides { content.prepareForHiding() }
            button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: destination.x, y: -400), in: content))
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(moves, 0)
            XCTAssertEqual(toggles, 0)
            XCTAssertEqual(content.layoutResult.buttons.flatMap(\.windowIDs), ["window-0", "window-1", "browser-window"])
        }
    }

    func testShrinkingTheBarDuringADragCancelsAHiddenSourceSafely() {
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 800, height: 32), popup: Popup())
        var moves = 0
        content.actions.reorder = { _, _, _ in moves += 1 }
        content.update(groups: twoGroups())
        let button = content.buttonViews["window:browser-window"]!
        let start = CGPoint(x: button.frame.midX, y: 16)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: start, in: content))
        button.mouseDragged(with: mouseEvent(.leftMouseDragged, point: CGPoint(x: start.x + 10, y: 16), in: content))
        content.frame.size.width = 100
        content.update(groups: twoGroups())
        XCTAssertNil(content.buttonViews["window:browser-window"])
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: CGPoint(x: 30, y: 16), in: content))
        content.frame.size.width = 800
        content.update(groups: twoGroups())
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(content.buttonViews["window:browser-window"]?.layer?.zPosition, 0)
        XCTAssertTrue(content.buttonViews.values.allSatisfy { $0.frame.minX.isFinite && $0.frame.width.isFinite })
    }

    func testNativeButtonsPreserveGeometryInEveryInteractionState() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 64),
                            styleMask: .borderless, backing: .buffered, defer: true)
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 64))
        panel.contentView = container
        for title in [".", "Windows", "A very long window title that must truncate"] {
            let width = TaskbarMetrics.buttonWidth(textWidth: (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
            let button = TaskbarButtonView(frame: CGRect(x: 10, y: 2, width: width, height: 28))
            container.addSubview(button)
            defer { button.removeFromSuperview() }
            button.title = title
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            let native: NSButton = button
            XCTAssertFalse(native.isBordered)
            XCTAssertTrue(native.isTransparent)
            XCTAssertEqual(native.tintProminence, .none)
            XCTAssertEqual(button.selectionView.fillColor, .unemphasizedSelectedContentBackgroundColor)
            XCTAssertEqual(button.selectionView.cornerRadius, 4)
            button.reduceMotion = { true }
            XCTAssertEqual(native.title, title)
            for scale: CGFloat in [1, 2] {
                container.bounds.size = CGSize(width: 400 * panel.backingScaleFactor / scale,
                                               height: 64 * panel.backingScaleFactor / scale)
                for active in [false, true, false] {
                    button.isActiveWindow = active
                    button.needsLayout = true
                    button.layoutSubtreeIfNeeded()
                    XCTAssertEqual(native.state, active ? .on : .off)
                    XCTAssertEqual(native.frame, CGRect(x: 10, y: 2, width: width, height: 28))
                    XCTAssertEqual(button.iconView.frame, CGRect(x: 6, y: 6, width: 16, height: 16))
                    let textRect = button.titleLabel.alignmentRect(forFrame: button.titleLabel.frame)
                    XCTAssertEqual(textRect.minX, 28)
                    XCTAssertEqual(textRect.maxX, width - 8)
                    XCTAssertEqual(textRect.midY, scale == 1 ? 14.5 : 14, accuracy: 0.000_001)
                    XCTAssertEqual(button.selectionView.frame, button.bounds)
                    XCTAssertEqual(button.indicator.frame, CGRect(x: active ? 8.5 : 12,
                                                                 y: 25, width: active ? 11 : 4, height: 2))
                }
            }
        }
    }

    func testPointerPressDoesNotInventAnActiveWindow() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        var calls = 0
        button.onClick = { calls += 1 }
        let point = CGPoint(x: 50, y: 14)
        button.mouseDown(with: mouseEvent(.leftMouseDown, point: point, in: button))
        XCTAssertTrue(button.isHighlighted)
        XCTAssertEqual(calls, 0)
        button.mouseUp(with: mouseEvent(.leftMouseUp, point: point, in: button))
        XCTAssertFalse(button.isHighlighted)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(button.state, .off)
        button.clickForTesting()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(button.state, .off)
        button.isActiveWindow = true
        button.clickForTesting()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(button.state, .on)
        button.isEnabled = false
        button.clickForTesting()
        XCTAssertEqual(calls, 3)
    }

    func testHoverKeepsNeutralFeedbackAndPopupNotifications() async {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        var hovering: [Bool] = []
        button.onHover = { hovering.append($0) }
        for type: NSEvent.EventType in [.mouseEntered, .mouseExited] {
            let event = NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            if type == .mouseEntered { button.mouseEntered(with: event) }
            else { button.mouseExited(with: event) }
        }
        XCTAssertEqual(hovering, [true, false])
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        button.isActiveWindow = true
        let deadline = ContinuousClock.now + .seconds(1)
        while abs(button.selectionView.alphaValue - 0.65) > 0.001, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(button.selectionView.alphaValue, 0.65, accuracy: 0.001)
        XCTAssertEqual(button.selectionView.fillColor, .unemphasizedSelectedContentBackgroundColor)
    }

    func testWindowsReferenceDistinguishesHoverActiveAndHeldPress() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
            button.appearance = NSAppearance(named: appearance)
            button.reduceMotion = { true }
            var clicks = 0
            button.onClick = { clicks += 1 }
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            button.mouseEntered(with: enter)
            let hoverFill = button.selectionView.alphaValue
            let hoverBorder = button.selectionView.borderColor.alphaComponent
            XCTAssertGreaterThan(hoverFill, 0)
            XCTAssertEqual(button.selectionView.borderWidth, 1)
            XCTAssertEqual(button.indicator.frame.width, 4)
            button.mouseExited(with: exit)
            XCTAssertEqual(button.selectionView.alphaValue, 0)
            button.isActiveWindow = true
            let activeFill = button.selectionView.alphaValue
            let activeBorder = button.selectionView.borderColor.alphaComponent
            XCTAssertEqual(hoverFill, activeFill)
            XCTAssertGreaterThan(activeBorder, hoverBorder)
            XCTAssertEqual(button.indicator.frame.width, 11)
            button.mouseEntered(with: enter)
            let activeHoverFill = button.selectionView.alphaValue
            XCTAssertGreaterThan(activeHoverFill, activeFill)
            XCTAssertLessThan(button.selectionView.borderColor.alphaComponent, activeBorder)
            button.mouseDown(with: mouseEvent(.leftMouseDown, point: CGPoint(x: 50, y: 14), in: button))
            XCTAssertLessThan(button.selectionView.alphaValue, activeFill)
            XCTAssertEqual(button.selectionView.borderColor.alphaComponent, 0)
            XCTAssertEqual(clicks, 0)
            button.cancelPendingPress()
            XCTAssertEqual(button.selectionView.alphaValue, activeHoverFill)
            XCTAssertEqual(clicks, 0)
            button.isActiveWindow = false
            XCTAssertEqual(button.selectionView.alphaValue, hoverFill)
            XCTAssertEqual(button.selectionView.borderColor.alphaComponent, hoverBorder)
            button.mouseExited(with: exit)
            XCTAssertEqual(button.selectionView.alphaValue, 0)
        }
    }

    func testActiveUnderlineMatchesTheSettledWindowsReferenceAtBothBackingScales() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 56),
                            styleMask: .borderless, backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        panel.contentView = content
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        content.addSubview(button)
        for scale: CGFloat in [1, 2, 1] {
            content.bounds.size = CGSize(width: 280 * panel.backingScaleFactor / scale,
                                         height: 56 * panel.backingScaleFactor / scale)
            for active in [false, true] {
                button.isActiveWindow = active
                button.needsLayout = true
                button.layoutSubtreeIfNeeded()
                let frame = button.indicator.frame
                XCTAssertEqual(frame.width, active ? 11 : 4)
                XCTAssertEqual(frame.height, 2)
                XCTAssertEqual(button.bounds.maxY - frame.maxY, 1)
                XCTAssertEqual(frame.midX, button.iconView.frame.midX, accuracy: 0.000_001)
                let backing = button.convertToBacking(frame)
                XCTAssertEqual(backing.width, (active ? 11 : 4) * scale)
                XCTAssertEqual(backing.height, 2 * scale)
                XCTAssertEqual(backing.midX, button.convertToBacking(button.iconView.frame).midX, accuracy: 0.000_001)
                XCTAssertEqual(backing.minY, backing.minY.rounded())
            }
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testNeutralHighlightAndWindowsIndicatorsRespectReduceMotion() {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 4, height: 2))
        button.isActiveWindow = true
        XCTAssertGreaterThan(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 11, height: 2))
        XCTAssertEqual(button.indicator.fillColor, .controlAccentColor)
        XCTAssertTrue(button.selectionView.layer?.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(button.indicator.layer?.animationKeys()?.isEmpty ?? true)
        button.isActiveWindow = false
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        XCTAssertEqual(button.indicator.fillColor, .secondaryLabelColor)
        XCTAssertEqual(button.indicator.frame.size, CGSize(width: 4, height: 2))
    }

    private func animatedIndicator(appearance: NSAppearance.Name) throws -> (NSPanel, TaskbarButtonView) {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 56),
                            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        panel.contentView = content
        let button = TaskbarButtonView(frame: CGRect(x: 10, y: 2, width: 140, height: 28))
        button.appearance = NSAppearance(named: appearance)
        button.reduceMotion = { false }
        content.addSubview(button)
        button.layoutSubtreeIfNeeded()
        panel.display()
        CATransaction.flush()
        return (panel, button)
    }

    private func indicatorPixels(_ button: TaskbarButtonView, scale: CGFloat) throws -> (frame: CGRect, color: NSColor) {
        CATransaction.flush()
        let presentation = try XCTUnwrap(button.indicator.layer?.presentation())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(40 * scale),
                                                   pixelsHigh: Int(4 * scale), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: presentation.frame.minX, y: 1)
        presentation.render(in: context.cgContext)
        let columns = (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
        }
        let first = try XCTUnwrap(columns.first)
        let last = try XCTUnwrap(columns.last)
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(14 * scale), y: Int(2 * scale))?.usingColorSpace(.sRGB))
        return (CGRect(x: CGFloat(first) / scale, y: 1, width: CGFloat(last - first + 1) / scale, height: 2), color)
    }

    private func indicatorTransition(_ button: TaskbarButtonView, active: Bool, scale: CGFloat) async throws -> [(frame: CGRect, color: NSColor)] {
        let targetWidth: CGFloat = active ? 11 : 4
        let targetColor: NSColor = active ? .controlAccentColor : .secondaryLabelColor
        button.isActiveWindow = active
        var samples: [(frame: CGRect, color: NSColor)] = []
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            button.needsLayout = true
            button.layoutSubtreeIfNeeded()
            samples.append(try indicatorPixels(button, scale: scale))
            if button.indicator.frame.width == targetWidth && button.indicator.fillColor == targetColor { break }
            try await Task.sleep(for: .milliseconds(3))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(button.indicator.frame.width, targetWidth)
        XCTAssertEqual(button.indicator.fillColor, targetColor)
        return samples
    }

    func testRenderedIndicatorExpandsAndContractsAroundTheIconWithoutSliding() async throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for scale: CGFloat in [1, 2] {
                let (panel, button) = try animatedIndicator(appearance: appearance)
                defer { panel.close() }
                for active in [true, false] {
                    let startWidth: CGFloat = active ? 4 : 11
                    let endWidth: CGFloat = active ? 11 : 4
                    let start = try indicatorPixels(button, scale: scale)
                    XCTAssertEqual(start.frame.width, startWidth, accuracy: 1 / scale)
                    let samples = try await indicatorTransition(button, active: active, scale: scale)
                    let widths = samples.map(\.frame.width)
                    for sample in samples {
                        XCTAssertEqual(sample.frame.midX, 14, accuracy: 0.5 / scale,
                                       "Rendered center at active=\(active), scale=\(scale)")
                        XCTAssertGreaterThanOrEqual(sample.frame.minX, 8.5 - 0.5 / scale)
                        XCTAssertLessThanOrEqual(sample.frame.maxX, 19.5 + 0.5 / scale)
                    }
                    XCTAssertEqual(try XCTUnwrap(widths.first), startWidth, accuracy: 1 / scale)
                    XCTAssertEqual(try XCTUnwrap(widths.last), endWidth, accuracy: 1 / scale)
                    XCTAssertTrue(widths.contains { $0 > 4 + 0.5 / scale && $0 < 11 - 0.5 / scale })
                    for (previous, next) in zip(widths, widths.dropFirst()) {
                        if active { XCTAssertGreaterThanOrEqual(next, previous) }
                        else { XCTAssertLessThanOrEqual(next, previous) }
                    }
                }
                XCTAssertFalse(panel.isVisible)
            }
        }
    }

    func testRenderedIndicatorChangesColorDuringTheCenteredExpansion() async throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let (panel, button) = try animatedIndicator(appearance: appearance)
            defer { panel.close() }
            let gray = try indicatorPixels(button, scale: 2).color
            let samples = try await indicatorTransition(button, active: true, scale: 2)
            let initial = try XCTUnwrap(samples.first).color
            let blue = try XCTUnwrap(samples.last).color
            func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
            }
            XCTAssertLessThan(distance(initial, gray), 0.05)
            XCTAssertTrue(samples.contains { distance($0.color, gray) > 0.05 && distance($0.color, blue) > 0.05 })
            XCTAssertGreaterThan(distance(blue, gray), 0.1)
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testRenderedIndicatorRetargetsFromItsCurrentSizeWithoutAJump() async throws {
        let (panel, button) = try animatedIndicator(appearance: .darkAqua)
        defer { panel.close() }
        button.isActiveWindow = true
        let deadline = ContinuousClock.now + .seconds(1)
        while button.indicator.frame.width <= 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(3))
        }
        let before = try indicatorPixels(button, scale: 2)
        XCTAssertGreaterThan(button.indicator.frame.width, 4)
        XCTAssertLessThan(button.indicator.frame.width, 11)
        let samples = try await indicatorTransition(button, active: false, scale: 2)
        XCTAssertEqual(try XCTUnwrap(samples.first).frame.width, before.frame.width, accuracy: 0.5)
        for sample in samples {
            XCTAssertEqual(sample.frame.midX, 14, accuracy: 0.25)
            XCTAssertLessThanOrEqual(sample.frame.width, before.frame.width + 0.5)
        }
        XCTAssertEqual(try XCTUnwrap(samples.last).frame.width, 4, accuracy: 0.5)
        XCTAssertFalse(panel.isVisible)
    }

    func testReduceMotionCancelsAnInFlightIndicatorTransition() async throws {
        let (panel, button) = try animatedIndicator(appearance: .aqua)
        defer { panel.close() }
        button.isActiveWindow = true
        let deadline = ContinuousClock.now + .seconds(1)
        while button.indicator.frame.width <= 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(3))
        }
        button.reduceMotion = { true }
        button.isActiveWindow = false
        for _ in 0..<5 {
            let pixels = try indicatorPixels(button, scale: 2)
            XCTAssertEqual(pixels.frame.midX, 14, accuracy: 0.25)
            XCTAssertEqual(pixels.frame.width, 4, accuracy: 0.5)
            XCTAssertEqual(button.indicator.fillColor, .secondaryLabelColor)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testOverflowUsesANativeSymbolButtonAtTheExistingSize() throws {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 2, width: 32, height: 28))
        button.isOverflow = true
        button.title = "More windows"
        button.layoutSubtreeIfNeeded()
        XCTAssertNotNil(button.iconView.image)
        XCTAssertTrue(button.titleLabel.isHidden)
        XCTAssertTrue(button.indicator.isHidden)
        XCTAssertEqual(button.iconView.frame, CGRect(x: 8, y: 6, width: 16, height: 16))
        XCTAssertEqual(button.title, "More windows")
        XCTAssertNil(button.toolTip)
    }

    func testWindowListUsesGlassAndNativeRowsWithTheWindowsGeometry() throws {
        let windows = groups()[0].windows
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { _ in })
        XCTAssertEqual(list.style, .regular)
        XCTAssertNil(list.tintColor)
        XCTAssertTrue(list.contentView === list.scrollView)
        XCTAssertFalse(list.scrollView.drawsBackground)
        XCTAssertFalse(list.scrollView.contentView.drawsBackground)
        XCTAssertEqual(list.tableView.backgroundColor, .clear)
        XCTAssertEqual(list.frame.size, CGSize(width: 216, height: 80))
        XCTAssertEqual(list.tableView.numberOfRows, 3)
        XCTAssertEqual(list.tableView.rowHeight, 40)
        XCTAssertEqual(list.tableView.intercellSpacing, .zero)
        for index in windows.indices {
            XCTAssertEqual(list.tableView.rect(ofRow: index), CGRect(x: 0, y: CGFloat(index) * 40, width: 216, height: 40))
            let row = try XCTUnwrap(list.nativeRow(at: index))
            let cell: NSTableCellView = row
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.imageView?.frame, CGRect(x: 8, y: 12, width: 16, height: 16))
            let label = try XCTUnwrap(cell.textField)
            XCTAssertEqual(label.alignmentRect(forFrame: label.frame), CGRect(x: 32, y: 12, width: 148, height: 20))
            XCTAssertEqual(row.closeButton.frame, CGRect(x: 180, y: 4, width: 32, height: 32))
            XCTAssertEqual(cell.textField?.stringValue, windows[index].title)
        }
        list.tableView.scrollRowToVisible(2)
        XCTAssertGreaterThan(list.scrollView.contentView.bounds.minY, 0)
    }

    func testLongWindowListLoadsIconsOnlyNearTheViewportAndRoutesScrolledActions() throws {
        let windows = groups(count: 200)[0].windows
        var iconRequests: [String] = []
        var activated: [String] = []
        var closed: [String] = []
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80,
                                        icon: { iconRequests.append($0.id); return nil },
                                        activate: { activated.append($0.id) }, close: { closed.append($0.id) }, fileHover: { _ in })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        XCTAssertEqual(list.tableView.numberOfRows, 200)
        XCTAssertLessThan(iconRequests.count, 20, "A two-row viewport must not resolve icons for the whole list")
        XCTAssertFalse(iconRequests.contains("window-199"))
        var updated = windows
        updated[199] = TaskbarWindowPresentation(item: windows[199].item, title: "Updated offscreen title", isActive: false)
        list.updateTitles(windows: updated)
        list.tableView.scrollRowToVisible(199)
        list.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(list.tableView.view(atColumn: 0, row: 199, makeIfNecessary: true) as? TaskbarWindowListRow)
        XCTAssertEqual(row.textField?.stringValue, "Updated offscreen title")
        try list.clickRowForTesting(at: 199)
        row.closeButton.performClick(nil)
        XCTAssertEqual(activated, ["window-199"])
        XCTAssertEqual(closed, ["window-199"])
        XCTAssertFalse(panel.isVisible)
    }

    func testRefreshingListIconsPreservesSelectionAndOnlyTouchesAvailableRows() throws {
        let windows = groups(count: 200)[0].windows
        var image = NSImage(size: NSSize(width: 32, height: 32))
        var requested: [String] = []
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80,
            icon: { requested.append($0.id); return image }, activate: { _ in }, close: { _ in }, fileHover: { _ in })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        let row = try XCTUnwrap(list.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TaskbarWindowListRow)
        list.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        requested.removeAll()
        image = NSImage(size: NSSize(width: 32, height: 32))
        list.refreshIcons()
        XCTAssertTrue(row.imageView?.image === image)
        XCTAssertEqual(list.tableView.selectedRow, 0)
        XCTAssertGreaterThan(requested.count, 0)
        XCTAssertLessThan(requested.count, 20)
        XCTAssertFalse(requested.contains("window-199"))
        XCTAssertFalse(panel.isVisible)
    }

    func testLongWindowListReusesNativeRowsAcrossScrollingWithoutKeepingOldActions() throws {
        let windows = groups(count: 200)[0].windows
        var activated: [String] = []
        var closed: [String] = []
        let list = TaskbarWindowListView(windows: windows, availableHeight: 80, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { closed.append($0.id) }, fileHover: { _ in })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        var visitedRows: [TaskbarWindowListRow] = []
        for index in stride(from: 0, to: 200, by: 10) {
            let row = try XCTUnwrap(list.nativeRow(at: index))
            visitedRows.append(row)
            XCTAssertEqual(row.item.id, "window-\(index)")
            XCTAssertEqual(row.textField?.stringValue, windows[index].title)
            try list.clickRowForTesting(at: index)
            row.closeButton.performClick(nil)
        }
        XCTAssertLessThan(Set(visitedRows.map(ObjectIdentifier.init)).count, 10)
        let expected = stride(from: 0, to: 200, by: 10).map { "window-\($0)" }
        XCTAssertEqual(activated, expected)
        XCTAssertEqual(closed, expected)
        XCTAssertFalse(panel.isVisible)
    }

    func testScrollingAWindowListRowOffscreenCancelsItsPendingFileHover() async throws {
        let clock = Clock()
        var hovered: [String] = []
        let list = TaskbarWindowListView(windows: groups(count: 200)[0].windows, availableHeight: 80,
                                        delay: { await clock.sleep($0) }, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { hovered.append($0.id) })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        let row = try XCTUnwrap(list.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TaskbarWindowListRow)
        row.scheduleFileHover()
        await Task.yield()
        list.tableView.scrollRowToVisible(199)
        list.layoutSubtreeIfNeeded()
        _ = list.tableView.view(atColumn: 0, row: 199, makeIfNecessary: true)
        await clock.advance()
        XCTAssertTrue(hovered.isEmpty, "An offscreen or reused row must not activate its former window")
        XCTAssertFalse(panel.isVisible)
    }

    func testNativeListCloseButtonClosesOnlyItsWindowWithoutActivatingIt() throws {
        let popup = Popup()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup)
        var closed: [String] = []
        var activated: [String] = []
        content.actions.close = { closed.append($0.windowID.rawValue) }
        content.actions.activate = { activated.append($0.windowID.rawValue) }
        content.update(groups: groups())
        content.buttonViews["group:test.editor"]?.clickForTesting()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 1))
        row.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)))
        XCTAssertFalse(row.closeButton.isHidden)
        row.closeButton.performClick(nil)
        XCTAssertEqual(closed, ["window-1"])
        XCTAssertTrue(activated.isEmpty)
        XCTAssertTrue(popup.isPresented)
    }

    func testScrolledNativeTableUpdatesTitlesWithoutRecreatingRows() throws {
        let windows = groups()[0].windows
        let list = TaskbarWindowListView(windows: windows, availableHeight: 40, icon: { _ in nil },
                                        activate: { _ in }, close: { _ in }, fileHover: { _ in })
        let original = try XCTUnwrap(list.nativeRow(at: 2))
        var updated = windows
        updated[2] = TaskbarWindowPresentation(item: windows[2].item, title: "Changed title", isActive: false)
        list.updateTitles(windows: updated)
        XCTAssertTrue(list.nativeRow(at: 2) === original)
        XCTAssertEqual(original.textField?.stringValue, "Changed title")
    }

    func testNativeTableMouseTrackingActivatesTheClickedRow() throws {
        _ = NSApplication.shared
        var activated: [String] = []
        let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120, icon: { _ in nil },
                                        activate: { activated.append($0.id) }, close: { _ in }, fileHover: { _ in })
        let panel = NSPanel(contentRect: list.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = list
        defer { panel.contentView = nil; panel.close() }
        panel.layoutIfNeeded()
        XCTAssertFalse(panel.isVisible)
        try list.clickRowForTesting(at: 1)
        XCTAssertEqual(activated, ["window-1"])
        XCTAssertFalse(panel.isVisible)
    }

    func testNativeListVisualFixturesRenderWithoutOpeningAWindow() throws {
        for dark in [false, true] {
            let list = TaskbarWindowListView(windows: groups()[0].windows, availableHeight: 120,
                                            icon: { _ in NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) },
                                            activate: { _ in }, close: { _ in }, fileHover: { _ in })
            list.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            list.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.bounds))
            list.effectiveAppearance.performAsCurrentDrawingAppearance {
                list.cacheDisplay(in: list.bounds, to: bitmap)
            }
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 216)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 120)
            XCTAssertEqual(bitmap.pixelsWide * 120, bitmap.pixelsHigh * 216)
            if let path = ProcessInfo.processInfo.environment["DESKMOTE_RENDER_PATH"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("list-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testRepresentativeVisualFixturesRenderWithoutScreenCapturePermission() async throws {
        let paths = ProcessInfo.processInfo.environment["DESKMOTE_RENDER_PATH"]
        for dark in [false, true] {
            for (name, width, count) in [("separate", CGFloat(800), 3), ("combined", CGFloat(240), 8), ("single", CGFloat(800), 1)] {
                let view = makeView(width: width)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.taskbarContent.update(groups: groups(count: count))
                view.layoutSubtreeIfNeeded()
                let deadline = ContinuousClock.now + .seconds(1)
                for button in view.taskbarContent.buttonViews.values {
                    let expected: CGFloat = button.isActiveWindow ? 0.65 : 0
                    while abs(button.selectionView.alphaValue - expected) > 0.001, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertEqual(button.selectionView.alphaValue, expected, accuracy: 0.001)
                }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    XCTFail("No render target for \(name)")
                    continue
                }
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                if let paths {
                    let directory = URL(fileURLWithPath: paths, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
                if let paths {
                    let directory = URL(fileURLWithPath: paths, isDirectory: true)
                    let content = view.taskbarContent
                    content.layer?.backgroundColor = NSColor(white: dark ? 0.11 : 0.94, alpha: 1).cgColor
                    content.layoutSubtreeIfNeeded()
                    content.effectiveAppearance.performAsCurrentDrawingAppearance {
                        content.displayIfNeeded()
                        for button in content.buttonViews.values {
                            button.layoutSubtreeIfNeeded()
                            button.displayIfNeeded()
                        }
                    }
                    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 64,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
                    context.translateBy(x: 0, y: 64)
                    context.scaleBy(x: 2, y: -2)
                    content.layer?.render(in: context)
                    try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("buttons-\(name)-\(dark ? "dark" : "light").png"))
                }
                view.taskbarContent.dismissPopups()
            }
        }
    }

}

@MainActor
private extension TaskbarWindowListView {
    func nativeRow(at index: Int) -> TaskbarWindowListRow? {
        tableView.scrollRowToVisible(index)
        layoutSubtreeIfNeeded()
        return tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TaskbarWindowListRow
    }

    var nativeRows: [TaskbarWindowListRow] {
        (0..<tableView.numberOfRows).compactMap { index in
            let row = nativeRow(at: index)
            XCTAssertNotNil(row)
            return row
        }
    }
}


@MainActor
extension TaskbarRendererTests {
    func testClickedListsStayOpenAfterPointerExitWithoutFocusLoss() async throws {
        for width: CGFloat in [60, 200] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            content.update(groups: groups())
            let button = try XCTUnwrap(width == 60 ? content.overflowButton : content.buttonViews["group:test.editor"])
            button.clickForTesting()
            XCTAssertEqual(popup.keyRequests, 1)
            let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
            let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
            list.mouseEntered(with: enter)
            list.mouseExited(with: exit)
            await clock.advance(allowIdle: true)
            XCTAssertTrue(popup.isPresented)
            XCTAssertTrue(popup.content === list)
            XCTAssertEqual(popup.keyRequests, 1)
            content.prepareForHiding()
        }
    }

    func testPendingSameGroupHoverPreservesClickedList() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        button.onHover?(true)
        button.clickForTesting()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        XCTAssertEqual(popup.keyRequests, 1)
        await clock.advance()
        XCTAssertTrue(popup.content === list)
        XCTAssertEqual(popup.presentations, 1)
        XCTAssertEqual(popup.keyRequests, 1)
        content.prepareForHiding()
    }
}


@MainActor
extension TaskbarRendererTests {
    func testReplacingOpenListPreservesPendingNeighborHover() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let groups = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
        content.update(groups: groups)
        let first = try XCTUnwrap(content.buttonViews["group:test.narrow"])
        let second = try XCTUnwrap(content.buttonViews["group:test.wide"])
        var actions: [WindowActionIdentity] = []
        content.actions.activate = { actions.append($0) }
        content.actions.close = { actions.append($0) }
        first.onHover?(true)
        await clock.advance(.milliseconds(400))
        let oldList = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        let retainedRow = try XCTUnwrap(oldList.nativeRow(at: 0))
        retainedRow.scheduleFileHover()
        second.onHover?(true)

        let record = WindowRecord(id: WindowID(rawValue: "narrow-replacement"), appID: AppID(rawValue: "narrow"),
            pid: 300, bundleIdentifier: "test.narrow", title: "Narrow window 2", bounds: .zero,
            status: .inactive, cgWindowID: 300, groupID: "narrow-replacement", displayUUID: "left")
        let replacement = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
        let updated = TaskbarGroupPresentation(id: groups[0].id, name: groups[0].name,
                                               windows: [groups[0].windows[0], replacement])
        content.update(groups: [updated, groups[1]])
        XCTAssertFalse(popup.isPresented)
        XCTAssertTrue(content.buttonViews["group:test.wide"] === second)
        retainedRow.close()
        try oldList.clickRowForTesting(at: 0)
        await clock.advance(.milliseconds(600))
        XCTAssertTrue(actions.isEmpty)
        await clock.advance(.milliseconds(400))
        let newList = popup.content as? TaskbarWindowListView
        XCTAssertEqual(newList?.nativeRows.map(\.item.id), ["wide-0", "wide-1"])
        XCTAssertEqual(popup.keyRequests, 0)
        content.prepareForHiding()
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertFalse(popup.isPresented)
    }

    func testPendingMouseHoverCannotOpenAfterItsButtonMovesAwayFromThePointer() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let panel = RecordingPopupPanel(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: true)
        panel.contentView = content
        defer { panel.close() }
        let groups = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
        content.update(groups: groups)
        let button = try XCTUnwrap(content.buttonViews["group:test.wide"])
        panel.pointer = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: button)

        content.update(groups: Array(groups.reversed()))
        XCTAssertTrue(content.buttonViews["group:test.wide"] === button)
        XCTAssertFalse(button.visibleRect.contains(button.convert(panel.pointer, from: nil)))
        await clock.advance(.milliseconds(400))
        XCTAssertFalse(popup.isPresented)
    }

    func testLateExitFromTheReturnedButtonPreservesCombinedHoverAndFeedback() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let panel = RecordingPopupPanel(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: true)
        panel.contentView = content
        defer { panel.close() }
        content.update(groups: unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"]))
        let first = try XCTUnwrap(content.buttonViews["group:test.narrow"])
        let second = try XCTUnwrap(content.buttonViews["group:test.wide"])
        first.reduceMotion = { true }
        let firstPoint = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let secondPoint = second.convert(CGPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil)

        panel.pointer = firstPoint
        try sendTrackingEvent(.mouseEntered, at: firstPoint, to: first)
        panel.pointer = secondPoint
        try sendTrackingEvent(.mouseEntered, at: secondPoint, to: second)
        panel.pointer = firstPoint
        try sendTrackingEvent(.mouseEntered, at: firstPoint, to: first)
        try sendTrackingEvent(.mouseExited, at: secondPoint, to: first)
        XCTAssertGreaterThan(first.selectionView.alphaValue, 0)
        await clock.advance(.milliseconds(400))
        XCTAssertEqual((popup.content as? TaskbarWindowListView)?.nativeRows.map(\.item.id), ["narrow-0", "narrow-1"])

        panel.pointer = CGPoint(x: -1, y: -1)
        try sendTrackingEvent(.mouseExited, at: panel.pointer, to: first)
        XCTAssertEqual(first.selectionView.alphaValue, 0)
        XCTAssertNotNil(popup.content)
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertFalse(popup.isPresented)
    }

    func testLateEnterFromANeighborKeepsTheCurrentCombinedHover() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let panel = RecordingPopupPanel(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: true)
        panel.contentView = content
        defer { panel.close() }
        content.update(groups: unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"]))
        let first = try XCTUnwrap(content.buttonViews["group:test.narrow"])
        let second = try XCTUnwrap(content.buttonViews["group:test.wide"])
        first.reduceMotion = { true }
        second.reduceMotion = { true }
        let firstPoint = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        panel.pointer = second.convert(CGPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil)

        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: second)
        try sendTrackingEvent(.mouseEntered, at: firstPoint, to: first)
        XCTAssertEqual(first.selectionView.alphaValue, 0)
        XCTAssertGreaterThan(second.selectionView.alphaValue, 0)
        await clock.advance(.milliseconds(400))
        XCTAssertEqual((popup.content as? TaskbarWindowListView)?.nativeRows.map(\.item.id), ["wide-0", "wide-1"])
    }

    func testLateEnterAfterLeavingAButtonCannotRestoreItsFeedback() throws {
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        let panel = RecordingPopupPanel(contentRect: button.frame, styleMask: .borderless, backing: .buffered, defer: true)
        panel.contentView = button
        defer { panel.close() }
        button.reduceMotion = { true }
        var hovering: [Bool] = []
        button.onHover = { hovering.append($0) }
        let inside = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        panel.pointer = inside
        try sendTrackingEvent(.mouseEntered, at: inside, to: button)
        XCTAssertGreaterThan(button.selectionView.alphaValue, 0)
        panel.pointer = CGPoint(x: -1, y: -1)
        try sendTrackingEvent(.mouseExited, at: panel.pointer, to: button)
        try sendTrackingEvent(.mouseEntered, at: inside, to: button)
        XCTAssertEqual(button.selectionView.alphaValue, 0)
        XCTAssertEqual(hovering, [true, false])
    }

    func testLatePopupExitCannotDismissAfterThePointerReturns() async throws {
        let clock = Clock()
        let popup = TaskbarPopupController { frame in
            RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        }
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        defer { popup.dismiss() }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        button.onHover?(true)
        await clock.advance(.milliseconds(400))
        let panel = try XCTUnwrap(popup.panel as? RecordingPopupPanel)
        let list = try XCTUnwrap(panel.contentView as? TaskbarWindowListView)
        let inside = list.convert(CGPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
        let outside = CGPoint(x: -1, y: -1)
        panel.pointer = inside
        try sendTrackingEvent(.mouseEntered, at: inside, to: list)
        button.onHover?(false)
        panel.pointer = outside
        try sendTrackingEvent(.mouseExited, at: outside, to: list)
        XCTAssertFalse(list.isPointerInside)
        try sendTrackingEvent(.mouseEntered, at: inside, to: list)
        XCTAssertFalse(list.isPointerInside)
        panel.pointer = inside
        try sendTrackingEvent(.mouseEntered, at: inside, to: list)
        try sendTrackingEvent(.mouseExited, at: outside, to: list)
        XCTAssertTrue(list.isPointerInside)
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertTrue(popup.panel === panel)

        panel.pointer = outside
        try sendTrackingEvent(.mouseExited, at: outside, to: list)
        XCTAssertFalse(list.isPointerInside)
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertFalse(popup.isPresented)
    }

    func testPopupTrackingIncludesTopEdgeAndExcludesBottomEdge() async throws {
        let clock = Clock()
        let popup = TaskbarPopupController { frame in
            RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        }
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        defer { popup.dismiss() }
        content.update(groups: groups())
        let button = try XCTUnwrap(content.buttonViews["group:test.editor"])
        button.onHover?(true)
        await clock.advance(.milliseconds(400))
        let panel = try XCTUnwrap(popup.panel as? RecordingPopupPanel)
        let list = try XCTUnwrap(panel.contentView as? TaskbarWindowListView)
        XCTAssertFalse(list.isFlipped)
        let rect = list.visibleRect
        XCTAssertFalse(rect.isEmpty)

        panel.pointer = list.convert(CGPoint(x: rect.midX, y: rect.maxY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: list)
        XCTAssertTrue(list.isPointerInside)

        panel.pointer = list.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: list)
        XCTAssertTrue(list.isPointerInside)
        button.onHover?(false)
        panel.pointer = list.convert(CGPoint(x: rect.midX, y: rect.minY), to: nil)
        try sendTrackingEvent(.mouseExited, at: panel.pointer, to: list)
        XCTAssertFalse(list.isPointerInside)
        XCTAssertTrue(popup.isPresented)
        await clock.advance(.milliseconds(250), allowIdle: true)
        XCTAssertFalse(popup.isPresented)
    }

    func testPendingNativeRowDragUsesTheCurrentPopupFrameBeforeActivating() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        for remainsOnRow in [false, true] {
            let clock = Clock()
            let dock = RecordingPopupPanel(contentRect: CGRect(x: screen.frame.minX + 300, y: screen.frame.minY, width: 200, height: 32),
                                           styleMask: .borderless, backing: .buffered, defer: true)
            let popup = TaskbarPopupController { frame in
                RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            }
            let content = TaskbarContentView(frame: CGRect(origin: .zero, size: dock.frame.size), popup: popup,
                                             delay: { await clock.sleep($0) })
            dock.contentView = content
            defer { popup.dismiss(); dock.close() }
            let groups = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
            content.update(groups: groups)
            var activated: [String] = []
            content.actions.activate = { activated.append($0.windowID.rawValue) }
            try XCTUnwrap(content.buttonViews["group:test.wide"]).clickForTesting()
            let panel = try XCTUnwrap(popup.panel)
            let list = try XCTUnwrap(panel.contentView as? TaskbarWindowListView)
            let row = try XCTUnwrap(list.nativeRow(at: 0))
            let x = remainsOnRow ? row.bounds.minX + 20 : row.bounds.maxX - 20
            let drag = FileDrag(location: row.convert(CGPoint(x: x, y: row.bounds.midY), to: nil))
            drag.draggingDestinationWindow = panel
            defer { drag.draggingPasteboard.releaseGlobally() }
            let screenLocation = panel.convertPoint(toScreen: drag.draggingLocation)
            XCTAssertEqual(row.draggingEntered(drag), .generic)
            XCTAssertTrue(list.isPointerInside)

            let originalFrame = panel.frame
            content.update(groups: Array(groups.reversed()))
            XCTAssertLessThan(panel.frame.minX, originalFrame.minX)
            XCTAssertTrue(popup.panel === panel)
            XCTAssertTrue(list.nativeRow(at: 0) === row)
            let newLocation = row.convert(panel.convertPoint(fromScreen: screenLocation), from: nil)
            XCTAssertEqual(row.visibleRect.contains(newLocation), remainsOnRow)
            await clock.advance(.milliseconds(600))
            XCTAssertEqual(activated, remainsOnRow ? ["wide-0"] : [])
            XCTAssertEqual(list.isPointerInside, remainsOnRow)
            sendTerminalDrag(drag, to: row)
            XCTAssertFalse(list.isPointerInside)
        }
    }

    func testOpenCombinedListFollowsMovedAnchorWithoutReopening() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let dock = RecordingPopupPanel(contentRect: CGRect(x: screen.frame.minX + 300, y: screen.frame.minY, width: 200, height: 32),
                                       styleMask: .borderless, backing: .buffered, defer: true)
        let popup = TaskbarPopupController { frame in
            RecordingPopupPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        }
        let content = TaskbarContentView(frame: CGRect(origin: .zero, size: dock.frame.size), popup: popup)
        dock.contentView = content
        defer { popup.dismiss(); dock.close() }
        let groups = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
        content.update(groups: groups)
        let button = try XCTUnwrap(content.buttonViews["group:test.wide"])
        button.clickForTesting()
        let panel = try XCTUnwrap(popup.panel as? RecordingPopupPanel)
        let list = try XCTUnwrap(panel.contentView as? TaskbarWindowListView)
        let row = try XCTUnwrap(list.nativeRow(at: 1))
        list.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        panel.pointer = list.convert(CGPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
        try sendTrackingEvent(.mouseEntered, at: panel.pointer, to: list)
        let start = panel.frame
        let startingAnchor = dock.convertToScreen(button.convert(button.bounds, to: nil))
        XCTAssertEqual(start.midX, startingAnchor.midX, accuracy: 0.01)

        content.update(groups: Array(groups.reversed()))
        let endingAnchor = dock.convertToScreen(button.convert(button.bounds, to: nil))
        XCTAssertLessThan(endingAnchor.midX, startingAnchor.midX)
        XCTAssertEqual(panel.frame.midX, endingAnchor.midX, accuracy: 0.01)
        XCTAssertEqual(panel.frame.minY, start.minY)
        XCTAssertEqual(panel.frame.size, start.size)
        XCTAssertTrue(popup.panel === panel)
        XCTAssertTrue(panel.contentView === list)
        XCTAssertTrue(list.nativeRow(at: 1) === row)
        XCTAssertTrue(list.isPointerInside)
        XCTAssertEqual(list.tableView.selectedRow, 1)
        XCTAssertEqual(panel.keyRequests, 1)
        XCTAssertEqual(panel.frontRequests, 1)
        XCTAssertFalse(panel.isVisible)
    }

    private func sendTrackingEvent(_ type: NSEvent.EventType, at point: CGPoint, to view: NSView) throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        if type == .mouseEntered { view.mouseEntered(with: event) }
        else { view.mouseExited(with: event) }
    }

    func testLateExitFromANeighborDoesNotCancelTheCurrentCombinedHover() async throws {
        let popup = Popup()
        let clock = Clock()
        let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                         delay: { await clock.sleep($0) })
        let combinedGroups = unequalGroups(shortFirst: true, shortTitles: ["Narrow window 1", "Narrow window 2"])
        content.update(groups: combinedGroups)
        let first = try XCTUnwrap(content.buttonViews["group:test.narrow"])
        let second = try XCTUnwrap(content.buttonViews["group:test.wide"])
        first.onHover?(true)
        second.onHover?(true)
        first.onHover?(false)
        await clock.advance()
        let list = try XCTUnwrap(popup.content as? TaskbarWindowListView)
        XCTAssertEqual(list.nativeRows.map(\.item.id), combinedGroups[1].windows.map(\.id))

        second.onHover?(false)
        await clock.advance()
        XCTAssertFalse(popup.isPresented)
    }

    func testPendingHoverCannotReplaceAnotherGroupOpenedByClick() async throws {
        for (fileHover, hoverBeforeClick) in [(false, true), (false, false), (true, true), (true, false)] {
            let popup = Popup()
            let clock = Clock()
            let content = TaskbarContentView(frame: CGRect(x: 0, y: 0, width: 200, height: 32), popup: popup,
                                             delay: { await clock.sleep($0) })
            let secondWindows = (0..<3).map { index in
                let id = "review-second-\(index)"
                let record = WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: "second"), pid: 200,
                    bundleIdentifier: "test.second", title: "Second window \(index)", bounds: nil,
                    status: .inactive, cgWindowID: UInt32(100 + index), groupID: id, displayUUID: "left")
                return TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
            }
            let second = TaskbarGroupPresentation(id: "test.second", name: "Second", windows: secondWindows)
            content.update(groups: groups() + [second])
            let firstButton = try XCTUnwrap(content.buttonViews["group:test.editor"])
            let secondButton = try XCTUnwrap(content.buttonViews["group:test.second"])
            func hoverOnFirstButton() {
                if fileHover { content.scheduleFileHover(buttonID: "group:test.editor") }
                else { firstButton.onHover?(true) }
            }
            if hoverBeforeClick { hoverOnFirstButton() }
            secondButton.clickForTesting()
            if !hoverBeforeClick { hoverOnFirstButton() }
            let clickedList = try XCTUnwrap(popup.content as? TaskbarWindowListView)
            XCTAssertEqual(popup.keyRequests, 1)
            XCTAssertEqual(clickedList.nativeRows.map(\.item.id), secondWindows.map(\.id))
            await clock.advance(allowIdle: true)
            XCTAssertTrue(popup.content === clickedList)
            XCTAssertEqual(popup.presentations, 1)
            XCTAssertEqual(popup.keyRequests, 1)
            content.prepareForHiding()
        }
    }
}
