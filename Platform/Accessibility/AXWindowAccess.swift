import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct AXElementKey: Hashable, @unchecked Sendable {
    let e: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool { CFEqual(lhs.e, rhs.e) }

    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(e)) }
}

enum AXWindowTitleRead: Equatable {
    case value(String)
    case empty
    case unread(AXError)

    var title: String? {
        if case .value(let title) = self { return title }
        return nil
    }

    func resolvedTitle(previousTitle: String? = nil) -> String {
        switch self {
        case .value(let title): return title
        case .empty: return ""
        case .unread: return previousTitle ?? ""
        }
    }

    static func classify(result: AXError, value: CFTypeRef?) -> Self {
        switch result {
        case .success:
            guard let text = value as? String else { return .unread(.failure) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .empty : .value(text)
        case .attributeUnsupported, .noValue:
            return .empty
        default:
            return .unread(result)
        }
    }
}

struct AXWindowSnapshot {
    let pid: Int32
    let cgWindowID: UInt32?
    let titleRead: AXWindowTitleRead
    let bounds: CGRect?
    let role: String?
    let subrole: String?
    let isMinimized: Bool
    var isFocusedWindow: Bool
    let element: AXUIElement

    let isMinimizedRead: Bool?
    let focusReadUptime: TimeInterval?
    let isModal: Bool?
    let isTopLevel: Bool?

    var title: String? { titleRead.title }

    init(pid: Int32, cgWindowID: UInt32?, titleRead: AXWindowTitleRead, bounds: CGRect?,
         role: String?, subrole: String?, isMinimized: Bool, isFocusedWindow: Bool, element: AXUIElement,
         isMinimizedRead: Bool? = nil, focusReadUptime: TimeInterval? = nil,
         isModal: Bool? = nil, isTopLevel: Bool? = nil) {
        self.pid = pid
        self.cgWindowID = cgWindowID
        self.titleRead = titleRead
        self.bounds = bounds
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isFocusedWindow = isFocusedWindow
        self.element = element
        self.isMinimizedRead = isMinimizedRead
        self.focusReadUptime = focusReadUptime
        self.isModal = isModal
        self.isTopLevel = isTopLevel
    }
}

struct AXWindowTarget {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    var cgWindowID: CGWindowID? = nil
    var expectedElement: AXElementKey? = nil
}

struct AXWindowHandle {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    let element: AXUIElement
}

enum AXWindowFrameAttribute: Equatable {
    case position
    case size
}

enum AXWindowAttributeSettableStatus: Equatable {
    case settable
    case notSettable
    case unread(AXError)

    var isSettable: Bool {
        if case .settable = self { return true }
        return false
    }
}

struct AXWindowFrameSettableStatus: Equatable {
    let position: AXWindowAttributeSettableStatus
    let size: AXWindowAttributeSettableStatus
}

enum AXWindowFrameWriteFailure: Error, Equatable {
    case invalidGeometry
    case initialFrameUnavailable
    case initialFrameMismatch(expected: CGRect, actual: CGRect)
    case windowIdentityUnavailable
    case windowIdentityChanged
    case capabilityQueryFailed(attribute: AXWindowFrameAttribute, error: AXError)
    case attributeNotSettable(AXWindowFrameAttribute)
    case valueCreationFailed(AXWindowFrameAttribute)
    case operationBudgetExhausted
    case writeFailed(attribute: AXWindowFrameAttribute, error: AXError)
    case verificationUnavailable
    case verificationMismatch(expected: CGRect, actual: CGRect)

    var mayHaveMutatedWindow: Bool {
        switch self {
        case .writeFailed, .verificationUnavailable, .verificationMismatch:
            return true
        case .invalidGeometry,
             .initialFrameUnavailable,
             .initialFrameMismatch,
             .windowIdentityUnavailable,
             .windowIdentityChanged,
             .capabilityQueryFailed,
             .attributeNotSettable,
             .valueCreationFailed,
             .operationBudgetExhausted:
            return false
        }
    }
}

enum AXWindowFrameRollbackPolicy {
    static func accepts(_ actual: CGRect, attemptedFrames: [CGRect], tolerance: CGFloat) -> Bool {
        attemptedFrames.contains { WindowFrameMatchPolicy.areClose(actual, $0, tolerance: tolerance) }
    }
}

enum AXWindowFrameRollbackResult: Equatable {
    case notRequested
    case restored(actualFrame: CGRect)
    case failed(reason: AXWindowFrameWriteFailure, actualFrame: CGRect?)
}

enum AXWindowFrameWriteResult: Equatable {
    case success(actualFrame: CGRect)
    case failure(reason: AXWindowFrameWriteFailure, rollback: AXWindowFrameRollbackResult)
}

enum AXWindowReadResult {
    case success([AXWindowSnapshot])
    case unread(AXError)

    var windowsOrEmpty: [AXWindowSnapshot] {
        switch self {
        case .success(let windows): return windows
        case .unread: return []
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum AXFocusedWindowRead: Equatable, Sendable {
    case window(CGWindowID)
    case none
    case unread(AXError)
}

struct AXFocusedWindowObservation: Sendable {
    let result: AXFocusedWindowRead
    let observedAt: TimeInterval
    let windowElement: AXElementKey?

    init(result: AXFocusedWindowRead, observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
         windowElement: AXElementKey? = nil) {
        self.result = result
        self.observedAt = observedAt
        self.windowElement = windowElement
    }
}

enum AXSystemFocusedWindowRead: Equatable, Sendable {
    case window(pid: pid_t, windowID: CGWindowID)
    case none
    case unread(AXError)
}

struct AXSystemFocusedWindowObservation: Sendable {
    let result: AXSystemFocusedWindowRead
    let windowElement: AXElementKey?

    init(result: AXSystemFocusedWindowRead, windowElement: AXElementKey? = nil) {
        self.result = result
        self.windowElement = windowElement
    }
}

protocol AppTrackerWindowReading: Sendable {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot]
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult
    func createdWindows(forPID pid: pid_t, elements: [AXElementKey], messagingTimeout: TimeInterval,
                        cancellation: OperationCancellation) -> [AXWindowSnapshot]
    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation
    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation
}

extension AppTrackerWindowReading {
    func createdWindows(forPID pid: pid_t, elements: [AXElementKey], messagingTimeout: TimeInterval,
                        cancellation: OperationCancellation) -> [AXWindowSnapshot] { [] }

    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation {
        .init(result: .unread(.notImplemented))
    }

    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        AXFocusedWindowObservation(result: .unread(.notImplemented))
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult {
        guard !cancellation.isCancelled else { return .unread(.cannotComplete) }
        return inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
    }
}

protocol AccessibilityOperations: Sendable {
    func isTrusted() -> Bool
    func application(_ pid: pid_t) -> AXUIElement
    func systemWide() -> AXUIElement?
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?)
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?)
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError
    func pid(_ element: AXUIElement) -> pid_t?
    func windowID(_ element: AXUIElement) -> CGWindowID?
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool)
}

