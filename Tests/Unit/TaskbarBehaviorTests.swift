import AppKit
import ApplicationServices
import Combine
import SwiftUI
import Synchronization
import XCTest

final class BehaviorDesktop: AccessibilityOperations, WindowSystemAccess, WindowFocusRequesting, @unchecked Sendable {
    struct State: Sendable {
        var windows: [CGWindowID: WindowRecord]
        var focused: CGWindowID? = 1001
        var omittedCG = Set<CGWindowID>()
        var generation = ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1))
        var writes: [String] = []
        var rejectWrites = false
        var ignoreWrites = false
        var denyFocus = false
        var missingWindows = Set<CGWindowID>()
        var terminated: [pid_t] = []
        var quitAttempts: [pid_t] = []
        var activationAttempts: [pid_t] = []
        var deniedQuit = false
        var cgOwnerOverride: pid_t?
        var originOverride: ApplicationOrigin?
        var beforeRead: (@Sendable (String) -> Void)?
        var beforeWindowIDRead: (@Sendable (CGWindowID) -> Void)?
        var beforeOwnerRead: (@Sendable (CGWindowID) -> Void)?
        var beforeFrameBatchRead: (@Sendable () -> Void)?
        var nativeWindowIDOverrides: [CGWindowID: CGWindowID] = [:]
        var unreadNativeWindowIDs = Set<CGWindowID>()
        var windowIDAttributes: [CGWindowID: CGWindowID] = [:]
        var beforeInventoryRead: (@Sendable (pid_t) -> Void)?
        var unreadInventories = Set<pid_t>()
        var unreadFocusedWindows = Set<pid_t>()
        var hiddenApplications = Set<pid_t>()
        var unhideAttempts: [pid_t] = []
        var beforeSettable: (@Sendable (String) -> Void)?
        var unreadSettableAttributes = Set<String>()
        var beforeAttributeWrite: (@Sendable (CGWindowID, String) -> AXError?)?
        var beforeSizeWrite: (@Sendable (CGWindowID, CGSize) -> AXError?)?
        var afterAttributeWrite: (@Sendable (CGWindowID, String) -> Void)?
        var rejectMinimizedAttribute = false
        var transientMinimizeReads = 0
        var malformedMinimizeButton = false
        var minimizeButtonReads = 0
        var allowFocusOfMinimized = false
        var frontmostPIDOverride: pid_t?
        var exposesSystemFocus = false
        var generationsByPID: [pid_t: ProcessGeneration] = [:]
        var unreadGenerations = Set<pid_t>()
        var afterGenerationRead: (@Sendable (pid_t, ProcessGeneration?) -> Void)?
        var subroles: [CGWindowID: String] = [:]
        var modalWindows: [CGWindowID: Bool] = [:]
        var topLevelWindows = Set<CGWindowID>()
        var enumeratedWindows: [pid_t: [CGWindowID]] = [:]
        var publishedFocusedWindows: [pid_t: CGWindowID] = [:]
        var publishedMainWindows: [pid_t: CGWindowID] = [:]
        var unreadOwners = Set<CGWindowID>()
        var unreadPositions = Set<CGWindowID>()
        var transientFrameReadFailures: [CGWindowID: [String: Int]] = [:]
    }

    let state: Mutex<State>
    let values: CurrentValueSubject<DockSnapshot, Never>
    let elements: [CGWindowID: AXUIElement]
    private let replacementElements = Mutex<[CGWindowID: AXElementKey]>([:])
    let applications: [pid_t: AXUIElement]
    let closeButtons: [CGWindowID: AXUIElement]
    let minimizeButtons: [CGWindowID: AXUIElement]
    let systemElement = AXUIElementCreateApplication(-48000)

    init(browserPID: pid_t = -42000, additionalWindows: Int = 0, editorBundleIdentifier: String = "test.Editor") {
        var windows = [("editor-a", Int32(-41000), UInt32(1001), "Editor"),
                       ("editor-b", Int32(-41000), UInt32(1002), "Editor"),
                       ("browser-c", browserPID, UInt32(2001), "Browser")].map { id, pid, number, app in
            WindowRecord(id: WindowID(rawValue: id), appID: AppID(rawValue: app), pid: pid,
                bundleIdentifier: app == "Editor" ? editorBundleIdentifier : "test." + app, title: id,
                bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                status: number == 1001 ? .active : .inactive, cgWindowID: number, groupID: "tabgrp-" + id, displayUUID: "left",
                applicationOrigin: ApplicationOrigin(bundleURL: URL(fileURLWithPath: "/Applications/\(app).app")),
                processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
        }
        for offset in 0..<additionalWindows {
            let number = CGWindowID(3000 + offset)
            windows.append(WindowRecord(id: WindowID(rawValue: "churn-\(number)"), appID: AppID(rawValue: "Editor"), pid: -41000,
                bundleIdentifier: "test.Editor", title: "churn-\(number)", bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                status: .inactive, cgWindowID: number, groupID: "churn-\(number)", displayUUID: "left",
                applicationOrigin: ApplicationOrigin(bundleURL: URL(fileURLWithPath: "/Applications/Editor.app")),
                processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1))))
        }
        state = Mutex(State(windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.cgWindowID!, $0) })))
        values = CurrentValueSubject(DockSnapshot(windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
                                                  orderedWindowIDs: windows.map(\.id)))
        elements = Dictionary(uniqueKeysWithValues: windows.map { ($0.cgWindowID!, AXUIElementCreateApplication(-50000 - Int32($0.cgWindowID!))) })
        closeButtons = Dictionary(uniqueKeysWithValues: [UInt32(1001), 1002, 2001].map { ($0, AXUIElementCreateApplication(-60000 - Int32($0))) })
        minimizeButtons = Dictionary(uniqueKeysWithValues: [UInt32(1001), 1002, 2001].map { ($0, AXUIElementCreateApplication(-70000 - Int32($0))) })
        applications = [-41000: AXUIElementCreateApplication(-41000), browserPID: AXUIElementCreateApplication(browserPID)]
    }

    func publish() {
        let snapshot = state.withLock { value in
            let records = value.windows.keys.sorted().compactMap { value.windows[$0] }
            return DockSnapshot(windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                                orderedWindowIDs: records.map(\.id))
        }
        values.send(snapshot)
    }

    func number(_ element: AXUIElement) -> CGWindowID? {
        replacementElements.withLock { replacements in
            if let match = replacements.first(where: { CFEqual($0.value.e, element) }) { return match.key }
            let original = elements.first { CFEqual($0.value, element) }?.key
            return original.flatMap { replacements[$0] == nil ? $0 : nil }
        }
    }

    func replaceElement(for id: CGWindowID) {
        let replacement = AXElementKey(e: AXUIElementCreateApplication(-80000 - Int32(id)))
        replacementElements.withLock { $0[id] = replacement }
    }

    private func element(for id: CGWindowID) -> AXUIElement? {
        replacementElements.withLock { $0[id]?.e } ?? elements[id]
    }

    func isTrusted() -> Bool { true }
    func systemWide() -> AXUIElement? { state.withLock { $0.exposesSystemFocus } ? systemElement : nil }
    func application(_ pid: pid_t) -> AXUIElement { applications[pid] ?? AXUIElementCreateApplication(-99999) }
    func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let id = number(element) else { return nil }
        state.withLock { $0.beforeWindowIDRead }?(id)
        return state.withLock {
            $0.unreadNativeWindowIDs.contains(id) ? nil : $0.nativeWindowIDOverrides[id] ?? id
        }
    }
    func pid(_ element: AXUIElement) -> pid_t? {
        guard let id = number(element) else { return applications.first { CFEqual($0.value, element) }?.key }
        state.withLock { $0.beforeOwnerRead }?(id)
        return state.withLock { $0.unreadOwners.contains(id) ? nil : $0.windows[id]?.pid }
    }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { .success }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) {
        state.withLock { $0.beforeSettable }?(attribute as String)
        return state.withLock {
            $0.unreadSettableAttributes.contains(attribute as String) ? (.cannotComplete, false) : (.success, true)
        }
    }

    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        guard attributes.contains(kAXPositionAttribute as String), attributes.contains(kAXSizeAttribute as String),
              let beforeFrameBatchRead = state.withLock({ $0.beforeFrameBatchRead }) else {
            return (.notImplemented, nil)
        }
        beforeFrameBatchRead()
        return (.success, attributes.map { copy(element, $0 as CFString).1 ?? kCFNull })
    }

    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        let name = attribute as String
        let value = state.withLock { $0 }
        value.beforeRead?(name)
        if CFEqual(element, systemElement) {
            guard name == kAXFocusedUIElementAttribute as String else { return (.attributeUnsupported, nil) }
            guard let focused = value.focused, let element = self.element(for: focused) else { return (.noValue, nil) }
            return (.success, element)
        }
        if let app = applications.first(where: { CFEqual($0.value, element) })?.key {
                if name == kAXFocusedWindowAttribute as String, value.unreadFocusedWindows.contains(app) {
                    return (.cannotComplete, nil)
                }
                if name == kAXRoleAttribute as String { return (.success, kAXApplicationRole as CFString) }
                if name == kAXWindowsAttribute as String {
                    value.beforeInventoryRead?(app)
                    if value.unreadInventories.contains(app) { return (.cannotComplete, nil) }
                    if let ids = value.enumeratedWindows[app] { return (.success, ids.compactMap { self.element(for: $0) } as CFArray) }
                    return (.success, value.windows.values.filter { $0.pid == app && !value.missingWindows.contains($0.cgWindowID!) }
                        .sorted { $0.cgWindowID! < $1.cgWindowID! }.compactMap { self.element(for: $0.cgWindowID!) } as CFArray)
                }
                if name == kAXFocusedWindowAttribute as String, let id = value.publishedFocusedWindows[app] {
                    return (.success, self.element(for: id))
                }
                if name == kAXMainWindowAttribute as String, let id = value.publishedMainWindows[app] {
                    return (.success, self.element(for: id))
                }
                if name == kAXFocusedWindowAttribute as String || name == kAXMainWindowAttribute as String,
                   let focused = value.focused, value.windows[focused]?.pid == app {
                    return (.success, self.element(for: focused))
                }
                return (.noValue, nil)
        }
        guard let id = number(element) else { return (.invalidUIElement, nil) }
            guard let window = value.windows[id], !value.missingWindows.contains(id) else { return (.invalidUIElement, nil) }
            let transientFailure = state.withLock { storage in
                let remaining = storage.transientFrameReadFailures[id]?[name] ?? 0
                guard remaining > 0 else { return false }
                storage.transientFrameReadFailures[id]?[name] = remaining - 1
                return true
            }
            if transientFailure { return (.cannotComplete, nil) }
            switch name {
            case "AXWindowID":
                guard let id = value.windowIDAttributes[id] else { return (.attributeUnsupported, nil) }
                return (.success, NSNumber(value: id))
            case kAXRoleAttribute as String: return (.success, kAXWindowRole as CFString)
            case kAXSubroleAttribute as String: return (.success, (value.subroles[id] ?? kAXStandardWindowSubrole as String) as CFString)
            case kAXModalAttribute as String:
                guard let modal = value.modalWindows[id] else { return (.attributeUnsupported, nil) }
                return (.success, modal ? kCFBooleanTrue : kCFBooleanFalse)
            case kAXParentAttribute as String:
                return (.success, value.topLevelWindows.contains(id) ? applications[window.pid] : self.element(for: id))
            case kAXTitleAttribute as String: return (.success, window.title as CFString)
            case kAXMinimizedAttribute as String: return (.success, window.status == .minimized ? kCFBooleanTrue : kCFBooleanFalse)
            case "AXFullScreen": return (.success, kCFBooleanFalse)
            case kAXPositionAttribute as String:
                if value.unreadPositions.contains(id) { return (.cannotComplete, nil) }
                var point = window.bounds!.origin
                return (.success, AXValueCreate(.cgPoint, &point))
            case kAXSizeAttribute as String:
                var size = window.bounds!.size
                return (.success, AXValueCreate(.cgSize, &size))
            case kAXCloseButtonAttribute as String: return (.success, closeButtons[id])
            case kAXMinimizeButtonAttribute as String:
                let unavailable = state.withLock { storage in
                    storage.minimizeButtonReads += 1
                    if storage.transientMinimizeReads > 0 { storage.transientMinimizeReads -= 1; return true }
                    return false
                }
                if unavailable { return (.cannotComplete, nil) }
                if value.malformedMinimizeButton { return (.success, "Not an AX element" as CFString) }
                return (.success, minimizeButtons[id])
            default: return (.attributeUnsupported, nil)
            }
    }

    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        guard let id = number(element) else { return .invalidUIElement }
        if let failure = state.withLock({ $0.beforeAttributeWrite })?(id, attribute as String) { return failure }
        let size: CGSize?
        if attribute as String == kAXSizeAttribute as String {
            var requestedSize = CGSize.zero
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &requestedSize) else { return .illegalArgument }
            if let failure = state.withLock({ $0.beforeSizeWrite })?(id, requestedSize) { return failure }
            size = requestedSize
        } else {
            size = nil
        }
        let result = state.withLock { storage -> AXError in
            guard var window = storage.windows[id] else { return .invalidUIElement }
            if storage.rejectWrites || (storage.rejectMinimizedAttribute && attribute as String == kAXMinimizedAttribute as String) { return .failure }
            storage.writes.append("\(id):\(attribute)")
            guard !storage.ignoreWrites else { return .success }
            if attribute as String == kAXMinimizedAttribute as String {
                window.status = (value as? NSNumber)?.boolValue == true ? .minimized : .inactive
                if window.status == .minimized, storage.focused == id { storage.focused = nil }
            } else if let size {
                window.bounds?.size = size
            } else if attribute as String == kAXPositionAttribute as String {
                var point = CGPoint.zero
                guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else { return .illegalArgument }
                window.bounds?.origin = point
            }
            storage.windows[id] = window
            return .success
        }
        publish()
        if result == .success { state.withLock { $0.afterAttributeWrite }?(id, attribute as String) }
        return result
    }

    func perform(_ element: AXUIElement, _ action: CFString) -> AXError {
        let close = closeButtons.first { CFEqual($0.value, element) }?.key
        let minimize = minimizeButtons.first { CFEqual($0.value, element) }?.key
        guard let id = close ?? minimize ?? number(element) else { return .invalidUIElement }
        let result = state.withLock { value -> AXError in
            guard value.windows[id] != nil else { return .invalidUIElement }
            if action as String == kAXPressAction as String {
                if close != nil { value.windows.removeValue(forKey: id); value.writes.append("\(id):close") }
                else if minimize != nil {
                    value.windows[id]?.status = .minimized
                    if value.focused == id { value.focused = nil }
                    value.writes.append("\(id):press-minimize")
                } else { return .actionUnsupported }
            }
            return .success
        }
        publish()
        return result
    }

    func generation(_ pid: pid_t) -> ProcessGeneration? {
        let (generation, afterRead) = state.withLock {
            ($0.unreadGenerations.contains(pid) ? nil : ($0.generationsByPID[pid] ?? $0.generation), $0.afterGenerationRead)
        }
        afterRead?(pid, generation)
        return generation
    }
    func app(_ pid: pid_t) -> WindowApplicationState? {
        state.withLock { value in
            guard applications[pid] != nil else { return nil }
            return WindowApplicationState(isActive: (value.frontmostPIDOverride ?? value.focused.flatMap { value.windows[$0]?.pid }) == pid,
                isHidden: value.hiddenApplications.contains(pid), isTerminated: value.terminated.contains(pid), activationPolicy: .regular,
                bundleURL: URL(fileURLWithPath: value.originOverride?.bundlePath ?? (pid == -41000 ? "/Applications/Editor.app" : "/Applications/Browser.app")))
        }
    }
    func activate(_ pid: pid_t) -> Bool {
        state.withLock { $0.activationAttempts.append(pid) }
        return true
    }
    func unhide(_ pid: pid_t) {
        state.withLock {
            $0.unhideAttempts.append(pid)
            $0.hiddenApplications.remove(pid)
        }
    }
    func terminate(_ pid: pid_t, generation: ProcessGeneration, origin: ApplicationOrigin?) -> Bool {
        state.withLock { value in
            value.quitAttempts.append(pid)
            guard !value.deniedQuit else { return false }
            value.terminated.append(pid)
            return true
        }
    }
    func windowInfo(_ options: CGWindowListOption, _ relative: CGWindowID) -> [[String: Any]]? {
        state.withLock { value in
            value.windows.values.filter { (relative == 0 || $0.cgWindowID == relative) && !value.omittedCG.contains($0.cgWindowID!) }
                .sorted { ($0.cgWindowID == value.focused ? 0 : 1, $0.cgWindowID!) < ($1.cgWindowID == value.focused ? 0 : 1, $1.cgWindowID!) }
                .map { [kCGWindowNumber as String: $0.cgWindowID!, kCGWindowOwnerPID as String: value.cgOwnerOverride ?? $0.pid,
                        kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: $0.status != .minimized,
                        kCGWindowBounds as String: $0.bounds!.dictionaryRepresentation] }
        }
    }
    func windowDescriptions(for ids: [CGWindowID]) -> [[String: Any]]? {
        let requested = Set(ids)
        return windowInfo(.optionAll, kCGNullWindowID)?.filter {
            ($0[kCGWindowNumber as String] as? NSNumber).map { requested.contains($0.uint32Value) } ?? false
        }
    }
    func setFrontmost(pid: pid_t, windowID: CGWindowID, mode: UInt32) -> Bool {
        let accepted = state.withLock { value in
            guard !value.denyFocus, let match = value.windows.first(where: { $0.value.cgWindowID == windowID }),
                  match.value.pid == pid, match.value.status != .minimized || value.allowFocusOfMinimized else { return false }
            for id in Array(value.windows.keys) where value.windows[id]?.status == .active { value.windows[id]?.status = .inactive }
            if match.value.status != .minimized { value.windows[match.key]?.status = .active }
            value.focused = match.key
            return true
        }
        publish()
        return accepted
    }
    func makeKey(pid: pid_t, windowID: CGWindowID) -> Bool { setFrontmost(pid: pid, windowID: windowID, mode: 0) }
}

@MainActor
final class BehaviorInventory: WindowInventoryTracking {
    let desktop: BehaviorDesktop
    var snapshots: AnyPublisher<DockSnapshot, Never> { desktop.values.eraseToAnyPublisher() }
    init(_ desktop: BehaviorDesktop) { self.desktop = desktop }
    func start() {}
    func stop() {}
}

final class BehaviorReadGate: Sendable {
    let entered = Mutex(false)
    let timedOut = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let attribute: String
    init(attribute: String = kAXFocusedWindowAttribute as String) { self.attribute = attribute }
    func read(_ attribute: String) {
        guard attribute == self.attribute else { return }
        let first = entered.withLock { value in let result = !value; value = true; return result }
        if first, release.wait(timeout: .now() + 2) == .timedOut { timedOut.withLock { $0 = true } }
    }
}

@MainActor
final class BehaviorPopup: TaskbarPopupPresenting {
    var panel: NSPanel? { nil }
    var isPresented: Bool { content != nil }
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?
    var content: NSView?
    private let presentationPanel: NSPanel?

    init(presentationPanel: NSPanel? = nil) {
        self.presentationPanel = presentationPanel
    }

    func makeKey() {}
    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
        self.content = content
        if let presentationPanel { onPresent?(presentationPanel) }
    }
    func dismiss() { (content as? TaskbarWindowListView)?.cancelPendingActions(); content = nil; onDismiss?() }
}

@MainActor
final class BehaviorMenu: TaskbarContextMenuPresenting {
    var visibilityChanged: ((Bool) -> Void)?
    var menu: NSMenu?
    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) { menu = TaskbarNativeMenuFactory.menu(entries: entries) }
    func dismiss() { menu = nil }
}

@MainActor
final class TaskbarBehaviorTests: XCTestCase {
    @MainActor
    final class Fixture {
        let desktop = BehaviorDesktop()
        let popup = BehaviorPopup()
        let menu = BehaviorMenu()
        let defaults: UserDefaults
        let domain = "DeskMote.Behavior.\(UUID().uuidString)"
        let runtime: AppRuntime
        let view: TaskbarView
        let ordering: StripOrderStore
        let presenter: TaskbarPresenter
        let spaces: TaskbarSpaceStore

        init(width: CGFloat = 800, displayUUID: String? = nil, spaces: TaskbarSpaceStore = TaskbarSpaceStore(
            read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0
        )) {
            self.spaces = spaces
            defaults = UserDefaults(suiteName: domain)!
            ordering = StripOrderStore(defaults: defaults, bootTimeProvider: { 123 })
            let reader = AXWindowReader(accessibility: desktop)
            runtime = AppRuntime(tracker: BehaviorInventory(desktop),
                actionExecutor: PlatformActionExecutor(reader: reader, system: desktop, focusBackend: desktop), isAppFrontmost: { [desktop] pid in desktop.app(pid)?.isActive == true })
            view = TaskbarView(frame: CGRect(x: 0, y: 0, width: width, height: 32), popup: popup, contextMenu: menu,
                               delay: { _ in await Task.yield() })
            let attribution: WindowDisplayAttribution.Table = displayUUID == nil ? .empty : .init(displays: [
                .init(uuid: "left", cgFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                .init(uuid: "right", cgFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ], primaryUUID: "left")
            presenter = TaskbarPresenter(view: view, runtime: runtime, ordering: ordering,
                topology: DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: displayUUID == nil ? 1 : 2,
                    identifiedDisplayUUIDs: displayUUID == nil ? ["left"] : ["left", "right"], attributionTable: attribution)),
                spaces: spaces, displayUUID: displayUUID, backgroundMenu: { _, _ in }, popupPresented: { _ in },
                contextMenuVisibilityChanged: { _ in }, system: desktop)
            runtime.start()
        }
        func stop() { view.taskbarContent.prepareForHiding(); runtime.stop(); defaults.removePersistentDomain(forName: domain) }
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func ready(_ fixture: Fixture) async { await wait { fixture.view.taskbarContent.groups.flatMap(\.windows).count == 3 } }

    private func drainTaskbarUpdates() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testRepeatedBrowserTabChangesUpdateTheNativeCaptionWithoutWaitingForQuiet() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-browser-c"])
        let order = fixture.view.taskbarContent.groups.flatMap(\.windows).map(\.id)

        let titles = ["Home — Chrome", "New Tab — Chrome", "Home — Chrome", "New Tab — Chrome", "Home — Chrome",
                      "Documentation — Chrome", " News - in group “Work” - Google Chrome Beta "]
        for title in titles {
            fixture.desktop.state.withLock { $0.windows[2001]?.title = title }
            fixture.desktop.publish()
            await drainTaskbarUpdates()

            XCTAssertEqual(fixture.runtime.snapshot.windows[WindowID(rawValue: "browser-c")]?.title, title)
            XCTAssertEqual(button.titleLabel.stringValue, title)
            XCTAssertEqual(button.accessibilityLabel(), title)
            XCTAssertTrue(fixture.view.taskbarContent.buttonViews["window:tabgrp-browser-c"] === button)
            XCTAssertEqual(fixture.view.taskbarContent.groups.flatMap(\.windows).map(\.id), order)
        }
    }

    func testChatTitleReplacesTransientApplicationNameOnEveryNavigation() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"])

