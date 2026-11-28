import Combine
import CoreGraphics
import Foundation

struct WindowFocusConfirmation: Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    let element: AXElementKey
    let observedAt: TimeInterval
}

struct WindowActionResult: Sendable {
    let success: Bool
    let focus: WindowFocusConfirmation?

    init(success: Bool, focus: WindowFocusConfirmation? = nil) {
        self.success = success
        self.focus = focus
    }
}

@MainActor
protocol WindowInventoryTracking: AnyObject {
    var snapshots: AnyPublisher<DockSnapshot, Never> { get }
    var windowSpaceInvalidations: AnyPublisher<CGWindowID, Never> { get }
    func start()
    func stop()
    func refreshFrontmostWindow()
    func acceptRestoredWindowFocus(_ focus: WindowFocusConfirmation, target: WindowActionIdentity)
}

extension WindowInventoryTracking {
    var windowSpaceInvalidations: AnyPublisher<CGWindowID, Never> { Empty().eraseToAnyPublisher() }
    func refreshFrontmostWindow() {}
    func acceptRestoredWindowFocus(_ focus: WindowFocusConfirmation, target: WindowActionIdentity) {}
}

protocol WindowActionExecuting: Sendable {
    func hasNativeFocus(_ record: WindowRecord, cancellation: OperationCancellation) -> Bool
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                 forcedMinimizedPrior: Bool,
                 cancellation: OperationCancellation,
                 onHandoffTarget: (@Sendable (WindowID) -> Void)?) -> Bool
    func executeWithFocusConfirmation(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                                      forcedMinimizedPrior: Bool, cancellation: OperationCancellation,
                                      onHandoffTarget: (@Sendable (WindowID) -> Void)?) -> WindowActionResult
}

extension WindowActionExecuting {
    func hasNativeFocus(_ record: WindowRecord, cancellation: OperationCancellation) -> Bool {
        !cancellation.isCancelled && record.status == .active
    }

    func executeWithFocusConfirmation(_ request: PlatformActionRequest, snapshot: DockSnapshot,
                                      forcedMinimizedPrior: Bool, cancellation: OperationCancellation,
                                      onHandoffTarget: (@Sendable (WindowID) -> Void)?) -> WindowActionResult {
        WindowActionResult(success: execute(request, snapshot: snapshot, forcedMinimizedPrior: forcedMinimizedPrior,
                                            cancellation: cancellation, onHandoffTarget: onHandoffTarget))
    }
}