extension AccessibilityOperations {
    func systemWide() -> AXUIElement? { nil }
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        (.notImplemented, nil)
    }
}

struct NativeAccessibilityOperations: AccessibilityOperations {
    func isTrusted() -> Bool { AXIsProcessTrusted() }
    func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func systemWide() -> AXUIElement? { AXUIElementCreateSystemWide() }
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        return (error, values as? [CFTypeRef])
    }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute, value)
    }
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError { AXUIElementPerformAction(element, action) }
    func pid(_ element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }
    func windowID(_ element: AXUIElement) -> CGWindowID? { AXWindowIDBridge.cgWindowID(for: element) }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { AXUIElementSetMessagingTimeout(element, timeout) }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) {
        var value = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute, &value)
        return (error, value.boolValue)
    }
}

struct AXWindowReader: AppTrackerWindowReading, Sendable {
    private typealias AttributeRead = (error: AXError, value: CFTypeRef?)
    private enum FocusedElementRead {
        case window(AXUIElement, observedAt: TimeInterval)
        case none(observedAt: TimeInterval)
        case unread(AXError)
    }

    private enum GeometryWrite {
        case size(CGSize)
        case frame(CGRect)
    }

    private struct GeometryWriteSample {
        let frame: CGRect
        var windowIDs: [CGWindowID?] = []
    }

    private static let geometryWriteAttributes = [kAXPositionAttribute, kAXSizeAttribute].map { $0 as String }
        + AXWindowIDBridge.fallbackAttributeNames
    private static let inventoryGeometryAttributes = [kAXPositionAttribute, kAXSizeAttribute].map { $0 as String }
    private static let inventoryWindowAttributes = inventoryGeometryAttributes + [kAXRoleAttribute, kAXSubroleAttribute].map { $0 as String }
    private static let inventoryAttributes = [kAXMinimizedAttribute, kAXTitleAttribute].map { $0 as String } + inventoryWindowAttributes

    let accessibility: any AccessibilityOperations
    private var budget: OperationReadBudget?
    private var readMessagingTimeout: TimeInterval = 0.1

    init(accessibility: any AccessibilityOperations = NativeAccessibilityOperations()) { self.accessibility = accessibility }