        for title in ["ChatGPT", "First conversation", "ChatGPT", "Second conversation", "ChatGPT", "Third conversation"] {
            fixture.desktop.state.withLock { $0.windows[1001]?.title = title }
            fixture.desktop.publish()
            await drainTaskbarUpdates()

            XCTAssertEqual(fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.title, title)
            XCTAssertEqual(button.titleLabel.stringValue, title)
            XCTAssertEqual(button.accessibilityLabel(), title)
            XCTAssertEqual(fixture.view.taskbarContent.groups.flatMap(\.windows).first(where: { $0.item.actionWindowID == "editor-a" })?.title, title)
        }
    }

    private func press(_ id: String, _ fixture: Fixture) throws {
        try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-\(id)"]).clickForTesting()
    }
    private func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    func testPrepareForHidingCancelsMousePressOnSurvivingButton() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        var toggles: [String] = []
        content.actions.toggle = { toggles.append($0.windowID.rawValue) }

        button.mouseDown(with: event(.leftMouseDown, point))
        content.prepareForHiding()
        XCTAssertTrue(content.buttonViews["window:tabgrp-editor-a"] === button)
        button.mouseUp(with: event(.leftMouseUp, point))
        XCTAssertEqual(toggles, [])

        button.mouseDown(with: event(.leftMouseDown, point))
        button.mouseUp(with: event(.leftMouseUp, point))
        XCTAssertEqual(toggles, ["editor-a"])
    }

    func testSurvivingButtonCancelsHeldPressWhenItsWindowChanges() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        func center() -> CGPoint {
            button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }

        button.mouseDown(with: event(.leftMouseDown, center()))
        fixture.desktop.state.withLock {
            $0.windows[1001]?.groupID = "tabgrp-editor-b"
            $0.windows[1002]?.groupID = "tabgrp-editor-a"
        }
        fixture.desktop.publish()
        await wait {
            content.groups.flatMap(\.windows).first { $0.id == "tabgrp-editor-a" }?.item.actionWindowID == "editor-b"
        }
        XCTAssertTrue(content.buttonViews["window:tabgrp-editor-a"] === button)
        button.mouseUp(with: event(.leftMouseUp, center()))
        XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)

        button.mouseDown(with: event(.leftMouseDown, center()))
        fixture.desktop.state.withLock { $0.windows[1002]?.title = "New editor title" }
        fixture.desktop.publish()
        await wait { button.titleLabel.stringValue == "New editor title" }
        button.mouseUp(with: event(.leftMouseUp, center()))
        await wait { fixture.desktop.state.withLock { $0.focused == 1002 } }
    }

    func testCombinedButtonCancelsHeldPressWhenOneActionTargetChanges() async throws {
        let fixture = Fixture(width: 150)
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let id = try XCTUnwrap(content.layoutResult.buttons.first { $0.isCombined }?.id)
        let button = try XCTUnwrap(content.buttonViews[id])
        func center() -> CGPoint {
            button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }

        button.mouseDown(with: event(.leftMouseDown, center()))
        fixture.desktop.state.withLock { $0.windows[1002]?.groupID = "replacement-seat" }
        fixture.desktop.publish()
        await wait { content.groups.flatMap(\.windows).contains { $0.id == "replacement-seat" } }
        XCTAssertTrue(content.buttonViews[id] === button)
        button.mouseUp(with: event(.leftMouseUp, center()))
        XCTAssertFalse(fixture.popup.isPresented)
        fixture.popup.dismiss()

        button.mouseDown(with: event(.leftMouseDown, center()))
        button.mouseUp(with: event(.leftMouseUp, center()))
        XCTAssertTrue(fixture.popup.isPresented)
    }

    func testSpaceChangeBlocksOldButtonsUntilAConfirmedProjection() async throws {
        let notifications = NotificationCenter()
        let calls = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let store = TaskbarSpaceStore(read: { requests in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 2 {
                _ = gate.wait(timeout: .now() + 3)
                return nil
            }
            let space = call == 1 ? 1 : 2
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: space)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map {
                    ($0.identity, Set([$0.identity.windowID == 2001 ? 2 : 1]))
                }))
        }, notifications: notifications, pollInterval: 0)
        let fixture = Fixture(spaces: store)
        defer { gate.signal(); store.stop(); fixture.stop() }
        await ready(fixture)
        store.start(snapshots: fixture.runtime.$snapshot.eraseToAnyPublisher())
        let content = fixture.view.taskbarContent
        await wait { content.groups.flatMap(\.windows).count == 2 }
        let old = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        let point = old.convert(CGPoint(x: old.bounds.midX, y: old.bounds.midY), to: nil)
        var toggles: [String] = []
        content.actions.toggle = { toggles.append($0.windowID.rawValue) }
        old.clickForTesting()
        XCTAssertEqual(toggles, ["editor-a"])
        toggles.removeAll()

        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await wait { calls.withLock { $0 } == 2 }
        XCTAssertTrue(content.buttonViews["window:tabgrp-editor-a"] === old)
        old.mouseDown(with: event(.leftMouseDown, point))
        old.mouseUp(with: event(.leftMouseUp, point))
        old.rightMouseDown(with: event(.rightMouseDown, point))
        XCTAssertNil(fixture.menu.menu)
        old.clickForTesting()
        XCTAssertEqual(toggles, [])

        let pendingRead = store.pendingWorkForTesting
        gate.signal()
        for task in pendingRead { await task.value }
        old.clickForTesting()
        XCTAssertEqual(toggles, [])

        store.refresh()
        await wait { content.groups.flatMap(\.windows).map(\.id) == ["tabgrp-browser-c"] }
        let current = try XCTUnwrap(content.buttonViews["window:tabgrp-browser-c"])
        current.clickForTesting()
        XCTAssertEqual(toggles, ["browser-c"])
    }

    func testSpaceChangesKeepButtonsUsableWithoutAnAvailableLayout() async throws {
        let notifications = NotificationCenter()
        let store = TaskbarSpaceStore(read: { _ in nil }, notifications: notifications, pollInterval: 0)
        let fixture = Fixture(spaces: store)
        defer { store.stop(); fixture.stop() }
        await ready(fixture)
        store.start(snapshots: fixture.runtime.$snapshot.eraseToAnyPublisher())
        await drainTaskbarUpdates()
        for task in store.pendingWorkForTesting { await task.value }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for task in store.pendingWorkForTesting { await task.value }

        let content = fixture.view.taskbarContent
        var toggles: [String] = []
        content.actions.toggle = { toggles.append($0.windowID.rawValue) }
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        button.clickForTesting()
        XCTAssertEqual(toggles, ["editor-a"])
    }

    func testInventoryDoesNotAssignAnotherProcessesAXWindowToTheEnumeratingApplication() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.enumeratedWindows[-41000] = [1001, 2001] }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        guard case .success(let windows) = result else { return XCTFail("Valid native windows must remain readable") }
        XCTAssertEqual(windows.compactMap(\.cgWindowID), [1001])
        XCTAssertEqual(windows.map(\.pid), [-41000])
    }

    func testUnreadNativeWindowOwnerDoesNotBecomeAnEmptySuccessfulInventory() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.enumeratedWindows[-41000] = [1001]; $0.unreadOwners = [1001] }
        let result = AXWindowReader(accessibility: desktop).inventoryWindows(forPID: -41000, messagingTimeout: 0.1)
        guard case .unread = result else { return XCTFail("Unread ownership must preserve existing inventory") }
    }

    func testButtonMinimizesThenRestoresTheSameWindowWhenCGEntryIsMissing() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        try press("editor-a", fixture)
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .minimized }
        fixture.desktop.state.withLock { _ = $0.omittedCG.insert(1001) }
        try press("editor-a", fixture)
        await wait { fixture.desktop.state.withLock { $0.windows[1001]?.status == .active } }
        await wait { fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.isActiveWindow == true }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes.filter { $0 == "1001:AXMinimized" }.count }, 2)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .inactive)
        XCTAssertEqual(fixture.view.taskbarContent.layoutResult.buttons.flatMap(\.windowIDs), ["tabgrp-editor-a", "tabgrp-editor-b", "tabgrp-browser-c"])
    }

    func testDelayedRestorationKeepsTheButtonActiveUntilExactFocusArrives() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock {
            $0.windows[1001]?.status = .minimized
            $0.focused = nil
            $0.denyFocus = true
        }
        fixture.desktop.publish()
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .minimized }
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"])
        var publishedFailure = false
        let feedback = fixture.runtime.debugState.$feedbackEntriesByWindowID.sink {
            if $0["editor-a"]?.phase == .failure { publishedFailure = true }
        }
        defer { feedback.cancel() }
        try press("editor-a", fixture)
        await drainTaskbarUpdates()
        XCTAssertTrue(button.isActiveWindow)
        let completion = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            fixture.desktop.state.withLock { $0.denyFocus = false }
            return fixture.desktop.setFrontmost(pid: -41000, windowID: 1001, mode: 0)
        }
        var inactiveDuringRestore = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status != .active {
            inactiveDuringRestore = inactiveDuringRestore || !button.isActiveWindow
            try await Task.sleep(for: .milliseconds(2))
        }
        let focused = await completion.value
        XCTAssertTrue(focused)
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        await drainTaskbarUpdates()
        XCTAssertFalse(inactiveDuringRestore)
        XCTAssertFalse(publishedFailure)
        XCTAssertTrue(button.isActiveWindow)
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"]?.phase, .success)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .inactive)
    }

    func testCombinedListActivatesOnlyTheChosenSiblingThroughTheProductionExecutor() async throws {
        let fixture = Fixture(width: 150); defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews.values.first { $0.isCombined })
        button.clickForTesting()
        let list = try XCTUnwrap(fixture.popup.content as? TaskbarWindowListView)
        let rows = try (0..<list.tableView.numberOfRows).map { index in
            list.tableView.scrollRowToVisible(index)
            list.layoutSubtreeIfNeeded()
            return try XCTUnwrap(list.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TaskbarWindowListRow)
        }
        XCTAssertEqual(rows.map(\.item.id), ["tabgrp-editor-a", "tabgrp-editor-b"])
        try list.clickRowForTesting(at: 1)
        await wait { fixture.desktop.state.withLock { $0.focused == 1002 } }
        await wait { fixture.view.taskbarContent.groups.flatMap(\.windows).first { $0.id == "tabgrp-editor-b" }?.isActive == true }
        XCTAssertFalse(fixture.popup.isPresented)
    }

    func testContextCloseRemovesOnlyItsWindowAndKeepsTheApplicationRunning() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 0)
        await wait { fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"] == nil }
        XCTAssertEqual(fixture.desktop.state.withLock { Set($0.windows.keys) }, [1001, 2001])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.terminated.isEmpty })
    }

    private func replaceEditorWindowBeforePresenterRefresh(
        _ fixture: Fixture, action: @escaping @MainActor () -> Void
    ) async {
        await drainTaskbarUpdates()
        fixture.desktop.state.withLock { $0.windows[1002]?.groupID = "replacement-seat" }
        fixture.desktop.publish()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let id = WindowID(rawValue: "editor-b")
                XCTAssertEqual(fixture.runtime.snapshot.windows[id]?.groupID, "replacement-seat")
                XCTAssertNotNil(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"])
                XCTAssertNil(fixture.view.taskbarContent.buttonViews["window:replacement-seat"])
                action()
                continuation.resume()
            }
        }
    }

    func testStaleButtonPressCannotTargetReplacementBeforePresenterRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let previous = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-b"])
        await replaceEditorWindowBeforePresenterRefresh(fixture) {
            previous.clickForTesting()
            XCTAssertNil(fixture.runtime.optimisticStatesByWindowID["editor-b"])
            XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
        }
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)

        await wait { content.buttonViews["window:replacement-seat"] != nil }
        let current = try XCTUnwrap(content.buttonViews["window:replacement-seat"])
        current.clickForTesting()
        await wait { fixture.desktop.state.withLock { $0.focused == 1002 } }
    }

    func testStaleContextCloseCannotTargetReplacementBeforePresenterRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let previous = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-b"])
        previous.onContextMenu?(event(.rightMouseDown, .zero))
        let menu = try XCTUnwrap(fixture.menu.menu)
        await replaceEditorWindowBeforePresenterRefresh(fixture) {
            menu.performActionForItem(at: 0)
            XCTAssertNil(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"])
            XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
        }
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.groupID }, "replacement-seat")

        await wait { content.buttonViews["window:replacement-seat"] != nil }
        let current = try XCTUnwrap(content.buttonViews["window:replacement-seat"])
        current.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        await wait { fixture.desktop.state.withLock { $0.windows[1002] == nil } }
    }

    func testMovedWindowRejectsStaleButtonAndMenuOnItsPreviousDisplay() async throws {
        let fixture = Fixture(displayUUID: "left")
        defer { fixture.stop() }
        await ready(fixture)
        await drainTaskbarUpdates()
        let content = fixture.view.taskbarContent
        let buttonID = "window:tabgrp-editor-b"
        let previous = try XCTUnwrap(content.buttonViews[buttonID])
        previous.onContextMenu?(event(.rightMouseDown, .zero))
        let menu = try XCTUnwrap(fixture.menu.menu)
        fixture.desktop.state.withLock { $0.windows[1002]?.displayUUID = "right" }
        fixture.desktop.publish()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let id = WindowID(rawValue: "editor-b")
                XCTAssertEqual(fixture.runtime.snapshot.windows[id]?.displayUUID, "right")
                XCTAssertTrue(content.buttonViews[buttonID] === previous)
                menu.performActionForItem(at: 0)
                XCTAssertNil(fixture.runtime.debugState.feedbackEntriesByWindowID[id.rawValue])
                previous.clickForTesting()
                XCTAssertNil(fixture.runtime.optimisticStatesByWindowID[id.rawValue])
                XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
                continuation.resume()
            }
        }
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        await wait { content.buttonViews[buttonID] == nil }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.displayUUID }, "right")
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)
    }

    func testStaleMenuCannotCloseATabThatLostRepresentation() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        fixture.desktop.state.withLock { $0.windows[1002]?.groupID = "tabgrp-editor-a" }
        fixture.desktop.publish()
        await wait { content.groups.flatMap(\.windows).count == 2 }
        await drainTaskbarUpdates()
        let buttonID = "window:tabgrp-editor-a"
        let button = try XCTUnwrap(content.buttonViews[buttonID])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        let menu = try XCTUnwrap(fixture.menu.menu)
        fixture.desktop.state.withLock {
            $0.windows[1001]?.status = .inactive
            $0.windows[1002]?.status = .active
            $0.focused = 1002
        }
        fixture.desktop.publish()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                XCTAssertEqual(fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-b")]?.status, .active)
                XCTAssertEqual(content.groups.flatMap(\.windows)
                    .first { $0.id == "tabgrp-editor-a" }?.item.actionWindowID, "editor-a")
                menu.performActionForItem(at: 0)
                XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
                continuation.resume()
            }
        }
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1001] })
        await wait {
            content.groups.flatMap(\.windows).first { $0.id == "tabgrp-editor-a" }?.item.actionWindowID == "editor-b"
        }
        button.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        await wait { fixture.desktop.state.withLock { $0.windows[1002] == nil } }
    }

    func testInFlightTaskbarCloseIsCancelledWhenItsSpaceChanges() async throws {
        try await verifyInFlightTaskbarCloseIsCancelledWhenItsSpaceChanges(hasLayout: true)
    }

    func testInFlightTaskbarCloseIsCancelledWhenSpaceLayoutIsUnavailable() async throws {
        try await verifyInFlightTaskbarCloseIsCancelledWhenItsSpaceChanges(hasLayout: false)
    }

    private func verifyInFlightTaskbarCloseIsCancelledWhenItsSpaceChanges(hasLayout: Bool) async throws {
        let notifications = NotificationCenter()
        let currentSpace = Mutex(1)
        let store = TaskbarSpaceStore(read: { requests in
            guard hasLayout else { return nil }
            let space = currentSpace.withLock { $0 }
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: space)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map {
                    ($0.identity, Set([$0.identity.windowID == 2001 ? 2 : 1]))
                }))
        }, notifications: notifications, pollInterval: 0)
        let fixture = Fixture(displayUUID: "left", spaces: store)
        let gate = BehaviorReadGate(attribute: kAXCloseButtonAttribute as String)
        defer { gate.release.signal(); store.stop(); fixture.stop() }
        await ready(fixture)
        store.start(snapshots: fixture.runtime.$snapshot.eraseToAnyPublisher())
        let content = fixture.view.taskbarContent
        if hasLayout { await wait { content.groups.flatMap(\.windows).count == 2 } }
        await drainTaskbarUpdates()
        for task in store.pendingWorkForTesting { await task.value }

        fixture.desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        await wait { gate.entered.withLock { $0 } }
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"]?.phase, .pending)

        currentSpace.withLock { $0 = 2 }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertNil(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"])
        gate.release.signal()
        for task in fixture.runtime.pendingActionsForTesting { await task.value }

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes.filter { $0.hasSuffix(":close") } }, [])
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1001] })
    }

    func testQueuedTaskbarCloseIsCancelledWhenItsSpaceChanges() async throws {
        let notifications = NotificationCenter()
        let currentSpace = Mutex(1)
        let store = TaskbarSpaceStore(read: { requests in
            let space = currentSpace.withLock { $0 }
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: space)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map {
                    ($0.identity, Set([$0.identity.windowID == 2001 ? 2 : 1]))
                }))
        }, notifications: notifications, pollInterval: 0)
        let fixture = Fixture(displayUUID: "left", spaces: store)
        let gate = BehaviorReadGate(attribute: kAXCloseButtonAttribute as String)
        defer { gate.release.signal(); store.stop(); fixture.stop() }
        await ready(fixture)
        store.start(snapshots: fixture.runtime.$snapshot.eraseToAnyPublisher())
        let content = fixture.view.taskbarContent
        await wait { content.groups.flatMap(\.windows).map(\.id) == ["tabgrp-editor-a", "tabgrp-editor-b"] }

        fixture.desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        fixture.runtime.close(windowID: "editor-a")
        await wait { gate.entered.withLock { $0 } }
        let second = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-b"])
        second.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"]?.phase, .pending)

        currentSpace.withLock { $0 = 2 }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await wait { content.groups.flatMap(\.windows).map(\.id) == ["tabgrp-browser-c"] }
        gate.release.signal()
        for task in fixture.runtime.pendingActionsForTesting { await task.value }

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes.filter { $0.hasSuffix(":close") } }, ["1001:close"])
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1002] })
        XCTAssertNil(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"])
    }

    func testQueuedTaskbarCloseIsCancelledWhenItsPanelHidesWithoutASpaceChange() async throws {
        let fixture = Fixture()
        let gate = BehaviorReadGate(attribute: kAXCloseButtonAttribute as String)
        defer { gate.release.signal(); fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        fixture.runtime.close(windowID: "editor-a")
        await wait { gate.entered.withLock { $0 } }
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"]?.phase, .pending)

        fixture.presenter.setPanelVisible(false)
        XCTAssertNil(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"])
        gate.release.signal()
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1002] })
    }

    func testRemovingThePanelCancelsACloseBeforeTheNativeEffect() async throws {
        let fixture = Fixture()
        let gate = BehaviorReadGate(attribute: kAXCloseButtonAttribute as String)
        defer { gate.release.signal(); fixture.stop() }
        await ready(fixture)
        let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 0,
            identifiedDisplayUUIDs: [], attributionTable: .empty))
        let coordinator = PanelCoordinator(placement: .fixed(displayUUID: "left"), overlaySpaceHost: nil,
            runtime: fixture.runtime, stripOrderStore: StripOrderStore(), displayTopologyStore: topology,
            screenProvider: { [] }, mainScreenProvider: { nil })
        coordinator.taskbarPresenter = fixture.presenter
        coordinator.taskbarView = fixture.view
        fixture.desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        await wait { gate.entered.withLock { $0 } }
        coordinator.tearDown()
        gate.release.signal()
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1002] })
    }

    func testStaleMenuCannotCloseAWindowMovedToAnotherSpace() async throws {
        let windowSpace = Mutex(1)
        let store = TaskbarSpaceStore(read: { requests in
            let space = windowSpace.withLock { $0 }
            return WindowSpaceSnapshot(
                layouts: ["left": .init(orderedSpaceIDs: [1, 2], fullscreenSpaceIDs: [], currentSpaceID: 1)],
                memberships: Dictionary(uniqueKeysWithValues: requests.map {
                    ($0.identity, Set([$0.identity.windowID == 1002 ? space : 1]))
                }))
        }, notifications: NotificationCenter(), pollInterval: 0)
        let fixture = Fixture(displayUUID: "left", spaces: store)
        defer { store.stop(); fixture.stop() }
        await ready(fixture)
        store.start(snapshots: fixture.runtime.$snapshot.eraseToAnyPublisher())
        let identity = try XCTUnwrap(StripItem.openWindows(from: fixture.runtime.snapshot)
            .first { $0.id == "tabgrp-editor-b" }?.spaceIdentity)
        await wait { store.snapshot.memberships[identity] == [1] }
        await drainTaskbarUpdates()
        let revision = store.confirmedSpaceRevision
        let content = fixture.view.taskbarContent
        let buttonID = "window:tabgrp-editor-b"
        let button = try XCTUnwrap(content.buttonViews[buttonID])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        let menu = try XCTUnwrap(fixture.menu.menu)
        windowSpace.withLock { $0 = 2 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let deadline = ContinuousClock.now + .seconds(2)
            @MainActor func attemptWhenMembershipChanges() {
                if store.snapshot.memberships[identity] == [2] {
                    XCTAssertEqual(store.confirmedSpaceRevision, revision)
                    XCTAssertTrue(content.buttonViews[buttonID] === button)
                    menu.performActionForItem(at: 0)
                    XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
                    continuation.resume()
                } else if ContinuousClock.now < deadline {
                    DispatchQueue.main.async { attemptWhenMembershipChanges() }
                } else {
                    XCTFail("Space membership did not change")
                    continuation.resume()
                }
            }
            store.refresh()
            attemptWhenMembershipChanges()
        }
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        await wait { content.buttonViews[buttonID] == nil }
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1002] })
    }

    func testImplicitPopupOnAnotherDisplayCannotDismissClickedList() async throws {
        let topology = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["left", "right"],
                                               attributionTable: .empty)
        let spaces = TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0)
        let runtime = AppRuntime(tracker: BehaviorInventory(BehaviorDesktop()))
        let ordering = StripOrderStore(defaults: UserDefaults(suiteName: "DeskMote.Popup.\(UUID())")!,
                                      bootTimeProvider: { 1 })
        var popups: [String: BehaviorPopup] = [:]
        var completedDelays = 0
        let orchestrator = TaskbarScreenOrchestrator(runtime: runtime, stripOrderStore: ordering,
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology), spaceStore: spaces,
            overlaySpaceHost: nil, topologySnapshotProvider: { topology }, startCoordinator: { coordinator in
                guard let key = coordinator.fixedUnitDisplayUUID else { return false }
                let popup = BehaviorPopup(presentationPanel: NSPanel(contentRect: .zero, styleMask: .borderless,
                                                                       backing: .buffered, defer: true))
                popups[key] = popup
                return coordinator.setupDockPanel { frame in
                    TaskbarView(frame: frame, popup: popup, contextMenu: BehaviorMenu(),
                                delay: { _ in completedDelays += 1 })
                }
            })
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        await drainTaskbarUpdates()
        for unit in orchestrator.units {
            let taskbar = try XCTUnwrap(unit.coordinator.taskbarView)
            let content = taskbar.taskbarContent
            let key = try XCTUnwrap(unit.key)
            let windows = (1...2).map { number in
                let id = WindowID(rawValue: "\(key)-\(number)")
                let record = WindowRecord(id: id, appID: AppID(rawValue: key), pid: -41000, bundleIdentifier: nil,
                    title: "Document window number \(number) on \(key)", bounds: nil,
                    status: .inactive, cgWindowID: UInt32(number))
                return TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
            }
            taskbar.frame.size.width = 120
            content.frame.size.width = 120
            content.update(groups: [.init(id: key, name: key, windows: windows)])
        }
        let left = try XCTUnwrap(orchestrator.units.first { $0.key == "left" }?.coordinator.taskbarView?.taskbarContent)
        let right = try XCTUnwrap(orchestrator.units.first { $0.key == "right" }?.coordinator.taskbarView?.taskbarContent)
        let leftPopup = try XCTUnwrap(popups["left"])
        let rightPopup = try XCTUnwrap(popups["right"])
        try XCTUnwrap(left.buttonViews["group:left"]).clickForTesting()
        let leftList = try XCTUnwrap(leftPopup.content)

        right.scheduleFileHover(buttonID: "group:right")
        await wait { completedDelays == 1 }
        XCTAssertTrue(leftPopup.content === leftList)
        XCTAssertFalse(rightPopup.isPresented)

        try XCTUnwrap(right.buttonViews["group:right"]).clickForTesting()
        XCTAssertFalse(leftPopup.isPresented)
        XCTAssertTrue(rightPopup.isPresented)
    }

    func testCombinedCloseClosesAllRepresentedWindowsWithoutQuittingOrClosingAnotherApp() async throws {
        let fixture = Fixture(width: 150); defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews.values.first { $0.isCombined })
        button.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 0)
        await wait { fixture.view.taskbarContent.groups.flatMap(\.windows).map(\.id) == ["tabgrp-browser-c"] }
        XCTAssertEqual(fixture.desktop.state.withLock { Array($0.windows.keys) }, [2001])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.terminated.isEmpty })
    }

    private func helperFixture(generation: Int64 = 10, origin: String = "/Applications/Browser.app") async -> Fixture {
        let fixture = Fixture()
        await ready(fixture)
        let owner = ApplicationIdentity(pid: -42000, bundleIdentifier: "test.Browser",
            origin: ApplicationOrigin(bundleURL: URL(fileURLWithPath: origin))!,
            generation: ProcessGeneration(timeval(tv_sec: Int(generation), tv_usec: 1)))
        fixture.desktop.state.withLock {
            $0.windows[1001]?.owningApplication = owner
            $0.windows[1002]?.owningApplication = owner
            $0.windows.removeValue(forKey: 2001)
            $0.exposesSystemFocus = true
        }
        fixture.desktop.publish()
        await wait { fixture.view.taskbarContent.groups.count == 1 && fixture.view.taskbarContent.groups[0].windows.count == 2 }
        return fixture
    }

    func testHelperGroupQuitTargetsOnlyTheVerifiedMainApplication() async throws {
        let fixture = await helperFixture(); defer { fixture.stop() }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        let menu = try XCTUnwrap(fixture.menu.menu)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.quitAttempts }, [-42000])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.terminated }, [-42000])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
    }

    func testHelperQuitRejectsAReplacedMainApplication() async throws {
        let fixture = await helperFixture(generation: 9); defer { fixture.stop() }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 1)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.quitAttempts.isEmpty })
    }

    func testHelperQuitRejectsADifferentMainApplicationOrigin() async throws {
        let fixture = await helperFixture(origin: "/Applications/Other.app"); defer { fixture.stop() }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 1)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.quitAttempts.isEmpty })
    }

    func testActiveHelperWindowMinimizesWhenItsMainApplicationIsFrontmost() async throws {
        let fixture = await helperFixture(); defer { fixture.stop() }
        fixture.desktop.state.withLock { $0.frontmostPIDOverride = -42000 }
        try press("editor-a", fixture)
        await wait { fixture.desktop.state.withLock { $0.windows[1001]?.status == .minimized } }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes }, ["1001:AXMinimized"])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .inactive)
    }

    func testHelperWindowRestoresAfterMinimizingWithTheMainApplicationFrontmost() async throws {
        let fixture = await helperFixture(); defer { fixture.stop() }
        fixture.desktop.state.withLock { $0.frontmostPIDOverride = -42000 }
        try press("editor-a", fixture)
        await wait { fixture.desktop.state.withLock { $0.windows[1001]?.status == .minimized } }
        try press("editor-a", fixture)
        await wait { fixture.desktop.state.withLock { $0.windows[1001]?.status == .active } }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes }, ["1001:AXMinimized", "1001:AXMinimized", "1001:AXMain"])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .inactive)
    }

    func testHelperWindowCloseKeepsItsSiblingAndMainApplicationRunning() async throws {
        let fixture = await helperFixture(); defer { fixture.stop() }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"]?.onContextMenu?(event(.rightMouseDown, .zero))
        try XCTUnwrap(fixture.menu.menu).performActionForItem(at: 0)
        await wait { fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"] == nil }
        XCTAssertEqual(fixture.desktop.state.withLock { Set($0.windows.keys) }, [1001])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes }, ["1002:close"])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.terminated.isEmpty })
    }

    func testNativeQuitReachesOnlyTheMatchingApplicationOnce() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        let button = try XCTUnwrap(fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"])
        button.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 1)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.terminated }, [-41000])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows.count }, 3)
    }

    func testChangedProcessGenerationPreventsQuitAndWindowMutation() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.generation = ProcessGeneration(timeval(tv_sec: 20, tv_usec: 1)) }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 1)
        try press("editor-a", fixture)
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        XCTAssertTrue(fixture.desktop.state.withLock { $0.terminated.isEmpty && $0.writes.isEmpty })
    }

    func testRestoreCanFocusTheSameAXElementWhenItsNativeNumberChanges() throws {
        let desktop = BehaviorDesktop()
        let element = try XCTUnwrap(desktop.elements[1001])
        let previous = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        desktop.state.withLock {
            $0.windows[1001] = WindowRecord(id: previous.id, appID: previous.appID, pid: previous.pid,
                bundleIdentifier: previous.bundleIdentifier, title: previous.title, bounds: previous.bounds,
                status: .minimized, cgWindowID: previous.cgWindowID, groupID: previous.groupID,
                displayUUID: previous.displayUUID, applicationOrigin: previous.applicationOrigin,
                processGeneration: previous.processGeneration, actionTarget: WindowActionTarget(element: AXElementKey(e: element)))
            $0.focused = 2001
            $0.afterAttributeWrite = { id, attribute in
                if id == 1001, attribute == (kAXMinimizedAttribute as String) {
                    desktop.state.withLock {
                        $0.nativeWindowIDOverrides[id] = 1009
                        $0.windows[id]?.cgWindowID = 1009
                    }
                }
            }
        }
        defer { desktop.state.withLock { $0.afterAttributeWrite = nil } }
        desktop.publish()
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertTrue(executor.execute(.init(kind: .activateWindow, windowID: previous.id),
                                       snapshot: desktop.values.value, forcedMinimizedPrior: false,
                                       cancellation: OperationCancellation(), onHandoffActivePrediction: nil))
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.cgWindowID }, 1009)
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1001)
    }

    func testWrongCGOwnerPreventsMutationDespiteMatchingAccessibilityHandle() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.cgOwnerOverride = -43000 }
        try press("editor-a", fixture)
        let pending = fixture.runtime.pendingActionsForTesting
        XCTAssertEqual(pending.count, 1)
        for task in pending { await task.value }
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"]?.phase, .failure)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.status }, .active)
    }

    func testCloseRejectsAnAccessibilityHandleNowPointingToASameProcessSibling() {
        let desktop = BehaviorDesktop()
        let reads = Mutex(0)
        desktop.state.withLock {
            $0.windowIDAttributes[1001] = 1002
            $0.beforeWindowIDRead = { id in
                guard id == 1001 else { return }
                let count = reads.withLock { $0 += 1; return $0 }
                desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = count == 1 ? 1002 : nil }
            }
        }
        defer { desktop.state.withLock { $0.beforeWindowIDRead = nil } }
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        let success = executor.execute(.init(kind: .closeWindow, windowID: .init(rawValue: "editor-b")),
            snapshot: desktop.values.value, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffActivePrediction: nil)

        XCTAssertFalse(success)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { Set($0.windows.keys) }, [1001, 1002, 2001])
    }

    func testCloseFindsRetainedAXWindowAfterSameCGIDFocusedAlias() throws {
        for (fastCapture, mainWindow, expectedInventoryReads): (String, CGWindowID, Int) in
            [("1", 1001, 1), ("1", 1002, 0), ("0", 1001, 1)] {
            let desktop = BehaviorDesktop()
            let record = try XCTUnwrap(desktop.state.withLock { $0.windows[1002] })
            let element = try XCTUnwrap(desktop.elements[1002])
            let inventoryReads = Mutex(0)
            desktop.state.withLock {
                $0.nativeWindowIDOverrides[1001] = 1002
                $0.publishedMainWindows[record.pid] = mainWindow
                $0.beforeInventoryRead = { _ in inventoryReads.withLock { $0 += 1 } }
            }
            let target = WindowRecord(id: record.id, appID: record.appID, pid: record.pid,
                bundleIdentifier: record.bundleIdentifier, title: record.title, bounds: record.bounds,
                status: record.status, cgWindowID: record.cgWindowID, processGeneration: record.processGeneration,
                actionTarget: WindowActionTarget(element: AXElementKey(e: element)))
            let snapshot = DockSnapshot(windows: [target.id: target], orderedWindowIDs: [target.id])
            let executor = PlatformActionExecutor(switches: .init(environment: [
                "DOCK_AX_ELEMENT_CACHE": "0", "DOCK_FAST_WINDOW_HANDLE": fastCapture,
            ]), reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

            XCTAssertTrue(executor.execute(.init(kind: .closeWindow, windowID: target.id),
                snapshot: snapshot, forcedMinimizedPrior: false,
                cancellation: OperationCancellation(), onHandoffActivePrediction: nil))
            XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1002:close"])
            XCTAssertEqual(desktop.state.withLock { Set($0.windows.keys) }, [1001, 2001])
            XCTAssertEqual(inventoryReads.withLock { $0 }, expectedInventoryReads)
        }
    }

    func testCloseRejectsAReplacementAXWindowBeforeItsSameCGIDSnapshotPublishes() throws {
        let desktop = BehaviorDesktop()
        let previousRecord = try XCTUnwrap(desktop.state.withLock { $0.windows[1002] })
        let pid = previousRecord.pid
        let cgID = try XCTUnwrap(previousRecord.cgWindowID)
        let cgSnapshot = AppTrackerCGWindowSnapshot(allWindowIDs: [cgID], onScreenWindowIDs: [cgID],
            windowIDsByPID: [pid: [cgID]], alphaByWindowID: [cgID: 1])
        let tracker = AppTracker()
        defer { tracker.stop() }
        tracker.installFixtureForTesting(AppEntry(pid: pid, bundleIdentifier: previousRecord.bundleIdentifier,
            appName: "Editor", activationPolicy: .regular, executablePath: nil, windowsByID: [:], windowOrder: [],
            isHidden: false, processGeneration: previousRecord.processGeneration))
        func observe(_ element: AXUIElement) {
            let window = AXWindowSnapshot(pid: pid, cgWindowID: cgID, titleRead: .value(previousRecord.title),
                bounds: previousRecord.bounds, role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                isMinimized: false, isFocusedWindow: false, element: element, isMinimizedRead: false)
            tracker.reconcileFixtureForTesting(pid: pid, cgSnapshot: cgSnapshot, now: Date(), eligible: [window],
                                               readOutcome: .success(count: 1))
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgID])
        }
        observe(AXUIElementCreateApplication(-89999))
        let previousSnapshot = tracker.snapshot
        let id = try XCTUnwrap(previousSnapshot.orderedWindowIDs.first)
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let request = PlatformActionRequest(kind: .closeWindow, windowID: id)

        XCTAssertFalse(executor.execute(request, snapshot: previousSnapshot, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffActivePrediction: nil))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertNotNil(desktop.state.withLock { $0.windows[cgID] })

        observe(try XCTUnwrap(desktop.elements[cgID]))
        XCTAssertTrue(executor.execute(request, snapshot: tracker.snapshot, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffActivePrediction: nil))
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["\(cgID):close"])
    }

    func testStaleHiddenFinderCommandDoesNotUnhideTheApplication() throws {
        let desktop = BehaviorDesktop(editorBundleIdentifier: "com.apple.finder")
        let source = try XCTUnwrap(desktop.state.withLock { $0.windows[1002] })
        let element = try XCTUnwrap(desktop.elements[1002])
        let record = WindowRecord(id: source.id, appID: source.appID, pid: source.pid,
                                  bundleIdentifier: source.bundleIdentifier, title: source.title, bounds: source.bounds,
                                  status: .hidden, cgWindowID: 1002, processGeneration: source.processGeneration,
                                  actionTarget: WindowActionTarget(element: AXElementKey(e: element)))
        desktop.state.withLock { _ = $0.hiddenApplications.insert(source.pid) }
        desktop.replaceElement(for: 1002)
        let reader = AXWindowReader(accessibility: desktop)
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
                                               reader: reader, system: desktop, focusBackend: desktop)
        let snapshot = DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id])
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id), snapshot: snapshot,
                                        forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                                        onHandoffActivePrediction: nil))
        XCTAssertTrue(desktop.state.withLock { $0.unhideAttempts.isEmpty })
    }

    func testWindowLabRejectsAReplacementAfterCapturingACommandCandidate() throws {
        let desktop = BehaviorDesktop()
        let original = try XCTUnwrap(desktop.elements[1002])
        let source = try XCTUnwrap(desktop.state.withLock { $0.windows[1002] })
        let record = WindowRecord(id: source.id, appID: source.appID, pid: source.pid,
                                  bundleIdentifier: source.bundleIdentifier, title: source.title, bounds: source.bounds,
                                  status: source.status, cgWindowID: source.cgWindowID,
                                  processGeneration: source.processGeneration,
                                  actionTarget: WindowActionTarget(element: AXElementKey(e: original)))
        let reader = AXWindowReader(accessibility: desktop)
        XCTAssertTrue(WindowLabInput.permitsCommand(record, pid: record.pid, windowID: 1002,
                                                    element: original, reader: reader, system: desktop))
        desktop.replaceElement(for: 1002)
        let replacement = try XCTUnwrap(reader.captureHandle(forPID: record.pid, cgWindowID: 1002)?.element)
        XCTAssertFalse(WindowLabInput.permitsCommand(record, pid: record.pid, windowID: 1002,
                                                     element: replacement, reader: reader, system: desktop))
    }

    func testUncapturableWindowDoesNotActivateAnotherWindowAsFallback() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { _ = $0.missingWindows.insert(1002) }
        try press("editor-b", fixture)
        await wait { fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"]?.phase == .failure }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
    }

    func testActivationDoesNotFocusAReplacementAXWindowWithTheSameCGID() throws {
        let desktop = BehaviorDesktop()
        let replacement = try XCTUnwrap(desktop.state.withLock { $0.windows[2001] })
        let original = WindowRecord(id: replacement.id, appID: replacement.appID, pid: replacement.pid,
            bundleIdentifier: replacement.bundleIdentifier, title: replacement.title, bounds: replacement.bounds,
            status: replacement.status, cgWindowID: replacement.cgWindowID, processGeneration: replacement.processGeneration,
            actionTarget: WindowActionTarget(element: AXElementKey(e: AXUIElementCreateApplication(-89999))))
        let snapshot = DockSnapshot(windows: [original.id: original], orderedWindowIDs: [original.id])
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: original.id),
            snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffActivePrediction: nil))
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1001)
        XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, [])
    }

    func testStoppingDuringNativeHandleCapturePreventsTheFollowingWindowWrite() async {
        let fixture = Fixture()
        let gate = BehaviorReadGate()
        defer { gate.release.signal(); fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        fixture.runtime.activate(windowID: "editor-b")
        await wait { gate.entered.withLock { $0 } }
        let pending = fixture.runtime.pendingActionsForTesting
        fixture.runtime.stop()
        gate.release.signal()
        for task in pending { await task.value }
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)
        XCTAssertTrue(fixture.runtime.optimisticStatesByWindowID.isEmpty)
    }

    func testCancelledNativeCaptureKeepsItsStagesOutOfTheReplacementClickTrace() async throws {
        let desktop = BehaviorDesktop()
        let reader = AXWindowReader(accessibility: desktop)
        let switches = ActionExecutionSwitches(environment: [
            DebugSwitch.clickTrace.rawValue: "1",
            DebugSwitch.axElementCache.rawValue: "0",
            DebugSwitch.fastWindowHandle.rawValue: "0"
        ])
        let runtime = AppRuntime(tracker: BehaviorInventory(desktop),
            actionExecutor: PlatformActionExecutor(switches: switches, reader: reader,
                                                  system: desktop, focusBackend: desktop),
            isAppFrontmost: { desktop.app($0)?.isActive == true })
        let lines = Mutex<[Data]>([])
        let trace = ClickLatencyTrace.Runtime(writeLine: { line in lines.withLock { $0.append(line) } })
        runtime.clickLatencyTrace = trace
        runtime.start()
        let gate = BehaviorReadGate(attribute: kAXWindowsAttribute as String)
        defer { gate.release.signal(); runtime.stop() }
        let id = WindowID(rawValue: "editor-b")
        await wait { runtime.snapshot.windows[id] != nil }
        let record = try XCTUnwrap(runtime.snapshot.windows[id])
        let invalidations = PassthroughSubject<Void, Never>()
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        runtime.trigger(.activate(id), expected: record.actionIdentity,
                        projectionInvalidations: invalidations.eraseToAnyPublisher(), isProjectionCurrent: { true })
        await wait { gate.entered.withLock { $0 } }

        invalidations.send()
        runtime.close(windowID: id.rawValue)
        desktop.state.withLock { $0.generationsByPID[record.pid] = .init(timeval(tv_sec: 99, tv_usec: 0)) }
        gate.release.signal()
        for action in runtime.pendingActionsForTesting { await action.value }
        XCTAssertFalse(gate.timedOut.withLock { $0 })

        func records() throws -> [[String: Any]] {
            trace.flush()
            return try lines.withLock { $0 }.map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            }
        }
        let interrupted = try records()
        XCTAssertEqual(interrupted.count, 2)
        let cancelled = try XCTUnwrap(interrupted.first)
        let replacement = try XCTUnwrap(interrupted.dropFirst().first)
        XCTAssertEqual(cancelled["kind"] as? String, "activateWindow")
        XCTAssertEqual(cancelled["success"] as? Bool, false)
        XCTAssertEqual(replacement["kind"] as? String, "closeWindow")
        XCTAssertEqual(replacement["success"] as? Bool, false)
        XCTAssertNotNil(replacement["execStartMs"])
        XCTAssertNil(replacement["handleMs"])
        XCTAssertNil(replacement["handleDetail"])
        XCTAssertNil(replacement["earlyFocusMs"])

        desktop.state.withLock { _ = $0.generationsByPID.removeValue(forKey: record.pid) }
        runtime.activate(windowID: id.rawValue)
        for action in runtime.pendingActionsForTesting { await action.value }
        let finished = try records()
        XCTAssertEqual(finished.count, 3)
        let completed = try XCTUnwrap(finished.last)
        XCTAssertEqual(completed["kind"] as? String, "activateWindow")
        XCTAssertEqual(completed["success"] as? Bool, true)
        XCTAssertEqual(completed["handleDetail"] as? String, "fallback")
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1002)
    }

    func testFinderActivationStopsCaptureRetriesWhenItsFirstInventoryReadCancels() throws {
        let desktop = BehaviorDesktop(editorBundleIdentifier: "com.apple.finder")
        let cancellation = OperationCancellation()
        let reads = Mutex(0)
        desktop.state.withLock {
            $0.windows[1001]?.status = .minimized
            $0.unreadInventories.insert(-41000)
            $0.beforeInventoryRead = { pid in
                guard pid == -41000 else { return }
                reads.withLock { $0 += 1 }
                cancellation.cancel()
            }
        }
        let record = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let executor = PlatformActionExecutor(
            switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0", "DOCK_FAST_WINDOW_HANDLE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id),
            snapshot: DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id]),
            forcedMinimizedPrior: true, cancellation: cancellation, onHandoffActivePrediction: nil))
        XCTAssertEqual(reads.withLock { $0 }, 1, "Cancellation during an admitted native read must prevent further Finder capture attempts")
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testMinimizeHandoffDoesNotActivateAnAppAfterItsCandidateWindowDisappears() throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { state in
            state.windows[1002]?.status = .minimized
            state.afterAttributeWrite = { [weak desktop] id, attribute in
                guard id == 1001, attribute == kAXMinimizedAttribute as String else { return }
                _ = desktop?.state.withLock { $0.windows.removeValue(forKey: 2001) }
            }
        }
        desktop.publish()
        let target = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertTrue(executor.execute(.init(kind: .minimizeWindow, windowID: target.id),
            snapshot: desktop.values.value, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffActivePrediction: nil))
        XCTAssertNil(desktop.state.withLock { $0.windows[2001] })
        XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, [])
    }

    func testMinimizeHandoffDoesNotFocusAReplacementAXWindowWithTheSameCGID() throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[1002]?.status = .minimized }
        desktop.publish()
        let replacement = try XCTUnwrap(desktop.state.withLock { $0.windows[2001] })
        let original = WindowRecord(id: replacement.id, appID: replacement.appID, pid: replacement.pid,
            bundleIdentifier: replacement.bundleIdentifier, title: replacement.title, bounds: replacement.bounds,
            status: replacement.status, cgWindowID: replacement.cgWindowID, processGeneration: replacement.processGeneration,
            actionTarget: WindowActionTarget(element: AXElementKey(e: AXUIElementCreateApplication(-89999))))
        let clicked = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        var records = desktop.values.value.windows
        records[original.id] = original
        let snapshot = DockSnapshot(windows: records, orderedWindowIDs: desktop.values.value.orderedWindowIDs)
        let predictions = Mutex<[WindowID]>([])
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        XCTAssertTrue(executor.execute(.init(kind: .minimizeWindow, windowID: clicked.id),
            snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffActivePrediction: { id in predictions.withLock { $0.append(id) } }))
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.status }, .minimized)
        XCTAssertNil(desktop.state.withLock { $0.focused })
        XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, [])
        XCTAssertEqual(predictions.withLock { $0 }, [])
    }

    func testCloseRevalidatesTheOriginalWindowAfterTheHandoffCandidateRead() async throws {
        for replaceOriginal in [false, true] {
            let desktop = BehaviorDesktop()
            desktop.state.withLock { $0.windows[1002]?.status = .minimized }
            desktop.publish()
            let original = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
            let candidate = try XCTUnwrap(desktop.state.withLock { $0.windows[2001] })
            let candidateElement = try XCTUnwrap(desktop.elements[2001])
            var records = desktop.values.value.windows
            records[candidate.id] = WindowRecord(id: candidate.id, appID: candidate.appID, pid: candidate.pid,
                bundleIdentifier: candidate.bundleIdentifier, title: candidate.title, bounds: candidate.bounds,
                status: candidate.status, cgWindowID: candidate.cgWindowID, processGeneration: candidate.processGeneration,
                actionTarget: WindowActionTarget(element: AXElementKey(e: candidateElement)))
            let snapshot = DockSnapshot(windows: records, orderedWindowIDs: desktop.values.value.orderedWindowIDs)
            let gate = BehaviorReadGate(attribute: kAXWindowsAttribute as String)
            let predictions = Mutex<[WindowID]>([])
            desktop.state.withLock {
                $0.beforeInventoryRead = { pid in
                    if pid == candidate.pid { gate.read(kAXWindowsAttribute as String) }
                }
            }
            let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
                reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
            let action = Task.detached {
                executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                    forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                    onHandoffActivePrediction: { id in predictions.withLock { $0.append(id) } })
            }
            await wait { gate.entered.withLock { $0 } }
            if replaceOriginal { desktop.replaceElement(for: 1001) }
            gate.release.signal()
            let succeeded = await action.value

            XCTAssertEqual(succeeded, !replaceOriginal)
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            XCTAssertEqual(predictions.withLock { $0 }, replaceOriginal ? [] : [candidate.id])
            XCTAssertEqual(desktop.state.withLock { $0.focused }, replaceOriginal ? 1001 : 2001)
            if replaceOriginal { XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, []) }
            XCTAssertEqual(desktop.state.withLock { $0.writes }, replaceOriginal ? [] : ["1001:close"])
        }
    }

    func testCloseRejectsHandoffCandidateReplacedDuringFinalSourceValidation() async throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[1002]?.status = .minimized }
        desktop.publish()
        let original = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let candidate = try XCTUnwrap(desktop.state.withLock { $0.windows[2001] })
        let candidateElement = try XCTUnwrap(desktop.elements[2001])
        var records = desktop.values.value.windows
        records[candidate.id] = WindowRecord(id: candidate.id, appID: candidate.appID, pid: candidate.pid,
            bundleIdentifier: candidate.bundleIdentifier, title: candidate.title, bounds: candidate.bounds,
            status: candidate.status, cgWindowID: candidate.cgWindowID, processGeneration: candidate.processGeneration,
            actionTarget: WindowActionTarget(element: AXElementKey(e: candidateElement)))
        let snapshot = DockSnapshot(windows: records, orderedWindowIDs: desktop.values.value.orderedWindowIDs)
        let gate = BehaviorReadGate(attribute: "original-window-id")
        let predictionSent = Mutex(false)
        let candidateChecked = Mutex(false)
        desktop.state.withLock {
            $0.beforeWindowIDRead = { id in
                guard predictionSent.withLock({ $0 }) else { return }
                if id == 2001 { candidateChecked.withLock { $0 = true } }
                if id == 1001 { gate.read("original-window-id") }
            }
        }
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let action = Task.detached {
            executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                onHandoffActivePrediction: { _ in predictionSent.withLock { $0 = true } })
        }
        await wait { gate.entered.withLock { $0 } }
        XCTAssertTrue(candidateChecked.withLock { $0 })
        desktop.replaceElement(for: 2001)
        gate.release.signal()

        let succeeded = await action.value
        XCTAssertTrue(succeeded)
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1001)
        XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, [])
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:close"])
    }

    func testCloseCannotStartHandoffWhenFinalSourceWindowNumberIsUnread() async throws {
        try await assertCloseHandoffRechecksFinalEvidence(sourceNumberBecomesUnread: true)
    }

    func testCloseCannotStartHandoffWhenCGOnlyCandidateDisappearsDuringFinalSourceRead() async throws {
        try await assertCloseHandoffRechecksFinalEvidence(sourceNumberBecomesUnread: false)
    }

    private func assertCloseHandoffRechecksFinalEvidence(sourceNumberBecomesUnread: Bool) async throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[1002]?.status = .minimized }
        desktop.publish()
        let snapshot = desktop.values.value
        let original = try XCTUnwrap(snapshot.windows[WindowID(rawValue: "editor-a")])
        XCTAssertNil(snapshot.windows[WindowID(rawValue: "browser-c")]?.actionTarget)
        let gate = BehaviorReadGate(attribute: "final-source-window-id")
        let predictionSent = Mutex(false)
        let sourceReads = Mutex(0)
        desktop.state.withLock {
            $0.beforeWindowIDRead = { id in
                guard id == 1001, predictionSent.withLock({ $0 }) else { return }
                let read = sourceReads.withLock { count in count += 1; return count }
                if read == 2 { gate.read("final-source-window-id") }
            }
        }
        let executor = PlatformActionExecutor(switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let action = Task.detached {
            executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                onHandoffActivePrediction: { _ in predictionSent.withLock { $0 = true } })
        }
        await wait { gate.entered.withLock { $0 } }
        desktop.state.withLock {
            if sourceNumberBecomesUnread { $0.unreadNativeWindowIDs.insert(1001) }
            else { $0.omittedCG.insert(2001) }
        }
        gate.release.signal()

        let succeeded = await action.value
        XCTAssertEqual(succeeded, !sourceNumberBecomesUnread)
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1001)
        XCTAssertEqual(desktop.state.withLock { $0.activationAttempts }, [])
        XCTAssertEqual(desktop.state.withLock { $0.writes }, sourceNumberBecomesUnread ? [] : ["1001:close"])
    }

    func testMinimizeFallbackRejectsANonElementButton() throws {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.rejectMinimizedAttribute = true
            $0.malformedMinimizeButton = true
        }
        let executor = AccessibilityWindowActionExecutor(reader: AXWindowReader(accessibility: desktop),
            focusBackend: desktop, system: desktop)
        let handle = try XCTUnwrap(executor.captureHandleByCGWindowID(1001, pid: -41000, title: nil, bounds: nil))
        let result = executor.minimize(handle)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.mechanism, "missing-minimize-button")
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testAXOnlyCloseCannotUseASeparateTrackedWindowWithTheSameTitleAndFrame() throws {
        let desktop = BehaviorDesktop()
        var original = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        original.cgWindowID = nil
        desktop.state.withLock { state in
            state.windows.removeValue(forKey: 1001)
            state.windows[1002]?.title = original.title
            state.focused = 1002
        }
        let sibling = try XCTUnwrap(desktop.state.withLock { $0.windows[1002] })
        let snapshot = DockSnapshot(windows: [original.id: original, sibling.id: sibling],
                                    orderedWindowIDs: [original.id, sibling.id])
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertFalse(executor.execute(.init(kind: .closeWindow, windowID: original.id),
            snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffActivePrediction: nil))
        XCTAssertNotNil(desktop.state.withLock { $0.windows[1002] })
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testFinderActivationStopsTheFastCaptureChainWhenItsFirstNativeReadCancels() throws {
        let desktop = BehaviorDesktop(editorBundleIdentifier: "com.apple.finder")
        let cancellation = OperationCancellation()
        let attributes = Mutex<[String]>([])
        desktop.state.withLock {
            $0.windows[1001]?.status = .minimized
            $0.focused = nil
            $0.beforeRead = { attribute in
                attributes.withLock { $0.append(attribute) }
                cancellation.cancel()
            }
        }
        let record = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let executor = PlatformActionExecutor(
            switches: .init(environment: ["DOCK_AX_ELEMENT_CACHE": "0", "DOCK_FAST_WINDOW_HANDLE": "1"]),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id),
            snapshot: DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id]),
            forcedMinimizedPrior: true, cancellation: cancellation, onHandoffActivePrediction: nil))
        XCTAssertEqual(attributes.withLock { $0 }, [kAXFocusedWindowAttribute as String])
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testQuitRejectsAnotherApplicationOriginEvenWithTheSameProcessGeneration() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.originOverride = ApplicationOrigin(bundleURL: URL(fileURLWithPath: "/Applications/Other.app")) }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 1)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.quitAttempts.isEmpty })
    }

    func testRefusedNormalQuitDoesNotCloseWindowsOrAttemptForcedTermination() async {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.deniedQuit = true }
        fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.onContextMenu?(event(.rightMouseDown, .zero))
        fixture.menu.menu?.performActionForItem(at: 1)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.quitAttempts }, [-41000])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.terminated.isEmpty && $0.writes.isEmpty })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows.count }, 3)
    }

    func testSeparateFileHoverRestoresTheWindowThroughTheProductionExecutor() async {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.windows[1002]?.status = .minimized; $0.omittedCG.insert(1002) }
        fixture.desktop.publish()
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-b")]?.status == .minimized }
        fixture.view.taskbarContent.scheduleFileHover(buttonID: "window:tabgrp-editor-b")
        await wait { fixture.desktop.state.withLock { $0.focused == 1002 && $0.windows[1002]?.status == .active } }
        await wait { fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-b"]?.isActiveWindow == true }
        XCTAssertFalse(fixture.popup.isPresented)
    }

    func testCombinedFileHoverWaitsForTheChosenRowThenRestoresOnlyThatWindow() async throws {
        let fixture = Fixture(width: 150); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.windows[1002]?.status = .minimized; $0.omittedCG.insert(1002) }
        fixture.desktop.publish()
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-b")]?.status == .minimized }
        let group = try XCTUnwrap(fixture.view.taskbarContent.layoutResult.buttons.first { $0.isCombined })
        fixture.view.taskbarContent.scheduleFileHover(buttonID: group.id)
        await wait { fixture.popup.content is TaskbarWindowListView }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1001)
        let list = try XCTUnwrap(fixture.popup.content as? TaskbarWindowListView)
        list.tableView.scrollRowToVisible(1)
        list.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(list.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TaskbarWindowListRow)
        row.scheduleFileHover()
        await wait { fixture.desktop.state.withLock { $0.focused == 1002 && $0.windows[1002]?.status == .active } }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.status }, .inactive)
    }

    func testMouseUpOutsidePreservesThePersistedOrderAfterAReorderPreview() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        let start = CGPoint(x: button.frame.midX, y: 16)
        let end = CGPoint(x: try XCTUnwrap(content.buttonViews["window:tabgrp-browser-c"]).frame.maxX - 4, y: 16)
        button.mouseDown(with: event(.leftMouseDown, start))
        button.mouseDragged(with: event(.leftMouseDragged, end))
        button.mouseUp(with: event(.leftMouseUp, CGPoint(x: end.x, y: -20)))
        let restored = StripOrderStore(defaults: fixture.defaults, bootTimeProvider: { 123 })
        XCTAssertEqual(restored.liveOrder, ["tabgrp-editor-a", "tabgrp-editor-b", "tabgrp-browser-c"])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
    }

    func testFailedOrUnconfirmedRestoreNeverPublishesSuccessfulActivation() async throws {
        for ignore in [false, true] {
            let fixture = Fixture(); defer { fixture.stop() }
            await ready(fixture)
            fixture.desktop.state.withLock { $0.windows[1001]?.status = .minimized; $0.focused = nil; $0.rejectWrites = !ignore; $0.ignoreWrites = ignore }
            fixture.desktop.publish()
            await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .minimized }
            try press("editor-a", fixture)
            for task in fixture.runtime.pendingActionsForTesting { await task.value }
            await wait { fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"]?.phase == .failure }
            XCTAssertNil(fixture.runtime.optimisticStatesByWindowID["editor-a"])
            await wait { fixture.view.taskbarContent.buttonViews["window:tabgrp-editor-a"]?.isActiveWindow == false }
            XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.status }, .minimized)
        }
    }

    func testFocusedMetadataCannotTurnAnUnappliedRestoreIntoSuccess() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock {
            $0.windows[1001]?.status = .minimized
            $0.focused = nil
            $0.ignoreWrites = true
            $0.allowFocusOfMinimized = true
        }
        fixture.desktop.publish()
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .minimized }
        try press("editor-a", fixture)
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        await wait { fixture.runtime.debugState.feedbackEntriesByWindowID["editor-a"]?.phase == .failure }
        XCTAssertNil(fixture.runtime.optimisticStatesByWindowID["editor-a"])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.status }, .minimized)
    }

    func testMinimizeButtonFallbackRetriesATransientReadAndConfirmsItsWindow() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { $0.rejectMinimizedAttribute = true; $0.transientMinimizeReads = 1 }
        try press("editor-a", fixture)
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .minimized }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.minimizeButtonReads }, 2)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.contains("1001:press-minimize") })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows.count }, 3)
    }

    func testFinishedDragPersistsTheWholeGroupAndSurvivesPresenterRecreation() async throws {
        let fixture = Fixture(); defer { fixture.stop() }
        await ready(fixture)
        let content = fixture.view.taskbarContent
        let button = try XCTUnwrap(content.buttonViews["window:tabgrp-editor-a"])
        let start = CGPoint(x: button.frame.midX, y: 16)
        let end = CGPoint(x: try XCTUnwrap(content.buttonViews["window:tabgrp-browser-c"]).frame.maxX - 4, y: 16)
        button.mouseDown(with: event(.leftMouseDown, start))
        button.mouseDragged(with: event(.leftMouseDragged, end))
        button.mouseUp(with: event(.leftMouseUp, end))
        await wait { fixture.ordering.liveOrder == ["tabgrp-browser-c", "tabgrp-editor-a", "tabgrp-editor-b"] }
        let restored = StripOrderStore(defaults: fixture.defaults, bootTimeProvider: { 123 })
        XCTAssertEqual(restored.liveOrder, ["tabgrp-browser-c", "tabgrp-editor-a", "tabgrp-editor-b"])
        let view = TaskbarView(frame: fixture.view.frame)
        let presenter = TaskbarPresenter(view: view, runtime: fixture.runtime, ordering: restored,
            topology: DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 1, identifiedDisplayUUIDs: ["left"], attributionTable: .empty)),
            spaces: fixture.spaces, displayUUID: nil, backgroundMenu: { _, _ in }, popupPresented: { _ in }, contextMenuVisibilityChanged: { _ in })
        withExtendedLifetime(presenter) { XCTAssertEqual(view.taskbarContent.layoutResult.buttons.flatMap(\.windowIDs), ["tabgrp-browser-c", "tabgrp-editor-a", "tabgrp-editor-b"]) }
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
    }
}

