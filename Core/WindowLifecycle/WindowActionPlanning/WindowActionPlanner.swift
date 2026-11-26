import AppKit
import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case toggle
    case activate
    case minimize
    case close
}

enum UserIntent: Hashable, Sendable {
    case toggle(WindowID)
    case activate(WindowID)
    case close(WindowID)

    var windowID: WindowID {
        switch self {
        case let .toggle(id), let .activate(id), let .close(id):
            return id
        }
    }

    var action: UserIntentAction {
        switch self {
        case .toggle:
            return .toggle
        case .activate:
            return .activate
        case .close:
            return .close
        }
    }
}

final class LifecycleActionPlanner {
    private let isAppFrontmost: (pid_t) -> Bool

    init(isAppFrontmost: @escaping (pid_t) -> Bool = {
        NSRunningApplication(processIdentifier: $0)?.isActive == true
    }) {
        self.isAppFrontmost = isAppFrontmost
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        pendingMinimize: Bool = false
    ) -> PlatformActionRequest {
        switch intent {
        case let .toggle(id):
            guard let record = snapshot.windows[id] else {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            let appIsFrontmost = isAppFrontmost(record.pid)
                || record.owningApplication.map { isAppFrontmost($0.pid) } == true
            if appIsFrontmost, record.status == .active, !pendingMinimize {
                return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
            }
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .activate(id):
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .close(id):
            return PlatformActionRequest(kind: .closeWindow, windowID: id)
        }
    }
}