    func withOperationBudget(_ budget: OperationReadBudget) -> Self {
        var reader = self
        reader.budget = budget
        return reader
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: messagingTimeout, cancellation: cancellation)
    }

    func createdWindows(forPID pid: pid_t, elements: [AXElementKey], messagingTimeout: TimeInterval,
                        cancellation: OperationCancellation) -> [AXWindowSnapshot] {
        guard messagingTimeout.isFinite, messagingTimeout > 0, !cancellation.isCancelled,
              accessibility.isTrusted(), !elements.isEmpty else { return [] }
        let application = accessibility.application(pid)
        var reader = self
        reader.readMessagingTimeout = messagingTimeout
        reader.budget = budget?.limited(to: messagingTimeout * 2)
            ?? OperationReadBudget(maximumDuration: messagingTimeout * 2, cancellation: cancellation)
        var windows: [AXWindowSnapshot] = []
        for element in elements {
            guard !cancellation.isCancelled, reader.budget?.canContinue == true else { break }
            guard !CFEqual(application, element.e) else { continue }
            let result = reader.readInventorySnapshots(elements: [element.e], pid: pid, maxAttempts: 1,
                                                       focusedElement: nil, focusReadUptime: nil)
            guard let window = result.windowsOrEmpty.first, window.role == kAXWindowRole,
                  let id = window.cgWindowID, id != 0 else { continue }
            windows.append(window)
        }
        return windows
    }

    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .init(result: .unread(.illegalArgument)) }
        guard accessibility.isTrusted() else { return .init(result: .unread(.apiDisabled)) }
        var reader = self
        reader.readMessagingTimeout = messagingTimeout
        reader.budget = OperationReadBudget(maximumDuration: messagingTimeout * 2, cancellation: cancellation)
        let application = accessibility.application(pid)
        let focus = reader.readFocusedElement(forPID: pid, from: application, maxAttempts: 1)
        let element: AXUIElement
        let observedAt: TimeInterval
        switch focus {
        case .window(let focused, let sampleTime):
            element = focused
            observedAt = sampleTime
        case .none(let sampleTime): return .init(result: .none, observedAt: sampleTime)
        case .unread(let error): return .init(result: .unread(error))
        }
        guard let remaining = reader.budget?.remaining, remaining > 0 else { return .init(result: .unread(.cannotComplete)) }
        reader.applyMessagingTimeout(min(messagingTimeout, remaining), to: element)
        guard let id = reader.cgWindowID(for: element, maxAttempts: 1), id != 0 else { return .init(result: .unread(.failure)) }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        return .init(result: .window(id), observedAt: observedAt, windowElement: AXElementKey(e: element))
    }

    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation {
        guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .init(result: .unread(.illegalArgument)) }
        guard accessibility.isTrusted() else { return .init(result: .unread(.apiDisabled)) }
        var reader = self
        reader.readMessagingTimeout = messagingTimeout
        reader.budget = OperationReadBudget(maximumDuration: messagingTimeout * 2, cancellation: cancellation)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        guard let system = accessibility.systemWide() else { return .init(result: .unread(.notImplemented)) }
        let (error, value) = accessibility.copy(system, kAXFocusedUIElementAttribute as CFString)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        if error == .noValue { return .init(result: .none) }
        guard error == .success else { return .init(result: .unread(error)) }
        guard let focused = Self.validatedElement(value) else { return .init(result: .unread(.failure)) }
        guard let pid = accessibility.pid(focused) else { return .init(result: .unread(.invalidUIElement)) }
        var role: CFTypeRef?
        let roleError = reader.copyAttributeValue(kAXRoleAttribute as CFString, from: focused, into: &role, maxAttempts: 1)
        guard roleError == .success else { return .init(result: .unread(roleError)) }
        let window: AXUIElement?
        if role as? String == kAXWindowRole as String {
            window = focused
        } else {
            var windowValue: CFTypeRef?
            let windowError = reader.copyAttributeValue(kAXWindowAttribute as CFString, from: focused, into: &windowValue, maxAttempts: 1)
            switch windowError {
            case .noValue: window = nil
            case .success:
                guard let element = Self.validatedElement(windowValue) else { return .init(result: .unread(.failure)) }
                window = element
            default: return .init(result: .unread(windowError))
            }
        }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        let observation: AXSystemFocusedWindowObservation
        if let window {
            guard accessibility.pid(window) == pid else { return .init(result: .unread(.invalidUIElement)) }
            guard let remaining = reader.budget?.remaining, remaining > 0 else { return .init(result: .unread(.cannotComplete)) }
            reader.applyMessagingTimeout(min(messagingTimeout, remaining), to: window)
            guard let id = reader.cgWindowID(for: window, maxAttempts: 1), id != 0 else { return .init(result: .unread(.failure)) }
            observation = .init(result: .window(pid: pid, windowID: id), windowElement: AXElementKey(e: window))
        } else {
            observation = .init(result: .none)
        }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        let (latestError, latest) = accessibility.copy(system, kAXFocusedUIElementAttribute as CFString)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        guard latestError == .success else { return .init(result: .unread(latestError)) }
        guard let latest = Self.validatedElement(latest), CFEqual(latest, focused), accessibility.pid(focused) == pid,
              window.map({ accessibility.pid($0) == pid }) ?? true else { return .init(result: .unread(.invalidUIElement)) }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        return observation
    }

    static func validatedElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func validatedElements(_ value: CFTypeRef?, budget: OperationReadBudget? = nil) -> [AXUIElement]? {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject] else { return nil }
        var result: [AXUIElement] = []
        for value in values {
            guard budget?.canContinue ?? true, let element = validatedElement(value) else { return nil }
            result.append(element)
        }
        return result
    }

    func windows(for app: NSRunningApplication) -> [AXWindowSnapshot] {
        windows(forPID: app.processIdentifier)
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        windowReadResult(forPID: pid).windowsOrEmpty
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: nil)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: messagingTimeout)
    }

    private func readWindows(forPID pid: pid_t, messagingTimeout: TimeInterval?,
                             cancellation: OperationCancellation = OperationCancellation(),
                             expectedElement: AXElementKey? = nil) -> AXWindowReadResult {
        var reader = self
        if let messagingTimeout {
            guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .unread(.illegalArgument) }
            reader.readMessagingTimeout = messagingTimeout
        }
        reader.budget = budget?.limited(to: 2)
            ?? OperationReadBudget(maximumDuration: 2, cancellation: cancellation)
        return reader.readWindowsWithinBudget(forPID: pid, messagingTimeout: messagingTimeout,
                                              expectedElement: expectedElement)
    }

    private func readWindowsWithinBudget(forPID pid: pid_t, messagingTimeout: TimeInterval?,
                                         expectedElement: AXElementKey?) -> AXWindowReadResult {
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        let appElement = accessibility.application(pid)
        applyMessagingTimeout(messagingTimeout, to: appElement)

        var rawWindows: CFTypeRef?
        let maxAttempts = messagingTimeout == nil ? 2 : 1
        let result = copyAttributeValue(
            kAXWindowsAttribute as CFString,
            from: appElement,
            into: &rawWindows,
            maxAttempts: maxAttempts
        )
        guard result == .success else { return .unread(result) }
        guard var elements = Self.validatedElements(rawWindows, budget: budget) else {
            return .unread(budget?.canContinue == false ? .cannotComplete : .failure)
        }

        let focusedElement: AXUIElement?
        let focusReadUptime: TimeInterval?
        switch readFocusedElement(forPID: pid, from: appElement, maxAttempts: maxAttempts) {
        case .window(let element, let sampleTime):
            focusedElement = element
            focusReadUptime = sampleTime
        case .none(let sampleTime):
            focusedElement = nil
            focusReadUptime = sampleTime
        case .unread:
            focusedElement = nil
            focusReadUptime = nil
        }
        let mainElement = elementAttribute(kAXMainWindowAttribute as CFString, from: appElement, maxAttempts: maxAttempts)
        for element in [focusedElement, mainElement].compactMap({ $0 }) {
            guard !elements.contains(where: { CFEqual($0, element) }) else { continue }
            elements.append(element)
        }
        if let expectedElement {
            guard let element = elements.first(where: { AXElementKey(e: $0) == expectedElement }) else {
                return .success([])
            }
            elements = [element]
        }
        return readInventorySnapshots(elements: elements, pid: pid, maxAttempts: maxAttempts,
                                      focusedElement: focusedElement, focusReadUptime: focusReadUptime)
    }

    private func readInventorySnapshots(elements: [AXUIElement], pid: pid_t, maxAttempts: Int,
                                        focusedElement: AXUIElement?, focusReadUptime: TimeInterval?) -> AXWindowReadResult {
        var snapshots: [AXWindowSnapshot] = []
        for element in elements {
            guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
            guard let ownerPID = accessibility.pid(element) else { return .unread(.cannotComplete) }
            guard ownerPID == pid else { continue }
            let batch = readInventoryAttributes(from: element)
            func attribute(_ name: String, recoveringTransientError: Bool = false) -> AttributeRead {
                if let read = batch[name] {
                    let malformed = read.error == .success && !isValidInventoryValue(read.value, attribute: name)
                    let recoverable = recoveringTransientError && Self.isTransientInventoryError(read.error)
                    if !malformed && !recoverable { return read }
                }
                var value: CFTypeRef?
                let error = copyAttributeValue(name as CFString, from: element, into: &value, maxAttempts: maxAttempts)
                guard error == .success else { return (error, nil) }
                guard isValidInventoryValue(value, attribute: name) else { return (.failure, nil) }
                return (.success, value)
            }
            let minimizedRead = attribute(kAXMinimizedAttribute as String)
            let minimized: Bool?
            switch minimizedRead.error {
            case .success:
                guard let value = minimizedRead.value as? NSNumber else { return .unread(.failure) }
                minimized = value.boolValue
            case .attributeUnsupported, .noValue:
                minimized = nil
            default:
                return .unread(minimizedRead.error)
            }
            let titleRead = attribute(kAXTitleAttribute as String)
            let title = AXWindowTitleRead.classify(result: titleRead.error, value: titleRead.value)
            var values: [String: CFTypeRef] = [:]
            for name in Self.inventoryWindowAttributes {
                let read = attribute(name, recoveringTransientError: true)
                switch read.error {
                case .success: values[name] = read.value
                case .attributeUnsupported, .noValue: break
                default:
                    guard minimized == true, Self.inventoryGeometryAttributes.contains(name),
                          Self.isTransientInventoryError(read.error) else { return .unread(read.error) }
                }
            }
            let windowID = cgWindowID(for: element, maxAttempts: maxAttempts)
            let bounds = values[kAXPositionAttribute as String].flatMap { position in
                frame(position: position, size: values[kAXSizeAttribute as String])
            }
            let role = normalizedString(values[kAXRoleAttribute as String])
            let subrole = normalizedString(values[kAXSubroleAttribute as String])
            var isModal: Bool?
            var isTopLevel: Bool?
            if subrole == kAXDialogSubrole as String || subrole == kAXUnknownSubrole as String {
                isModal = boolAttribute(kAXModalAttribute as CFString, from: element, maxAttempts: maxAttempts)
                if let parent = elementAttribute(kAXParentAttribute as CFString, from: element, maxAttempts: maxAttempts) {
                    isTopLevel = accessibility.pid(parent) == pid
                        && stringAttribute(kAXRoleAttribute as CFString, from: parent, maxAttempts: maxAttempts) == kAXApplicationRole as String
                }
            }
            snapshots.append(AXWindowSnapshot(
                pid: pid,
                cgWindowID: windowID,
                titleRead: title,
                bounds: bounds,
                role: role,
                subrole: subrole,
                isMinimized: minimized ?? false,
                isFocusedWindow: focusedElement.map { CFEqual($0, element) } ?? false,
                element: element,
                isMinimizedRead: minimized,
                focusReadUptime: focusReadUptime,
                isModal: isModal, isTopLevel: isTopLevel
            ))
        }
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        return .success(snapshots)
    }

    private static func isTransientInventoryError(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .failure
    }

    private func isValidInventoryValue(_ value: CFTypeRef?, attribute: String) -> Bool {
        guard let value else { return false }
        switch attribute {
        case kAXPositionAttribute: return axValue(from: value).map(AXValueGetType) == .cgPoint
        case kAXSizeAttribute: return axValue(from: value).map(AXValueGetType) == .cgSize
        case kAXMinimizedAttribute: return CFGetTypeID(value) == CFBooleanGetTypeID()
        default: return CFGetTypeID(value) == CFStringGetTypeID()
        }
    }

    private func readInventoryAttributes(from element: AXUIElement) -> [String: AttributeRead] {
        let attributes = Self.inventoryAttributes
        guard budget?.canContinue ?? true else {
            return [kAXMinimizedAttribute as String: (.cannotComplete, nil)]
        }
        applyMessagingTimeout(min(readMessagingTimeout, budget?.remaining ?? readMessagingTimeout), to: element)
        let (error, values) = accessibility.copyAttributes(element, attributes)
        switch error {
        case .notImplemented, .attributeUnsupported, .illegalArgument, .failure:
            return [:]
        case .success:
            guard let values, values.count == attributes.count else { return [:] }
            var result: [String: AttributeRead] = [:]
            for (attribute, value) in zip(attributes, values) {
                if CFGetTypeID(value) == CFNullGetTypeID() { continue }
                var error = AXError.failure
                if let axValue = axValue(from: value), AXValueGetValue(axValue, .axError, &error) {
                    result[attribute] = (error, nil)
                } else {
                    result[attribute] = (.success, value)
                }
            }
            return result
        default:
            return [kAXMinimizedAttribute as String: (error, nil)]
        }
    }

    func captureHandle(
        for target: AXWindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0,
        messagingTimeout: TimeInterval? = nil,
        cancellation: OperationCancellation = OperationCancellation()
    ) -> AXWindowHandle? {
        guard !cancellation.isCancelled, accessibility.isTrusted(), budget?.canContinue != false else { return nil }
        let boundedAttempts = max(1, attempts)

        for attempt in 0..<boundedAttempts {
            guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
            let candidates: [AXWindowSnapshot]
            switch readWindows(forPID: target.pid, messagingTimeout: messagingTimeout,
                               cancellation: cancellation, expectedElement: target.expectedElement) {
            case .success(let snapshots): candidates = snapshots
            case .unread: candidates = []
            }
            guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
            if let snapshot = bestMatch(for: target, from: candidates) {
                return AXWindowHandle(
                    pid: target.pid,
                    title: snapshot.title,
                    bounds: snapshot.bounds,
                    element: snapshot.element
                )
            }

            if attempt < boundedAttempts - 1, retryIntervalMicroseconds > 0 {
                let interval = Double(retryIntervalMicroseconds) / 1_000_000
                let wait = min(interval, budget?.remaining ?? interval)
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
            }
        }

        return nil
    }

    func captureHandle(
        forPID pid: pid_t,
        cgWindowID: CGWindowID,
        messagingTimeout: TimeInterval = 0.1,
        expectedElement: AXElementKey? = nil
    ) -> AXWindowHandle? {
        guard budget?.canContinue != false, accessibility.isTrusted(),
              cgWindowID != 0,
              messagingTimeout.isFinite,
              messagingTimeout > 0 else {
            return nil
        }

        let deadline = ProcessInfo.processInfo.systemUptime + min(messagingTimeout, budget?.remaining ?? messagingTimeout)
        let appElement = accessibility.application(pid)

        func remainingTimeout() -> TimeInterval? {
            guard budget?.canContinue != false else { return nil }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            return remaining > 0 ? remaining : nil
        }

        func matches(_ element: AXUIElement) -> Bool {
            if let expectedElement, AXElementKey(e: element) != expectedElement { return false }
            guard accessibility.pid(element) == pid, let timeout = remainingTimeout() else { return false }
            applyMessagingTimeout(timeout, to: element)
            if let bridgedID = accessibility.windowID(element) {
                return bridgedID == cgWindowID
            }

            for attribute in AXWindowIDBridge.fallbackAttributeNames {
                guard let timeout = remainingTimeout() else { return false }
                applyMessagingTimeout(timeout, to: element)
                if let id = numericWindowIDAttribute(attribute as CFString, from: element, maxAttempts: 1) {
                    return id == cgWindowID
                }
            }
            return false
        }

        func elementAttributeWithinDeadline(_ attribute: CFString) -> AXUIElement? {
            guard let timeout = remainingTimeout() else { return nil }
            applyMessagingTimeout(timeout, to: appElement)
            return elementAttribute(attribute, from: appElement, maxAttempts: 1)
        }

        if let focused = elementAttributeWithinDeadline(kAXFocusedWindowAttribute as CFString),
           matches(focused) {
            return AXWindowHandle(pid: pid, title: nil, bounds: nil, element: focused)
        }
        if let main = elementAttributeWithinDeadline(kAXMainWindowAttribute as CFString),
           matches(main) {
            return AXWindowHandle(pid: pid, title: nil, bounds: nil, element: main)
        }

        guard let timeout = remainingTimeout() else { return nil }
        applyMessagingTimeout(timeout, to: appElement)
        var rawWindows: CFTypeRef?
        guard copyAttributeValue(
            kAXWindowsAttribute as CFString,
            from: appElement,
            into: &rawWindows,
            maxAttempts: 1
        ) == .success,
              let elements = Self.validatedElements(rawWindows, budget: budget),
              let element = elements.first(where: matches) else {
            return nil
        }

        return AXWindowHandle(
            pid: pid,
            title: nil,
            bounds: nil,
            element: element
        )
    }

    func focusedWindow(forPID pid: pid_t, messagingTimeout: TimeInterval? = nil) -> AXUIElement? {
        let app = accessibility.application(pid)
        applyMessagingTimeout(messagingTimeout, to: app)
        guard case .window(let element, _) = readFocusedElement(forPID: pid, from: app,
            maxAttempts: messagingTimeout == nil ? 2 : 1) else { return nil }
        return element
    }

    private func readFocusedElement(forPID pid: pid_t, from application: AXUIElement, maxAttempts: Int) -> FocusedElementRead {
        var value: CFTypeRef?
        let error = copyAttributeValue(kAXFocusedWindowAttribute as CFString, from: application, into: &value,
                                       maxAttempts: maxAttempts)
        let observedAt = ProcessInfo.processInfo.systemUptime
        guard budget?.canContinue != false else { return .unread(.cannotComplete) }
        if error == .noValue { return .none(observedAt: observedAt) }
        guard error == .success else { return .unread(error) }
        guard let element = Self.validatedElement(value) else { return .unread(.failure) }
        guard accessibility.pid(element) == pid else { return .unread(.invalidUIElement) }
        guard budget?.canContinue != false else { return .unread(.cannotComplete) }
        return .window(element, observedAt: observedAt)
    }

    func stringAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> String? {
        normalizedString(copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts))
    }

    private func normalizedString(_ value: CFTypeRef?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func titleAttribute(from element: AXUIElement, maxAttempts: Int = 2) -> AXWindowTitleRead {
        var value: CFTypeRef?
        let result = copyAttributeValue(
            kAXTitleAttribute as CFString,
            from: element,
            into: &value,
            maxAttempts: maxAttempts
        )
        return AXWindowTitleRead.classify(result: result, value: value)
    }

    func boolAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> Bool? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    func cgWindowID(for element: AXUIElement, maxAttempts: Int = 2, messagingTimeout: TimeInterval? = nil) -> UInt32? {
        guard budget?.canContinue != false else { return nil }
        applyMessagingTimeout(messagingTimeout, to: element)
        if let bridgedID = accessibility.windowID(element) {
            return bridgedID
        }

        for attribute in AXWindowIDBridge.fallbackAttributeNames {
            if let id = numericWindowIDAttribute(attribute as CFString, from: element, maxAttempts: maxAttempts) {
                return id
            }
        }

        return nil
    }

    func matchesCGWindowID(
        _ expected: CGWindowID,
        element: AXUIElement,
        messagingTimeout: TimeInterval
    ) -> Bool? {
        let readBudget = budget?.limited(to: messagingTimeout) ??
            OperationReadBudget(maximumDuration: messagingTimeout, cancellation: OperationCancellation())
        let reader = withOperationBudget(readBudget)
        guard let actual = reader.cgWindowID(for: element, maxAttempts: 1, messagingTimeout: messagingTimeout),
              readBudget.canContinue else { return nil }
        return actual == expected
    }

    func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int = 2
    ) -> AXUIElement? {
        Self.validatedElement(copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts))
    }

    func frame(of element: AXUIElement, maxAttempts: Int = 2) -> CGRect? {
        guard let positionAX = copyAttributeValue(kAXPositionAttribute as CFString, from: element, maxAttempts: maxAttempts),
              let sizeAX = copyAttributeValue(kAXSizeAttribute as CFString, from: element, maxAttempts: maxAttempts) else {
            return nil
        }

        return frame(position: positionAX, size: sizeAX)
    }

    private func frame(position positionAX: CFTypeRef, size sizeAX: CFTypeRef?) -> CGRect? {
        guard let sizeAX, let position = axValue(from: positionAX),
              let sizeValueRef = axValue(from: sizeAX) else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(sizeValueRef) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeValueRef, .cgSize, &size) else {
            return nil
        }

        let frame = CGRect(origin: point, size: size)
        return WindowFrameMatchPolicy.isValid(frame) ? frame : nil
    }

    func frame(of element: AXUIElement, messagingTimeout: TimeInterval) -> CGRect? {
        applyMessagingTimeout(messagingTimeout, to: element)
        return frame(of: element, maxAttempts: 1)
    }

    func frameSettableStatus(
        of element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1
    ) -> AXWindowFrameSettableStatus {
        applyMessagingTimeout(messagingTimeout, to: element)
        return AXWindowFrameSettableStatus(
            position: settableStatus(kAXPositionAttribute as CFString, on: element),
            size: settableStatus(kAXSizeAttribute as CFString, on: element)
        )
    }

    func setSize(
        _ size: CGSize,
        for element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1,
        frameVerificationTolerance: CGFloat = 1,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        restoreOnFailureTo restoreFrame: CGRect? = nil,
        expectedWindowID: CGWindowID? = nil,
        onAttempt: (CGRect) -> Void = { _ in },
        checkWriteAdmission: () -> AXWindowFrameWriteFailure? = { nil }
    ) -> AXWindowFrameWriteResult {
        performGeometryWrite(
            .size(size), for: element, messagingTimeout: messagingTimeout,
            frameVerificationTolerance: frameVerificationTolerance,
            onlyIfCurrentMatches: expectedCurrentFrame,
            restoreOnFailureTo: restoreFrame,
            expectedWindowID: expectedWindowID,
            onAttempt: onAttempt,
            checkWriteAdmission: checkWriteAdmission
        )
    }

    func setFrame(
        _ frame: CGRect,
        for element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1,
        frameVerificationTolerance: CGFloat = 1,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        restoreOnFailureTo restoreFrame: CGRect? = nil,
        expectedWindowID: CGWindowID? = nil,
        onAttempt: (CGRect) -> Void = { _ in },
        checkWriteAdmission: () -> AXWindowFrameWriteFailure? = { nil }
    ) -> AXWindowFrameWriteResult {
        performGeometryWrite(
            .frame(frame), for: element, messagingTimeout: messagingTimeout,
            frameVerificationTolerance: frameVerificationTolerance,
            onlyIfCurrentMatches: expectedCurrentFrame,
            restoreOnFailureTo: restoreFrame,
            expectedWindowID: expectedWindowID,
            onAttempt: onAttempt,
            checkWriteAdmission: checkWriteAdmission
        )
    }

    private func performGeometryWrite(
        _ geometry: GeometryWrite,
        for element: AXUIElement,
        messagingTimeout: TimeInterval,
        frameVerificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect?,
        restoreOnFailureTo restoreFrame: CGRect?,
        expectedWindowID: CGWindowID?,
        onAttempt: (CGRect) -> Void,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?
    ) -> AXWindowFrameWriteResult {
        applyMessagingTimeout(messagingTimeout, to: element)
        guard isValid(geometry), isValid(tolerance: frameVerificationTolerance),
              expectedCurrentFrame.map(isValid(frame:)) ?? true,
              restoreFrame.map(isValid(frame:)) ?? true else {
            return .failure(reason: .invalidGeometry, rollback: .notRequested)
        }

        var attemptedFrames: [CGRect] = []
        func recordAttempt(_ frame: CGRect) {
            attemptedFrames.append(frame)
            onAttempt(frame)
        }
        let result: Result<CGRect, AXWindowFrameWriteFailure>
        switch geometry {
        case let .size(size):
            result = writeSize(
                size, to: element, frameVerificationTolerance: frameVerificationTolerance,
                onlyIfCurrentMatches: expectedCurrentFrame, expectedWindowID: expectedWindowID,
                checkWriteAdmission: checkWriteAdmission, recordAttempt: recordAttempt
            )
        case let .frame(frame):
            result = writeFrame(
                frame, to: element, frameVerificationTolerance: frameVerificationTolerance,
                onlyIfCurrentMatches: expectedCurrentFrame, expectedWindowID: expectedWindowID,
                checkWriteAdmission: checkWriteAdmission, recordAttempt: recordAttempt
            )
        }
        switch result {
        case let .success(actualFrame):
            return .success(actualFrame: actualFrame)
        case let .failure(reason):
            return .failure(
                reason: reason,
                rollback: rollbackResult(
                    after: reason,
                    to: restoreFrame,
                    for: element,
                    attemptedFrames: attemptedFrames,
                    frameVerificationTolerance: frameVerificationTolerance,
                    expectedWindowID: expectedWindowID,
                    checkWriteAdmission: checkWriteAdmission
                )
            )
        }
    }

    func setMinimized(_ minimized: Bool, for handle: AXWindowHandle) -> Bool {
        let value: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let result = accessibility.set(
            handle.element,
            kAXMinimizedAttribute as CFString,
            value
        )
        return result == .success
    }

    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int = 2
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = copyAttributeValue(attribute, from: element, into: &value, maxAttempts: maxAttempts)
        return result == .success ? value : nil
    }

    @discardableResult
    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        into value: inout CFTypeRef?,
        maxAttempts: Int = 2
    ) -> AXError {
        var attempt = 0
        var lastResult: AXError = .failure
        while attempt < maxAttempts {
            if let budget {
                guard budget.canContinue else { return .cannotComplete }
                applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element)
            }
            let result: AXError
            (result, value) = accessibility.copy(element, attribute)
            if result == .success {
                return result
            }

            lastResult = result
            if result != .cannotComplete {
                return result
            }

            attempt += 1
        }

        return lastResult
    }

    private func numericWindowIDAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int
    ) -> UInt32? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts) else {
            return nil
        }
        return AXWindowIDBridge.cgWindowID(from: value)
    }

    private func axValue(from value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func settableStatus(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> AXWindowAttributeSettableStatus {
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
        let (result, isSettable) = accessibility.isSettable(element, attribute)
        guard result == .success else { return .unread(result) }
        return isSettable ? .settable : .notSettable
    }

    private func windowIdentityFailure(_ expectedWindowID: CGWindowID?, for element: AXUIElement) -> AXWindowFrameWriteFailure? {
        guard let expectedWindowID else { return nil }
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        guard let actualWindowID = cgWindowID(for: element, maxAttempts: 1) else {
            return budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable
        }
        return actualWindowID == expectedWindowID ? nil : .windowIdentityChanged
    }

    private func geometryWriteSample(
        for element: AXUIElement, expectedWindowID: CGWindowID?, maxAttempts: Int
    ) -> GeometryWriteSample? {
        if expectedWindowID != nil {
            guard budget?.canContinue != false else { return nil }
            if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
            let attributes = Self.geometryWriteAttributes
            let (error, values) = accessibility.copyAttributes(element, attributes)
            switch error {
            case .success:
                if let values, values.count == attributes.count,
                   let frame = frame(position: values[0], size: values[1]) {
                    return GeometryWriteSample(frame: frame, windowIDs: values.dropFirst(2).map(AXWindowIDBridge.cgWindowID))
                }
            case .notImplemented, .attributeUnsupported, .illegalArgument, .failure:
                break
            default:
                return nil
            }
        }
        return frame(of: element, maxAttempts: maxAttempts).map { GeometryWriteSample(frame: $0) }
    }

    private func writeGeometryAttribute(
        _ attribute: AXWindowFrameAttribute, to element: AXUIElement, value: CFTypeRef,
        expectedWindowID: CGWindowID?, sample: GeometryWriteSample,
        onlyIfCurrentMatches expectedFrame: CGRect?, frameVerificationTolerance: CGFloat,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?, onAttempt: (CGRect) -> Void
    ) -> AXWindowFrameWriteFailure? {
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) { return failure }
        var admittedFrame = sample.frame
        if let expectedWindowID, let expectedFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                if budget?.canContinue == false { return .operationBudgetExhausted }
                return attribute == .position ? .verificationUnavailable : .initialFrameUnavailable
            }
            for (index, id) in current.windowIDs.enumerated() {
                guard let id, id != expectedWindowID else { continue }
                if !sample.windowIDs.indices.contains(index) || sample.windowIDs[index] != id {
                    return .windowIdentityChanged
                }
            }
            for (index, id) in sample.windowIDs.enumerated() where id == expectedWindowID {
                guard current.windowIDs.indices.contains(index), current.windowIDs[index] != nil else {
                    return .windowIdentityUnavailable
                }
            }
            guard measuredFramesAgree(current.frame, expectedFrame, tolerance: frameVerificationTolerance) else {
                return attribute == .position
                    ? .verificationUnavailable
                    : .initialFrameMismatch(expected: expectedFrame, actual: current.frame)
            }
            admittedFrame = current.frame
        }
        if let failure = checkWriteAdmission() { return failure }
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        onAttempt(admittedFrame)
        let name = attribute == .size ? kAXSizeAttribute : kAXPositionAttribute
        let result = accessibility.set(element, name as CFString, value)
        return result == .success ? nil : .writeFailed(attribute: attribute, error: result)
    }

    private func writeSize(
        _ size: CGSize,
        to element: AXUIElement,
        frameVerificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?,
        recordAttempt: (CGRect) -> Void = { _ in }
    ) -> Result<CGRect, AXWindowFrameWriteFailure> {
        guard let initialFrame = frame(of: element, maxAttempts: 1) else {
            return .failure(budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable)
        }
        if let expectedCurrentFrame,
           !measuredFramesAgree(initialFrame, expectedCurrentFrame, tolerance: frameVerificationTolerance) {
            return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: initialFrame))
        }

        if sizesMatch(initialFrame.size, size, tolerance: frameVerificationTolerance) {
            return .success(initialFrame)
        }

        switch settableStatus(kAXSizeAttribute as CFString, on: element) {
        case .settable:
            break
        case .notSettable:
            return .failure(.attributeNotSettable(.size))
        case let .unread(error):
            return .failure(.capabilityQueryFailed(attribute: .size, error: error))
        }

        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else {
            return .failure(.valueCreationFailed(.size))
        }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) {
            return .failure(failure)
        }
        var sample = GeometryWriteSample(frame: initialFrame)
        if let expectedCurrentFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                return .failure(budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable)
            }
            guard measuredFramesAgree(current.frame, expectedCurrentFrame, tolerance: frameVerificationTolerance) else {
                return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: current.frame))
            }
            sample = current
        }

        var expectedFrame = CGRect(origin: sample.frame.origin, size: size)
        if let failure = writeGeometryAttribute(
            .size, to: element, value: sizeValue, expectedWindowID: expectedWindowID, sample: sample,
            onlyIfCurrentMatches: expectedCurrentFrame, frameVerificationTolerance: frameVerificationTolerance,
            checkWriteAdmission: checkWriteAdmission,
            onAttempt: { admitted in
                expectedFrame.origin = admitted.origin
                recordAttempt(expectedFrame)
            }
        ) {
            return .failure(failure)
        }

        guard let actualFrame = frame(of: element, maxAttempts: 2) else {
            return .failure(.verificationUnavailable)
        }
        guard measuredFramesAgree(actualFrame, expectedFrame, tolerance: frameVerificationTolerance) else {
            return .failure(.verificationMismatch(expected: expectedFrame, actual: actualFrame))
        }
        return .success(actualFrame)
    }

    private func writeFrame(
        _ intendedWindowFrame: CGRect,
        to element: AXUIElement,
        frameVerificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?,
        recordAttempt: (CGRect) -> Void = { _ in }
    ) -> Result<CGRect, AXWindowFrameWriteFailure> {
        guard let initialFrame = frame(of: element, maxAttempts: 1) else {
            return .failure(.initialFrameUnavailable)
        }
        if let expectedCurrentFrame,
           !measuredFramesAgree(initialFrame, expectedCurrentFrame, tolerance: frameVerificationTolerance) {
            return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: initialFrame))
        }
        if measuredFramesAgree(initialFrame, intendedWindowFrame, tolerance: frameVerificationTolerance) {
            return .success(initialFrame)
        }

        let needsSize = !sizesMatch(
            initialFrame.size,
            intendedWindowFrame.size,
            tolerance: frameVerificationTolerance
        )
        let needsPosition = !pointsMatch(
            initialFrame.origin,
            intendedWindowFrame.origin,
            tolerance: frameVerificationTolerance
        )

        if needsSize {
            switch settableStatus(kAXSizeAttribute as CFString, on: element) {
            case .settable:
                break
            case .notSettable:
                return .failure(.attributeNotSettable(.size))
            case let .unread(error):
                return .failure(.capabilityQueryFailed(attribute: .size, error: error))
            }
        }
        if needsPosition {
            switch settableStatus(kAXPositionAttribute as CFString, on: element) {
            case .settable:
                break
            case .notSettable:
                return .failure(.attributeNotSettable(.position))
            case let .unread(error):
                return .failure(.capabilityQueryFailed(attribute: .position, error: error))
            }
        }

        var mutableSize = intendedWindowFrame.size
        let sizeValue = needsSize ? AXValueCreate(.cgSize, &mutableSize) : nil
        if needsSize, sizeValue == nil {
            return .failure(.valueCreationFailed(.size))
        }

        var mutablePosition = intendedWindowFrame.origin
        let positionValue = needsPosition ? AXValueCreate(.cgPoint, &mutablePosition) : nil
        if needsPosition, positionValue == nil {
            return .failure(.valueCreationFailed(.position))
        }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) {
            return .failure(failure)
        }
        var sample = GeometryWriteSample(frame: initialFrame)
        if let expectedCurrentFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                return .failure(.initialFrameUnavailable)
            }
            guard measuredFramesAgree(current.frame, expectedCurrentFrame, tolerance: frameVerificationTolerance) else {
                return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: current.frame))
            }
            sample = current
        }

        var admittedFrame = sample.frame
        if let sizeValue {
            if let failure = writeGeometryAttribute(
                .size, to: element, value: sizeValue, expectedWindowID: expectedWindowID, sample: sample,
                onlyIfCurrentMatches: expectedCurrentFrame, frameVerificationTolerance: frameVerificationTolerance,
                checkWriteAdmission: checkWriteAdmission,
                onAttempt: { admitted in
                    admittedFrame = admitted
                    recordAttempt(CGRect(origin: admitted.origin, size: intendedWindowFrame.size))
                }
            ) {
                return .failure(failure)
            }
        }

        if let positionValue {
            if needsSize, let failure = windowIdentityFailure(expectedWindowID, for: element) {
                return .failure(failure)
            }
            let expectedPartial = CGRect(origin: admittedFrame.origin, size: needsSize ? intendedWindowFrame.size : admittedFrame.size)
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 2),
                  measuredFramesAgree(current.frame, expectedPartial, tolerance: frameVerificationTolerance) else {
                return .failure(.verificationUnavailable)
            }
            if let failure = writeGeometryAttribute(
                .position, to: element, value: positionValue, expectedWindowID: expectedWindowID, sample: current,
                onlyIfCurrentMatches: expectedPartial, frameVerificationTolerance: frameVerificationTolerance,
                checkWriteAdmission: checkWriteAdmission,
                onAttempt: { _ in recordAttempt(intendedWindowFrame) }
            ) {
                return .failure(needsSize && failure == .operationBudgetExhausted ? .verificationUnavailable : failure)
            }
        }

        guard let actualFrame = frame(of: element, maxAttempts: 2) else {
            return .failure(.verificationUnavailable)
        }
        guard measuredFramesAgree(actualFrame, intendedWindowFrame, tolerance: frameVerificationTolerance) else {
            return .failure(.verificationMismatch(expected: intendedWindowFrame, actual: actualFrame))
        }
        return .success(actualFrame)
    }

    private func rollbackResult(
        after failure: AXWindowFrameWriteFailure,
        to restoreFrame: CGRect?,
        for element: AXUIElement,
        attemptedFrames: [CGRect],
        frameVerificationTolerance: CGFloat,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?
    ) -> AXWindowFrameRollbackResult {
        guard failure.mayHaveMutatedWindow, let restoreFrame else {
            return .notRequested
        }

        guard let current = frame(of: element, maxAttempts: 1) else {
            return .failed(reason: .verificationUnavailable, actualFrame: nil)
        }
        guard AXWindowFrameRollbackPolicy.accepts(current, attemptedFrames: attemptedFrames, tolerance: frameVerificationTolerance) else {
            return .failed(reason: .initialFrameMismatch(expected: attemptedFrames.last ?? restoreFrame, actual: current), actualFrame: current)
        }
        switch writeFrame(
            restoreFrame,
            to: element,
            frameVerificationTolerance: frameVerificationTolerance,
            onlyIfCurrentMatches: current,
            expectedWindowID: expectedWindowID,
            checkWriteAdmission: checkWriteAdmission
        ) {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason):
            return .failed(
                reason: reason,
                actualFrame: frame(of: element, maxAttempts: 1)
            )
        }
    }

    private func isValid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func isValid(_ geometry: GeometryWrite) -> Bool {
        switch geometry {
        case let .size(size): isValid(size: size)
        case let .frame(frame): isValid(frame: frame)
        }
    }

    private func isValid(frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && isValid(size: frame.size)
    }

    private func isValid(tolerance: CGFloat) -> Bool {
        tolerance.isFinite && tolerance >= 0
    }

    private func measuredFramesAgree(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        pointsMatch(lhs.origin, rhs.origin, tolerance: tolerance)
            && sizesMatch(lhs.size, rhs.size, tolerance: tolerance)
    }

    private func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    private func sizesMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func applyMessagingTimeout(_ timeout: TimeInterval?, to element: AXUIElement) {
        guard let timeout else { return }
        let boundedTimeout = min(timeout, budget?.remaining ?? timeout)
        guard boundedTimeout > 0 else { return }
        _ = accessibility.setTimeout(element, Float(boundedTimeout))
    }

    private func bestMatch(
        for target: AXWindowTarget,
        from snapshots: [AXWindowSnapshot]
    ) -> AXWindowSnapshot? {
        if target.expectedElement != nil, target.cgWindowID == nil {
            return snapshots.first
        }
        let candidates = snapshots.map {
            AXWindowMatchPolicy.Candidate(title: $0.title, bounds: $0.bounds, cgWindowID: $0.cgWindowID)
        }
        guard let index = AXWindowMatchPolicy.unambiguousCandidateIndex(
            targetTitle: target.title,
            targetBounds: target.bounds,
            candidates: candidates,
            expectedCGWindowID: target.cgWindowID
        ) else { return nil }
        return snapshots[index]
    }

}