@MainActor
final class BehaviorLiftHost: WindowLiftAvoidanceHost {
    var contexts: [WindowLiftAvoidanceContext]
    init(_ context: WindowLiftAvoidanceContext) { contexts = [context] }
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] { contexts }
    func windowGeometryChanged() {}
}

final class BehaviorLiftProbeGate: WindowLiftWindowProbing, Sendable {
    struct State: Sendable {
        var holdNext = false
        var entered = false
        var timedOut = false
        var providesFrames = true
        var frameOverrides: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
    }
    let state = Mutex(State())
    let release = DispatchSemaphore(value: 0)
    let live: LiveWindowLiftProbe
    init(_ desktop: BehaviorDesktop) { live = LiveWindowLiftProbe(system: desktop) }
    func capture(on contexts: [WindowLiftAvoidanceContext], excludingPID: pid_t,
                 includeLiveWindowKeys: Bool, includesTiles: Bool,
                 trackedKeys: Set<WindowLiftAvoidance.WindowKey>, livenessKeys: Set<WindowLiftAvoidance.WindowKey>) -> WindowLiftCGScanResult {
        let result = live.capture(on: contexts, excludingPID: excludingPID, includeLiveWindowKeys: includeLiveWindowKeys,
                                  includesTiles: includesTiles, trackedKeys: trackedKeys, livenessKeys: livenessKeys)
        let hold = state.withLock { value in
            guard value.holdNext else { return false }
            value.holdNext = false
            value.entered = true
            return true
        }
        if hold, release.wait(timeout: .now() + 3) == .timedOut {
            state.withLock { $0.timedOut = true }
        }
        return result
    }
    func frames(for keys: Set<WindowLiftAvoidance.WindowKey>) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        let sample = state.withLock { $0 }
        guard sample.providesFrames else { return [:] }
        return live.frames(for: keys).merging(sample.frameOverrides.filter { keys.contains($0.key) }) { _, override in override }
    }
}

