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
        var fullscreenWindows = Set<CGWindowID>()
        var missingFullscreenFlag = Set<CGWindowID>()
        var sizeWriteAttempts = 0
        var requestedSizes: [CGSize] = []
        var requestedPositions: [CGPoint] = []
        var rejectSizeAsUnsupported = false
        var rejectPositions = false
        var beforePositionWrite: (@Sendable () -> Void)?
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
        var afterFrameBatchRead: (@Sendable () -> Void)?
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
              let afterFrameBatchRead = state.withLock({ $0.afterFrameBatchRead }) else {
            return (.notImplemented, nil)
        }
        let values: [CFTypeRef] = attributes.map { copy(element, $0 as CFString).1 ?? kCFNull }
        afterFrameBatchRead()
        return (.success, values)
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
            case "AXFullScreen":
                if value.missingFullscreenFlag.contains(id) { return (.attributeUnsupported, nil) }
                return (.success, value.fullscreenWindows.contains(id) ? kCFBooleanTrue : kCFBooleanFalse)
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

    func heightCommitFrame(_ element: AXElementKey, replacingFrame: CGRect? = nil) -> CGRect? {
        guard let id = number(element.e) else { return nil }
        return state.withLock { storage in
            guard let window = storage.windows[id], window.status != .minimized,
                  !storage.fullscreenWindows.contains(id), !storage.missingWindows.contains(id),
                  !storage.unreadPositions.contains(id) else { return nil }
            if let replacingFrame { storage.windows[id]?.bounds = replacingFrame }
            return storage.windows[id]?.bounds
        }
    }

    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        guard let id = number(element) else { return .invalidUIElement }
        let size: CGSize?
        if attribute as String == kAXSizeAttribute as String {
            var requestedSize = CGSize.zero
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &requestedSize) else { return .illegalArgument }
            size = requestedSize
        } else {
            size = nil
        }
        let position: CGPoint?
        if attribute as String == kAXPositionAttribute as String {
            var point = CGPoint.zero
            guard CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else { return .illegalArgument }
            position = point
            state.withLock { $0.beforePositionWrite }?()
        } else {
            position = nil
        }
        let result = state.withLock { storage -> AXError in
            guard var window = storage.windows[id] else { return .invalidUIElement }
            if let size {
                storage.sizeWriteAttempts += 1
                storage.requestedSizes.append(size)
                if storage.rejectSizeAsUnsupported { return .attributeUnsupported }
            }
            if let position {
                storage.requestedPositions.append(position)
                if storage.rejectPositions { return .cannotComplete }
            }
            if storage.rejectWrites || (storage.rejectMinimizedAttribute && attribute as String == kAXMinimizedAttribute as String) { return .failure }
            storage.writes.append("\(id):\(attribute)")
            guard !storage.ignoreWrites else { return .success }
            if attribute as String == kAXMinimizedAttribute as String {
                window.status = (value as? NSNumber)?.boolValue == true ? .minimized : .inactive
                if window.status == .minimized, storage.focused == id { storage.focused = nil }
            } else if let size {
                window.bounds?.size = size
            } else if let position {
                window.bounds?.origin = position
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
    let invalidations = PassthroughSubject<CGWindowID, Never>()
    var snapshots: AnyPublisher<DockSnapshot, Never> { desktop.values.eraseToAnyPublisher() }
    var windowSpaceInvalidations: AnyPublisher<CGWindowID, Never> { invalidations.eraseToAnyPublisher() }
    private let onStart: @MainActor () -> Void
    init(_ desktop: BehaviorDesktop, onStart: @escaping @MainActor () -> Void = {}) {
        self.desktop = desktop
        self.onStart = onStart
    }
    func start() { onStart() }
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
    var onDismiss: (() -> Void)?
    var content: NSView?
    func makeKey() {}
    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
        self.content = content
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
                spaces: spaces, displayUUID: displayUUID, backgroundMenu: { _, _ in },
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
        await wait { content.buttonViews["window:tabgrp-editor-a"] == nil }
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

    func testButtonRestoresAnExternalHiddenWindowThroughTheNativeExecutor() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        await ready(fixture)
        fixture.desktop.state.withLock { state in
            state.windows[2001]?.status = .hidden
            _ = state.hiddenApplications.insert(-42000)
        }
        fixture.desktop.publish()
        let window = WindowID(rawValue: "browser-c")
        await wait { fixture.runtime.snapshot.windows[window]?.status == .hidden }

        try press("browser-c", fixture)
        for action in fixture.runtime.pendingActionsForTesting { await action.value }
        XCTAssertEqual(fixture.runtime.snapshot.windows[window]?.status, .active)
        XCTAssertEqual(fixture.desktop.state.withLock { $0.focused }, 2001)
    }

    func testDelayedRestorationHighlightsTheButtonOnlyAfterExactFocusArrives() async throws {
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
        let feedback = fixture.runtime.feedbackTestProbe.$feedbackEntriesByWindowID.sink {
            if $0["editor-a"]?.phase == .failure { publishedFailure = true }
        }
        defer { feedback.cancel() }
        try press("editor-a", fixture)
        await drainTaskbarUpdates()
        XCTAssertFalse(button.isActiveWindow)
        let completion = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            fixture.desktop.state.withLock { $0.denyFocus = false }
            return fixture.desktop.setFrontmost(pid: -41000, windowID: 1001, mode: 0)
        }
        await wait { fixture.runtime.snapshot.windows[WindowID(rawValue: "editor-a")]?.status == .active }
        let focused = await completion.value
        XCTAssertTrue(focused)
        for task in fixture.runtime.pendingActionsForTesting { await task.value }
        await drainTaskbarUpdates()
        XCTAssertFalse(publishedFailure)
        XCTAssertTrue(button.isActiveWindow)
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"]?.phase, .success)
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
            XCTAssertNil(fixture.runtime.pendingMinimizations["editor-b"])
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
            XCTAssertNil(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"])
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
                XCTAssertNil(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID[id.rawValue])
                previous.clickForTesting()
                XCTAssertNil(fixture.runtime.pendingMinimizations[id.rawValue])
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
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"]?.phase, .pending)

        currentSpace.withLock { $0 = 2 }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertNil(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"])
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
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"]?.phase, .pending)

        currentSpace.withLock { $0 = 2 }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await wait { content.groups.flatMap(\.windows).map(\.id) == ["tabgrp-browser-c"] }
        gate.release.signal()
        for task in fixture.runtime.pendingActionsForTesting { await task.value }

        XCTAssertFalse(gate.timedOut.withLock { $0 })
        XCTAssertEqual(fixture.desktop.state.withLock { $0.writes.filter { $0.hasSuffix(":close") } }, ["1001:close"])
        XCTAssertNotNil(fixture.desktop.state.withLock { $0.windows[1002] })
        XCTAssertNil(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"])
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
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"]?.phase, .pending)

        fixture.presenter.setPanelVisible(false)
        XCTAssertNil(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"])
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
        let coordinator = PanelCoordinator(placement: .fixed(displayUUID: "left"),
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
        let desktop = SpaceLayoutSnapshot(orderedSpaceIDs: [1], fullscreenSpaceIDs: [], currentSpaceID: 1)
        let spaces = TaskbarSpaceStore(read: { _ in
            WindowSpaceSnapshot(layouts: ["left": desktop, "right": desktop], memberships: [:])
        }, notifications: NotificationCenter(), pollInterval: 0)
        let runtime = AppRuntime(tracker: BehaviorInventory(BehaviorDesktop()))
        let ordering = StripOrderStore(defaults: UserDefaults(suiteName: "DeskMote.Popup.\(UUID())")!,
                                      bootTimeProvider: { 1 })
        var popups: [String: BehaviorPopup] = [:]
        var completedDelays = 0
        let orchestrator = TaskbarScreenOrchestrator(runtime: runtime, stripOrderStore: ordering,
            displayTopologyStore: DisplayTopologyStore(initialSnapshot: topology), spaceStore: spaces,
            topologySnapshotProvider: { topology }, startCoordinator: { coordinator in
                guard let key = coordinator.fixedUnitDisplayUUID else { return false }
                let popup = BehaviorPopup()
                popups[key] = popup
                return coordinator.setupDockPanel { frame in
                    TaskbarView(frame: frame, popup: popup, contextMenu: BehaviorMenu(),
                                delay: { _ in completedDelays += 1 })
                }
            })
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        await wait { spaces.activeLayouts.count == 2 }
        await drainTaskbarUpdates()
        for unit in orchestrator.units {
            let taskbar = try XCTUnwrap(unit.coordinator.taskbarView)
            unit.coordinator.taskbarPresenter?.setPanelVisible(true)
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

    func testVisibleSettingsActivationSurvivesTemporarilyUnreadableWindowIdentityAfterEarlyFocus() throws {
        let desktop = BehaviorDesktop(editorBundleIdentifier: "com.apple.systempreferences")
        let failures = Mutex(0)
        desktop.state.withLock {
            $0.windows[1001]?.status = .inactive
            $0.focused = 2001
            $0.beforeWindowIDRead = { id in
                guard id == 1001, desktop.state.withLock({ $0.focused == id }) else { return }
                let unreadable = failures.withLock { count in count += 1; return count <= 2 }
                desktop.state.withLock {
                    if unreadable { $0.unreadNativeWindowIDs.insert(id) }
                    else { $0.unreadNativeWindowIDs.remove(id) }
                }
            }
        }
        defer { desktop.state.withLock { $0.beforeWindowIDRead = nil } }
        desktop.publish()
        let target = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let executor = PlatformActionExecutor(reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertTrue(executor.execute(.init(kind: .activateWindow, windowID: target.id),
                                       snapshot: desktop.values.value, forcedMinimizedPrior: false,
                                       cancellation: OperationCancellation(), onHandoffTarget: nil))
        XCTAssertGreaterThan(failures.withLock { $0 }, 2)
        XCTAssertEqual(desktop.state.withLock { $0.focused }, 1001)
        XCTAssertFalse(desktop.state.withLock { $0.writes.contains("1001:minimized") })
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
                                       cancellation: OperationCancellation(), onHandoffTarget: nil))
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
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"]?.phase, .failure)
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        let success = executor.execute(.init(kind: .closeWindow, windowID: .init(rawValue: "editor-b")),
            snapshot: desktop.values.value, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffTarget: nil)

        XCTAssertFalse(success)
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertEqual(desktop.state.withLock { Set($0.windows.keys) }, [1001, 1002, 2001])
    }

    func testCloseFindsRetainedAXWindowAfterSameCGIDFocusedAlias() throws {
        for (fastCapture, mainWindow, expectedInventoryReads): (Bool, CGWindowID, Int) in
            [(true, 1001, 1), (true, 1002, 0), (false, 1001, 1)] {
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
            let executor = PlatformActionExecutor(switches: .init(fastWindowHandleEnabled: fastCapture, axElementCacheEnabled: false), reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

            XCTAssertTrue(executor.execute(.init(kind: .closeWindow, windowID: target.id),
                snapshot: snapshot, forcedMinimizedPrior: false,
                cancellation: OperationCancellation(), onHandoffTarget: nil))
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
                                               readOutcome: .success)
            tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgID])
        }
        observe(AXUIElementCreateApplication(-89999))
        let previousSnapshot = tracker.snapshot
        let id = try XCTUnwrap(previousSnapshot.orderedWindowIDs.first)
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let request = PlatformActionRequest(kind: .closeWindow, windowID: id)

        XCTAssertFalse(executor.execute(request, snapshot: previousSnapshot, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffTarget: nil))
        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })
        XCTAssertNotNil(desktop.state.withLock { $0.windows[cgID] })

        observe(try XCTUnwrap(desktop.elements[cgID]))
        XCTAssertTrue(executor.execute(request, snapshot: tracker.snapshot, forcedMinimizedPrior: false,
            cancellation: OperationCancellation(), onHandoffTarget: nil))
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
                                               reader: reader, system: desktop, focusBackend: desktop)
        let snapshot = DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id])
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id), snapshot: snapshot,
                                        forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                                        onHandoffTarget: nil))
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
        await wait { fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"]?.phase == .failure }
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: original.id),
            snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffTarget: nil))
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
        XCTAssertTrue(fixture.runtime.pendingMinimizations.isEmpty)
    }

    func testCancelledNativeCaptureAndStaleReplacementNeverWrite() async throws {
        let desktop = BehaviorDesktop()
        let reader = AXWindowReader(accessibility: desktop)
        let switches = ActionExecutionSwitches(fastWindowHandleEnabled: false, axElementCacheEnabled: false)
        let runtime = AppRuntime(tracker: BehaviorInventory(desktop),
            actionExecutor: PlatformActionExecutor(switches: switches, reader: reader,
                                                  system: desktop, focusBackend: desktop),
            isAppFrontmost: { desktop.app($0)?.isActive == true })
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

        XCTAssertTrue(desktop.state.withLock { $0.writes.isEmpty })

        desktop.state.withLock { _ = $0.generationsByPID.removeValue(forKey: record.pid) }
        runtime.activate(windowID: id.rawValue)
        for action in runtime.pendingActionsForTesting { await action.value }
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
            switches: .init(fastWindowHandleEnabled: false, axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id),
            snapshot: DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id]),
            forcedMinimizedPrior: true, cancellation: cancellation, onHandoffTarget: nil))
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
            onHandoffTarget: nil))
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)

        XCTAssertTrue(executor.execute(.init(kind: .minimizeWindow, windowID: clicked.id),
            snapshot: snapshot, forcedMinimizedPrior: false, cancellation: OperationCancellation(),
            onHandoffTarget: { id in predictions.withLock { $0.append(id) } }))
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
            let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
                reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
            let action = Task.detached {
                executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                    forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                    onHandoffTarget: { id in predictions.withLock { $0.append(id) } })
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let action = Task.detached {
            executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                onHandoffTarget: { _ in predictionSent.withLock { $0 = true } })
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
        let executor = PlatformActionExecutor(switches: .init(axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        let action = Task.detached {
            executor.execute(.init(kind: .closeWindow, windowID: original.id), snapshot: snapshot,
                forcedMinimizedPrior: false, cancellation: OperationCancellation(),
                onHandoffTarget: { _ in predictionSent.withLock { $0 = true } })
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
            onHandoffTarget: nil))
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
            switches: .init(fastWindowHandleEnabled: true, axElementCacheEnabled: false),
            reader: AXWindowReader(accessibility: desktop), system: desktop, focusBackend: desktop)
        XCTAssertFalse(executor.execute(.init(kind: .activateWindow, windowID: record.id),
            snapshot: DockSnapshot(windows: [record.id: record], orderedWindowIDs: [record.id]),
            forcedMinimizedPrior: true, cancellation: cancellation, onHandoffTarget: nil))
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
            await wait { fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"]?.phase == .failure }
            XCTAssertNil(fixture.runtime.pendingMinimizations["editor-a"])
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
        await wait { fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-a"]?.phase == .failure }
        XCTAssertNil(fixture.runtime.pendingMinimizations["editor-a"])
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
            spaces: fixture.spaces, displayUUID: nil, backgroundMenu: { _, _ in }, contextMenuVisibilityChanged: { _ in })
        withExtendedLifetime(presenter) { XCTAssertEqual(view.taskbarContent.layoutResult.buttons.flatMap(\.windowIDs), ["tabgrp-browser-c", "tabgrp-editor-a", "tabgrp-editor-b"]) }
        XCTAssertTrue(fixture.desktop.state.withLock { $0.writes.isEmpty })
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
}