enum AXWindowIDBridge {
    typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let fallbackAttributeNames = ["AXWindowID", "AXWindowNumber"]

    private static let getWindowFunction: GetWindowFunction? = {
        let frameworkPaths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        ]
        let symbolNames = [
            "_AXUIElementGetWindow",
            "AXUIElementGetWindow"
        ]

        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            for symbolName in symbolNames {
                if let symbol = dlsym(handle, symbolName) {
                    return unsafeBitCast(symbol, to: GetWindowFunction.self)
                }
            }
            dlclose(handle)
        }

        return nil
    }()

    static func cgWindowID(for element: AXUIElement) -> UInt32? {
        guard let getWindowFunction else { return nil }

        var windowID = CGWindowID(0)
        guard getWindowFunction(element, &windowID) == .success else {
            return nil
        }
        return windowID == 0 ? nil : UInt32(windowID)
    }

    static func cgWindowID(from value: CFTypeRef) -> UInt32? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let id = UInt32(exactly: number.doubleValue), id != 0 else { return nil }
            return id
        }

        if let string = value as? String,
           let id = UInt32(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id == 0 ? nil : id
        }

        return nil
    }
}

#if DEBUG
extension AXWindowFrameAttribute {
    var diagnosticDescription: String {
        switch self { case .position: return "position"; case .size: return "size" }
    }
}