final class BehaviorLiftWriteGate: Sendable {
    let entered = Mutex(false)
    let timedOut = Mutex(false)
    let release = DispatchSemaphore(value: 0)

    func didWrite(_ id: CGWindowID, attribute: String) {
        guard id == 1001, attribute == kAXSizeAttribute as String else { return }
        let first = entered.withLock { value in
            let first = !value
            value = true
            return first
        }
        if first, release.wait(timeout: .now() + 3) == .timedOut { timedOut.withLock { $0 = true } }
    }
}

final class BehaviorLiftExecutorGate: Sendable {
    let entered = Mutex(false)
    let progressedBeforeRelease = Mutex(false)

    func hold() {
        let first = entered.withLock { value in
            let first = !value
            value = true
            return first
        }
        guard first else { return }
        let progress = DispatchSemaphore(value: 0)
        Task.detached(priority: .high) { progress.signal() }
        progressedBeforeRelease.withLock { $0 = progress.wait(timeout: .now() + 0.5) == .success }
    }
}

@MainActor
final class WindowLiftBehaviorTests: XCTestCase {
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func makeController(_ desktop: BehaviorDesktop, width: CGFloat = 1920, height: CGFloat = 1080, probe: (any WindowLiftWindowProbing)? = nil,
                                geometryObserver: FrontmostWindowGeometryObserver? = nil,
                                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
                                beforeRestoration: (@Sendable (WindowLiftAvoidance.WindowKey, WindowRestorationFrames) -> Void)? = nil,
                                diagnosticReporter: @escaping (String) -> Void = { _ in }) -> (WindowLiftAvoidanceController, BehaviorLiftHost) {
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let host = BehaviorLiftHost(.init(geometry: .init(screenFrame: screen, visibleFrame: screen, taskbarTopEdge: 32, topReservedHeight: 30),
                                         displayWindowServerFrame: screen, usableWindowServerFrame: screen, primaryDisplayHeight: height))
        let reader = AXWindowReader(accessibility: desktop)
        let access = AXWindowRestorationAccess(reader: reader, processStartTime: { pid in
            desktop.generation(pid).map { timeval(tv_sec: Int($0.seconds), tv_usec: $0.microseconds) }
        })
        let controller = WindowLiftAvoidanceController(host: host, isTrustedProbe: { true },
            restoreWindow: { key, frames, start, live, budget in
                beforeRestoration?(key, frames)
                return WindowRestorer(access: access).restore(key: key, frames: frames, expectedStartTime: start,
                                                       liveWindowKeys: live, cancellation: budget.cancellation, budget: budget)
            }, restorationWindowKeys: { desktop.state.withLock { Set($0.windows.values.map { .init(pid: $0.pid, cgWindowID: $0.cgWindowID!) }) } },
            windowProbe: probe ?? LiveWindowLiftProbe(system: desktop), reader: reader, system: desktop,
            makeGeometryObserver: { geometryObserver ?? FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none }) },
            uptime: uptime, workspaceNotificationCenter: workspaceNotificationCenter,
            diagnosticReporter: diagnosticReporter)
        controller.isEnabled = true
        return (controller, host)
    }

    private func failFrameReadsAfterAnimatedWrite(_ desktop: BehaviorDesktop, afterAcknowledgement: Bool) {
        let written = Mutex(false)
        desktop.state.withLock {
            $0.afterAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String else { return }
                let first = written.withLock { value in
                    let result = !value
                    value = true
                    return result
                }
                guard first else { return }
                if !afterAcknowledgement {
                    desktop.state.withLock { _ = $0.unreadPositions.insert(1001) }
                }
            }
            $0.beforeSettable = { attribute in
                guard afterAcknowledgement, attribute == kAXSizeAttribute as String,
                      written.withLock({ $0 }) else { return }
                desktop.state.withLock { _ = $0.unreadPositions.insert(1001) }
            }
        }
    }

    func testStopPreservesManualBottomEdgeAfterVerifiedLift() async {
        let desktop = BehaviorDesktop()
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let manuallyResized = CGRect(x: 0, y: 30, width: 1920, height: 1033)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        guard case .lifted = controller.states[key] else {
            XCTFail("Expected the lift to settle before the manual resize")
            return
        }
        desktop.state.withLock {
            $0.windows[1001]?.bounds = manuallyResized
            $0.writes.removeAll()
        }

        let result = await controller.stopAndRestore()

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manuallyResized)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testStopDoesNotRestoreReplacementReusingTheSameWindowID() async {
        let desktop = BehaviorDesktop()
        let target = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        guard case .lifted = controller.states[key] else {
            XCTFail("Expected the original window to be lifted before replacement")
            return
        }
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, target)
        desktop.state.withLock {
            $0.windows.removeValue(forKey: 1001)
            $0.windows[1002]?.bounds = target
            $0.windows[1002]?.cgWindowID = 1001
            $0.windows[1002]?.status = .active
            $0.nativeWindowIDOverrides[1002] = 1001
            $0.focused = 1002
            $0.enumeratedWindows[-41000] = [1002]
            $0.writes.removeAll()
        }

        let result = await controller.stopAndRestore()

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, target)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testStopPreservesManualBottomEdgeWhileValidatingTheFirstWrite() async {
        await checkStopPreservesManualFrameWhileValidating(CGRect(x: 0, y: 30, width: 1920, height: 1033))
    }

    func testStopPreservesManualTargetWhileValidatingTheFirstWrite() async {
        await checkStopPreservesManualFrameWhileValidating(CGRect(x: 0, y: 30, width: 1920, height: 1016))
    }

    private func checkStopPreservesManualFrameWhileValidating(_ manuallyResized: CGRect) async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorReadGate(attribute: kAXRoleAttribute as String)
        desktop.state.withLock { $0.beforeRead = { gate.read($0) } }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        desktop.state.withLock { $0.windows[1001]?.bounds = manuallyResized }
        controller.stop()
        gate.release.signal()

        let result = await controller.stopAndRestore()

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manuallyResized)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testInactiveFrontWindowDoesNotBlockActiveLiftCandidate() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        let adjusted = CGRect(x: 0, y: 30, width: 2560, height: 1376)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = native
            $0.windows[2001]?.bounds = native
            $0.omittedCG.insert(1002)
            $0.frontmostPIDOverride = -42000
        }
        let (controller, host) = makeController(desktop, width: 2560, height: 1440,
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let target = WindowLiftAvoidance.WindowKey(pid: -42000, cgWindowID: 2001)

        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[target]?.value

        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
        XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["2001:AXSize"])
        await controller.stopAndRestore()
    }

    func testFloatingFrontWindowDoesNotBlockSameApplicationsLiftCandidate() async {
        let desktop = BehaviorDesktop(additionalWindows: 1)
        let floating = CGRect(x: 90, y: 200, width: 2300, height: 950)
        let native = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        let adjusted = CGRect(x: 0, y: 30, width: 2560, height: 1376)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = floating
            $0.windows[1002]?.bounds = native
            $0.windows[3000]?.bounds = native
            $0.omittedCG.insert(2001)
        }
        let (controller, host) = makeController(desktop, width: 2560, height: 1440,
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let target = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1002)

        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[target]?.value

        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, floating)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.windows[3000]?.bounds }, native)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1002:AXSize"])
        await controller.stopAndRestore()
    }

    func testTrackedReliftDefersInitialLiftOnlyOnItsOwnDisplay() async {
        for secondDisplay in [false, true] {
            let desktop = BehaviorDesktop(additionalWindows: 1)
            let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
            let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
            let floating = CGRect(x: 90, y: 150, width: 1700, height: 800)
            let initialFrame = native.offsetBy(dx: secondDisplay ? 1920 : 0, dy: 0)
            desktop.state.withLock {
                $0.focused = 3000
                $0.omittedCG = [1001, 1002, 2001]
            }
            let clock = Mutex<TimeInterval>(10)
            let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } },
                workspaceNotificationCenter: NotificationCenter())
            defer { withExtendedLifetime(host) {} }
            if secondDisplay {
                let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                host.contexts.append(.init(geometry: .init(screenFrame: screen, visibleFrame: screen,
                    taskbarTopEdge: 32, topReservedHeight: 30), displayWindowServerFrame: screen,
                    usableWindowServerFrame: screen, primaryDisplayHeight: 1080))
            }
            let managed = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 3000)
            let initial = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1002)

            controller.poll()
            await controller.scanTask?.value
            await controller.writeTasks[managed]?.value
            XCTAssertEqual(desktop.state.withLock { $0.windows[3000]?.bounds }, adjusted)

            clock.withLock { $0 += 2 }
            desktop.state.withLock {
                $0.focused = 1001
                $0.omittedCG = [2001]
                $0.windows[1001]?.bounds = floating
                $0.windows[1002]?.bounds = initialFrame
                $0.windows[3000]?.bounds = native
                $0.writes.removeAll()
            }
            controller.poll()
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await controller.scanTask?.value
            await controller.writeTasks[managed]?.value
            await controller.writeTasks[initial]?.value

            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, floating)
            XCTAssertEqual(desktop.state.withLock { $0.windows[3000]?.bounds }, adjusted)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds },
                secondDisplay ? CGRect(x: 1920, y: 30, width: 1920, height: 1016) : initialFrame)
            XCTAssertEqual(desktop.state.withLock { $0.writes.sorted() },
                secondDisplay ? ["1002:AXSize", "3000:AXSize"] : ["3000:AXSize"])
            await controller.stopAndRestore()
        }
    }

    func testOlderScanRespectsTheNewerTrackedWindowsDisplayReservation() async throws {
        for retiresWindow in [false, true] {
            let desktop = BehaviorDesktop()
            let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
            let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
            let floating = CGRect(x: 90, y: 150, width: 1700, height: 800)
            desktop.state.withLock { $0.omittedCG = [1002, 2001] }
            let probe = BehaviorLiftProbeGate(desktop)
            let (controller, host) = makeController(desktop, probe: probe, uptime: { 10 },
                workspaceNotificationCenter: NotificationCenter())
            defer { probe.release.signal(); withExtendedLifetime(host) {} }
            let managed = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let initial = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1002)
            controller.poll()
            await controller.scanTask?.value
            await controller.writeTasks[managed]?.value
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
            controller.trackedProbeTimer?.invalidate()
            if let prior = controller.trackedProbeTask { await prior.value }

            desktop.state.withLock {
                $0.omittedCG = [2001]
                $0.writes.removeAll()
            }
            probe.state.withLock { $0.holdNext = true }
            controller.poll()
            let captured = try XCTUnwrap(controller.scanTask)
            await wait { probe.state.withLock { $0.entered } }
            if retiresWindow { desktop.state.withLock { $0.windows[1001]?.bounds = floating } }
            controller.probeTrackedFrames()
            let newer = try XCTUnwrap(controller.trackedProbeTask)
            await newer.value
            XCTAssertEqual(controller.states[managed] == nil, retiresWindow)
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            probe.release.signal()
            await captured.value
            await controller.writeTasks[initial]?.value

            XCTAssertFalse(probe.state.withLock { $0.timedOut })
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, retiresWindow ? floating : adjusted)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, retiresWindow ? adjusted : native)
            XCTAssertEqual(desktop.state.withLock { $0.writes }, retiresWindow ? ["1002:AXSize"] : [])
            await controller.stopAndRestore()
        }
    }

    func testClearedFrontWindowCannotReserveDisplayWhileSuppressed() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let moved = native.offsetBy(dx: 6, dy: 0)
        desktop.state.withLock { $0.omittedCG = [1002, 2001] }
        let clock = Mutex<TimeInterval>(10)
        let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } },
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let managed = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let initial = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1002)
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[managed]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)

        clock.withLock { $0 += 2 }
        desktop.state.withLock {
            $0.omittedCG = [2001]
            $0.windows[1001]?.bounds = moved
            $0.writes.removeAll()
        }
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[initial]?.value

        XCTAssertNil(controller.states[managed])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, moved)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1002:AXSize"])
        await controller.stopAndRestore()
    }

    func testExhaustedFrontWindowDoesNotBlockAnEligibleInitialLift() async {
        for showsWindowOnExhaustion in [false, true] {
            let desktop = BehaviorDesktop()
            let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
            let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
            let floating = CGRect(x: 90, y: 150, width: 1700, height: 800)
            desktop.state.withLock { $0.omittedCG = [1002, 2001] }
            let (controller, host) = makeController(desktop, uptime: { 10 },
                workspaceNotificationCenter: NotificationCenter())
            defer { withExtendedLifetime(host) {} }
            let managed = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let initial = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1002)

            func completeScan() async {
                controller.isEnabled = true
                controller.poll()
                controller.isEnabled = false
                controller.updatePollTimerLifecycle()
                controller.updateTrackedProbeLifecycle()
                await controller.scanTask?.value
                await controller.writeTasks[managed]?.value
                await controller.writeTasks[initial]?.value
            }

            await completeScan()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
            for round in 1...2 {
                desktop.state.withLock { $0.windows[1001]?.bounds = floating }
                await completeScan()
                XCTAssertNil(controller.states[managed])
                desktop.state.withLock {
                    $0.windows[1001]?.bounds = native
                    if round == 2, showsWindowOnExhaustion { $0.omittedCG = [2001] }
                }
                await completeScan()
            }
            if !showsWindowOnExhaustion {
                desktop.state.withLock { $0.omittedCG = [2001] }
                await completeScan()
            }

            if case let .abandoned(session) = controller.states[managed] {
                XCTAssertEqual(session.reason, .reliftLimitReached)
                XCTAssertEqual(session.applicationResponseRounds, 2)
            } else {
                XCTFail("Expected the front window to retain its exhausted response budget")
            }
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, adjusted)
            XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXSize", "1002:AXSize"])
            await controller.stopAndRestore()
        }
    }

    private func completeCandidateScan(_ controller: WindowLiftAvoidanceController) async {
        controller.isEnabled = true
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        for writer in Array(controller.writeTasks.values) { await writer.value }
    }

    func testTrackedWindowThatExhaustsImmediateReliftsDoesNotBlockTheNextCandidate() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        desktop.state.withLock { $0.omittedCG = [1002, 2001] }
        let (controller, host) = makeController(desktop, uptime: { 10 },
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }

        await completeCandidateScan(controller)
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        await completeCandidateScan(controller)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = native
            $0.omittedCG = [2001]
        }
        await completeCandidateScan(controller)

        if case let .abandoned(session) = controller.states[key] {
            XCTAssertEqual(session.reason, .reliftLimitReached)
            XCTAssertEqual(session.liftRetryCount, 1)
            XCTAssertEqual(session.applicationResponseRounds, 0)
        } else {
            XCTFail("Expected the immediate relift budget to remain exhausted")
        }
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXSize", "1002:AXSize"])
        await controller.stopAndRestore()
    }

    func testClearedWindowCannotReserveDisplayForAnExhaustedDetour() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let floating = CGRect(x: 90, y: 150, width: 1700, height: 800)
        let moved = native.offsetBy(dx: 6, dy: 0)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        desktop.state.withLock { $0.omittedCG = [1002, 2001] }
        let (controller, host) = makeController(desktop, uptime: { 10 },
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }

        await completeCandidateScan(controller)
        desktop.state.withLock { $0.windows[1001]?.bounds = floating }
        await completeCandidateScan(controller)
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        await completeCandidateScan(controller)
        if case let .lifted(session) = controller.states[key] {
            XCTAssertEqual(session.applicationResponseRounds, 1)
        } else {
            XCTFail("Expected one detour response before testing exhaustion")
        }
        desktop.state.withLock {
            $0.windows[1001]?.bounds = moved
            $0.omittedCG = [2001]
        }
        await completeCandidateScan(controller)

        XCTAssertNil(controller.states[key])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, moved)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXSize", "1002:AXSize"])

        await completeCandidateScan(controller)
        if case let .abandoned(session) = controller.states[key] {
            XCTAssertEqual(session.reason, .reliftLimitReached)
            XCTAssertEqual(session.applicationResponseRounds, 2)
        } else {
            XCTFail("Expected the ordinary scan to retain the exhausted detour budget")
        }
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXSize", "1002:AXSize"])
        await controller.stopAndRestore()
    }

    func testInactiveManagedWindowRegainsBottomClearanceWithoutReactivation() async {
        for elapsed: TimeInterval in [0.25, 2] {
            let desktop = BehaviorDesktop()
            let clock = Mutex<TimeInterval>(10)
            let otherFrame = CGRect(x: 200, y: 140, width: 900, height: 600)
            desktop.state.withLock { $0.windows[2001]?.bounds = otherFrame }
            let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } })
            defer { withExtendedLifetime(host) {} }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
            controller.poll()
            await wait {
                desktop.state.withLock { $0.windows[1001]?.bounds == adjusted }
                    && controller.writeTasks[key] == nil
            }

            clock.withLock { $0 += elapsed }
            _ = desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0)
            desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050) }
            controller.poll()
            await controller.scanTask?.value
            await controller.writeTasks[key]?.value

            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
            XCTAssertFalse(desktop.app(-41000)?.isActive ?? true)
            XCTAssertEqual(desktop.state.withLock { $0.focused }, 2001)
            XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds }, otherFrame)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
            await controller.stopAndRestore()
        }
    }

    func testClearanceLossReportsTheObservedAndTargetFramesOnce() async {
        let desktop = BehaviorDesktop()
        var diagnostics: [String] = []
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let overlapping = CGRect(x: 0, y: 30, width: 1920, height: 1040)
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter(),
            diagnosticReporter: { diagnostics.append($0) })
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds?.height }, 1016)

        desktop.state.withLock { $0.windows[1001]?.bounds = overlapping }
        for _ in 0..<2 {
            controller.poll()
            await controller.scanTask?.value
        }

        let events = diagnostics.filter { $0.contains("lift clearance lost") }
        XCTAssertEqual(events.count, 1)
        guard let event = events.first else { return }
        for field in ["wid=1001", "cg=[0.0,30.0,1920.0,1040.0]", "native=[0.0,30.0,1920.0,1050.0]",
                      "target=[0.0,30.0,1920.0,1016.0]", "panelTopY=1048.0", "classification=managedTrajectory",
                      "decision=none"] {
            XCTAssertTrue(event.contains(field), event)
        }
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, overlapping)

        let offDisplay = overlapping.offsetBy(dx: 1920, dy: 0)
        desktop.state.withLock { $0.windows[1001]?.bounds = offDisplay }
        controller.poll()
        await controller.scanTask?.value
        XCTAssertEqual(diagnostics.filter { $0.contains("lift clearance lost") }.count, 1)
    }

    func testInactiveManagedWindowRegainsClearanceAfterMaximizedTopInsetChanges() async {
        let width: CGFloat = 1512
        let height: CGFloat = 982
        let initialFrame = CGRect(x: 0, y: 30, width: width, height: 952)
        let firstAdjustment = CGRect(x: 0, y: 30, width: width, height: 918)
        let returnedFrame = CGRect(x: 0, y: 33, width: width, height: 949)
        let secondAdjustment = CGRect(x: 0, y: 33, width: width, height: 915)
        let closeReturn = CGRect(x: 0, y: 32, width: width, height: 950)
        let closeAdjustment = CGRect(x: 0, y: 32, width: width, height: 916)
        let returnWithBottomInset = CGRect(x: 0, y: 32, width: width, height: 948)
        let shiftedFrame = CGRect(x: 6, y: 33, width: 1506, height: 949)
        let narrowedFrame = CGRect(x: 2, y: 33, width: 1508, height: 949)
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let visibleFrame = CGRect(x: 0, y: 0, width: width, height: 949)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let cases: [(elapsed: TimeInterval, observed: CGRect, expected: CGRect)] = [
            (0.25, returnedFrame, secondAdjustment),
            (2, returnedFrame, secondAdjustment),
            (2, closeReturn, closeAdjustment),
            (2, returnWithBottomInset, closeAdjustment),
            (2, shiftedFrame, shiftedFrame),
            (2, narrowedFrame, narrowedFrame)
        ]

        for scenario in cases {
            let desktop = BehaviorDesktop()
            let clock = Mutex<TimeInterval>(10)
            let otherFrame = CGRect(x: 200, y: 140, width: 900, height: 600)
            desktop.state.withLock {
                $0.windows[1001]?.bounds = initialFrame
                $0.windows[1002]?.bounds = otherFrame
                $0.windows[2001]?.bounds = otherFrame
            }
            let (controller, host) = makeController(desktop, width: width, height: height,
                uptime: { clock.withLock { $0 } }, workspaceNotificationCenter: NotificationCenter())
            defer { withExtendedLifetime(host) {} }
            host.contexts = [.init(geometry: .init(screenFrame: screen, visibleFrame: visibleFrame,
                taskbarTopEdge: 32, topReservedHeight: 33), displayWindowServerFrame: screen,
                usableWindowServerFrame: returnedFrame, primaryDisplayHeight: height)]

            controller.poll()
            await controller.scanTask?.value
            await controller.writeTasks[key]?.value
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, firstAdjustment)

            clock.withLock { $0 += scenario.elapsed }
            XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
            desktop.state.withLock { $0.windows[1001]?.bounds = scenario.observed }
            controller.poll()
            await controller.scanTask?.value
            await controller.writeTasks[key]?.value

            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, scenario.expected,
                "Observed \(scenario.observed) at +\(scenario.elapsed) s")
            XCTAssertEqual(desktop.state.withLock { $0.focused }, 2001)
            XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds }, otherFrame)
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, scenario.observed)
        }
    }

    func testFocusNotificationDuringBackgroundMaintenanceValidationDoesNotCancelClearance() async {
        let nextApplication = NSRunningApplication.current
        let desktop = BehaviorDesktop(browserPID: nextApplication.processIdentifier)
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none })
        let (controller, host) = makeController(desktop, geometryObserver: observer)
        let gate = BehaviorReadGate()
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "0"])
        for task in observer.work.pendingForTesting { await task.value }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == adjusted }
                && controller.writeTasks[key] == nil
        }

        _ = desktop.setFrontmost(pid: nextApplication.processIdentifier, windowID: 2001, mode: 0)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050)
            $0.beforeRead = { gate.read($0) }
        }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        guard gate.entered.withLock({ $0 }) else { await controller.stopAndRestore(); return }
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        let previousGeneration = observer.work.generation
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: nextApplication])
        await wait { observer.work.generation != previousGeneration }
        gate.release.signal()
        await writer?.value

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertFalse(desktop.app(-41000)?.isActive ?? true)
        await controller.stopAndRestore()
    }

    func testBackgroundMaintenanceRetriesAfterMaximizedInsetChangesDuringValidation() async {
        let desktop = BehaviorDesktop()
        let clock = Mutex<TimeInterval>(10)
        let gate = BehaviorReadGate()
        let probe = BehaviorLiftProbeGate(desktop)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let firstAdjustment = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let firstReturn = CGRect(x: 0, y: 33, width: 1920, height: 1047)
        let settledReturn = CGRect(x: 0, y: 37, width: 1920, height: 1043)
        let expected = CGRect(x: 0, y: 37, width: 1920, height: 1009)
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, probe: probe, uptime: { clock.withLock { $0 } },
            workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); probe.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == firstAdjustment }
                && controller.writeTasks[key] == nil
        }

        clock.withLock { $0 += 2 }
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
        desktop.state.withLock {
            $0.windows[1001]?.bounds = firstReturn
            $0.beforeRead = { gate.read($0) }
        }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        let firstWriter = controller.writeTasks[key]
        XCTAssertNotNil(firstWriter)
        desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 320, y: 160, width: 620, height: 420) }
        probe.state.withLock { $0.holdNext = true }
        controller.poll()
        let staleScan = controller.scanTask
        XCTAssertNotNil(staleScan)
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await wait { probe.state.withLock { $0.entered } }

        desktop.state.withLock { $0.windows[1001]?.bounds = settledReturn }
        gate.release.signal()
        await firstWriter?.value
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        probe.release.signal()
        await staleScan?.value

        controller.isEnabled = true
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 2001)
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, settledReturn)
    }

    func testStopBeforeBackgroundMaintenanceWriteRestoresOnlyTheConfirmedTarget() async {
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let manual = CGRect(x: 0, y: 30, width: 1920, height: 1026)
        let pending = CGRect(x: 0, y: 37, width: 1920, height: 1043)
        for (beforeStop, expected) in [(adjusted, native), (manual, manual)] {
            let desktop = BehaviorDesktop()
            let gate = BehaviorReadGate()
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
            let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.poll()
            await wait {
                desktop.state.withLock { $0.windows[1001]?.bounds == adjusted }
                    && controller.writeTasks[key] == nil
            }
            XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
            desktop.state.withLock {
                $0.windows[1001]?.bounds = pending
                $0.beforeRead = { gate.read($0) }
            }
            controller.poll()
            await wait { gate.entered.withLock { $0 } }
            desktop.state.withLock { $0.windows[1001]?.bounds = beforeStop }

            controller.stop()
            gate.release.signal()
            await controller.restoreTask?.value
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        }
    }

    func testUnavailableValidationFrameDoesNotRestartBackgroundMaintenance() async {
        let desktop = BehaviorDesktop()
        let probe = BehaviorLiftProbeGate(desktop)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let returned = CGRect(x: 0, y: 37, width: 1920, height: 1043)
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, probe: probe, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == adjusted }
                && controller.writeTasks[key] == nil
        }
        let writes = desktop.state.withLock { $0.writes }
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
        desktop.state.withLock { $0.windows[1001]?.bounds = returned }
        probe.state.withLock { $0.providesFrames = false }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value

        XCTAssertEqual(desktop.state.withLock { $0.writes }, writes)
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, returned)
    }

    func testBackgroundMaintenancePreservesAWindowMovedDuringValidation() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop)
        let gate = BehaviorReadGate()
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == CGRect(x: 0, y: 30, width: 1920, height: 1016) }
                && controller.writeTasks[key] == nil
        }
        let writes = desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" }.count }
        _ = desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050)
            $0.beforeRead = { gate.read($0) }
        }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        let writer = controller.writeTasks[key]
        let manualFrame = CGRect(x: 320, y: 160, width: 620, height: 420)
        desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame }
        gate.release.signal()
        await writer?.value

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manualFrame)
        XCTAssertEqual(desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" }.count }, writes)
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manualFrame)
    }

    func testBackgroundMaintenanceRejectsReusedProcessGeneration() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == CGRect(x: 0, y: 30, width: 1920, height: 1016) }
                && controller.writeTasks[key] == nil
        }
        let writes = desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" }.count }
        let unadjustedWindowFrame = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        _ = desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = unadjustedWindowFrame
            $0.generationsByPID[-41000] = ProcessGeneration(timeval(tv_sec: 11, tv_usec: 1))
        }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value

        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, unadjustedWindowFrame)
        XCTAssertEqual(desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" }.count }, writes)
        XCTAssertNil(controller.managedFrames[key])
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, unadjustedWindowFrame)
    }

    func testUnmanagedInactiveMaximizedWindowsRemainUntouched() async {
        let desktop = BehaviorDesktop()
        let otherFrame = CGRect(x: 200, y: 140, width: 900, height: 600)
        desktop.state.withLock { $0.windows[2001]?.bounds = otherFrame }
        _ = desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0)
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value

        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertTrue(controller.managedFrames.isEmpty)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds }, otherFrame)
        await controller.stopAndRestore()
    }

    func testBackgroundMaintenanceRejectsAReplacementAXElementWithTheSameWindowNumber() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == adjusted } && controller.writeTasks[key] == nil
        }
        let writes = desktop.state.withLock { $0.writes }
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
        desktop.replaceElement(for: 1001)
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.writes }, writes)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
        _ = await controller.stopAndRestore()
    }

    func testQuitRestoresConfirmedLiftAfterTemporaryMaintenanceValidationFailure() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let probe = BehaviorLiftProbeGate(desktop)
        let (controller, host) = makeController(desktop, probe: probe, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        controller.poll()
        await wait {
            desktop.state.withLock { $0.windows[1001]?.bounds == adjusted } && controller.writeTasks[key] == nil
        }
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))
        probe.state.withLock { $0.providesFrames = false }
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        controller.poll()
        await controller.scanTask?.value
        let maintenance = controller.writeTasks[key]
        XCTAssertNotNil(maintenance)
        desktop.state.withLock { $0.windows[1001]?.bounds = adjusted }
        await maintenance?.value
        let stopped = await controller.stopAndRestore()
        XCTAssertEqual(stopped, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
    }

    func testPermissionUnfreezeKeepsConfirmedLiftAfterCancellingMaintenanceValidation() async {
        await checkRestorationAfterMaintenanceInterruption(.permissionFreeze)
    }

    func testPersistentCGAndAXMismatchKeepsConfirmedLift() async {
        await checkRestorationAfterMaintenanceInterruption(.frameMismatch)
    }

    func testUnreadProcessGenerationBeforeMaintenanceKeepsConfirmedLift() async {
        await checkRestorationAfterMaintenanceInterruption(.unreadProcessAtStart)
    }

    func testUnreadProcessGenerationAtMaintenanceAdmissionKeepsConfirmedLift() async {
        await checkRestorationAfterMaintenanceInterruption(.unreadProcessAtAdmission)
    }

    func testConfirmedManualGeometryDuringMaintenanceDiscardsRestorationAuthority() async {
        await checkRestorationAfterMaintenanceInterruption(.manualGeometry)
    }

    func testUnreadProcessGenerationAtFirstNativeMaintenanceWriteKeepsPreviousLift() async {
        await checkRestorationAfterFirstNativeWriteRejection(.unreadProcess)
    }

    func testReplacedProcessAtFirstNativeMaintenanceWriteDiscardsPreviousLift() async {
        await checkRestorationAfterFirstNativeWriteRejection(.replacedProcess)
    }

    func testMissingWindowNumberInFinalNativeMaintenanceSampleKeepsPreviousLift() async {
        await checkRestorationAfterFirstNativeWriteRejection(.unreadWindowNumber)
    }

    func testDifferentWindowNumberInFinalNativeMaintenanceSampleDiscardsPreviousLift() async {
        await checkRestorationAfterFirstNativeWriteRejection(.replacedWindowNumber)
    }

    private enum FirstWriteRejection {
        case unreadProcess, replacedProcess, unreadWindowNumber, replacedWindowNumber

        var finalSample: Bool { self == .unreadWindowNumber || self == .replacedWindowNumber }
        var replacedIdentity: Bool { self == .replacedProcess || self == .replacedWindowNumber }
    }

    private func checkRestorationAfterFirstNativeWriteRejection(_ rejection: FirstWriteRejection) async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorReadGate()
        let frameSamples = Mutex(0)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))

        desktop.state.withLock {
            $0.writes.removeAll()
            $0.windows[1001]?.bounds = native
            $0.windowIDAttributes[1001] = 1001
            $0.beforeFrameBatchRead = {
                let sample = frameSamples.withLock {
                    $0 += 1
                    return $0
                }
                if sample == (rejection.finalSample ? 2 : 1) { gate.read(gate.attribute) }
            }
        }
        controller.poll()
        await controller.scanTask?.value
        await wait { gate.entered.withLock { $0 } }
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        desktop.state.withLock {
            switch rejection {
            case .replacedProcess:
                $0.generationsByPID[key.pid] = ProcessGeneration(timeval(tv_sec: 11, tv_usec: 1))
            case .unreadProcess:
                $0.unreadGenerations.insert(key.pid)
            case .unreadWindowNumber:
                $0.windowIDAttributes.removeValue(forKey: 1001)
            case .replacedWindowNumber:
                $0.windowIDAttributes[1001] = 1002
            }
        }
        gate.release.signal()
        await writer?.value
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(frameSamples.withLock { $0 }, 2)
        desktop.state.withLock {
            $0.unreadGenerations.remove(key.pid)
            $0.windowIDAttributes[1001] = 1001
            $0.windows[1001]?.bounds = adjusted
        }

        if rejection.replacedIdentity {
            XCTAssertNil(controller.managedFrames[key])
        } else {
            XCTAssertEqual(controller.managedFrames[key]?.settledQuartz, adjusted)
        }
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        let stopped = await controller.stopAndRestore()
        XCTAssertEqual(stopped, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, rejection.replacedIdentity ? adjusted : native)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, rejection.replacedIdentity ? [] : ["1001:AXSize"])
    }

    func testPermissionFreezeDoesNotReviveLiftAfterConfirmedProcessReplacement() async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorReadGate()
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let replacement = ProcessGeneration(timeval(tv_sec: 11, tv_usec: 1))
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))

        desktop.state.withLock {
            $0.writes.removeAll()
            $0.windows[1001]?.bounds = native
            $0.beforeRead = { gate.read($0) }
        }
        controller.poll()
        await controller.scanTask?.value
        await wait { gate.entered.withLock { $0 } }
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        desktop.state.withLock {
            $0.generationsByPID[key.pid] = replacement
            $0.afterGenerationRead = { [weak controller] pid, observed in
                guard pid == key.pid, observed == replacement else { return }
                MainActor.assumeIsolated {
                    controller?.beginPermissionUncertainty()
                    desktop.state.withLock {
                        $0.afterGenerationRead = nil
                        $0.unreadGenerations.insert(key.pid)
                        $0.windows[1001]?.bounds = adjusted
                    }
                }
            }
        }
        gate.release.signal()
        await writer?.value
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertFalse(controller.isEnabled)
        controller.endPermissionUncertainty()
        await wait { controller.isEnabled }
        await controller.scanTask?.value

        XCTAssertNil(controller.managedFrames[key])
        let stopped = await controller.stopAndRestore()
        XCTAssertEqual(stopped, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testManualGeometryDiscardsRestorationAuthorityWhenSizeCapabilityIsUnread() async {
        await checkRestorationAfterMaintenanceInterruption(.manualGeometryWithUnreadCapability)
    }

    private enum MaintenanceInterruption {
        case permissionFreeze, frameMismatch, unreadProcessAtStart, unreadProcessAtAdmission
        case manualGeometry, manualGeometryWithUnreadCapability
    }

    private func checkRestorationAfterMaintenanceInterruption(_ interruption: MaintenanceInterruption) async {
        let desktop = BehaviorDesktop()
        let probe = BehaviorLiftProbeGate(desktop)
        let gate = BehaviorReadGate()
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let manual = CGRect(x: 0, y: 30, width: 1920, height: 1030)
        desktop.state.withLock { $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600) }
        let (controller, host) = makeController(desktop, probe: probe, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertTrue(desktop.setFrontmost(pid: -42000, windowID: 2001, mode: 0))

        if interruption == .frameMismatch { probe.state.withLock { $0.frameOverrides[key] = native } }
        desktop.state.withLock {
            $0.writes.removeAll()
            $0.windows[1001]?.bounds = native
            if interruption == .unreadProcessAtStart {
                $0.unreadGenerations.insert(key.pid)
            } else {
                $0.beforeRead = { gate.read($0) }
            }
        }
        controller.poll()
        await controller.scanTask?.value
        if interruption == .unreadProcessAtStart {
            desktop.state.withLock {
                $0.unreadGenerations.remove(key.pid)
                $0.windows[1001]?.bounds = adjusted
            }
        } else {
            await wait { gate.entered.withLock { $0 } }
            let writer = controller.writeTasks[key]
            XCTAssertNotNil(writer)
            if interruption == .permissionFreeze { controller.beginPermissionUncertainty() }
            desktop.state.withLock {
                switch interruption {
                case .unreadProcessAtAdmission:
                    $0.unreadGenerations.insert(key.pid)
                case .manualGeometry, .manualGeometryWithUnreadCapability:
                    $0.windows[1001]?.bounds = manual
                    if interruption == .manualGeometryWithUnreadCapability {
                        $0.unreadSettableAttributes.insert(kAXSizeAttribute as String)
                    }
                default:
                    $0.windows[1001]?.bounds = adjusted
                }
            }
            gate.release.signal()
            await writer?.value
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            if interruption == .unreadProcessAtAdmission {
                desktop.state.withLock {
                    $0.unreadGenerations.remove(key.pid)
                    $0.windows[1001]?.bounds = adjusted
                }
            }
            if interruption == .permissionFreeze {
                controller.endPermissionUncertainty()
                await wait { controller.isEnabled }
                await controller.scanTask?.value
            }
        }

        let shouldRestore = interruption != .manualGeometry && interruption != .manualGeometryWithUnreadCapability
        XCTAssertEqual(controller.managedFrames[key]?.settledQuartz, shouldRestore ? adjusted : nil)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        let frameBeforeStop = interruption == .manualGeometry ? manual : adjusted
        if interruption == .manualGeometryWithUnreadCapability {
            desktop.state.withLock {
                $0.unreadSettableAttributes.removeAll()
                $0.windows[1001]?.bounds = frameBeforeStop
            }
        }
        let stopped = await controller.stopAndRestore()
        XCTAssertEqual(stopped, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, shouldRestore ? native : frameBeforeStop)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, shouldRestore ? ["1001:AXSize"] : [])
    }

    func testAnimatedLiftPreservesAnUnacknowledgedHeightBetweenNativeAndTarget() async throws {
        let desktop = BehaviorDesktop()
        let nativeHeight: CGFloat = 1050
        let targetHeight: CGFloat = 1016
        let midpoint = (nativeHeight + targetHeight) / 2
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let progression = Mutex((firstWrite: CGRect?.none, positionReads: 0, manual: CGRect?.none))
        desktop.state.withLock {
            $0.omittedCG = [1002, 2001]
            $0.afterAttributeWrite = { [weak desktop] id, attribute in
                guard let desktop, id == key.cgWindowID, attribute == kAXSizeAttribute as String else { return }
                let current = desktop.state.withLock { $0.windows[id]?.bounds }
                progression.withLock { if $0.firstWrite == nil { $0.firstWrite = current } }
            }
            $0.beforeRead = { [weak desktop] attribute in
                guard let desktop, attribute == kAXPositionAttribute as String else { return }
                let manual = progression.withLock { progress -> CGRect? in
                    guard var frame = progress.firstWrite else { return nil }
                    progress.positionReads += 1
                    guard progress.positionReads == 2 else { return nil }
                    frame.size.height = frame.height > midpoint ? 1025 : 1041
                    progress.manual = frame
                    return frame
                }
                if let manual { desktop.state.withLock { $0.windows[key.cgWindowID]?.bounds = manual } }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
        await controller.scanTask?.value
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await writer?.value

        let firstWrite = try XCTUnwrap(progression.withLock { $0.firstWrite })
        let manual = try XCTUnwrap(progression.withLock { $0.manual })
        let tolerance = WindowLiftAvoidance.frameVerificationTolerance
        XCTAssertGreaterThanOrEqual(firstWrite.height, targetHeight)
        XCTAssertLessThan(firstWrite.height, nativeHeight - tolerance)
        XCTAssertGreaterThan(manual.height, targetHeight + tolerance)
        XCTAssertLessThan(manual.height, nativeHeight - tolerance)
        XCTAssertGreaterThan(abs(manual.height - firstWrite.height), tolerance)
        XCTAssertEqual(desktop.state.withLock { $0.windows[key.cgWindowID]?.bounds }, manual)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        let stopped = await controller.stopAndRestore()
        XCTAssertEqual(stopped, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[key.cgWindowID]?.bounds }, manual)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
    }

    func testNativeValidationDoesNotBlockIndependentAsyncProgress() async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorLiftExecutorGate()
        desktop.state.withLock { $0.beforeRead = { if $0 == kAXFocusedWindowAttribute as String { gate.hold() } } }
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.writeTasks[.init(pid: -41000, cgWindowID: 1001)]?.value
        XCTAssertTrue(gate.progressedBeforeRelease.withLock { $0 }, "Native validation IPC must leave the constrained cooperative executor available")
        await controller.stopAndRestore()
    }

    func testNativeSizeWriteDoesNotBlockIndependentAsyncProgress() async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorLiftExecutorGate()
        desktop.state.withLock { $0.afterAttributeWrite = { id, attribute in
            if id == 1001, attribute == kAXSizeAttribute as String { gate.hold() }
        } }
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.writeTasks[.init(pid: -41000, cgWindowID: 1001)]?.value
        XCTAssertTrue(gate.progressedBeforeRelease.withLock { $0 }, "Native geometry IPC must leave the constrained cooperative executor available")
        await controller.stopAndRestore()
    }

    func testInstantLiftCannotWriteAnElementThatChangedWindowIdentityAfterValidation() async {
        let desktop = BehaviorDesktop()
        let sizeCapabilityChecks = Mutex(0)
        desktop.state.withLock {
            $0.beforeSettable = { attribute in
                guard attribute == kAXSizeAttribute as String else { return }
                let count = sizeCapabilityChecks.withLock { $0 += 1; return $0 }
                if count == 3 {
                    desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = 1002 }
                }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.poll()
        await controller.scanTask?.value
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await writer?.value
        XCTAssertGreaterThanOrEqual(sizeCapabilityChecks.withLock { $0 }, 3)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        await controller.stopAndRestore()
    }

    func testStoppingBeforeSizeWriteAdmissionPreventsAnyAXMutation() async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorReadGate(attribute: kAXSizeAttribute as String)
        let sizeCapabilityChecks = Mutex(0)
        desktop.state.withLock {
            $0.beforeSettable = { attribute in
                guard attribute == kAXSizeAttribute as String else { return }
                let count = sizeCapabilityChecks.withLock { $0 += 1; return $0 }
                if count == 3 { gate.read(attribute) }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        controller.stop()
        gate.release.signal()
        await controller.stopAndRestore()

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
    }

    func testStoppingRollsBackAnAdmittedSizeWriteThatAppliesAfterTheFirstNativeRead() async {
        let desktop = BehaviorDesktop()
        let gate = BehaviorReadGate(attribute: kAXSizeAttribute as String)
        let stage = Mutex((returnedTimeout: false, appliedLate: false))
        desktop.state.withLock {
            $0.beforeAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String,
                      !stage.withLock({ $0.returnedTimeout }) else { return nil }
                gate.read(attribute)
                stage.withLock { $0.returnedTimeout = true }
                return .cannotComplete
            }
            $0.beforeRead = { attribute in
                guard attribute == kAXSizeAttribute as String else { return }
                let applyLate = stage.withLock { state in
                    guard state.returnedTimeout, !state.appliedLate else { return false }
                    state.appliedLate = true
                    return true
                }
                if applyLate {
                    desktop.state.withLock { $0.windows[1001]?.bounds?.size.height = 1016 }
                }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        controller.stop()
        gate.release.signal()
        let completion = await controller.stopAndRestore()

        XCTAssertTrue(stage.withLock { $0.appliedLate })
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(completion, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
    }

    func testStoppingRechecksNativeFrameAfterRollingBackAnAcknowledgedAnimationFrame() async {
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let manual = CGRect(x: 300, y: 200, width: 600, height: 400)
        let sizeAttribute = kAXSizeAttribute as String
        for replacement in [nil, manual] as [CGRect?] {
            let desktop = BehaviorDesktop()
            let gate = BehaviorReadGate(attribute: sizeAttribute)
            let stage = Mutex((sizeWrites: 0, pendingFrame: CGRect?.none, applied: false))
            desktop.state.withLock {
                $0.beforeSizeWrite = { id, size in
                    guard id == 1001, size != native.size else { return nil }
                    let isInterruptedWrite = stage.withLock { value in
                        value.sizeWrites += 1
                        guard value.sizeWrites == 2 else { return false }
                        value.pendingFrame = CGRect(origin: native.origin, size: size)
                        return true
                    }
                    guard isInterruptedWrite else { return nil }
                    gate.read(sizeAttribute)
                    return .cannotComplete
                }
                $0.beforeRead = { attribute in
                    guard attribute == sizeAttribute,
                          desktop.state.withLock({ $0.windows[1001]?.bounds == native }) else { return }
                    let lateFrame = stage.withLock { value -> CGRect? in
                        guard let pendingFrame = value.pendingFrame, !value.applied else { return nil }
                        value.applied = true
                        return replacement ?? pendingFrame
                    }
                    if let lateFrame { desktop.state.withLock { $0.windows[1001]?.bounds = lateFrame } }
                }
            }
            let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.entered.withLock { $0 } }
            let intermediate = desktop.state.withLock { $0.windows[1001]?.bounds }
            XCTAssertNotEqual(intermediate, native)
            XCTAssertNotEqual(intermediate, stage.withLock { $0.pendingFrame })
            controller.stop()
            gate.release.signal()
            let completion = await controller.stopAndRestore()

            XCTAssertFalse(gate.timedOut.withLock { $0 })
            XCTAssertTrue(stage.withLock { $0.applied })
            XCTAssertEqual(completion, .complete)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, replacement ?? native)
        }
    }

    func testDeferredLiftRestorationRejectsAnElementThatChangedIdentityAfterCapture() {
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let target = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let start = timeval(tv_sec: 10, tv_usec: 1)
        let frames = WindowRestorationFrames(
            nativeAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: native, primaryDisplayHeight: 1080),
            targetAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: target, primaryDisplayHeight: 1080),
            primaryDisplayHeight: 1080
        )
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.windows[1001]?.bounds = target
            $0.beforeSettable = { attribute in
                guard attribute == kAXSizeAttribute as String else { return }
                desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = 1002 }
            }
        }
        let access = AXWindowRestorationAccess(reader: AXWindowReader(accessibility: desktop), processStartTime: { _ in start })

        let result = WindowRestorer(access: access).restore(key: key, frames: frames,
            expectedStartTime: start, liveWindowKeys: [key])

        XCTAssertEqual(result, .retry)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, target)
    }

    func testRestorationUsesTheNewNumberOfTheOriginalLiftedAXElement() throws {
        let desktop = BehaviorDesktop()
        let element = try XCTUnwrap(desktop.elements[1001])
        let start = timeval(tv_sec: 10, tv_usec: 1)
        let previous = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let current = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1009)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let target = CGRect(x: 0, y: 30, width: 1920, height: 1018)
        var frames = WindowRestorationFrames(
            nativeAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: native, primaryDisplayHeight: 1080),
            targetAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: target, primaryDisplayHeight: 1080),
            primaryDisplayHeight: 1080)
        frames.expectedElement = AXElementKey(e: element)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = target
            $0.windows[1001]?.cgWindowID = current.cgWindowID
            $0.nativeWindowIDOverrides[1001] = current.cgWindowID
        }
        let access = AXWindowRestorationAccess(reader: AXWindowReader(accessibility: desktop),
            processStartTime: { _ in start }, system: desktop)
        XCTAssertEqual(WindowRestorer(access: access).restore(key: previous, frames: frames,
            expectedStartTime: start, liveWindowKeys: [current]), .handled)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
    }

    func testDeferredLiftRestorationRetriesAnAdmittedPartialFrameAfterIdentityReturns() async {
        let desktop = BehaviorDesktop()
        let stage = Mutex((sizeApplied: false, identityReadsAfterSize: 0))
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let target = CGRect(x: 30, y: 45, width: 1920, height: 1016)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        desktop.state.withLock {
            $0.windows[1001]?.bounds = target
            $0.afterAttributeWrite = { id, attribute in
                if id == 1001, attribute == kAXSizeAttribute as String {
                    stage.withLock { $0.sizeApplied = true }
                }
            }
            $0.beforeWindowIDRead = { id in
                guard id == 1001 else { return }
                let wasReplaced = stage.withLock { value in
                    guard value.sizeApplied else { return false }
                    value.identityReadsAfterSize += 1
                    return value.identityReadsAfterSize == 1
                }
                desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = wasReplaced ? 1002 : nil }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        controller.enqueueRestorationForTesting(key: key, frames: WindowRestorationFrames(
            nativeAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: native, primaryDisplayHeight: 1080),
            targetAppKit: WindowLiftAvoidance.appKitCoordinates(fromQuartz: target, primaryDisplayHeight: 1080),
            primaryDisplayHeight: 1080, processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1))
        ))

        let result = await controller.stopAndRestore()

        XCTAssertEqual(result, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXPosition"])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
    }

    func testAnimatedLiftCannotContinueOrRollbackOnAChangedWindowIdentity() async throws {
        for cancelsWriter in [false, true] {
            let desktop = BehaviorDesktop()
            let gate = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) } }
            let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.entered.withLock { $0 } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = try XCTUnwrap(controller.writeTasks[key])
            let partial = try XCTUnwrap(desktop.state.withLock { $0.windows[1001]?.bounds })
            XCTAssertGreaterThan(partial.height, 1016)
            XCTAssertLessThan(partial.height, 1048)
            desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = 1002 }
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            if cancelsWriter { controller.stop() }
            gate.release.signal()
            await writer.value
            await controller.stopAndRestore()

            XCTAssertFalse(gate.timedOut.withLock { $0 })
            XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, partial)
        }
    }

    func testGuardedSizeWriteRejectsAWindowSwapDuringTheLastGeometryRead() throws {
        let desktop = BehaviorDesktop()
        let identityChecked = Mutex(false)
        let current = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        desktop.state.withLock {
            $0.beforeWindowIDRead = { id in
                if id == 1001 { identityChecked.withLock { $0 = true } }
            }
            $0.beforeRead = { attribute in
                guard attribute == kAXSizeAttribute as String, identityChecked.withLock({ $0 }) else { return }
                desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = 1002 }
            }
        }
        let element = try XCTUnwrap(desktop.elements[1001])

        let result = AXWindowReader(accessibility: desktop).setSize(
            CGSize(width: 1920, height: 1016), for: element,
            onlyIfCurrentMatches: current, expectedWindowID: 1001
        )

        XCTAssertEqual(result, .failure(reason: .windowIdentityChanged, rollback: .notRequested))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, current)
    }

    func testGuardedPositionWriteRejectsAWindowSwapDuringTheLastGeometryRead() throws {
        let desktop = BehaviorDesktop()
        let stage = Mutex((sizeWritten: false, checkedAfterSize: false))
        let current = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let target = CGRect(x: 60, y: 50, width: 1920, height: 1016)
        desktop.state.withLock {
            $0.afterAttributeWrite = { id, attribute in
                if id == 1001, attribute == kAXSizeAttribute as String {
                    stage.withLock { $0.sizeWritten = true }
                }
            }
            $0.beforeWindowIDRead = { id in
                if id == 1001 { stage.withLock { $0.checkedAfterSize = $0.sizeWritten } }
            }
            $0.beforeRead = { attribute in
                guard attribute == kAXSizeAttribute as String, stage.withLock({ $0.checkedAfterSize }) else { return }
                desktop.state.withLock { $0.nativeWindowIDOverrides[1001] = 1002 }
            }
        }
        let element = try XCTUnwrap(desktop.elements[1001])

        let result = AXWindowReader(accessibility: desktop).setFrame(
            target, for: element, onlyIfCurrentMatches: current, expectedWindowID: 1001
        )

        XCTAssertEqual(result, .failure(reason: .windowIdentityChanged, rollback: .notRequested))
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(origin: current.origin, size: target.size))
    }

    func testGuardedSizeWritePreservesAManualResizeDuringNativeIdentityRead() throws {
        let desktop = BehaviorDesktop()
        let identityReads = Mutex(0)
        let current = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let manual = CGRect(x: 0, y: 30, width: 1920, height: 1033)
        desktop.state.withLock {
            $0.beforeWindowIDRead = { id in
                guard id == 1001, identityReads.withLock({ $0 += 1; return $0 == 2 }) else { return }
                desktop.state.withLock { $0.windows[1001]?.bounds = manual }
            }
        }
        let element = try XCTUnwrap(desktop.elements[1001])

        let result = AXWindowReader(accessibility: desktop).setSize(
            CGSize(width: 1920, height: 1016), for: element,
            onlyIfCurrentMatches: current, expectedWindowID: 1001
        )

        XCTAssertEqual(result, .failure(reason: .initialFrameMismatch(expected: current, actual: manual),
                                        rollback: .notRequested))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manual)
    }

    func testGuardedPositionWritePreservesAManualMoveDuringNativeIdentityRead() throws {
        let desktop = BehaviorDesktop()
        let stage = Mutex((sizeWritten: false, identityReadsAfterSize: 0))
        let current = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let target = CGRect(x: 60, y: 50, width: 1920, height: 1016)
        let manual = CGRect(x: 20, y: 40, width: 1920, height: 1016)
        desktop.state.withLock {
            $0.afterAttributeWrite = { id, attribute in
                if id == 1001, attribute == kAXSizeAttribute as String {
                    stage.withLock { $0.sizeWritten = true }
                }
            }
            $0.beforeWindowIDRead = { id in
                guard id == 1001 else { return }
                let shouldMove = stage.withLock { value in
                    guard value.sizeWritten else { return false }
                    value.identityReadsAfterSize += 1
                    return value.identityReadsAfterSize == 2
                }
                if shouldMove { desktop.state.withLock { $0.windows[1001]?.bounds = manual } }
            }
        }
        let element = try XCTUnwrap(desktop.elements[1001])

        let result = AXWindowReader(accessibility: desktop).setFrame(
            target, for: element, onlyIfCurrentMatches: current,
            restoreOnFailureTo: current, expectedWindowID: 1001
        )

        XCTAssertEqual(result, .failure(reason: .verificationUnavailable,
                                        rollback: .failed(reason: .initialFrameMismatch(
                                            expected: CGRect(origin: current.origin, size: target.size), actual: manual),
                                            actualFrame: manual)))
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manual)
    }

    func testGuardedSizeWriteRejectsAWindowSwapDuringTheFinalFrameBatch() throws {
        let desktop = BehaviorDesktop()
        let identityReads = Mutex(0)
        let current = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        desktop.state.withLock {
            $0.windowIDAttributes[1001] = 1001
            $0.beforeWindowIDRead = { id in
                if id == 1001 { identityReads.withLock { $0 += 1 } }
            }
            $0.beforeFrameBatchRead = {
                guard identityReads.withLock({ $0 >= 2 }) else { return }
                desktop.state.withLock {
                    $0.nativeWindowIDOverrides[1001] = 1002
                    $0.windowIDAttributes[1001] = 1002
                }
            }
        }
        let element = try XCTUnwrap(desktop.elements[1001])

        let result = AXWindowReader(accessibility: desktop).setSize(
            CGSize(width: 1920, height: 1016), for: element,
            onlyIfCurrentMatches: current, expectedWindowID: 1001
        )

        XCTAssertEqual(result, .failure(reason: .windowIdentityChanged, rollback: .notRequested))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, current)
    }

    func testGuardedSizeWriteUsesTheLastAdmittedOriginForVerificationAndRollback() throws {
        let reference = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let admitted = CGRect(x: -2, y: 30, width: 1920, height: 1016)
        let restored = CGRect(origin: admitted.origin, size: reference.size)
        for failsAfterWriting in [false, true] {
            let desktop = BehaviorDesktop()
            let firstWrite = Mutex(true)
            desktop.state.withLock {
                $0.windows[1001]?.bounds?.origin.x = 2
                $0.beforeSettable = { attribute in
                    guard attribute == kAXSizeAttribute as String else { return }
                    desktop.state.withLock { $0.windows[1001]?.bounds?.origin.x = -2 }
                }
                if failsAfterWriting {
                    $0.beforeAttributeWrite = { id, attribute in
                        guard id == 1001, attribute == kAXSizeAttribute as String,
                              firstWrite.withLock({ first in defer { first = false }; return first }) else { return nil }
                        desktop.state.withLock { $0.windows[1001]?.bounds?.size = admitted.size }
                        return .cannotComplete
                    }
                }
            }
            let element = try XCTUnwrap(desktop.elements[1001])
            var attempts: [CGRect] = []
            let result = AXWindowReader(accessibility: desktop).setSize(
                admitted.size, for: element, frameVerificationTolerance: 2, onlyIfCurrentMatches: reference,
                restoreOnFailureTo: restored, onAttempt: { attempts.append($0) }
            )

            XCTAssertEqual(attempts, [admitted])
            if failsAfterWriting {
                XCTAssertEqual(result, .failure(reason: .writeFailed(attribute: .size, error: .cannotComplete),
                                                rollback: .restored(actualFrame: restored)))
                XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, restored)
            } else {
                XCTAssertEqual(result, .success(actualFrame: admitted))
                XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, admitted)
            }
        }
    }

    func testSlowNativeValidationAndWriteShareOneOperationBudget() async {
        let desktop = BehaviorDesktop()
        let reads = Mutex(0)
        desktop.state.withLock { $0.beforeRead = { attribute in
            guard attribute != kAXFocusedWindowAttribute as String else { return }
            reads.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.09)
        } }
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        let started = ProcessInfo.processInfo.systemUptime
        controller.poll()
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        await wait { controller.writeTasks[key] != nil }
        let writer = controller.writeTasks[key]
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await writer?.value
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThanOrEqual(reads.withLock { $0 }, 12, "A one-second transaction budget must stop additional IPC, even when each individual response is within its timeout")
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertFalse(desktop.state.withLock { $0.writes.contains("1001:AXSize") }, "Exhausted validation must not start a geometry write")
        desktop.state.withLock { $0.beforeRead = nil }
        await controller.stopAndRestore()
    }

    func testStopDrainsTheInFlightNativeSizeWriteBeforeRestoring() async {
        for manual in [false, true] {
            let desktop = BehaviorDesktop()
            let gate = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) } }
            let (controller, host) = makeController(desktop)
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.poll()
            await wait { gate.entered.withLock { $0 } }
            let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
            if manual { desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame } }
            controller.stop()
            let restoration = controller.restoreTask
            XCTAssertNotNil(restoration)
            XCTAssertFalse(controller.pendingRestorations.isEmpty)
            gate.release.signal()
            await restoration?.value
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manual ? manualFrame : CGRect(x: 0, y: 30, width: 1920, height: 1050))
            XCTAssertTrue(controller.writeTasks.isEmpty)
            XCTAssertTrue(controller.pendingRestorations.isEmpty)
        }
    }

    func testBudgetExpiryAfterAnAnimatedSizeWriteRestoresOnlyItsOwnPartialFrame() async {
        for manual in [false, true] {
            let desktop = BehaviorDesktop()
            let mutated = Mutex(false)
            let gate = BehaviorLiftWriteGate()
            let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
            desktop.state.withLock { $0.afterAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String else { return }
                let first = mutated.withLock { value in
                    let first = !value
                    value = true
                    return first
                }
                guard first else { return }
                if manual { desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame } }
                gate.didWrite(id, attribute: attribute)
                Thread.sleep(forTimeInterval: 1.05)
            } }
            let (controller, host) = makeController(desktop)
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await wait { gate.entered.withLock { $0 } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = controller.writeTasks[key]
            XCTAssertNotNil(writer)
            gate.release.signal()
            await writer?.value
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            let expected = manual ? manualFrame : CGRect(x: 0, y: 30, width: 1920, height: 1050)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected,
                "A deadline reached after mutation must drain guarded cleanup without stranding a partial animation or replacing a manual frame")
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        }
    }

    func testBudgetExpiredBeforeNativeSizeAdmissionIsNonmutating() {
        let desktop = BehaviorDesktop()
        let clock = Mutex<TimeInterval>(0)
        let sizeReads = Mutex(0)
        desktop.state.withLock { $0.beforeRead = { attribute in
            guard attribute == kAXSizeAttribute as String else { return }
            let lastRead = sizeReads.withLock { value in value += 1; return value == 2 }
            if lastRead { clock.withLock { $0 = 2 } }
        } }
        let reader = AXWindowReader(accessibility: desktop).withOperationBudget(
            OperationReadBudget(maximumDuration: 1, cancellation: OperationCancellation(), uptime: { clock.withLock { $0 } }))
        let original = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let result = reader.setSize(CGSize(width: 1920, height: 1018), for: desktop.elements[1001]!,
            onlyIfCurrentMatches: original)
        guard case let .failure(reason, rollback) = result else { return XCTFail("Expected exhausted operation") }
        XCTAssertFalse(reason.mayHaveMutatedWindow)
        XCTAssertEqual(rollback, .notRequested)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, original)
    }

    func testBudgetExpiryBeforeTheNextAnimatedWriteRestoresOnlyTheAcknowledgedFrame() async {
        for manual in [false, true] {
            let desktop = BehaviorDesktop()
            let gate = Mutex((written: false, armed: false, expired: false))
            let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
            desktop.state.withLock {
                $0.afterAttributeWrite = { id, attribute in
                    if id == 1001, attribute == kAXSizeAttribute as String { gate.withLock { $0.written = true } }
                }
                $0.beforeSettable = { attribute in
                    if attribute == kAXSizeAttribute as String {
                        gate.withLock { if $0.written && !$0.expired { $0.armed = true } }
                    }
                }
                $0.beforeRead = { attribute in
                    guard attribute == kAXSizeAttribute as String else { return }
                    let expire = gate.withLock { value in
                        guard value.armed && !value.expired else { return false }
                        value.expired = true
                        return true
                    }
                    guard expire else { return }
                    if manual { desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame } }
                    Thread.sleep(forTimeInterval: 1.05)
                }
            }
            let (controller, host) = makeController(desktop)
            defer { withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.withLock { $0.expired } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = controller.writeTasks[key] ?? controller.writeDrainTasks[key]?.values.first
            XCTAssertNotNil(writer)
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await writer?.value
            let expected = manual ? manualFrame : CGRect(x: 0, y: 30, width: 1920, height: 1050)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        }
    }

    func testTimedOutNativeWriteWithoutMutationRestoresOnlyThePreviousAnimatedFrame() async {
        for manual in [false, true] {
            let desktop = BehaviorDesktop()
            let gate = Mutex((admitted: 0, timedOut: false))
            let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
            desktop.state.withLock { $0.beforeAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String else { return nil }
                let expire = gate.withLock { value in
                    value.admitted += 1
                    guard value.admitted == 2 else { return false }
                    value.timedOut = true
                    return true
                }
                guard expire else { return nil }
                if manual { desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame } }
                Thread.sleep(forTimeInterval: 1.05)
                return .cannotComplete
            } }
            let (controller, host) = makeController(desktop)
            defer { withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.withLock { $0.timedOut } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = controller.writeTasks[key] ?? controller.writeDrainTasks[key]?.values.first
            XCTAssertNotNil(writer)
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await writer?.value
            let expected = manual ? manualFrame : CGRect(x: 0, y: 30, width: 1920, height: 1050)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        }
    }

    func testCancellingQueuedNativeValidationDoesNotStartItsIPC() async {
        let firstDesktop = BehaviorDesktop()
        let gate = BehaviorLiftWriteGate()
        firstDesktop.state.withLock { $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) } }
        let (firstController, firstHost) = makeController(firstDesktop)
        let secondDesktop = BehaviorDesktop()
        let secondReads = Mutex(0)
        secondDesktop.state.withLock { $0.beforeRead = { _ in secondReads.withLock { $0 += 1 } } }
        let (secondController, secondHost) = makeController(secondDesktop)
        defer { gate.release.signal(); withExtendedLifetime((firstHost, secondHost)) {} }
        firstController.poll()
        await wait { gate.entered.withLock { $0 } }
        firstController.isEnabled = false
        firstController.updatePollTimerLifecycle()
        firstController.updateTrackedProbeLifecycle()
        secondController.poll()
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        await wait { secondController.writeTasks[key] != nil }
        let queuedWriter = secondController.writeTasks[key]
        try? await Task.sleep(for: .milliseconds(20))
        secondController.isEnabled = false
        secondController.updatePollTimerLifecycle()
        secondController.updateTrackedProbeLifecycle()
        secondController.clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        gate.release.signal()
        await queuedWriter?.value
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(secondReads.withLock { $0 }, 0)
        XCTAssertTrue(secondDesktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(secondDesktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        await firstController.stopAndRestore()
        await secondController.stopAndRestore()
    }

    func testQuitRestoresAnAcknowledgedSizeThatAppearsAfterTheFirstCleanupRead() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let writeGate = BehaviorReadGate(attribute: kAXSizeAttribute as String)
        let requested = Mutex<CGSize?>(nil)
        let firstCleanupRead = Mutex(false)
        desktop.state.withLock {
            $0.omittedCG = [1002, 2001]
            $0.beforeSizeWrite = { id, size in
                guard id == 1001, size.height < native.height else { return nil }
                requested.withLock { $0 = size }
                writeGate.read(kAXSizeAttribute as String)
                return .success
            }
            $0.beforeRead = { [weak desktop] attribute in
                guard attribute == kAXSizeAttribute as String, let desktop,
                      let size = requested.withLock({ $0 }) else { return }
                let first = firstCleanupRead.withLock {
                    let first = !$0
                    $0 = true
                    return first
                }
                if first { desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(origin: native.origin, size: size) } }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { writeGate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { writeGate.entered.withLock { $0 } }
        controller.stop()
        writeGate.release.signal()
        let result = await controller.stopAndRestore()
        XCTAssertFalse(writeGate.timedOut.withLock { $0 })
        XCTAssertTrue(firstCleanupRead.withLock { $0 })
        XCTAssertEqual(result, .complete)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
    }

    func testPermissionUncertaintyCancelsAQueuedAnimationStepAndRestoresItsAcknowledgedFrame() async {
        for manual in [false, true] {
            let desktop = BehaviorDesktop()
            let firstWrite = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { firstWrite.didWrite($0, attribute: $1) } }
            let (controller, host) = makeController(desktop)
            let blockingDesktop = BehaviorDesktop()
            let blocker = BehaviorReadGate()
            blockingDesktop.state.withLock { $0.beforeRead = { blocker.read($0) } }
            let (blockingController, blockingHost) = makeController(blockingDesktop)
            defer { firstWrite.release.signal(); blocker.release.signal(); withExtendedLifetime((host, blockingHost)) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { firstWrite.entered.withLock { $0 } }
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            blockingController.poll()
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            await wait { blockingController.writeTasks[key] != nil }
            let writer = controller.writeTasks[key]
            XCTAssertNotNil(writer)
            firstWrite.release.signal()
            await wait { blocker.entered.withLock { $0 } }
            try? await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" }.count }, 1)
            let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
            desktop.state.withLock {
                $0.focused = nil
                if manual { $0.windows[1001]?.bounds = manualFrame }
            }
            controller.beginPermissionUncertainty()
            controller.endPermissionUncertainty()
            blockingController.isEnabled = false
            blockingController.updatePollTimerLifecycle()
            blockingController.updateTrackedProbeLifecycle()
            blockingController.clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
            blocker.release.signal()
            await writer?.value
            await wait { controller.isEnabled }
            XCTAssertFalse(firstWrite.timedOut.withLock { $0 })
            XCTAssertFalse(blocker.timedOut.withLock { $0 })
            let expected = manual ? manualFrame : CGRect(x: 0, y: 30, width: 1920, height: 1050)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
            await controller.stopAndRestore()
            await blockingController.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        }
    }

    func testPermissionUncertaintyRetainsAnUnreadCancelledAnimatedWriteUntilNativeRestoration() async throws {
        for unread in [false, true] {
            let desktop = BehaviorDesktop()
            let gate = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { id, attribute in
                if unread, id == 1001, attribute == kAXSizeAttribute as String {
                    _ = desktop.state.withLock { $0.unreadPositions.insert(1001) }
                }
                gate.didWrite(id, attribute: attribute)
            } }
            let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.entered.withLock { $0 } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = try XCTUnwrap(controller.writeTasks[key])
            let partial = try XCTUnwrap(desktop.state.withLock { $0.windows[1001]?.bounds })
            XCTAssertGreaterThan(abs(partial.height - 1050), 2)
            XCTAssertGreaterThanOrEqual(partial.height, 1016)
            desktop.state.withLock { $0.focused = nil }
            controller.beginPermissionUncertainty()
            controller.endPermissionUncertainty()
            gate.release.signal()
            await writer.value
            await wait { controller.isEnabled }
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            let unavailableCompletion = await controller.stopAndRestore()
            XCTAssertFalse(gate.timedOut.withLock { $0 })
            if unread {
                XCTAssertEqual(unavailableCompletion, .incomplete(remaining: 1))
                XCTAssertNotNil(controller.pendingRestorations[key])
                XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, partial)
            } else {
                XCTAssertEqual(unavailableCompletion, .complete)
                XCTAssertTrue(controller.pendingRestorations.isEmpty)
                XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
            }
            desktop.state.withLock {
                $0.unreadPositions.remove(1001)
                $0.afterAttributeWrite = nil
            }
            let completion = await controller.stopAndRestore()
            XCTAssertEqual(completion, .complete)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
            XCTAssertTrue(controller.pendingRestorations.isEmpty)
        }
    }

    func testDelayedRestorationAfterUnreadCancellationPreservesManualFramesAndReusedProcesses() async throws {
        for change in 0..<3 {
            let desktop = BehaviorDesktop()
            let gate = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String else { return }
                _ = desktop.state.withLock { $0.unreadPositions.insert(1001) }
                gate.didWrite(id, attribute: attribute)
            } }
            let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            await wait { gate.entered.withLock { $0 } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = try XCTUnwrap(controller.writeTasks[key])
            let partial = try XCTUnwrap(desktop.state.withLock { $0.windows[1001]?.bounds })
            XCTAssertGreaterThan(abs(partial.height - 1050), 2)
            XCTAssertGreaterThanOrEqual(partial.height, 1016)
            desktop.state.withLock { $0.focused = nil }
            controller.beginPermissionUncertainty()
            controller.endPermissionUncertainty()
            gate.release.signal()
            await writer.value
            await wait { controller.isEnabled }
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            let unavailableCompletion = await controller.stopAndRestore()
            XCTAssertEqual(unavailableCompletion, .incomplete(remaining: 1))
            XCTAssertNotNil(controller.pendingRestorations[key])
            let manualFrame = change == 0 ? CGRect(x: 300, y: 200, width: 600, height: 400) :
                CGRect(x: 0, y: 30, width: 1920, height: partial.height > 1032 ? 1022 : 1043)
            desktop.state.withLock {
                $0.unreadPositions.remove(1001)
                $0.afterAttributeWrite = nil
                if change == 2 { $0.generationsByPID[-41000] = ProcessGeneration(timeval(tv_sec: 11, tv_usec: 1)) }
                else { $0.windows[1001]?.bounds = manualFrame }
            }
            let writesBeforeRecovery = desktop.state.withLock { $0.writes }
            let completion = await controller.stopAndRestore()
            XCTAssertEqual(completion, .complete)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, change == 2 ? partial : manualFrame)
            XCTAssertEqual(desktop.state.withLock { $0.writes }, writesBeforeRecovery)
            XCTAssertTrue(controller.pendingRestorations.isEmpty)
            XCTAssertFalse(gate.timedOut.withLock { $0 })
        }
    }

    func testFrozenControllerRetainsCompletedWriteFramesUntilRestoration() async throws {
        let desktop = BehaviorDesktop()
        let gate = BehaviorLiftWriteGate()
        let restorationStarted = Mutex(false)
        let postWriteFrameReads = Mutex<[String]>([])
        let restorationFrames = Mutex<[WindowRestorationFrames]>([])
        let framesAtRestoration = Mutex<[CGRect?]>([])
        desktop.state.withLock {
            $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) }
            $0.beforeRead = { attribute in
                if gate.entered.withLock({ $0 }), !restorationStarted.withLock({ $0 }),
                   attribute == kAXPositionAttribute as String || attribute == kAXSizeAttribute as String {
                    postWriteFrameReads.withLock { $0.append(attribute) }
                }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter(),
            beforeRestoration: { key, frames in
                guard key == .init(pid: -41000, cgWindowID: 1001) else { return }
                restorationStarted.withLock { $0 = true }
                restorationFrames.withLock { $0.append(frames) }
                framesAtRestoration.withLock { $0.append(desktop.state.withLock { $0.windows[1001]?.bounds }) }
            })
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { gate.entered.withLock { $0 } }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let writer = try XCTUnwrap(controller.writeTasks.removeValue(forKey: key))
        desktop.state.withLock { $0.focused = nil }
        controller.beginPermissionUncertainty()
        XCTAssertFalse(writer.isCancelled)
        gate.release.signal()
        await writer.value
        XCTAssertNotNil(controller.pendingRestorations[key])
        controller.endPermissionUncertainty()
        await wait { controller.isEnabled }
        let completion = await controller.stopAndRestore()
        XCTAssertEqual(completion, .complete)
        XCTAssertEqual(postWriteFrameReads.withLock { $0 }, [kAXPositionAttribute as String, kAXSizeAttribute as String],
            "The completed outcome must reach freeze without entering cancellation rollback")
        XCTAssertEqual(framesAtRestoration.withLock { $0 }, [CGRect(x: 0, y: 30, width: 1920, height: 1016)],
            "Restoration must receive the completed target before any rollback writes the native frame")
        let capturedFrames = try XCTUnwrap(restorationFrames.withLock { $0.first })
        XCTAssertEqual(capturedFrames.nativeQuartz, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertEqual(capturedFrames.targetQuartz, CGRect(x: 0, y: 30, width: 1920, height: 1016))
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertFalse(gate.timedOut.withLock { $0 })
    }

    func testDeadWindowChurnReleasesObservationMetadataAfterDraining() async {
        let desktop = BehaviorDesktop(additionalWindows: 12)
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        desktop.state.withLock { $0.windows = $0.windows.filter { $0.key >= 3000 } }
        for id in CGWindowID(3000)..<CGWindowID(3012) {
            desktop.state.withLock { $0.focused = id }
            controller.poll()
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: id)
            await wait { if case .lifted = controller.states[key] { return true }; return false }
            desktop.state.withLock { $0.windows.removeValue(forKey: id) }
            controller.poll()
            if let scan = controller.scanTask { await scan.value }
            await wait { controller.states[key] == nil }
        }
        let activeWatermarks = Mirror(reflecting: controller).children.first { $0.label == "observationWatermarks" }?.value
            as? [WindowLiftAvoidance.WindowKey: UInt64]
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(activeWatermarks?.count, 0, "Pruned metadata must be released while the controller remains running")
        await controller.stopAndRestore()
        let watermarks = Mirror(reflecting: controller).children.first { $0.label == "observationWatermarks" }?.value
            as? [WindowLiftAvoidance.WindowKey: UInt64]
        XCTAssertNotNil(watermarks)
        XCTAssertEqual(watermarks?.count, 0, "Closed windows must not leave metadata proportional to lifetime window churn")
        XCTAssertTrue(controller.writeDrainTasks.isEmpty)
    }

    func testStopDrainsRetiredWritersAfterMonitoringAndSessionsAreAlreadyCleared() async {
        let desktop = BehaviorDesktop()
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let gate = AsyncStream<Void>.makeStream()
        let writerFinished = Mutex(false)
        let writer = Task.detached {
            for await _ in gate.stream {}
            writerFinished.withLock { $0 = true }
        }
        defer { gate.continuation.finish() }
        controller.isEnabled = false
        controller.writeDrainTasks[key] = [UUID(): writer]
        controller.clearManagedSession(for: key, cancelWriter: false, reason: "applicationTerminated")
        XCTAssertTrue(controller.states.isEmpty)
        XCTAssertFalse(controller.isEnabled)
        var stopped = false
        let stopping = Task { await controller.stopAndRestore(); stopped = true }

        await wait { stopped || controller.restoreTask != nil }
        XCTAssertFalse(stopped, "Stopping still owns the drain after the visible session has been cleared")
        XCTAssertFalse(writerFinished.withLock { $0 })
        XCTAssertTrue(controller.writeDrainTasks.isEmpty)
        gate.continuation.finish()
        await stopping.value
        await writer.value

        XCTAssertTrue(stopped)
        XCTAssertTrue(writerFinished.withLock { $0 })
        XCTAssertTrue(controller.writeDrainTasks.isEmpty)
        XCTAssertNil(controller.restoreTask)
        let watermarks = Mirror(reflecting: controller).children.first { $0.label == "observationWatermarks" }?.value
            as? [WindowLiftAvoidance.WindowKey: UInt64]
        XCTAssertEqual(watermarks?.count, 0)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
    }

    func testClearedSessionRejectsAnAlreadyCapturedScanBeforeReleasingItsMetadata() async {
        let desktop = BehaviorDesktop()
        let probe = BehaviorLiftProbeGate(desktop)
        let (controller, host) = makeController(desktop, probe: probe)
        defer { probe.release.signal(); withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.poll()
        await wait { if case .lifted = controller.states[key] { return true }; return false }
        controller.trackedProbeTimer?.invalidate()
        controller.trackedProbeTimer = nil
        if let prior = controller.trackedProbeTask { await prior.value }
        desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050) }
        probe.state.withLock { $0.holdNext = true }
        controller.poll()
        await wait { probe.state.withLock { $0.entered } }
        let pending = controller.scanTask
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        controller.clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        let writes = desktop.state.withLock { $0.writes }
        probe.release.signal()
        await pending?.value
        XCTAssertNil(controller.states[key], "A scan captured before session invalidation must not resurrect its writer")
        XCTAssertEqual(desktop.state.withLock { $0.writes }, writes)
        await controller.stopAndRestore()
        let watermarks = Mirror(reflecting: controller).children.first { $0.label == "observationWatermarks" }?.value
            as? [WindowLiftAvoidance.WindowKey: UInt64]
        XCTAssertEqual(watermarks?.count, 0)
    }

    func testProductionCaptureAndWriterAdjustHeightThenRestoreTheConfirmedFrame() async throws {
        let desktop = BehaviorDesktop()
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await wait { desktop.state.withLock { $0.windows[1001]?.bounds == CGRect(x: 0, y: 30, width: 1920, height: 1016) } }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        await wait { if case .lifted = controller.states[key] { return true }; return false }
        XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertEqual(controller.pendingRestorations.count, 0)
        XCTAssertTrue(desktop.state.withLock { $0.writes.contains("1001:AXSize") })
    }

    func testMeasuredWeatherHeightSurvivesTransientVerificationReads() async {
        for animated in [false, true] {
            for attribute in [kAXPositionAttribute as String, kAXSizeAttribute as String] {
                let desktop = BehaviorDesktop()
                let native = CGRect(x: 0, y: 30, width: 2560, height: 1410)
                desktop.state.withLock {
                    $0.windows[1001]?.bounds = native
                    $0.afterAttributeWrite = { id, name in
                        guard id == 1001, name == kAXSizeAttribute as String else { return }
                        desktop.state.withLock { $0.transientFrameReadFailures[id] = [attribute: 1] }
                    }
                }
                let (controller, host) = makeController(desktop, width: 2560, height: 1440,
                                                        workspaceNotificationCenter: NotificationCenter())
                controller.isEnabled = false
                controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": animated ? "1" : "0"])
                let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
                await wait { if case .lifted = controller.states[key] { return true }; return false }
                let adjusted = desktop.state.withLock { $0.windows[1001]?.bounds }
                XCTAssertEqual(adjusted?.origin, CGPoint(x: 0, y: 30))
                XCTAssertEqual(adjusted?.width, 2560)
                XCTAssertEqual(adjusted?.height ?? .infinity, 1376, accuracy: 2)
                XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds },
                               CGRect(x: 0, y: 30, width: 1920, height: 1050))
                await controller.stopAndRestore()
                XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
                XCTAssertTrue(controller.pendingRestorations.isEmpty)
                withExtendedLifetime(host) {}
            }
        }
    }

    func testFrameWriteRetriesTransientVerificationAfterEachGeometryWrite() {
        for attribute in [kAXPositionAttribute as String, kAXSizeAttribute as String] {
            let desktop = BehaviorDesktop()
            desktop.state.withLock { $0.afterAttributeWrite = { id, name in
                guard id == 1001,
                      name == kAXSizeAttribute as String || name == kAXPositionAttribute as String else { return }
                desktop.state.withLock { $0.transientFrameReadFailures[id] = [attribute: 1] }
            } }
            let reader = AXWindowReader(accessibility: desktop)
            let target = CGRect(x: 200, y: 100, width: 1920, height: 1016)
            let result = reader.setFrame(target, for: desktop.elements[1001]!,
                onlyIfCurrentMatches: CGRect(x: 0, y: 30, width: 1920, height: 1050))
            guard case let .success(actual) = result else { XCTFail("Transient verification must recover: \(result)"); continue }
            XCTAssertEqual(actual, target)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, target)
            XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize", "1001:AXPosition"])
        }
    }

    func testApplicationSwitchDuringHeightWriteDoesNotExpandThePreviousWindow() async {
        let nextApplication = NSRunningApplication.current
        for animated in [false, true] {
            let desktop = BehaviorDesktop(browserPID: nextApplication.processIdentifier)
            let gate = BehaviorLiftWriteGate()
            desktop.state.withLock { $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) } }
            let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none })
            let (controller, host) = makeController(desktop, geometryObserver: observer)
            defer { gate.release.signal(); withExtendedLifetime(host) {} }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": animated ? "1" : "0"])
            for task in observer.work.pendingForTesting { await task.value }
            await wait { gate.entered.withLock { $0 } }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            let writer = controller.writeTasks[key]
            XCTAssertNotNil(writer)
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            let observationGeneration = observer.work.generation
            _ = desktop.setFrontmost(pid: nextApplication.processIdentifier, windowID: 2001, mode: 0)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: nextApplication])
            await wait { observer.work.generation != observationGeneration }
            gate.release.signal()
            await writer?.value
            XCTAssertFalse(gate.timedOut.withLock { $0 }, "The activation must be delivered before the write is released")
            if let adjusted = desktop.state.withLock({ $0.windows[1001]?.bounds }) {
                XCTAssertEqual(adjusted.origin, CGPoint(x: 0, y: 30))
                XCTAssertEqual(adjusted.width, 1920)
                XCTAssertLessThanOrEqual(adjusted.maxY, 1048, "Keep the bottom above the 32-point taskbar, animated=\(animated)")
                XCTAssertGreaterThanOrEqual(adjusted.maxY, 1044, "Preserve the bounded native sizing tolerance")
            } else { XCTFail("The adjusted window must remain available") }
            XCTAssertNotNil(controller.managedFrames[key], "Keep restoration metadata after a focus change")
            XCTAssertTrue({ if case .lifted = controller.states[key] { return true }; return false }())
            XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds },
                           CGRect(x: 0, y: 30, width: 1920, height: 1050))
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                           CGRect(x: 0, y: 30, width: 1920, height: 1050))
        }
    }

    func testApplicationSwitchBeforeTheFirstHeightWriteLeavesTheWindowUntouched() async {
        let nextApplication = NSRunningApplication.current
        let desktop = BehaviorDesktop(browserPID: nextApplication.processIdentifier)
        let validationStarted = Mutex(false)
        desktop.state.withLock {
            $0.unreadPositions = [1001]
            $0.beforeRead = { attribute in
                if attribute == kAXPositionAttribute as String { validationStarted.withLock { $0 = true } }
            }
        }
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none })
        let (controller, host) = makeController(desktop, geometryObserver: observer)
        defer { withExtendedLifetime(host) {} }
        controller.isEnabled = false
        controller.start(environment: [:])
        for task in observer.work.pendingForTesting { await task.value }
        await wait { validationStarted.withLock { $0 } }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        let observationGeneration = observer.work.generation
        _ = desktop.setFrontmost(pid: nextApplication.processIdentifier, windowID: 2001, mode: 0)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: nextApplication])
        await wait { observer.work.generation != observationGeneration }
        await writer?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                       CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertFalse(desktop.state.withLock { $0.writes.contains("1001:AXSize") })
        XCTAssertNil(controller.managedFrames[key])
        await controller.stopAndRestore()
    }

    func testManualGeometryDuringAFocusSwitchIsPreservedByTheInFlightWriter() async {
        let nextApplication = NSRunningApplication.current
        let desktop = BehaviorDesktop(browserPID: nextApplication.processIdentifier)
        let gate = BehaviorLiftWriteGate()
        desktop.state.withLock { $0.afterAttributeWrite = { gate.didWrite($0, attribute: $1) } }
        let observer = FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none })
        let (controller, host) = makeController(desktop, geometryObserver: observer)
        defer { gate.release.signal(); withExtendedLifetime(host) {} }
        controller.isEnabled = false
        controller.start(environment: [:])
        for task in observer.work.pendingForTesting { await task.value }
        await wait { gate.entered.withLock { $0 } }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        let observationGeneration = observer.work.generation
        _ = desktop.setFrontmost(pid: nextApplication.processIdentifier, windowID: 2001, mode: 0)
        let manualFrame = CGRect(x: 300, y: 200, width: 600, height: 400)
        desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: nextApplication])
        await wait { observer.work.generation != observationGeneration }
        gate.release.signal()
        await writer?.value
        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manualFrame)
        XCTAssertNil(controller.managedFrames[key])
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manualFrame)
    }

    func testHorizontallyOffscreenWindowClearsTaskbarAfterRepeatedMovesAndRestoresItsLatestFrame() async {
        for animated in [false, true] {
            let desktop = BehaviorDesktop()
            let clock = Mutex<TimeInterval>(10)
            let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } },
                workspaceNotificationCenter: NotificationCenter())
            defer { withExtendedLifetime(host) {} }
            let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            host.contexts = [.init(geometry: .init(screenFrame: screen,
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050), taskbarTopEdge: 32),
                displayWindowServerFrame: screen, usableWindowServerFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                primaryDisplayHeight: 1080)]
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            desktop.state.withLock {
                $0.windows[1001]?.bounds = CGRect(x: -200, y: 30, width: 960, height: 1050)
            }
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": animated ? "1" : "0", "DOCK_WINDOW_LIFT_TILES": "1"])
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            for x: CGFloat in [-200, 1160, -250] {
                clock.withLock { $0 += 2 }
                desktop.state.withLock {
                    $0.windows[1001]?.bounds = CGRect(x: x, y: 30, width: 960, height: 1050)
                }
                for _ in 0..<2 {
                    controller.isEnabled = true
                    controller.poll()
                    controller.isEnabled = false
                    controller.updatePollTimerLifecycle()
                    controller.updateTrackedProbeLifecycle()
                    await controller.scanTask?.value
                    await controller.writeTasks[key]?.value
                }
                let actual = desktop.state.withLock { $0.windows[1001]?.bounds }
                XCTAssertEqual(actual?.origin, CGPoint(x: x, y: 30))
                XCTAssertEqual(actual?.width, 960)
                if animated {
                    XCTAssertEqual(actual?.height ?? 0, 1016, accuracy: 2)
                } else {
                    XCTAssertEqual(actual?.height, 1016)
                }
                XCTAssertNotNil(controller.managedFrames[key])
            }
            XCTAssertTrue(desktop.state.withLock { $0.writes.contains("1001:AXSize") })
            XCTAssertFalse(desktop.state.withLock { $0.writes.contains("1001:AXPosition") })
            XCTAssertEqual(desktop.state.withLock { $0.windows[1002]?.bounds },
                           CGRect(x: 0, y: 30, width: 1920, height: 1050))
            XCTAssertEqual(desktop.state.withLock { $0.windows[2001]?.bounds },
                           CGRect(x: 0, y: 30, width: 1920, height: 1050))
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                           CGRect(x: -250, y: 30, width: 960, height: 1050))
        }
    }

    func testMeasuredChatGPTFrameOnTheSecondaryDisplayTraversesTheProductionWriter() async {
        let desktop = BehaviorDesktop()
        let native = CGRect(x: 3797, y: 30, width: 1339, height: 1410)
        desktop.state.withLock { $0.windows[1001]?.bounds = native }
        let (controller, host) = makeController(desktop, width: 2560, height: 1440,
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let screen = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
        host.contexts = [.init(geometry: .init(screenFrame: screen, visibleFrame: screen,
            taskbarTopEdge: 32, topReservedHeight: 22), displayWindowServerFrame: screen, usableWindowServerFrame: screen,
            primaryDisplayHeight: 1440)]
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "0", "DOCK_WINDOW_LIFT_TILES": "1"])
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                       CGRect(x: 3797, y: 30, width: 1339, height: 1376))
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, native)
    }

    func testPrivateWorkspaceCenterIsolatesGeometryFromNativeActivationEvents() async {
        let nativeCenter = NSWorkspace.shared.notificationCenter
        for isolated in [false, true] {
            let desktop = BehaviorDesktop()
            let posted = Mutex(false)
            desktop.state.withLock { $0.beforeRead = { attribute in
                guard attribute == kAXFocusedWindowAttribute as String else { return }
                let first = posted.withLock { value in
                    let result = !value
                    value = true
                    return result
                }
                if first {
                    nativeCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
                }
            } }
            let (controller, host) = makeController(desktop,
                workspaceNotificationCenter: isolated ? NotificationCenter() : nativeCenter)
            defer { withExtendedLifetime(host) {} }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "0"])
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await controller.scanTask?.value
            await controller.writeTasks[key]?.value
            XCTAssertTrue(posted.withLock { $0 })
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                           CGRect(x: 0, y: 30, width: 1920, height: isolated ? 1016 : 1050))
            XCTAssertEqual(desktop.state.withLock { $0.writes.contains("1001:AXSize") }, isolated)
            await controller.stopAndRestore()
        }
    }

    func testInterruptedAnimatedFrameRecoversAfterFailedRollbackWithoutReplacingManualOrReusedWindows() async {
        for mode in 0..<6 {
            let desktop = BehaviorDesktop()
            let change = mode % 3
            let clock = Mutex<TimeInterval>(10)
            failFrameReadsAfterAnimatedWrite(desktop, afterAcknowledgement: mode >= 3)
            let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } },
                workspaceNotificationCenter: NotificationCenter())
            defer { withExtendedLifetime(host) {} }
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            controller.isEnabled = false
            controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            await controller.scanTask?.value
            await controller.writeTasks[key]?.value
            let partial = desktop.state.withLock { $0.windows[1001]?.bounds }
            let partialHeight = partial?.height ?? 0
            XCTAssertGreaterThan(partialHeight, 1016)
            XCTAssertLessThan(partialHeight, 1048)
            XCTAssertNotNil(controller.pendingRestorations[key])
            let manual = CGRect(x: 300, y: 200, width: 600, height: 400)
            desktop.state.withLock {
                $0.afterAttributeWrite = nil
                $0.beforeSettable = nil
                $0.unreadPositions.remove(1001)
                if change == 1 { $0.windows[1001]?.bounds = manual }
                if change == 2 { $0.generationsByPID[-41000] = ProcessGeneration(timeval(tv_sec: 11, tv_usec: 1)) }
            }
            clock.withLock { $0 += 6 }
            controller.isEnabled = true
            controller.poll()
            controller.isEnabled = false
            controller.updatePollTimerLifecycle()
            controller.updateTrackedProbeLifecycle()
            let restoration = controller.restoreTask
            XCTAssertNotNil(restoration)
            await restoration?.value
            let expected = change == 0 ? CGRect(x: 0, y: 30, width: 1920, height: 1050) : (change == 1 ? manual : partial)
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
            XCTAssertNil(controller.pendingRestorations[key])
            if change == 0 {
                clock.withLock { $0 += 2 }
                controller.isEnabled = true
                controller.poll()
                controller.isEnabled = false
                controller.updatePollTimerLifecycle()
                controller.updateTrackedProbeLifecycle()
                await controller.scanTask?.value
                await controller.writeTasks[key]?.value
                let adjusted = desktop.state.withLock { $0.windows[1001]?.bounds }
                XCTAssertEqual(adjusted?.origin, CGPoint(x: 0, y: 30))
                XCTAssertEqual(adjusted?.height ?? 0, 1016, accuracy: 2)
            }
            await controller.stopAndRestore()
            XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
            XCTAssertTrue(controller.pendingRestorations.isEmpty)
        }
    }

    func testUnreadAnimatedFrameCanFinishOnceWithoutReactivation() async {
        await checkUnreadAnimatedFrameRecovery(replacement: nil)
    }

    func testUnreadAnimatedFramePreservesAManualReplacement() async {
        await checkUnreadAnimatedFrameRecovery(replacement: CGRect(x: 300, y: 200, width: 600, height: 400))
    }

    func testUnreadAnimatedFrameDoesNotTakeOwnershipOfAnExternalTarget() async {
        await checkUnreadAnimatedFrameRecovery(replacement: CGRect(x: 0, y: 30, width: 1920, height: 1016))
    }

    func testUnreadAnimatedFrameDoesNotWriteAfterTheOriginalDeadline() async {
        await checkUnreadAnimatedFrameRecovery(replacement: nil, expires: true)
    }

    func testUnreadAnimatedFrameRechecksProcessIdentityBeforeWriting() async {
        await checkUnreadAnimatedFrameRecovery(replacement: nil, replacesProcess: true)
    }

    func testUnreadAnimatedFrameChecksGeometryAfterReadingWindowIdentity() async {
        await checkUnreadAnimatedFrameRecovery(replacement: CGRect(x: 300, y: 200, width: 600, height: 400),
                                               movesDuringIdentityRead: true)
    }

    func testUnreadAnimatedFrameDoesNotRollbackIntoAReplacedProcess() async {
        await checkUnreadAnimatedFrameRecovery(replacement: nil, replacesProcessAfterWrite: true)
    }

    private func checkUnreadAnimatedFrameRecovery(
        replacement: CGRect?, expires: Bool = false, replacesProcess: Bool = false,
        movesDuringIdentityRead: Bool = false, replacesProcessAfterWrite: Bool = false
    ) async {
        let desktop = BehaviorDesktop()
        let stage = Mutex((writes: 0, positionReads: 0, interruptedHeight: CGFloat.zero))
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        desktop.state.withLock {
            $0.windows[1002]?.bounds = CGRect(x: 50, y: 100, width: 600, height: 450)
            $0.windows[2001]?.bounds = CGRect(x: 200, y: 140, width: 900, height: 600)
            $0.afterAttributeWrite = { id, attribute in
                guard id == 1001, attribute == kAXSizeAttribute as String else { return }
                let count = stage.withLock { value in
                    value.writes += 1
                    return value.writes
                }
                guard replacesProcessAfterWrite, count == 2 else { return }
                desktop.state.withLock {
                    $0.generationsByPID[-41000] = ProcessGeneration(timeval(tv_sec: 20, tv_usec: 1))
                    $0.transientFrameReadFailures[1001] = [kAXPositionAttribute as String: 2]
                }
            }
            $0.beforeRead = { attribute in
                guard attribute == kAXPositionAttribute as String else { return }
                let interrupt = stage.withLock { value in
                    guard value.writes > 0 else { return false }
                    value.positionReads += 1
                    return value.positionReads == 2
                }
                guard interrupt else { return }
                let height = desktop.state.withLock { value in
                    let existingHeight = value.windows[1001]?.bounds?.height ?? 0
                    value.frontmostPIDOverride = -42000
                    value.focused = 2001
                    value.transientFrameReadFailures[1001] = [kAXPositionAttribute as String: 2]
                    if let replacement, !movesDuringIdentityRead { value.windows[1001]?.bounds = replacement }
                    return existingHeight
                }
                stage.withLock { $0.interruptedHeight = height }
                if expires { Thread.sleep(forTimeInterval: 1.05) }
            }
            $0.beforeSettable = { attribute in
                guard replacesProcess, attribute == kAXSizeAttribute as String,
                      stage.withLock({ $0.positionReads >= 4 }) else { return }
                desktop.state.withLock {
                    $0.generationsByPID[-41000] = ProcessGeneration(timeval(tv_sec: 20, tv_usec: 1))
                }
            }
            $0.beforeWindowIDRead = { id in
                guard movesDuringIdentityRead, id == 1001, let replacement,
                      stage.withLock({ $0.positionReads >= 4 }) else { return }
                desktop.state.withLock { $0.windows[1001]?.bounds = replacement }
            }
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
        await controller.scanTask?.value
        let writer = controller.writeTasks[key]
        XCTAssertNotNil(writer)
        await writer?.value
        await controller.restoreTask?.value

        let interruptedHeight = stage.withLock { $0.interruptedHeight }
        XCTAssertGreaterThan(interruptedHeight, adjusted.height)
        XCTAssertLessThan(interruptedHeight, native.height)
        XCTAssertFalse(desktop.app(-41000)?.isActive ?? true)
        let interrupted = CGRect(origin: native.origin, size: CGSize(width: native.width, height: interruptedHeight))
        let expected = replacement ?? (expires ? native : replacesProcess ? interrupted : adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expected)
        let sizeWrites = desktop.state.withLock { $0.writes.filter { $0 == "1001:AXSize" } }
        XCTAssertEqual(sizeWrites.count, replacement == nil && !replacesProcess ? 2 : 1)
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 2001)

        await controller.stopAndRestore()
        let expectedAfterStop = replacement ?? (replacesProcess ? interrupted : replacesProcessAfterWrite ? adjusted : native)
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, expectedAfterStop)
    }

    func testPendingRecoveryPreventsANewLiftUntilItsDelayedRestorationIsHandled() async {
        let desktop = BehaviorDesktop()
        let clock = Mutex<TimeInterval>(10)
        desktop.state.withLock { $0.omittedCG = [1002, 2001] }
        failFrameReadsAfterAnimatedWrite(desktop, afterAcknowledgement: true)
        let (controller, host) = makeController(desktop, uptime: { clock.withLock { $0 } },
            workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "1"])
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        await controller.restoreTask?.value
        XCTAssertNotNil(controller.pendingRestorations[key])
        let writesBeforeRecovery = desktop.state.withLock { $0.writes }
        desktop.state.withLock {
            $0.afterAttributeWrite = nil
            $0.beforeSettable = nil
            $0.unreadPositions.remove(1001)
            $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        }
        clock.withLock { $0 += 2 }
        controller.isEnabled = true
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.writes }, writesBeforeRecovery)
        XCTAssertNotNil(controller.pendingRestorations[key])
        clock.withLock { $0 += 6 }
        controller.isEnabled = true
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.restoreTask?.value
        XCTAssertNil(controller.pendingRestorations[key])
        controller.isEnabled = true
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        let adjusted = desktop.state.withLock { $0.windows[1001]?.bounds }
        XCTAssertEqual(adjusted?.height ?? 0, 1016, accuracy: 2)
        if case let .lifted(session) = controller.states[key] {
            XCTAssertEqual(session.applicationResponseRounds, 1)
        } else {
            XCTFail("Recovery must retain its bounded abandoned session until the next verified lift")
        }
        let finalWrites = desktop.state.withLock { $0.writes }
        clock.withLock { $0 += 6 }
        controller.isEnabled = true
        controller.poll()
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)
        XCTAssertEqual(desktop.state.withLock { $0.writes }, finalWrites)
        await controller.stopAndRestore()
    }

    func testManualGeometryAfterMovingOffscreenIsPreservedDuringStop() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock {
            $0.windows[1001]?.bounds = CGRect(x: -200, y: 0, width: 1920, height: 1080)
        }
        let (controller, host) = makeController(desktop, workspaceNotificationCenter: NotificationCenter())
        defer { withExtendedLifetime(host) {} }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        controller.isEnabled = false
        controller.start(environment: ["DOCK_WINDOW_LIFT_ANIM": "0", "DOCK_WINDOW_LIFT_TILES": "1"])
        controller.isEnabled = false
        controller.updatePollTimerLifecycle()
        controller.updateTrackedProbeLifecycle()
        await controller.scanTask?.value
        await controller.writeTasks[key]?.value
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds },
                       CGRect(x: -200, y: 0, width: 1920, height: 1046))
        let manualFrame = CGRect(x: -250, y: 200, width: 900, height: 600)
        desktop.state.withLock { $0.windows[1001]?.bounds = manualFrame }
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, manualFrame)
    }

    func testChromeFullscreenReturnAndRepeatedMaximizeTraverseTheProductionWriter() async {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 2560, height: 1410) }
        let (controller, host) = makeController(desktop, width: 2560, height: 1440)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        await wait { desktop.state.withLock { $0.windows[1001]?.bounds == CGRect(x: 0, y: 30, width: 2560, height: 1376) } }
        desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 2560, height: 1410) }
        controller.poll()
        await wait { desktop.state.withLock { $0.windows[1001]?.bounds == CGRect(x: 0, y: 30, width: 2560, height: 1376) } }
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 2560, height: 1410))
    }

    func testAProbeCapturedBeforeTheHeightWriteCannotRestartTheCompletedAdjustment() async {
        let desktop = BehaviorDesktop()
        let probe = BehaviorLiftProbeGate(desktop)
        let validationEntered = Mutex(false)
        desktop.state.withLock {
            $0.unreadPositions = [1001]
            $0.beforeRead = { attribute in
                if attribute == kAXPositionAttribute as String { validationEntered.withLock { $0 = true } }
            }
        }
        let (controller, host) = makeController(desktop, probe: probe)
        defer { probe.release.signal(); withExtendedLifetime(host) {} }
        controller.poll()
        await wait { validationEntered.withLock { $0 } }
        controller.trackedProbeTimer?.invalidate()
        controller.trackedProbeTimer = nil
        if let prior = controller.trackedProbeTask { await prior.value }
        probe.state.withLock { $0.holdNext = true }
        controller.poll()
        await wait { probe.state.withLock { $0.entered } }
        let pendingProbe = controller.scanTask
        controller.isEnabled = false
        controller.updateTrackedProbeLifecycle()
        controller.updatePollTimerLifecycle()
        desktop.state.withLock { _ = $0.unreadPositions.remove(1001) }
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        await wait { if case .lifted = controller.states[key] { return true }; return false }
        probe.release.signal()
        await pendingProbe?.value
        guard case .lifted = controller.states[key] else {
            await controller.stopAndRestore()
            return XCTFail("A pre-write CG sample must not replace the confirmed adjusted state")
        }
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1016))
        XCTAssertEqual(desktop.state.withLock { $0.writes }, ["1001:AXSize"])
        await controller.stopAndRestore()
    }

    func testManualGeometryAfterAdjustmentIsNotOverwrittenDuringStop() async {
        let desktop = BehaviorDesktop()
        let (controller, host) = makeController(desktop)
        defer { withExtendedLifetime(host) {} }
        controller.poll()
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        await wait { if case .lifted = controller.states[key] { return true }; return false }
        desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 300, y: 200, width: 600, height: 400) }
        await controller.stopAndRestore()
        XCTAssertEqual(desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 300, y: 200, width: 600, height: 400))
    }

    func testNativeReaderRejectsAnAcknowledgedButUnappliedSizeWrite() {
        let desktop = BehaviorDesktop()
        desktop.state.withLock { $0.ignoreWrites = true }
        let reader = AXWindowReader(accessibility: desktop)
        let result = reader.setSize(CGSize(width: 1920, height: 1016), for: desktop.elements[1001]!, messagingTimeout: 0.1,
            frameVerificationTolerance: 2, onlyIfCurrentMatches: CGRect(x: 0, y: 30, width: 1920, height: 1050), restoreOnFailureTo: nil)
        guard case let .failure(reason, _) = result else { return XCTFail("Unconfirmed frame must fail") }
        XCTAssertEqual(reason, .verificationMismatch(expected: CGRect(x: 0, y: 30, width: 1920, height: 1016),
                                                      actual: CGRect(x: 0, y: 30, width: 1920, height: 1050)))
    }
}

