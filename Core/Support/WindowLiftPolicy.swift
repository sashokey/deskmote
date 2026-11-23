import CoreGraphics
import Darwin
import Foundation

struct WindowLiftAvoidanceContext: Equatable, Sendable {
    let geometry: WindowLiftAvoidance.Geometry
    let displayWindowServerFrame: CGRect
    let usableWindowServerFrame: CGRect
    let primaryDisplayHeight: CGFloat
}

enum WindowLiftAvoidance {
    static let windowFitTolerance: CGFloat = 12
    static let frameVerificationTolerance: CGFloat = 2
    static let taskbarClearanceInset: CGFloat = 2
    static let animationDuration: TimeInterval = 0.5
    static let liftFrameRate: Double = 30
    static let activeDetectionInterval: TimeInterval = 0.2
    static let transitioningWindowProbeInterval: TimeInterval = 0.05
    static let maxLiftRetries = 1
    static let applicationResponseWindow: TimeInterval = 1.0
    static let maxResponseRounds = 2
    static let minimumTiledWidthRatio: CGFloat = 0.25
    static let minimumTiledHeightRatio: CGFloat = 0.30

    enum PollCadence {
        static let idleDetectionInterval: TimeInterval = 1.0

        static func needsFastProbe(_ state: SessionState, at now: TimeInterval) -> Bool {
            if case .writing = state { return true }
            guard let responseStart = state.responseStart else { return false }
            return now < responseStart + applicationResponseWindow
        }

        static func windowPollDelay(states: [SessionState], suppressions: [Suppression], at now: TimeInterval) -> TimeInterval {
            if states.contains(where: { needsFastProbe($0, at: now) }) { return activeDetectionInterval }
            let awaitingResponse = suppressions.contains { $0.awaitsApplicationResponse(at: now) }
            return awaitingResponse ? activeDetectionInterval : idleDetectionInterval
        }
    }

    struct EventPollCoalescer: Equatable {
        private(set) var pending = false
        private(set) var lastScanStartedAt: TimeInterval?

        mutating func request(at now: TimeInterval, scanInFlight: Bool) -> Action {
            pending = true
            return servicePendingScan(at: now, scanInFlight: scanInFlight)
        }

        mutating func reset() {
            pending = false
            lastScanStartedAt = nil
        }

        mutating func finishObservationScan(at now: TimeInterval) -> Action {
            servicePendingScan(at: now, scanInFlight: false)
        }

        mutating func coalescingDelayElapsed(at now: TimeInterval, scanInFlight: Bool) -> Action {
            servicePendingScan(at: now, scanInFlight: scanInFlight)
        }

        private mutating func servicePendingScan(at now: TimeInterval, scanInFlight: Bool) -> Action {
            guard pending, !scanInFlight else { return .none }
            if let lastScanStartedAt {
                let delay = activeDetectionInterval - (now - lastScanStartedAt)
                if delay > 0.000_001 { return .schedule(after: delay) }
            }

            pending = false
            lastScanStartedAt = now
            return .start
        }

        enum Action: Equatable {
            case none, start
            case schedule(after: TimeInterval)
        }
    }

    struct WindowKey: Hashable, Sendable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    struct Geometry: Equatable, Sendable {
        let screenFrame: CGRect
        let visibleFrame: CGRect
        let taskbarTopEdge: CGFloat
        let topReservedHeight: CGFloat

        init(screenFrame: CGRect, visibleFrame: CGRect, taskbarTopEdge: CGFloat, topReservedHeight: CGFloat = 0) {
            self.screenFrame = screenFrame
            self.visibleFrame = visibleFrame
            self.taskbarTopEdge = taskbarTopEdge
            self.topReservedHeight = topReservedHeight
        }

        func coversUsableScreen(_ frame: CGRect, tolerance: CGFloat = WindowLiftAvoidance.windowFitTolerance) -> Bool {
            matchesVisibleArea(for: frame, tolerance: tolerance) { area in
                WindowLiftAvoidance.coversUsableScreen(frame, visible: area, tolerance: tolerance)
            }
        }