extension AXWindowFrameWriteFailure {
    var diagnosticDescription: String {
        switch self {
        case .invalidGeometry: return "invalidGeometry"
        case .initialFrameUnavailable: return "initialFrameUnavailable"
        case let .initialFrameMismatch(expected, actual):
            return "initialFrameMismatch(expected:\(WindowFrameMatchPolicy.signature(for: expected)),actual:\(WindowFrameMatchPolicy.signature(for: actual)))"
        case .windowIdentityUnavailable: return "windowIdentityUnavailable"
        case .windowIdentityChanged: return "windowIdentityChanged"
        case let .capabilityQueryFailed(attribute, error): return "capabilityQueryFailed(\(attribute.diagnosticDescription),\(error.rawValue))"
        case let .attributeNotSettable(attribute): return "attributeNotSettable(\(attribute.diagnosticDescription))"
        case let .valueCreationFailed(attribute): return "valueCreationFailed(\(attribute.diagnosticDescription))"
        case .operationBudgetExhausted: return "operationBudgetExhausted"
        case let .writeFailed(attribute, error): return "writeFailed(\(attribute.diagnosticDescription),\(error.rawValue))"
        case .verificationUnavailable: return "verificationUnavailable"
        case let .verificationMismatch(expected, actual):
            return "verificationMismatch(expected:\(WindowFrameMatchPolicy.signature(for: expected)),actual:\(WindowFrameMatchPolicy.signature(for: actual)))"
        }
    }
}

extension AXWindowFrameRollbackResult {
    var diagnosticDescription: String {
        switch self {
        case .notRequested: return "notRequested"
        case let .restored(actual): return "restored(\(WindowFrameMatchPolicy.signature(for: actual)))"
        case let .failed(reason, actual): return "failed(\(reason.diagnosticDescription),\(WindowFrameMatchPolicy.signature(for: actual)))"
        }
    }
}
#endif