@MainActor
final class BehaviorStatusItem: StatusItemPresenting {
    var isVisible = false
    var menu: NSMenu?
    var name: NSStatusItem.AutosaveName?
    func configureAutosaveName(_ name: NSStatusItem.AutosaveName) { self.name = name }
    func configureButtonImage(_ image: NSImage?) {}
}

@MainActor
final class BehaviorPermissionWindow: NSWindow {
    var presentations = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { presentations += 1 }
}

final class BehaviorPermission: Sendable {
    let trusted = Mutex(false)
    let clock = Mutex<TimeInterval>(0)
}

@MainActor
final class ApplicationBehaviorTests: XCTestCase {
    @MainActor
    final class Effects {
        var statusCreations = 0
        var prompts = 0
        var panelCreations = 0
        var liftCreations = 0
        var quitRequests = 0
        var instanceCleanupRequests = 0
        var relaunchURLs: [URL] = []
        var frameAtRelaunch: CGRect?
        var relaunchFails = false
        var terminationReplies: [Bool] = []
        var writesAtTermination: [String]?
        var windows: [BehaviorPermissionWindow] = []
        var panels: TaskbarScreenOrchestrator?
        var lift: WindowLiftAvoidanceController?
    }

    @MainActor
    final class Fixture {
        let desktop = BehaviorDesktop()
        let effects = Effects()
        let status = BehaviorStatusItem()
        let permission = BehaviorPermission()
        let runtime: AppRuntime
        let delegate: AppDelegate
        let domain = "DeskMote.ApplicationBehavior.\(UUID().uuidString)"
        let defaults: UserDefaults