        func isTileAtScreenBottom(_ frame: CGRect, tolerance: CGFloat = WindowLiftAvoidance.windowFitTolerance) -> Bool {
            matchesVisibleArea(for: frame, tolerance: tolerance) { area in
                let minimumWidth = area.width * WindowLiftAvoidance.minimumTiledWidthRatio - tolerance
                let minimumHeight = area.height * WindowLiftAvoidance.minimumTiledHeightRatio
                guard frame.width >= minimumWidth, frame.height >= minimumHeight,
                      edgesMatch(frame.minY, area.minY, tolerance),
                      frame.maxY <= area.maxY + tolerance else { return false }

                return edgesMatch(frame.maxY, area.maxY, tolerance)
                    || edgesMatch(frame.minX, area.minX, tolerance)
                    || edgesMatch(frame.maxX, area.maxX, tolerance)
            }
        }

        func canClearTaskbar(_ frame: CGRect, includesTiles: Bool) -> Bool {
            coversUsableScreen(frame) || (includesTiles && isTileAtScreenBottom(frame))
        }

        func desiredClearanceFrame(for frame: CGRect, includesTiles: Bool,
                             taskbarClearanceInset: CGFloat = WindowLiftAvoidance.taskbarClearanceInset) -> CGRect? {
            guard canClearTaskbar(frame, includesTiles: includesTiles) else { return nil }
            return frameClearingTaskbar(frame, taskbarClearanceInset: taskbarClearanceInset)
        }

        func taskbarClearanceFrame(for maximizedFrame: CGRect, taskbarClearanceInset: CGFloat = WindowLiftAvoidance.taskbarClearanceInset) -> CGRect? {
            guard coversUsableScreen(maximizedFrame) else { return nil }
            return frameClearingTaskbar(maximizedFrame, taskbarClearanceInset: taskbarClearanceInset)
        }

        func taskbarClearanceFrame(forMaximizedReturn frame: CGRect, from unadjustedWindowFrame: CGRect) -> CGRect? {
            let tolerance = WindowLiftAvoidance.frameVerificationTolerance
            guard frame.maxY != unadjustedWindowFrame.maxY, coversUsableScreen(unadjustedWindowFrame),
                  edgesMatch(frame.minX, unadjustedWindowFrame.minX, tolerance),
                  edgesMatch(frame.maxX, unadjustedWindowFrame.maxX, tolerance),
                  edgesMatch(frame.width, unadjustedWindowFrame.width, tolerance),
                  edgesMatch(frame.minY, unadjustedWindowFrame.minY, tolerance) else { return nil }
            return taskbarClearanceFrame(for: frame)
        }

        func permitsLiftAfterFrameChange(_ frame: CGRect, suppressedNative: CGRect,
                                            userEra: Bool, includesTiles: Bool) -> Bool {
            guard includesTiles, userEra, canClearTaskbar(frame, includesTiles: true) else { return false }
            return !coversUsableScreen(suppressedNative) || !coversUsableScreen(frame)
        }

        private func matchesVisibleArea(for frame: CGRect, tolerance: CGFloat, _ matches: (CGRect) -> Bool) -> Bool {
            guard belongsMostlyToDisplay(frame), isValid(frame: visibleFrame),
                  validTolerance(tolerance) else { return false }
            if matches(visibleFrame) { return true }
            guard let menuVisibleFrame else { return false }
            return matches(menuVisibleFrame)
        }

        private var menuVisibleFrame: CGRect? {
            guard topReservedHeight.isFinite, topReservedHeight > 0,
                  topReservedHeight < screenFrame.height else { return nil }
            let top = min(visibleFrame.maxY, screenFrame.maxY - topReservedHeight)
            guard top > visibleFrame.minY else { return nil }
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width, height: top - visibleFrame.minY)
        }

        private func frameClearingTaskbar(_ frame: CGRect, taskbarClearanceInset: CGFloat) -> CGRect? {
            guard validTolerance(taskbarClearanceInset), taskbarTopEdge.isFinite else { return nil }
            return WindowLiftAvoidance.taskbarClearanceFrame(for: frame,
                targetBottom: max(frame.minY, visibleFrame.minY, taskbarTopEdge + taskbarClearanceInset))
        }

