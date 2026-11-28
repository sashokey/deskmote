import AppKit
import ApplicationServices
import Foundation
import Synchronization

struct WindowAdjustmentDisplay: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let panelFrame: CGRect?
    var displayUUID: String? = nil
}

struct HeightWriteKey: Hashable, Sendable {
    let pid: pid_t
    let generation: ProcessGeneration
    let windowID: CGWindowID
}

enum HeightWriteAction: Equatable, Sendable {
    case size(CGSize)
    case position(CGPoint)
}

struct WindowHeightScanRow: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let layer: Int?
    let bounds: CGRect?
}

struct WindowHeightFallbackContext: Sendable {
    let epoch: UInt64
    var displays: [WindowAdjustmentDisplay]
    var desktopIDs: [String: Int]
}

struct HeightFallbackProof: Sendable {
    let key: HeightWriteKey
    let element: AXElementKey
    let context: WindowHeightFallbackContext
}

struct HeightFallbackMembership: Sendable {
    let confirmed: Bool?
    var revision: UInt64? = nil

    func permits(using readNative: () -> Bool?) -> Bool {
        (confirmed ?? readNative()) == true
    }

    func stillPermits(_ latest: Self) -> Bool {
        revision == latest.revision && latest.confirmed != false && (confirmed != true || latest.confirmed == true)
    }
}

enum HeightFallbackResolution: Sendable {
    case ready(HeightFallbackProof)
    case excluded
    case unknown
}

extension WindowHeightFallbackContext {
    func display(for frame: CGRect) -> WindowAdjustmentDisplay? {
        guard let index = WindowDisplayAttribution.owningDisplayIndex(for: frame, screenCGFrames: displays.lazy.map(\.frame))
        else { return nil }
        return displays[index]
    }

    func permits(_ display: WindowAdjustmentDisplay) -> Bool {
        guard let uuid = display.displayUUID else { return false }
        return display.panelFrame != nil && desktopIDs[uuid] != nil
    }
}

private func pollAdjustment(for frame: CGRect, on display: WindowAdjustmentDisplay) -> HeightWriteAction? {
    guard let panel = display.panelFrame, panel.height.isFinite, panel.height > 0,
          frame.minY.isFinite, frame.maxY.isFinite, frame.height > 0,
          frame.maxY > panel.minY else { return nil }
    let top = display.visibleFrame.minY
    guard top.isFinite, panel.minY.isFinite, panel.minY > top else { return nil }
    if frame.minY == top, frame.width.isFinite, frame.width > 0 {
        return .size(CGSize(width: frame.width, height: panel.minY - top))
    }
    if frame.minY == top + panel.height, frame.minX.isFinite {
        return .position(CGPoint(x: frame.minX, y: top))
    }
    return nil
}

final class WindowHeightFallback: Sendable {
    typealias Schedule = @Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> @Sendable () -> Void

    private struct Key: Hashable, Sendable {
        let id: CGWindowID
        let pid: pid_t

        init(_ row: WindowHeightScanRow) {
            id = row.windowID
            pid = row.pid
        }
    }

    private struct Candidate: Sendable {
        let row: WindowHeightScanRow
        let display: WindowAdjustmentDisplay
        let continuity: UInt64
    }

    private struct Snapshot: Sendable {
        let id: UInt64
        let context: WindowHeightFallbackContext
        let candidates: [Key: Candidate]
        let order: [Key]
    }

    private struct Work: Sendable {
        let run: UInt64
        let key: Key
        let candidate: Candidate
        let context: WindowHeightFallbackContext
    }

    private struct State {
        var run: UInt64 = 0
        var tick: UInt64 = 0
        var running = false
        var draining = false
        var cancel: (@Sendable () -> Void)?
        var snapshot: Snapshot?
        var pass: UInt64?
        var consumed: Set<Key> = []
        var cursor: (key: Key, continuity: UInt64)?

        mutating func discard() {
            snapshot = nil
            pass = nil
            cursor = nil
            consumed.removeAll(keepingCapacity: true)
        }

        func accepts(_ work: Work) -> Bool {
            running && run == work.run && snapshot?.candidates[work.key]?.continuity == work.candidate.continuity
        }