        init(trusted initial: Bool = false, liftHost: BehaviorLiftHost? = nil,
             previousInstanceExit: (@MainActor @Sendable () async -> Bool)? = nil,
             configureEnvironment: (inout ApplicationEnvironment, UserDefaults) -> Void = { _, _ in }) {
            permission.trusted.withLock { $0 = initial }
            defaults = UserDefaults(suiteName: domain)!
            let reader = AXWindowReader(accessibility: desktop)
            runtime = AppRuntime(tracker: BehaviorInventory(desktop),
                actionExecutor: PlatformActionExecutor(reader: reader, system: desktop, focusBackend: desktop))
            let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty))
            var environment = ApplicationEnvironment()
            environment.bundleURL = URL(fileURLWithPath: "/Applications/DeskMote.app")
            environment.permissionService = PermissionService(trustCheck: { [permission] in permission.trusted.withLock { $0 } },
                promptRequest: { [effects] in effects.prompts += 1; return false }, readOnlyVolumeCheck: { _ in false })
            environment.permissionProbe = { [permission] in permission.trusted.withLock { $0 } }
            environment.now = { [permission] in permission.clock.withLock { $0 } }
            environment.setActivationPolicy = { _ in }
            environment.retirePreviousInstances = { [effects] in
                effects.instanceCleanupRequests += 1
                return previousInstanceExit
            }
            environment.resetAppearance = {}
            environment.activateApplication = {}
            environment.terminate = { [effects] in effects.quitRequests += 1 }
            environment.launchInstance = { [effects, desktop] url in
                effects.relaunchURLs.append(url)
                effects.frameAtRelaunch = desktop.state.withLock { $0.windows[1001]?.bounds }
                return effects.relaunchFails ? .failure(CocoaError(.fileReadUnknown)) : .success(())
            }
            environment.replyToTermination = { [effects, desktop] _, result in
                effects.writesAtTermination = desktop.state.withLock { $0.writes }
                effects.terminationReplies.append(result)
            }
            environment.makeStatusItem = { [status, effects] in effects.statusCreations += 1; return status }
            environment.makePermissionWindow = { [effects] frame, style in
                let window = BehaviorPermissionWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: true)
                effects.windows.append(window)
                return window
            }
            environment.makePanels = { [effects] runtime, ordering, topology in
                effects.panelCreations += 1
                let panels = TaskbarScreenOrchestrator(runtime: runtime, stripOrderStore: ordering, displayTopologyStore: topology,
                    spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter(), pollInterval: 0),
                    overlaySpaceHost: nil,
                    topologySnapshotProvider: { .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty) })
                effects.panels = panels
                return panels
            }
            environment.makeLift = { [effects, desktop, permission, liftHost] host in
                effects.liftCreations += 1
                let reader = AXWindowReader(accessibility: desktop)
                let access = AXWindowRestorationAccess(reader: reader, processStartTime: { pid in
                    desktop.generation(pid).map { timeval(tv_sec: Int($0.seconds), tv_usec: $0.microseconds) }
                })
                let lift = WindowLiftAvoidanceController(host: liftHost ?? host,
                    isTrustedProbe: { permission.trusted.withLock { $0 } },
                    restoreWindow: { key, frames, start, live, budget in
                        WindowRestorer(access: access).restore(key: key, frames: frames, expectedStartTime: start,
                            liveWindowKeys: live, cancellation: budget.cancellation, budget: budget)
                    }, restorationWindowKeys: { nil }, windowProbe: LiveWindowLiftProbe(system: desktop), reader: reader, system: desktop,
                    makeGeometryObserver: { FrontmostWindowGeometryObserver(makeSession: { _, _ in nil }, readFocused: { _ in .none }) },
                    workspaceNotificationCenter: NotificationCenter())
                effects.lift = lift
                return lift
            }
            configureEnvironment(&environment, defaults)
            delegate = AppDelegate(environment: environment, runtime: runtime, displayTopologyStore: topology,
                stripOrderStore: StripOrderStore(defaults: defaults))
        }

        func seedUnrestorableWindow(in lift: WindowLiftAvoidanceController,
                                    onAttempt: @escaping @Sendable () -> Void = {}) -> WindowLiftAvoidance.WindowKey {
            let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
            desktop.state.withLock {
                $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1016)
                $0.beforeAttributeWrite = { id, _ in
                    guard id == key.cgWindowID else { return nil }
                    onAttempt()
                    return .cannotComplete
                }
            }
            lift.pendingRestorations[key] = .init(
                nativeAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                targetAppKit: CGRect(x: 0, y: 34, width: 1920, height: 1016),
                primaryDisplayHeight: 1080, processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
            return key
        }

        func launch() { delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
        func stop() { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); defaults.removePersistentDomain(forName: domain) }
    }

    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testSavedModulesWaitForAnActiveSessionAtStartupWithoutBlockingTheCore() async {
        let notifications = NotificationCenter()
        var starts: [Bool] = []
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, defaults in
            environment.moduleSessionIsActive = { false }
            environment.moduleSessionNotifications = notifications
            defaults.set(true, forKey: "deskmote.module.saved-input")
            let toggle = DeskMoteModuleToggle(id: "saved-input", title: "Input", defaults: defaults, start: {
                starts.append($0)
                return .running
            }, stop: {})
            environment.makeModules = { _ in [.toggle(toggle)] }
        })
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        XCTAssertTrue(starts.isEmpty)
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(starts, [false])
    }

    func testAccessibilityRecoveryDoesNotStartTheInputModuleInAnInactiveSession() async {
        var sessionActive = true
        var starts = 0
        var stops = 0
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, defaults in
            environment.moduleSessionIsActive = { sessionActive }
            defaults.set(true, forKey: "deskmote.module.session-input")
            let toggle = DeskMoteModuleToggle(id: "session-input", title: "Input", defaults: defaults,
                requiresAccessibility: true, start: { _ in starts += 1; return .running }, stop: { stops += 1 })
            environment.makeModules = { _ in [.toggle(toggle)] }
        })
        defer { fixture.stop() }
        fixture.launch()
        XCTAssertEqual(starts, 1)
        sessionActive = false
        fixture.permission.trusted.withLock { $0 = false }
        fixture.delegate.schedulePermissionProbe()
        await wait { stops == 1 }
        fixture.permission.trusted.withLock { $0 = true }
        fixture.delegate.schedulePermissionProbe()
        let deadline = ContinuousClock.now + .milliseconds(100)
        while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(starts, 1)
        sessionActive = true
        fixture.delegate.schedulePermissionProbe()
        await wait { starts == 2 }
    }

    func testFirstLaunchUsesOnlySystemPromptAndLateGrantStartsRuntimeOnce() async {
        let fixture = Fixture(); defer { fixture.stop() }
        fixture.launch()
        XCTAssertEqual(fixture.effects.prompts, 1)
        XCTAssertTrue(fixture.effects.windows.isEmpty)
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)
        fixture.permission.trusted.withLock { $0 = true }
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(fixture.effects.panelCreations, 1)
        XCTAssertEqual(fixture.effects.liftCreations, 1)
        XCTAssertEqual(fixture.effects.prompts, 1)
        XCTAssertTrue(fixture.effects.windows.isEmpty)
    }

    func testReplacementLaunchWaitsForThePreviousOwnerToExit() async {
        let (exit, signal) = AsyncStream<Bool>.makeStream()
        let fixture = Fixture(trusted: true, previousInstanceExit: {
            var iterator = exit.makeAsyncIterator()
            return await iterator.next() ?? false
        })
        defer { signal.finish(); fixture.stop() }
        fixture.launch()
        fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertEqual(fixture.effects.instanceCleanupRequests, 1)
        XCTAssertEqual(fixture.effects.statusCreations, 0)
        XCTAssertEqual(fixture.effects.panelCreations, 0)
        XCTAssertEqual(fixture.effects.liftCreations, 0)
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)

        signal.yield(true)
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        XCTAssertEqual(fixture.effects.statusCreations, 1)
        XCTAssertEqual(fixture.effects.panelCreations, 1)
        XCTAssertEqual(fixture.effects.liftCreations, 1)
    }

    func testReplacementLaunchQuitsWhenThePreviousOwnerCannotExit() async {
        let fixture = Fixture(trusted: true, previousInstanceExit: { false })
        defer { fixture.stop() }
        fixture.launch()

        await wait { fixture.effects.quitRequests == 1 }
        XCTAssertEqual(fixture.effects.panelCreations, 0)
        XCTAssertEqual(fixture.effects.liftCreations, 0)
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)
    }

    func testReopenRestoresTheSameHiddenStatusItemWithoutStartingAnotherRuntime() async {
        let fixture = Fixture(trusted: true); defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        let menu = fixture.status.menu
        XCTAssertFalse(fixture.status.isVisible)
        XCTAssertFalse(fixture.delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(fixture.status.isVisible)
        XCTAssertTrue(fixture.status.menu === menu)
        XCTAssertEqual(fixture.effects.statusCreations, 1)
        XCTAssertEqual(fixture.effects.panelCreations, 1)
        XCTAssertEqual(fixture.effects.liftCreations, 1)
    }

    func testTerminationWaitsForActualFrameRestorationBeforeReplying() async throws {
        let fixture = Fixture(trusted: true); defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        let lift = try XCTUnwrap(fixture.effects.lift)
        fixture.desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1016) }
        lift.pendingRestorations[.init(pid: -41000, cgWindowID: 1001)] = .init(
            nativeAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1050), targetAppKit: CGRect(x: 0, y: 34, width: 1920, height: 1016),
            primaryDisplayHeight: 1080, processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(fixture.effects.terminationReplies.isEmpty)
        await wait { fixture.effects.terminationReplies == [true] }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.bounds }, CGRect(x: 0, y: 30, width: 1920, height: 1050))
        XCTAssertTrue(lift.pendingRestorations.isEmpty)
        fixture.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)
    }

    func testQuitDoesNotStartAnotherRestorationBatchAfterItsReply() async throws {
        let fixture = Fixture(trusted: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        let lift = try XCTUnwrap(fixture.effects.lift)
        let attempts = Mutex(0)
        let key = fixture.seedUnrestorableWindow(in: lift) { attempts.withLock { $0 += 1 } }

        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await wait { fixture.effects.terminationReplies == [true] }
        XCTAssertNotNil(lift.pendingRestorations[key])
        let attemptsAtReply = attempts.withLock { $0 }
        XCTAssertGreaterThan(attemptsAtReply, 0)

        fixture.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        await lift.restoreTask?.value
        XCTAssertEqual(attempts.withLock { $0 }, attemptsAtReply)
    }

    func testQuitStopsWindowRuntimeBeforeItAwaitsRestoration() async {
        let fixture = Fixture(trusted: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)
        await wait { fixture.effects.terminationReplies == [true] }
        fixture.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    func testPermissionLossSuspendsRealRuntimeAndStopsHeightWrites() async throws {
        let fixture = Fixture(trusted: true); defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        fixture.permission.trusted.withLock { $0 = false }
        fixture.delegate.schedulePermissionProbe()
        await wait { fixture.effects.lift?.isEnabled == false }
        fixture.permission.clock.withLock { $0 = 6 }
        fixture.delegate.schedulePermissionProbe()
        await wait { fixture.runtime.snapshot.windows.isEmpty }
        fixture.runtime.activate(windowID: "editor-a")
        XCTAssertTrue(fixture.runtime.pendingActionsForTesting.isEmpty)
        XCTAssertFalse(fixture.effects.lift?.isEnabled ?? true)
        XCTAssertEqual(fixture.effects.panels?.units.count, 0)
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(fixture.effects.prompts, 1)
        XCTAssertFalse(fixture.effects.windows.contains { $0.isVisible })
    }

    func testPermissionRecoveryRetriesPendingRestorationBeforeRelaunching() async throws {
        let fixture = Fixture(trusted: true)
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        let lift = try XCTUnwrap(fixture.effects.lift)
        let key = fixture.seedUnrestorableWindow(in: lift)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        fixture.permission.trusted.withLock { $0 = false }
        fixture.delegate.schedulePermissionProbe()
        await wait { !lift.isEnabled }
        fixture.permission.clock.withLock { $0 = 6 }
        fixture.delegate.schedulePermissionProbe()
        await wait { fixture.effects.windows.first?.presentations == 1 }
        let content = try XCTUnwrap(fixture.effects.windows.first?.contentView as? NSHostingView<PermissionOnboardingWindowContent>)
        let coordinator = content.rootView.coordinator
        guard case let .suspended(episode) = coordinator.phase else { return XCTFail("Expected permission recovery") }

        fixture.permission.trusted.withLock { $0 = true }
        coordinator.recheck()
        XCTAssertEqual(coordinator.phase, .restoringWindows(episode: episode))
        await wait { coordinator.phase != .restoringWindows(episode: episode) }

        XCTAssertEqual(coordinator.phase, .restorationFailed(episode: episode))
        XCTAssertEqual(coordinator.presentation, .restorationFailed)
        XCTAssertTrue(fixture.effects.relaunchURLs.isEmpty)
        XCTAssertEqual(fixture.effects.quitRequests, 0)
        XCTAssertNotNil(lift.pendingRestorations[key])
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.bounds }, adjusted)

        fixture.desktop.state.withLock { $0.beforeAttributeWrite = nil }
        coordinator.retryRelaunch()
        await wait { fixture.effects.relaunchURLs.count == 1 }
        XCTAssertEqual(fixture.effects.frameAtRelaunch, native)
        XCTAssertTrue(lift.pendingRestorations.isEmpty)
    }

    func testPermissionRecoveryRestoresTheFrameBeforeRequestingRelaunchAndTermination() async throws {
        for failRelaunch in [false, true] {
            let fixture = Fixture(trusted: true); defer { fixture.stop() }
            fixture.effects.relaunchFails = failRelaunch
            fixture.launch()
            await wait { fixture.runtime.snapshot.windows.count == 3 }
            let lift = try XCTUnwrap(fixture.effects.lift)
            fixture.desktop.state.withLock { $0.windows[1001]?.bounds = CGRect(x: 0, y: 30, width: 1920, height: 1016) }
            lift.pendingRestorations[.init(pid: -41000, cgWindowID: 1001)] = .init(
                nativeAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1050), targetAppKit: CGRect(x: 0, y: 34, width: 1920, height: 1016),
                primaryDisplayHeight: 1080, processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
            fixture.permission.trusted.withLock { $0 = false }
            fixture.delegate.schedulePermissionProbe()
            await wait { !lift.isEnabled }
            fixture.permission.clock.withLock { $0 = 6 }
            fixture.delegate.schedulePermissionProbe()
            await wait { fixture.runtime.snapshot.windows.isEmpty }
            fixture.permission.trusted.withLock { $0 = true }
            fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            await wait { fixture.effects.relaunchURLs.count == 1 }
            XCTAssertEqual(fixture.effects.frameAtRelaunch, CGRect(x: 0, y: 30, width: 1920, height: 1050))
            XCTAssertEqual(fixture.effects.relaunchURLs, [URL(fileURLWithPath: "/Applications/DeskMote.app")])
            await wait { failRelaunch || fixture.effects.quitRequests == 1 }
            XCTAssertEqual(fixture.effects.quitRequests, failRelaunch ? 0 : 1)
            fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            XCTAssertEqual(fixture.effects.relaunchURLs.count, 1)
            XCTAssertTrue(lift.pendingRestorations.isEmpty)
        }
    }
}