        private func belongsMostlyToDisplay(_ frame: CGRect) -> Bool {
            guard isValid(frame: frame), isValid(frame: screenFrame) else { return false }
            let overlap = frame.intersection(screenFrame)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            return overlap.width * overlap.height >= frame.width * frame.height * 0.5
        }
    }

    struct Suppression: Equatable {
        let unadjustedWindowFrame: CGRect
        let intendedWindowFrame: CGRect
        let origin: Origin

        enum Origin: Equatable {
            case untilNative, userChange
            case applicationResponse(standoffRounds: Int, clearedAt: TimeInterval)
        }

        enum Decision: Equatable {
            case hold, restart
            case reassert(standoffRounds: Int)
        }

        func decision(for frame: CGRect, geometry: Geometry, includesTiles: Bool, at: TimeInterval) -> Decision {
            let frames = LiftFrames(native: unadjustedWindowFrame, target: intendedWindowFrame)
            let isNative = frames.classify(frame) == .native
            switch origin {
            case .untilNative:
                return isNative ? .restart : .hold
            case .userChange:
                let releases = isNative || geometry.permitsLiftAfterFrameChange(
                    frame, suppressedNative: unadjustedWindowFrame, userEra: true, includesTiles: includesTiles
                )
                return releases ? .restart : .hold
            case let .applicationResponse(rounds, clearedAt):
                if isNative {
                    return isReturnWithinResponseWindow(clearedAt: clearedAt, at: at) ? .reassert(standoffRounds: rounds) : .restart
                }
                guard geometry.canClearTaskbar(frame, includesTiles: includesTiles) else { return .hold }
                return .reassert(standoffRounds: rounds)
            }
        }

        fileprivate func awaitsApplicationResponse(at now: TimeInterval) -> Bool {
            guard case let .applicationResponse(_, clearedAt) = origin else { return false }
            return now < clearedAt + applicationResponseWindow
        }
    }

    static func measuredFramesAgree(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = frameVerificationTolerance) -> Bool {
        guard validTolerance(tolerance), isValid(frame: lhs), isValid(frame: rhs) else { return false }
        return edgesMatch(lhs.minX, rhs.minX, tolerance)
            && edgesMatch(lhs.minY, rhs.minY, tolerance)
            && edgesMatch(lhs.width, rhs.width, tolerance)
            && edgesMatch(lhs.height, rhs.height, tolerance)
    }

    static func coversUsableScreen(_ frame: CGRect, visible: CGRect, tolerance: CGFloat = windowFitTolerance) -> Bool {
        guard validTolerance(tolerance), isValid(frame: frame), isValid(frame: visible) else { return false }
        return edgesMatch(frame.minX, visible.minX, tolerance)
            && edgesMatch(frame.maxX, visible.maxX, tolerance)
            && edgesMatch(frame.minY, visible.minY, tolerance)
            && edgesMatch(frame.maxY, visible.maxY, tolerance)
    }

    static func taskbarClearanceFrame(for frame: CGRect, taskbarTopY: CGFloat, taskbarClearanceInset: CGFloat = taskbarClearanceInset) -> CGRect? {
        guard taskbarTopY.isFinite, validTolerance(taskbarClearanceInset) else { return nil }
        return taskbarClearanceFrame(for: frame, targetBottom: max(frame.minY, taskbarTopY + taskbarClearanceInset))
    }

    private static func validTolerance(_ value: CGFloat) -> Bool {
        value.isFinite && value >= 0
    }

    private static func edgesMatch(_ first: CGFloat, _ second: CGFloat, _ tolerance: CGFloat) -> Bool {
        abs(first - second) <= tolerance
    }

    enum FrameClassification: Equatable {
        case target, native, managedTrajectory, external
    }

    static func classifyObservedLiftFrame(of frame: CGRect, unadjustedWindowFrame: CGRect, intendedWindowFrame: CGRect,
                                    tolerance: CGFloat = frameVerificationTolerance) -> FrameClassification {
        guard validTolerance(tolerance), isValid(frame: frame), isValid(frame: unadjustedWindowFrame),
              isValid(frame: intendedWindowFrame) else { return .external }
        if measuredFramesAgree(frame, intendedWindowFrame, tolerance: tolerance) { return .target }
        if measuredFramesAgree(frame, unadjustedWindowFrame, tolerance: tolerance) { return .native }

        let lowerBottom = min(unadjustedWindowFrame.minY, intendedWindowFrame.minY)
        let upperBottom = max(unadjustedWindowFrame.minY, intendedWindowFrame.minY)
        guard (lowerBottom...upperBottom).contains(frame.minY),
              edgesMatch(frame.minX, unadjustedWindowFrame.minX, tolerance),
              edgesMatch(frame.width, unadjustedWindowFrame.width, tolerance),
              edgesMatch(frame.maxY, unadjustedWindowFrame.maxY, tolerance) else { return .external }
        return .managedTrajectory
    }

    static func geometrySamplesAgree(_ sample: CGRect, comparedTo reference: CGRect,
                                 tolerance: CGFloat = frameVerificationTolerance) -> Bool {
        measuredFramesAgree(sample, reference, tolerance: tolerance)
    }

    static func geometrySamplesAgree(initialCGFrame: CGRect, confirmedCGFrame: CGRect, confirmedAXFrame: CGRect,
                                 tolerance: CGFloat = frameVerificationTolerance) -> Bool {
        guard measuredFramesAgree(initialCGFrame, confirmedCGFrame, tolerance: tolerance) else { return false }
        return measuredFramesAgree(initialCGFrame, confirmedAXFrame, tolerance: tolerance)
            && measuredFramesAgree(confirmedCGFrame, confirmedAXFrame, tolerance: tolerance)
    }

    struct PollSchedule: Equatable {
        let pollDeadlines: [TimeInterval]
        static let standard = PollSchedule(pollDeadlines: [0, 0.1, 0.25])

        var delaysBetweenPolls: [TimeInterval] {
            pollDeadlines.indices.map { index in
                let previous = index > 0 ? pollDeadlines[index - 1] : 0
                return max(0, pollDeadlines[index] - previous)
            }
        }

        func delayUntilPoll(for index: Int, elapsed: TimeInterval) -> TimeInterval? {
            guard elapsed.isFinite, pollDeadlines.indices.contains(index) else { return nil }
            return max(0, pollDeadlines[index] - max(0, elapsed))
        }
    }

    enum Event: Equatable {
        case maximizedDetected(generation: UInt64, at: TimeInterval, nativeFrame: CGRect, targetFrame: CGRect)
        case nonMaximizedObserved(generation: UInt64, at: TimeInterval, frame: CGRect)
        case windowUnavailable(generation: UInt64)
        case detourReturnObserved(generation: UInt64, at: TimeInterval, nativeFrame: CGRect,
                                 targetFrame: CGRect, standoffRounds: Int)
        case writeFinished(generation: UInt64, at: TimeInterval, actualFrame: CGRect, reliftCount: Int)
        case writeFailed(generation: UInt64, at: TimeInterval, reliftCount: Int)
        case reliftLimitReached(generation: UInt64, at: TimeInterval, reliftCount: Int)
    }

    static func reduce(state: SessionState, event: Event) -> Transition {
        switch event {
        case let .maximizedDetected(generation, at, native, target):
            guard let frames = LiftFrames(validating: native, target: target) else { return .keeping(state) }
            return acceptMaximized(frames, for: state, generation: generation, at: at)
        case let .nonMaximizedObserved(generation, at, frame):
            return acceptObservation(frame, for: state, generation: generation, at: at)
        case let .windowUnavailable(generation):
            guard let latest = state.latestGeneration, generation >= latest else { return .keeping(state) }
            return .cleared
        case let .detourReturnObserved(generation, at, native, target, previousRounds):
            guard case .idle = state, previousRounds >= 0,
                  let frames = LiftFrames(validating: native, target: target) else { return .keeping(state) }
            let rounds = min(previousRounds + 1, maxResponseRounds)
            if rounds < maxResponseRounds { return frames.start(generation: generation, rounds: rounds) }
            return frames.abandon(generation: generation, at: at, relifts: maxLiftRetries,
                                  rounds: rounds, reason: .reliftLimitReached)
        case let .writeFinished(generation, at, actualFrame, relifts):
            guard let attempt = state.attempt(for: generation) else { return .keeping(state) }
            return attempt.complete(with: actualFrame, at: at, relifts: relifts)
        case let .writeFailed(generation, at, relifts):
            guard let attempt = state.attempt(for: generation) else { return .keeping(state) }
            return attempt.fail(at: at, relifts: relifts, reason: .writeFailed)
        case let .reliftLimitReached(generation, at, relifts):
            guard let attempt = state.attempt(for: generation) else { return .keeping(state) }
            return attempt.fail(at: at, relifts: relifts, reason: .reliftLimitReached)
        }
    }

    private static func acceptMaximized(_ frames: LiftFrames, for state: SessionState,
                                        generation: UInt64, at time: TimeInterval) -> Transition {
        switch state {
        case .idle:
            return frames.start(generation: generation)
        case let .writing(attempt):
            guard generation > attempt.newestObservedGeneration else { return .keeping(state) }
            return attempt.observing(generation)
        case let .lifted(session):
            guard generation > session.generation else { return .keeping(state) }
            return session.reasserting(frames, generation: generation, at: time)
        case let .abandoned(session):
            guard generation >= session.generation else { return .keeping(state) }
            return session.observing(frames, generation: generation, at: time, mayRetry: true)
        }
    }

    private static func acceptObservation(_ frame: CGRect, for state: SessionState,
                                          generation: UInt64, at time: TimeInterval) -> Transition {
        guard isValid(frame: frame), let latest = state.latestGeneration,
              generation >= latest else { return .keeping(state) }
        switch state {
        case .idle:
            return .keeping(state)
        case let .writing(attempt):
            if attempt.frames.classify(frame) == .external { return .cleared }
            return attempt.observing(generation)
        case let .lifted(session):
            let frames = session.frames
            switch frames.classify(frame) {
            case .external:
                return .cleared
            case .native:
                guard generation > session.generation else { return .keeping(state) }
                return session.reasserting(frames, generation: generation, at: time)
            case .target, .managedTrajectory:
                return session.observing(generation, at: time)
            }
        case let .abandoned(session):
            let frames = session.frames
            let classification = frames.classify(frame)
            if classification == .external { return .cleared }
            return session.observing(frames, generation: generation, at: time, mayRetry: classification == .native)
        }
    }

    enum SessionState: Equatable {
        case idle
        case writing(WriteAttempt)
        case lifted(LiftedSession)
        case abandoned(AbandonedSession)

        fileprivate var latestGeneration: UInt64? {
            switch self {
            case .idle: return nil
            case let .writing(attempt): return attempt.newestObservedGeneration
            case let .lifted(session): return session.generation
            case let .abandoned(session): return session.generation
            }
        }

        fileprivate var responseStart: TimeInterval? {
            switch self {
            case let .lifted(session): return session.liftSettledAt
            case let .abandoned(session): return session.liftAbandonedAt
            case .idle, .writing: return nil
            }
        }

        fileprivate func attempt(for generation: UInt64) -> WriteAttempt? {
            guard case let .writing(attempt) = self, attempt.generation == generation else { return nil }
            return attempt
        }
    }

    struct Transition: Equatable {
        let state: SessionState
        let action: Action

        static func keeping(_ state: SessionState) -> Self {
            Self(state: state, action: .none)
        }

        static var cleared: Self { Self(state: .idle, action: .clear) }
    }

    enum Action: Equatable {
        case none
        case clear
        case abandon(AbandonReason)
        case write(targetFrame: CGRect, rollbackFrame: CGRect, generation: UInt64, isRelift: Bool)
    }

    struct WriteAttempt: Equatable {
        let generation: UInt64
        let newestObservedGeneration: UInt64
        let unadjustedWindowFrame: CGRect
        let intendedWindowFrame: CGRect
        let liftRetryCount: Int
        let applicationResponseRounds: Int

        var isRepeatedLift: Bool { liftRetryCount > 0 }

        fileprivate var frames: LiftFrames { LiftFrames(native: unadjustedWindowFrame, target: intendedWindowFrame) }

        fileprivate func observing(_ generation: UInt64) -> Transition {
            .keeping(.writing(Self(generation: self.generation,
                newestObservedGeneration: max(generation, newestObservedGeneration),
                unadjustedWindowFrame: unadjustedWindowFrame, intendedWindowFrame: intendedWindowFrame, liftRetryCount: liftRetryCount,
                applicationResponseRounds: applicationResponseRounds)))
        }

        fileprivate func complete(with actualFrame: CGRect, at time: TimeInterval, relifts: Int) -> Transition {
            guard relifts >= liftRetryCount, relifts <= maxLiftRetries,
                  measuredFramesAgree(actualFrame, intendedWindowFrame) else {
                return fail(at: time, relifts: relifts, reason: .writeFailed)
            }
            return .keeping(.lifted(LiftedSession(generation: max(generation, newestObservedGeneration),
                unadjustedWindowFrame: unadjustedWindowFrame, taskbarClearanceFrame: intendedWindowFrame, liftRetryCount: relifts,
                liftSettledAt: time, applicationResponseRounds: applicationResponseRounds)))
        }

        fileprivate func fail(at time: TimeInterval, relifts: Int, reason: AbandonReason) -> Transition {
            frames.abandon(generation: max(generation, newestObservedGeneration), at: time,
                           relifts: max(liftRetryCount, relifts), rounds: applicationResponseRounds, reason: reason)
        }
    }

    struct LiftedSession: Equatable {
        let generation: UInt64
        let unadjustedWindowFrame: CGRect
        let taskbarClearanceFrame: CGRect
        let liftRetryCount: Int
        let liftSettledAt: TimeInterval
        let applicationResponseRounds: Int

        fileprivate var frames: LiftFrames { LiftFrames(native: unadjustedWindowFrame, target: taskbarClearanceFrame) }

        fileprivate func reasserting(_ frames: LiftFrames, generation: UInt64, at time: TimeInterval) -> Transition {
            guard time - liftSettledAt <= applicationResponseWindow else { return frames.start(generation: generation) }
            if liftRetryCount < maxLiftRetries {
                return frames.start(generation: generation, relifts: liftRetryCount + 1, rounds: applicationResponseRounds)
            }
            return frames.abandon(generation: generation, at: time, relifts: liftRetryCount,
                                  rounds: applicationResponseRounds, reason: .reliftLimitReached)
        }

        fileprivate func observing(_ generation: UInt64, at time: TimeInterval) -> Transition {
            let rounds = time - liftSettledAt > applicationResponseWindow ? 0 : applicationResponseRounds
            return .keeping(.lifted(Self(generation: generation, unadjustedWindowFrame: unadjustedWindowFrame, taskbarClearanceFrame: taskbarClearanceFrame,
                                        liftRetryCount: liftRetryCount, liftSettledAt: liftSettledAt, applicationResponseRounds: rounds)))
        }
    }

    struct AbandonedSession: Equatable {
        let generation: UInt64
        let unadjustedWindowFrame: CGRect
        let taskbarClearanceFrame: CGRect
        let liftRetryCount: Int
        let reason: AbandonReason
        let liftAbandonedAt: TimeInterval
        let applicationResponseRounds: Int

        fileprivate var frames: LiftFrames { LiftFrames(native: unadjustedWindowFrame, target: taskbarClearanceFrame) }

        fileprivate func observing(_ frames: LiftFrames, generation: UInt64, at time: TimeInterval,
                                    mayRetry: Bool) -> Transition {
            if mayRetry, applicationResponseRounds < maxResponseRounds, time - liftAbandonedAt > applicationResponseWindow {
                return frames.start(generation: generation, rounds: min(applicationResponseRounds + 1, maxResponseRounds))
            }
            return .keeping(.abandoned(Self(generation: generation, unadjustedWindowFrame: frames.native,
                taskbarClearanceFrame: frames.target, liftRetryCount: liftRetryCount, reason: reason,
                liftAbandonedAt: liftAbandonedAt, applicationResponseRounds: applicationResponseRounds)))
        }
    }

    enum AbandonReason: Equatable {
        case reliftLimitReached
        case writeFailed
    }

    fileprivate struct LiftFrames {
        let native: CGRect
        let target: CGRect

        init(native: CGRect, target: CGRect) {
            self.native = native
            self.target = target
        }

        init?(validating native: CGRect, target: CGRect) {
            guard isValid(frame: native), isValid(frame: target) else { return nil }
            self.init(native: native, target: target)
        }

        func classify(_ frame: CGRect) -> FrameClassification {
            classifyObservedLiftFrame(of: frame, unadjustedWindowFrame: native, intendedWindowFrame: target)
        }

        func start(generation: UInt64, relifts: Int = 0, rounds: Int = 0) -> Transition {
            let attempt = WriteAttempt(generation: generation, newestObservedGeneration: generation,
                                       unadjustedWindowFrame: native, intendedWindowFrame: target, liftRetryCount: relifts,
                                       applicationResponseRounds: rounds)
            return Transition(state: .writing(attempt), action: .write(targetFrame: target, rollbackFrame: native,
                                                                        generation: generation, isRelift: attempt.isRepeatedLift))
        }

        func abandon(generation: UInt64, at time: TimeInterval, relifts: Int, rounds: Int,
                     reason: AbandonReason) -> Transition {
            let session = AbandonedSession(generation: generation, unadjustedWindowFrame: native, taskbarClearanceFrame: target,
                                           liftRetryCount: relifts, reason: reason, liftAbandonedAt: time,
                                           applicationResponseRounds: rounds)
            return Transition(state: .abandoned(session), action: .abandon(reason))
        }
    }

    static func isReturnWithinResponseWindow(clearedAt: TimeInterval, at: TimeInterval) -> Bool {
        at - clearedAt <= applicationResponseWindow
    }

    static func isAfterApplicationResponse(state: SessionState, at: TimeInterval) -> Bool {
        guard let responseStart = state.responseStart else { return false }
        return at - responseStart > applicationResponseWindow
    }

    static func qualifiesForLiftProbe(quartzFrame: CGRect, isTracked: Bool, context: WindowLiftAvoidanceContext,
                                includesTiles: Bool) -> Bool {
        if quartzFrame.width > context.displayWindowServerFrame.width * 0.7 { return true }
        guard includesTiles else { return false }
        return isTracked || context.geometry.isTileAtScreenBottom(
            appKitCoordinates(fromQuartz: quartzFrame, primaryDisplayHeight: context.primaryDisplayHeight)
        )
    }

    static func interpolatedLiftFrame(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let amount = CGFloat(cubicLiftProgress(progress))
        func interpolateCoordinate(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            from + (to - from) * amount
        }
        let origin = CGPoint(x: interpolateCoordinate(start.minX, end.minX), y: interpolateCoordinate(start.minY, end.minY))
        let size = CGSize(width: interpolateCoordinate(start.width, end.width), height: interpolateCoordinate(start.height, end.height))
        return CGRect(origin: origin, size: size)
    }

    static func cubicLiftProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let value = unitProgress(progress)
        if value < 0.5 { return 4 * value * value * value }
        let remainder = -2 * value + 2
        return 1 - remainder * remainder * remainder / 2
    }

    static func segmentLiftProgress(_ overallProgress: Double, startingAt segmentStart: Double) -> Double {
        guard overallProgress.isFinite, segmentStart.isFinite else { return 0 }
        let start = unitProgress(segmentStart)
        guard start < 1 else { return 1 }
        return unitProgress((unitProgress(overallProgress) - start) / (1 - start))
    }

    private static func unitProgress(_ progress: Double) -> Double {
        min(1, max(0, progress))
    }

    static func rollbackFrameAction(originalFrame: CGRect, attemptedFrame: CGRect,
                                 currentFrame: CGRect?) -> RollbackDecision {
        guard let current = currentFrame else { return .preserveCurrent }
        if measuredFramesAgree(current, originalFrame) { return .notNeeded }
        return measuredFramesAgree(current, attemptedFrame) ? .restore(originalFrame) : .preserveCurrent
    }

    enum RollbackDecision: Equatable {
        case notNeeded, preserveCurrent
        case restore(CGRect)
    }

    enum AnimationWriteFailure: Equatable {
        case initialFrameMismatch(actualFrame: CGRect)
        case terminalWriteFailure
    }

    static func animationRecoveryAction(_ failure: AnimationWriteFailure, unadjustedWindowFrame: CGRect,
                                              intendedWindowFrame: CGRect, liftRetryCount: Int,
                                              lastAcknowledgedFrame: CGRect? = nil) -> AnimationWriteFailureDecision {
        guard liftRetryCount >= 0, case let .initialFrameMismatch(actual) = failure,
              isValid(frame: actual), let frames = LiftFrames(validating: unadjustedWindowFrame, target: intendedWindowFrame) else {
            return .abandonWriteFailed
        }

        let classification = frames.classify(actual)
        if classification == .target { return .complete(actualFrame: actual) }
        if let lastAcknowledgedFrame, measuredFramesAgree(actual, lastAcknowledgedFrame) {
            return .continueFromActual(actualFrame: actual)
        }

        switch classification {
        case .target:
            return .complete(actualFrame: actual)
        case .managedTrajectory:
            return .continueFromActual(actualFrame: actual)
        case .external:
            return .clearSession(preservingFrame: actual)
        case .native:
            if liftRetryCount < maxLiftRetries {
                return .restartFromNative(nativeFrame: actual, nextReliftCount: liftRetryCount + 1)
            }
            return .reliftLimitReached(actualFrame: actual, reliftCount: liftRetryCount)
        }
    }

    enum AnimationWriteFailureDecision: Equatable {
        case complete(actualFrame: CGRect)
        case continueFromActual(actualFrame: CGRect)
        case clearSession(preservingFrame: CGRect)
        case restartFromNative(nativeFrame: CGRect, nextReliftCount: Int)
        case reliftLimitReached(actualFrame: CGRect, reliftCount: Int)
        case abandonWriteFailed
    }

    static func obsoleteSessionKeys(tracked: Set<WindowKey>, live: Set<WindowKey>, observationGeneration: UInt64,
                                      observationWatermarks: [WindowKey: UInt64]) -> Set<WindowKey> {
        missingSessionKeys(tracked: tracked, live: live).filter { key in
            observationGeneration > observationWatermarks[key, default: 0]
        }
    }

    static func missingSessionKeys(tracked: Set<WindowKey>, live: Set<WindowKey>) -> Set<WindowKey> {
        tracked.subtracting(live)
    }

    static func windowServerFrame(fromAppKit frame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        flippedFrame(frame, screenHeight: primaryDisplayHeight)
    }

    static func appKitCoordinates(fromQuartz frame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        flippedFrame(frame, screenHeight: primaryDisplayHeight)
    }

    private static func flippedFrame(_ frame: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func taskbarClearanceFrame(for frame: CGRect, targetBottom: CGFloat) -> CGRect? {
        guard isValid(frame: frame), targetBottom.isFinite else { return nil }
        guard targetBottom > frame.minY + frameVerificationTolerance,
              targetBottom < frame.maxY - frameVerificationTolerance else { return nil }
        return CGRect(x: frame.minX, y: targetBottom, width: frame.width, height: frame.maxY - targetBottom)
    }

    static func displayContextIndex(for quartzFrame: CGRect, screenCGFrames: [CGRect]) -> Int? {
        WindowDisplayAttribution.owningDisplayIndex(for: quartzFrame, screenCGFrames: screenCGFrames)
    }

    private static func isValid(frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
    }

}

#if DEBUG
extension WindowLiftAvoidance.AbandonReason {
    var diagnosticDescription: String {
        switch self {
        case .reliftLimitReached: return "reliftLimitReached"
        case .writeFailed: return "writeFailed"
        }
    }
}

extension WindowLiftAvoidance.AnimationWriteFailureDecision {
    var diagnosticDescription: String {
        switch self {
        case .complete: return "complete"
        case .continueFromActual: return "continueFromActual"
        case .clearSession: return "clearSession"
        case .restartFromNative: return "restartFromNative"
        case .reliftLimitReached: return "reliftLimitReached"
        case .abandonWriteFailed: return "abandonWriteFailed"
        }
    }
}
#endif