        mutating func adopt(_ snapshot: Snapshot) {
            if pass != snapshot.id {
                pass = snapshot.id
                consumed.removeAll(keepingCapacity: true)
            }
        }

        mutating func next() -> Work? {
            guard running, let snapshot, !snapshot.order.isEmpty else {
                draining = false
                return nil
            }
            adopt(snapshot)
            let order = snapshot.order
            let start: Int
            if let cursor, snapshot.candidates[cursor.key]?.continuity == cursor.continuity,
               let offset = order.firstIndex(of: cursor.key) {
                start = (offset + 1) % order.count
            } else {
                start = 0
            }
            for count in order.indices {
                let key = order[(start + count) % order.count]
                guard let candidate = snapshot.candidates[key], consumed.insert(key).inserted else { continue }
                return Work(run: run, key: key, candidate: candidate, context: snapshot.context)
            }
            draining = false
            return nil
        }

        mutating func finish(_ work: Work) {
            guard accepts(work) else { return }
            cursor = (work.key, work.candidate.continuity)
        }
    }


    private let readFrame: @Sendable (AXElementKey) -> CGRect?
    private let write: @Sendable (HeightWriteAction, AXElementKey) -> AXError
    private let capture: @Sendable () -> [WindowHeightScanRow]?
    private let context: @Sendable () -> WindowHeightFallbackContext?
    private let resolve: @Sendable (WindowHeightScanRow, WindowHeightFallbackContext) -> HeightFallbackResolution
    private let isCurrent: @Sendable (HeightFallbackProof) -> Bool
    private let isCurrentPosition: @Sendable (HeightFallbackProof) -> Bool
    private let membership: @Sendable (HeightFallbackProof, String, Int) -> HeightFallbackMembership
    private let readNativeDesktop: @Sendable (HeightFallbackProof, Int) -> Bool?
    private let schedule: Schedule
    private let state = Mutex(State())
    private let scans = DispatchQueue(label: "io.github.sashokey.deskmote.height-fallback.scan", qos: .utility)
    private let checks = DispatchQueue(label: "io.github.sashokey.deskmote.height-fallback.ax", qos: .utility)

    init(readFrame: @escaping @Sendable (AXElementKey) -> CGRect?,
         write: @escaping @Sendable (HeightWriteAction, AXElementKey) -> AXError,
         capture: @escaping @Sendable () -> [WindowHeightScanRow]?,
         context: @escaping @Sendable () -> WindowHeightFallbackContext?,
         resolve: @escaping @Sendable (WindowHeightScanRow, WindowHeightFallbackContext) -> HeightFallbackResolution,
         isCurrent: @escaping @Sendable (HeightFallbackProof) -> Bool,
         isCurrentPosition: @escaping @Sendable (HeightFallbackProof) -> Bool,
         membership: @escaping @Sendable (HeightFallbackProof, String, Int) -> HeightFallbackMembership,
         readNativeDesktop: @escaping @Sendable (HeightFallbackProof, Int) -> Bool?,
         schedule: @escaping Schedule = WindowHeightFallback.scheduleTicks) {
        self.readFrame = readFrame
        self.write = write
        self.capture = capture
        self.context = context
        self.resolve = resolve
        self.isCurrent = isCurrent
        self.isCurrentPosition = isCurrentPosition
        self.membership = membership
        self.readNativeDesktop = readNativeDesktop
        self.schedule = schedule
    }

    private static func scheduleTicks(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(100)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.resume()
        return { timer.cancel() }
    }

    func start() {
        let run = state.withLock { state -> UInt64? in
            guard !state.running else { return nil }
            state.run &+= 1
            state.running = true
            state.tick = 0
            state.discard()
            return state.run
        }
        guard let run else { return }
        let cancel = schedule(scans) { [weak self] in self?.scan(run: run) }
        let installed = state.withLock { state in
            guard state.running, state.run == run else { return false }
            state.cancel = cancel
            return true
        }
        if !installed { cancel() }
    }