extension TaskbarBehaviorTests {
    func testHelperActivationRejectsAStaleOrUnrelatedFrontmostHost() async throws {
        for (generation, origin, frontmost) in [(Int64(9), "/Applications/Browser.app", pid_t(-42000)),
                                                 (Int64(10), "/Applications/Other.app", pid_t(-42000)),
                                                 (Int64(10), "/Applications/Browser.app", pid_t(-43000))] {
            let fixture = await helperFixture(generation: generation, origin: origin)
            defer { fixture.stop() }
            fixture.desktop.state.withLock { $0.frontmostPIDOverride = frontmost }
            fixture.runtime.activate(windowID: "editor-b")
            for task in fixture.runtime.pendingActionsForTesting { await task.value }
            XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"]?.phase, .failure)
        }
    }

    func testHelperRestorationConfirmsSuccessWithItsVerifiedHostFrontmost() async throws {
        let fixture = await helperFixture()
        defer { fixture.stop() }
        fixture.desktop.state.withLock {
            $0.frontmostPIDOverride = -42000
            $0.windows[1002]?.status = .minimized
        }
        fixture.desktop.publish()
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-b")]?.status == .minimized }
        let snapshot = fixture.runtime.snapshot
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: fixture.desktop),
            system: fixture.desktop, focusBackend: fixture.desktop)
        let succeeded = await Task.detached {
            executor.execute(.init(kind: .activateWindow, windowID: WindowID(rawValue: "editor-b")),
                snapshot: snapshot, forcedMinimizedPrior: true, cancellation: OperationCancellation(),
                onHandoffActivePrediction: nil)
        }.value
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1002)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .active)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.status }, .inactive)
        XCTAssertTrue(succeeded)
    }

    func testHelperActivationConfirmsSuccessWhenVerifiedHostRemainsFrontmost() async throws {
        let fixture = await helperFixture()
        defer { fixture.stop() }
        fixture.desktop.state.withLock { $0.frontmostPIDOverride = -42000 }
        fixture.runtime.activate(windowID: "editor-b")
        let pending = fixture.runtime.pendingActionsForTesting
        for task in pending { await task.value }
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 1002)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1002]?.status }, .active)
        XCTAssertEqual(fixture.runtime.debugState.feedbackEntriesByWindowID["editor-b"]?.phase, .success)
    }
}

