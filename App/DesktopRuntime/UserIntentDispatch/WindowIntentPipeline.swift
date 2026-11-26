import Foundation
#if DEBUG
import os
#endif

@MainActor
final class IntentPipeline {
    private let actionPlanning: LifecycleActionPlanner
    private let monotonicNow: () -> ContinuousClock.Instant
    private(set) var feedbackState = IntentFeedbackState()
    #if DEBUG
    private let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "intent-pipeline")
    #endif

    init(actionPlanning: LifecycleActionPlanner, monotonicNow: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.actionPlanning = actionPlanning
        self.monotonicNow = monotonicNow
    }

    func reset() { feedbackState = IntentFeedbackState() }

    func discardFeedback(for windowIDs: Set<String>) {
        feedbackState.discard(windowIDs: windowIDs)
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        pendingMinimize: Bool = false
    ) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: snapshot, pendingMinimize: pendingMinimize)
    }

    func canBegin(intent: UserIntent) -> Bool {
        if feedbackState.canBegin(windowID: intent.windowID.rawValue) { return true }
        return intent.action == .close && feedbackState.entriesByWindowID[intent.windowID.rawValue]?.action != .close
    }

    func registerPending(intent: UserIntent, request: PlatformActionRequest, at timestamp: ContinuousClock.Instant? = nil) {
        feedbackState.begin(
            windowID: intent.windowID.rawValue,
            action: feedbackAction(for: request),
            at: timestamp ?? monotonicNow()
        )
    }

    func registerExecutionResult(intent: UserIntent, request: PlatformActionRequest, success: Bool) {
        let action = feedbackAction(for: request)
        if success {
            feedbackState.markSucceededImmediatelyIfNeeded(
                windowID: intent.windowID.rawValue,
                action: action,
                at: monotonicNow()
            )
        } else {
            feedbackState.markFailed(windowID: intent.windowID.rawValue, action: action, at: monotonicNow())
        }
    }

    func reconcile(with snapshot: DockSnapshot, now: ContinuousClock.Instant? = nil) {
        let before = feedbackState.entriesByWindowID
        feedbackState.reconcile(snapshot: snapshot, now: now ?? monotonicNow())
        for (windowID, entry) in feedbackState.entriesByWindowID {
            if let old = before[windowID], old.phase == .pending, entry.phase != .pending {
                #if DEBUG
                logger.info("[B-pending-cleared] t=\(CFAbsoluteTimeGetCurrent(), privacy: .public) windowID=\(windowID, privacy: .public) action=\(entry.action.rawValue, privacy: .public) → \(entry.phase.rawValue, privacy: .public)")
                #endif
            }
        }
    }

    private func feedbackAction(for request: PlatformActionRequest) -> UserIntentAction {
        switch request.kind {
        case .activateWindow:
            return .activate
        case .minimizeWindow:
            return .minimize
        case .closeWindow:
            return .close
        }
    }
}

struct IntentFeedbackState {
    private(set) var entriesByWindowID: [String: Entry] = [:]

    mutating func discard(windowIDs: Set<String>) {
        for id in windowIDs { entriesByWindowID.removeValue(forKey: id) }
    }

    func canBegin(windowID: String) -> Bool {
        guard let entry = entriesByWindowID[windowID] else { return true }
        return entry.phase != .pending
    }

    mutating func begin(windowID: String, action: UserIntentAction, at timestamp: ContinuousClock.Instant) {
        let entry = Entry(
            windowID: windowID,
            action: action,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[windowID] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(
        windowID: String,
        action: UserIntentAction,
        at timestamp: ContinuousClock.Instant
    ) {
        if action == .activate {
            update(windowID: windowID, phase: .success, at: timestamp)
        }
    }

    mutating func markFailed(windowID: String, action: UserIntentAction, at timestamp: ContinuousClock.Instant) {
        update(windowID: windowID, phase: .failure, at: timestamp)
    }

    mutating func reconcile(snapshot: DockSnapshot, now: ContinuousClock.Instant) {
        var orderedWindowIDs: Set<WindowID>?
        for (windowID, entry) in entriesByWindowID {
            if entry.phase == .pending,
               entry.updatedAt.duration(to: now) > entry.phase.retention {
                update(windowID: windowID, phase: .failure, at: now)
                continue
            }

            let typedWindowID = WindowID(rawValue: windowID)
            guard let record = snapshot.windows[typedWindowID] else {
                guard entry.action == .close else { continue }
                let ordered = orderedWindowIDs ?? Set(snapshot.orderedWindowIDs)
                orderedWindowIDs = ordered
                if !ordered.contains(typedWindowID) {
                    update(windowID: windowID, phase: .success, at: now)
                }
                continue
            }

            switch entry.action {
            case .toggle:
                break
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .close:
                if record.status == .closedPending {
                    update(windowID: windowID, phase: .success, at: now)
                }
            }
        }

        entriesByWindowID = entriesByWindowID.filter { _, entry in
            entry.updatedAt.duration(to: now) <= entry.phase.retention
        }
    }

    private mutating func update(windowID: String, phase: FeedbackPhase, at timestamp: ContinuousClock.Instant) {
        guard var entry = entriesByWindowID[windowID], entry.phase != phase else { return }
        entry.phase = phase
        entry.updatedAt = timestamp
        entriesByWindowID[windowID] = entry
    }

    struct Entry: Hashable {
        let windowID: String
        let action: UserIntentAction
        var phase: FeedbackPhase
        var updatedAt: ContinuousClock.Instant
    }

    enum FeedbackPhase: String, Hashable {
        case pending
        case success
        case failure

        var retention: Duration {
            switch self {
            case .pending:
                return .seconds(4)
            case .success, .failure:
                return .milliseconds(1500)
            }
        }
    }
}