    func stop() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.running = false
            state.discard()
            defer { state.cancel = nil }
            return state.cancel
        }
        cancel?()
    }

    private func scan(run: UInt64) {
        let tick = state.withLock { state -> UInt64? in
            guard state.running, state.run == run else { return nil }
            state.tick &+= 1
            return state.tick
        }
        guard let tick else { return }
        guard let current = context(), current.displays.contains(where: current.permits),
              let rows = capture() else {
            state.withLock { if $0.run == run { $0.discard() } }
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let matching = rows.compactMap { row -> (WindowHeightScanRow, WindowAdjustmentDisplay)? in
            guard row.windowID != 0, row.pid != 0, row.pid != ownPID, (row.layer ?? 0) >= 0,
                  let frame = row.bounds, let display = current.display(for: frame),
                  current.permits(display), pollAdjustment(for: frame, on: display) != nil else { return nil }
            return (row, display)
        }
        let scheduleDrain = state.withLock { state in
            guard state.running, state.run == run else { return false }
            let previous = state.snapshot.flatMap { snapshot in
                snapshot.context.epoch == current.epoch && snapshot.context.desktopIDs == current.desktopIDs
                    ? snapshot.candidates : nil
            }
            var candidates: [Key: Candidate] = [:]
            var order: [Key] = []
            for (row, display) in matching {
                let key = Key(row)
                guard candidates[key] == nil else { continue }
                let old = previous?[key]
                let continuity = old?.display == display ? old?.continuity ?? tick : tick
                candidates[key] = Candidate(row: row, display: display, continuity: continuity)
                order.append(key)
            }
            state.snapshot = Snapshot(id: tick, context: current, candidates: candidates, order: order)
            guard !state.draining, !order.isEmpty else { return false }
            state.draining = true
            return true
        }
        if scheduleDrain { checks.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while let work = state.withLock({ $0.next() }) {
            adjust(work)
            state.withLock { $0.finish(work) }
        }
    }

    private func adjust(_ work: Work) {
        let display = work.candidate.display
        guard let uuid = display.displayUUID, let desktop = work.context.desktopIDs[uuid],
              state.withLock({ $0.accepts(work) }),
              case let .ready(proof) = resolve(work.candidate.row, work.context),
              state.withLock({ $0.accepts(work) }), isCurrentPosition(proof) else { return }
        let admitted = membership(proof, uuid, desktop)
        guard admitted.permits(using: { readNativeDesktop(proof, desktop) }),
              let frame = readFrame(proof.element),
              let current = context(), current.epoch == work.context.epoch,
              current.desktopIDs[uuid] == desktop, current.display(for: frame) == display,
              let action = pollAdjustment(for: frame, on: display), isCurrent(proof),
              let latest = context(), latest.epoch == current.epoch,
              latest.desktopIDs[uuid] == desktop, latest.display(for: frame) == display,
              admitted.stillPermits(membership(proof, uuid, desktop)),
              state.withLock({ $0.accepts(work) }) else { return }
        let result = write(action, proof.element)
        _ = result
    }

    #if DESKMOTE_TEST
    func drainForTesting() async {
        await withCheckedContinuation { continuation in
            scans.async { [checks] in checks.async { continuation.resume() } }
        }
    }
    #endif
}

enum HeightFallbackInventory: Sendable {
    case unknown
    case excluded
    case unavailable
    case ordinary(WindowSpaceIdentity, AXElementKey)

    static func classify(_ key: HeightWriteKey, in records: some Sequence<WindowRecord>) -> Self {
        var match: WindowRecord?
        for record in records where record.cgWindowID == key.windowID && record.pid == key.pid &&
            record.processGeneration == key.generation {
            guard match == nil else { return .unavailable }
            match = record
        }
        guard let record = match else { return .unknown }
        guard record.source == .external, !ApplicationIdentity.isDeskMote(record.bundleIdentifier) else { return .excluded }
        guard record.isOnDesktop, record.status == .active || record.status == .inactive,
              let target = record.actionTarget, let identity = WindowSpaceIdentity(record.actionIdentity)
        else { return .unavailable }
        return .ordinary(identity, target.element)
    }
}

struct NativeHeightFallbackResolver: Sendable {
    let accessibility: any AccessibilityOperations
    let system: any WindowSystemAccess
    let inventory: @Sendable (HeightWriteKey) -> HeightFallbackInventory
    let confirmedDesktop: @Sendable (HeightWriteKey, AXElementKey, String, Int) -> HeightFallbackMembership
    let spaceIDs: @Sendable (Int) -> [Int]?

    init(accessibility: any AccessibilityOperations, system: any WindowSystemAccess,
         inventory: @escaping @Sendable (HeightWriteKey) -> HeightFallbackInventory,
         confirmedDesktop: @escaping @Sendable (HeightWriteKey, AXElementKey, String, Int) -> HeightFallbackMembership,
         spaceIDs: @escaping @Sendable (Int) -> [Int]? = { WindowSpaceMembershipReader.spaceIDs(forWindowNumber: $0) }) {
        self.accessibility = accessibility
        self.system = system
        self.inventory = inventory
        self.confirmedDesktop = confirmedDesktop
        self.spaceIDs = spaceIDs
    }

    func resolve(_ row: WindowHeightScanRow, context: WindowHeightFallbackContext) -> HeightFallbackResolution {
        guard let app = system.app(row.pid), !app.isTerminated else { return .unknown }
        guard !app.isHidden, !ApplicationIdentity.isDeskMote(app.bundleIdentifier) else { return .excluded }
        guard let generation = system.generation(row.pid) else { return .unknown }
        let key = HeightWriteKey(pid: row.pid, generation: generation, windowID: row.windowID)
        let element: AXElementKey
        switch inventory(key) {
        case .excluded:
            return .excluded
        case .ordinary(_, let existing) where matches(existing, key: key):
            element = existing
        case .ordinary, .unknown, .unavailable:
            guard let parent = NativeWindowParentReader.parents(for: [row.windowID])[row.windowID] else { return .unknown }
            guard parent == 0 else { return .excluded }
            let reader = AXWindowReader(accessibility: accessibility)
            guard let handle = reader.captureHandle(forPID: row.pid, cgWindowID: row.windowID) else { return .unknown }
            let (roleStatus, role) = accessibility.copy(handle.element, kAXRoleAttribute as CFString)
            guard roleStatus == .success, let role = role as? String else { return .unknown }
            guard role == kAXWindowRole as String else { return .excluded }
            let (subroleStatus, subrole) = accessibility.copy(handle.element, kAXSubroleAttribute as CFString)
            guard subroleStatus == .success || subroleStatus == .noValue || subroleStatus == .attributeUnsupported
            else { return .unknown }
            if subrole as? String == kAXDialogSubrole as String { return .excluded }
            element = AXElementKey(e: handle.element)
        }
        return .ready(HeightFallbackProof(key: key, element: element, context: context))
    }

    private func matches(_ element: AXElementKey, key: HeightWriteKey) -> Bool {
        guard accessibility.pid(element.e) == key.pid else { return false }
        if let id = accessibility.windowID(element.e) { return id == key.windowID }
        return AXWindowReader(accessibility: accessibility).captureHandle(
            forPID: key.pid, cgWindowID: key.windowID, expectedElement: element) != nil
    }

    func isCurrent(_ proof: HeightFallbackProof) -> Bool {
        let key = proof.key
        guard let app = system.app(key.pid), !app.isHidden, !app.isTerminated,
              system.generation(key.pid) == key.generation else { return false }
        return isCurrentPosition(proof) && matches(proof.element, key: key)
    }

    func isCurrentPosition(_ proof: HeightFallbackProof) -> Bool {
        switch inventory(proof.key) {
        case .ordinary(_, let element): element == proof.element
        case .excluded, .unavailable: false
        case .unknown: true
        }
    }

    func membership(_ proof: HeightFallbackProof, display: String, desktop: Int) -> HeightFallbackMembership {
        confirmedDesktop(proof.key, proof.element, display, desktop)
    }

    func readNativeDesktop(_ proof: HeightFallbackProof, desktop: Int) -> Bool? {
        spaceIDs(Int(proof.key.windowID))?.contains(desktop)
    }
}