extension ApplicationBehaviorTests {
    func testQuitWithoutTrustDrainsTheAdmittedNativeSizeWriteBeforeReplying() async throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = BehaviorLiftHost(.init(
            geometry: .init(screenFrame: screen, visibleFrame: screen, taskbarTopEdge: 32, topReservedHeight: 30),
            displayWindowServerFrame: screen, usableWindowServerFrame: screen, primaryDisplayHeight: 1080))
        let fixture = Fixture(trusted: true, liftHost: host)
        let gate = BehaviorLiftWriteGate()
        fixture.desktop.state.withLock {
            $0.beforeAttributeWrite = { id, attribute in
                gate.didWrite(id, attribute: attribute)
                return nil
            }
        }
        defer { gate.release.signal(); fixture.stop(); withExtendedLifetime(host) {} }
        fixture.launch()
        await wait { gate.entered.withLock { $0 } }
        let lift = try XCTUnwrap(fixture.effects.lift)
        let writer = try XCTUnwrap(lift.writeTasks[.init(pid: -41000, cgWindowID: 1001)])
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
        fixture.permission.trusted.withLock { $0 = false }

        let reply = fixture.delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await Task.yield()
        XCTAssertTrue(fixture.effects.terminationReplies.isEmpty)
        var writesAtCompletion: [String]?
        if reply == .terminateNow {
            fixture.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            writesAtCompletion = fixture.desktop.state.withLock { $0.writes }
        }
        gate.release.signal()
        await writer.value
        if reply == .terminateLater {
            await wait { fixture.effects.terminationReplies == [true] }
            writesAtCompletion = fixture.effects.writesAtTermination
        }

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        let writesAfterDrain = fixture.desktop.state.withLock { $0.writes }
        XCTAssertTrue(writesAfterDrain.contains("1001:AXSize"))
        XCTAssertEqual(writesAtCompletion, writesAfterDrain)
        fixture.permission.trusted.withLock { $0 = true }
        await lift.stopAndRestore()
    }

    func testQuitWithoutTrustOrALiftControllerTerminatesImmediately() {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.launch()

        XCTAssertNil(fixture.effects.lift)
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertTrue(fixture.effects.terminationReplies.isEmpty)
    }

    func testQuitAfterTrustReturnsBeforeWatchdogUnfreezeRestoresManagedWindow() async throws {
        let fixture = Fixture(trusted: true)
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        let lift = try XCTUnwrap(fixture.effects.lift)
        let key = WindowLiftAvoidance.WindowKey(pid: -41000, cgWindowID: 1001)
        let native = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let adjusted = CGRect(x: 0, y: 30, width: 1920, height: 1016)
        let frames = WindowRestorationFrames(
            nativeAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1050),
            targetAppKit: CGRect(x: 0, y: 34, width: 1920, height: 1016),
            primaryDisplayHeight: 1080, processGeneration: ProcessGeneration(timeval(tv_sec: 10, tv_usec: 1)))
        fixture.desktop.state.withLock { $0.windows[1001]?.bounds = adjusted }
        lift.managedFrames[key] = frames
        lift.states[key] = .lifted(.init(generation: 1, unadjustedWindowFrame: frames.nativeAppKit,
            taskbarClearanceFrame: frames.targetAppKit, liftRetryCount: 0, liftSettledAt: 0, applicationResponseRounds: 0))
        fixture.permission.trusted.withLock { $0 = false }
        fixture.delegate.schedulePermissionProbe()
        await wait { !lift.isEnabled }

        fixture.permission.trusted.withLock { $0 = true }
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await wait { fixture.effects.terminationReplies == [true] }

        XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.bounds }, native)
        await lift.restoreAndStopForPermissionRecovery()
    }
}