@MainActor
final class ApplicationBehaviorTests: XCTestCase {
    @MainActor
    final class Effects {
        var statusCreations = 0
        var prompts = 0
        var panelCreations = 0
        var quitRequests = 0
        var instanceCleanupRequests = 0
        var windows: [BehaviorPermissionWindow] = []
        var panels: TaskbarScreenOrchestrator?
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

        init(trusted initial: Bool = false,
             previousInstanceExit: (@MainActor @Sendable () async -> Bool)? = nil,
             startInventory: @escaping @MainActor () -> Void = {},
             configureEnvironment: (inout ApplicationEnvironment, UserDefaults) -> Void = { _, _ in }) {
            permission.trusted.withLock { $0 = initial }
            defaults = UserDefaults(suiteName: domain)!
            let topology = DisplayTopologyStore(initialSnapshot: .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty))
            var environment = ApplicationEnvironment()
            environment.bundleURL = URL(fileURLWithPath: "/Applications/DeskMote.app")
            environment.permissionService = PermissionService(trustCheck: { [permission] in permission.trusted.withLock { $0 } },
                promptRequest: { [effects] in effects.prompts += 1; return false }, readOnlyVolumeCheck: { _ in false })
            environment.permissionProbe = { [permission] in permission.trusted.withLock { $0 } }
            environment.setActivationPolicy = { _ in }
            environment.retirePreviousInstances = { [effects] in
                effects.instanceCleanupRequests += 1
                return previousInstanceExit
            }
            environment.resetAppearance = {}
            environment.activateApplication = {}
            environment.terminate = { [effects] in effects.quitRequests += 1 }
            environment.forceExit = {}
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
                    topologySnapshotProvider: { .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty) })
                effects.panels = panels
                return panels
            }
            configureEnvironment(&environment, defaults)
            let reader = AXWindowReader(accessibility: desktop)
            runtime = AppRuntime(tracker: BehaviorInventory(desktop, onStart: startInventory),
                accessibilityAccess: environment.runtimeAccessibilityAccess,
                actionExecutor: PlatformActionExecutor(reader: reader, system: desktop, focusBackend: desktop))
            delegate = AppDelegate(environment: environment, runtime: runtime, displayTopologyStore: topology,
                stripOrderStore: StripOrderStore(defaults: defaults))
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

    func testWatchdogDefersInputModuleUntilSessionIsActive() async {
        let notifications = NotificationCenter()
        var sessionActive = false
        var starts = 0
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, defaults in
            environment.moduleSessionIsActive = { sessionActive }
            environment.moduleSessionNotifications = notifications
            defaults.set(true, forKey: "deskmote.module.session-input")
            let toggle = DeskMoteModuleToggle(id: "session-input", title: "Input", defaults: defaults,
                requiresAccessibility: true, start: { _ in starts += 1; return .running }, stop: {})
            environment.makeModules = { _ in [.toggle(toggle)] }
        })
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.delegate.permissionWatchdog.isReady }
        XCTAssertEqual(starts, 0)
        sessionActive = true
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(starts, 1)
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
        XCTAssertTrue(fixture.runtime.snapshot.windows.isEmpty)

        signal.yield(true)
        await wait { fixture.runtime.snapshot.windows.count == 3 }
        XCTAssertEqual(fixture.effects.statusCreations, 1)
        XCTAssertEqual(fixture.effects.panelCreations, 1)
    }

    func testReplacementLaunchQuitsWhenThePreviousOwnerCannotExit() async {
        let fixture = Fixture(trusted: true, previousInstanceExit: { false })
        defer { fixture.stop() }
        fixture.launch()

        await wait { fixture.effects.quitRequests == 1 }
        XCTAssertEqual(fixture.effects.panelCreations, 0)
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
    }

    func testQuitStopsWindowRuntimeAndKeepsTheAdjustedHeight() async {
        await WindowHeightFallbackTests.verifyQuitKeepsCorrectedHeight()
    }

    func testPermissionWatchdogSubmitsTheFirstPeriodicProbeOffMain() async {
        let probes = expectation(description: "Startup and first scheduled trust probes")
        probes.expectedFulfillmentCount = 2
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.moduleSessionNotifications = NotificationCenter()
            environment.permissionProbe = {
                XCTAssertFalse(Thread.isMainThread)
                probes.fulfill()
                return true
            }
        })
        defer { fixture.stop() }
        fixture.launch()
        await fulfillment(of: [probes], timeout: 9)
    }

    func testPermissionWatchdogProbesWhileMainThreadIsBusy() {
        let access = RuntimeAccessibilityAccess()
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.runtimeAccessibilityAccess = access
            environment.permissionProbe = { false }
        })
        defer { fixture.stop() }
        fixture.launch()

        let deadline = ContinuousClock.now + .seconds(3)
        while access.allowsCalls, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(access.call {
            XCTFail("The first denied sample must block new AX work on the background queue")
            return .success
        }, .apiDisabled)
    }

    func testFirstRuntimeAXCallHasTerminalProtection() async {
        for initiallyTrusted in [true, false] {
            let access = RuntimeAccessibilityAccess(initiallyTrusted: false)
            let calls = Mutex(0)
            let fixture = Fixture(trusted: initiallyTrusted, startInventory: {
                XCTAssertEqual(access.call {
                    calls.withLock { $0 += 1 }
                    return .apiDisabled
                }, .apiDisabled)
            }, configureEnvironment: { environment, _ in
                environment.runtimeAccessibilityAccess = access
                environment.permissionProbe = { true }
            })
            defer { fixture.stop() }
            fixture.launch()
            if !initiallyTrusted {
                XCTAssertFalse(access.allowsCalls)
                XCTAssertEqual(calls.withLock { $0 }, 0)
                XCTAssertEqual(fixture.effects.prompts, 1)
                fixture.permission.trusted.withLock { $0 = true }
                fixture.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            }
            await wait { fixture.effects.quitRequests == 1 }
            XCTAssertEqual(calls.withLock { $0 }, 1)
            XCTAssertFalse(access.allowsCalls)
            _ = access.updateTrust(true)
            XCTAssertFalse(access.allowsCalls)
        }
    }

    func testRequiredAccessibilityLossRequestsQuitOnce() async throws {
        let access = RuntimeAccessibilityAccess(initiallyTrusted: false)
        let exits = Mutex(0)
        let clock = WatchdogTestClock()
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.runtimeAccessibilityAccess = access
            environment.permissionClock = { clock.now }
            environment.schedulePermissionDeadline = clock.schedule
            environment.forceExit = { exits.withLock { $0 += 1 } }
        })
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.delegate.permissionWatchdog.isReady }
        XCTAssertEqual(access.call { .apiDisabled }, .apiDisabled)
        XCTAssertFalse(access.allowsCalls)
        await wait { fixture.effects.quitRequests == 1 }
        clock.advance(to: 2)
        XCTAssertEqual(exits.withLock { $0 }, 0)
        clock.advance(to: 3)
        clock.advance(to: 6)
        XCTAssertEqual(exits.withLock { $0 }, 1)
        XCTAssertEqual(fixture.effects.quitRequests, 1)
    }

    func testPermissionWatchdogAndHeightPollProgressIndependently() async {
        let access = RuntimeAccessibilityAccess(initiallyTrusted: false)
        let probing = Mutex(0)
        let probeRelease = DispatchSemaphore(value: 0)
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.runtimeAccessibilityAccess = access
            environment.permissionProbe = {
                let sample = probing.withLock { $0 += 1; return $0 }
                if sample == 1 {
                    _ = probeRelease.wait(timeout: .now() + 2)
                    return true
                }
                return false
            }
        })
        defer { probeRelease.signal(); fixture.stop() }
        fixture.launch()
        await wait { probing.withLock { $0 == 1 } }
        await WindowHeightFallbackTests.verifyCaptureDuringHeldAX(access: access) {
            XCTAssertEqual(probing.withLock { $0 }, 1)
            probeRelease.signal()
            await self.wait { fixture.delegate.permissionWatchdog.isReady }
            fixture.delegate.schedulePermissionProbe()
            await self.wait { probing.withLock({ $0 == 2 }) && fixture.effects.quitRequests == 1 }
            XCTAssertFalse(access.allowsCalls)
        }
    }

    func testWakeRequiresFreshPermissionReadiness() async throws {
        let access = RuntimeAccessibilityAccess(initiallyTrusted: false)
        let clock = WatchdogTestClock()
        let notifications = NotificationCenter()
        let exits = Mutex(0)
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.runtimeAccessibilityAccess = access
            environment.permissionClock = { clock.now }
            environment.schedulePermissionDeadline = clock.schedule
            environment.moduleSessionNotifications = notifications
            environment.forceExit = { exits.withLock { $0 += 1 } }
        })
        defer { fixture.stop() }
        fixture.launch()
        await wait { fixture.delegate.permissionWatchdog.isReady }
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(fixture.delegate.permissionWatchdog.isReady)
        clock.advance(to: 3)
        XCTAssertEqual(exits.withLock { $0 }, 0)
        XCTAssertEqual(fixture.effects.quitRequests, 0)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await wait { fixture.delegate.permissionWatchdog.isReady }
    }

    func testCommandShiftRestoresOnlyAfterTheWatchdogIsReady() async {
        let probing = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        var starts = 0
        let fixture = Fixture(trusted: true, configureEnvironment: { environment, defaults in
            environment.permissionProbe = {
                probing.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                return true
            }
            defaults.set(true, forKey: "deskmote.module.test-command-shift")
            let toggle = DeskMoteModuleToggle(id: "test-command-shift", title: "Command Shift", defaults: defaults,
                requiresAccessibility: true, start: { _ in starts += 1; return .running }, stop: {})
            environment.makeModules = { _ in [.toggle(toggle)] }
        })
        defer { release.signal(); fixture.stop() }
        fixture.launch()
        await wait { probing.withLock { $0 } && fixture.runtime.snapshot.windows.count == 3 }
        XCTAssertEqual(starts, 0)
        release.signal()
        await wait { starts == 1 }
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
            XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"]?.phase, .failure)
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
                onHandoffTarget: nil)
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
        XCTAssertEqual(fixture.runtime.feedbackTestProbe.feedbackEntriesByWindowID["editor-b"]?.phase, .success)
    }
}
