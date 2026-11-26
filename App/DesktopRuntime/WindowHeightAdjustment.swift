import CoreGraphics
import Foundation
import Synchronization
#if DEBUG
import os
#endif

struct WindowAdjustmentDisplay: Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let panelFrame: CGRect?
}

@MainActor
final class WindowHeightAdjustment {
    private final class Binding: @unchecked Sendable {
        let window: AXElementKey
        let ownerPID: pid_t
        var firstFrame: FirstFrame?
        var observedGeometryChange = false
        var previousFrame: CGRect?
        var adjustedFrame: CGRect?
        var handledCreation = false
        var pendingCreation: Creation?
        #if DEBUG
        var pendingWriteObservation: Work?
        #endif

        init(window: AXElementKey, ownerPID: pid_t) {
            self.window = window
            self.ownerPID = ownerPID
        }
    }

    private struct Revision: Sendable {
        var binding: UInt64 = 0
        var layout: UInt64 = 0
        var geometry: UInt64 = 0

        func matches(_ other: Revision) -> Bool {
            binding == other.binding && layout == other.layout
        }
    }

    private final class Revisions: Sendable {
        let current = Mutex(Revision())

        func ifCurrent(_ expected: Revision, _ update: (Revision) -> Void = { _ in }) -> Bool {
            current.withLock { revision in
                guard revision.matches(expected) else { return false }
                update(revision)
                return true
            }
        }
    }

    private struct Work: Sendable {
        let revision: Revision
        #if DEBUG
        let id: UInt64
        let receivedAt: TimeInterval
        let enqueuedAt: TimeInterval
        #endif
    }

    private struct FirstFrame: Sendable {
        let frame: CGRect
        let work: Work
    }

    private struct Creation: Sendable {
        let work: Work
        let evidence: String
    }

    private enum Skip: String, Error {
        case noOwningDisplay
        case topEdgeMismatch
        case bottomEdgeMismatch
        case panelUnavailable
        case panelNotOverlapped
        case alreadyAtWorkingHeight
        case invalidTargetHeight
    }

    #if DEBUG
    private nonisolated static let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "window-height")
    private nonisolated static let tracesEnabled = Bundle.main.bundleIdentifier == ApplicationIdentity.properWMDevelopmentIdentifier
    private var sequence: UInt64 = 0
    #endif
    private let reader: AXWindowReader
    private let queue = DispatchQueue(label: "io.github.sashokey.deskmote.window-height", qos: .utility)
    private let revisions = Revisions()
    private var binding: Binding?

    init(accessibility: any AccessibilityOperations) {
        reader = AXWindowReader(accessibility: accessibility)
    }

    func bind(_ window: AXElementKey?, ownerPID: pid_t?) {
        stop()
        guard let window, let ownerPID, ownerPID != ProcessInfo.processInfo.processIdentifier else { return }
        let binding = Binding(window: window, ownerPID: ownerPID)
        self.binding = binding
        let work = nextWork()
        queue.async { [reader, revisions] in
            #if DEBUG
            let resources = ActionResourceLog.begin("windowHeight.baseline", correlation: String(work.id))
            defer { resources?.finish() }
            #endif
            guard revisions.ifCurrent(work.revision) else { return }
            let frame = reader.heightAdjustmentFrame(of: window.e)
            #if DEBUG
            Self.recordAXRead(frame, window: binding, work: work, notification: "focus-baseline", displays: nil)
            #endif
            _ = revisions.ifCurrent(work.revision) { _ in
                binding.firstFrame = frame.map { FirstFrame(frame: $0, work: work) }
                binding.previousFrame = frame
            }
        }
    }

    func newWindowConfirmed(_ window: AXElementKey, displays: [WindowAdjustmentDisplay], evidence: String) {
        guard let binding, binding.window == window else {
            #if DEBUG
            Self.logger.notice("height-skip reason=binding-mismatch source=\(evidence, privacy: .public) window=\(window.hashValue)")
            #endif
            return
        }
        let work = nextWork()
        let creation = Creation(work: work, evidence: evidence)
        queue.async { [reader, revisions] in
            #if DEBUG
            let resources = ActionResourceLog.begin("windowHeight.\(evidence)", correlation: String(work.id))
            defer { resources?.finish() }
            #endif
            Self.applyCreation(creation, verifiedBy: nil, binding: binding, displays: displays,
                               reader: reader, revisions: revisions)
        }
    }

    func geometryChanged(_ window: AXElementKey, displays: [WindowAdjustmentDisplay], notification: String,
                         receivedAt: TimeInterval?) {
        guard let binding, binding.window == window else { return }
        let work = nextWork(receivedAt: receivedAt, isGeometry: true)
        queue.async { [reader, revisions] in
            #if DEBUG
            let resources = ActionResourceLog.begin("windowHeight.geometryChanged", correlation: String(work.id))
            defer { resources?.finish() }
            #endif
            guard revisions.ifCurrent(work.revision) else { return }
            let observed = reader.heightAdjustmentFrame(of: window.e)
            #if DEBUG
            Self.recordAXRead(observed, window: binding, work: work, notification: notification, displays: displays)
            #endif
            if let creation = binding.pendingCreation, creation.work.revision.matches(work.revision) {
                Self.applyCreation(creation, verifiedBy: (work, observed), binding: binding, displays: displays,
                                   reader: reader, revisions: revisions)
            }
            guard let frame = observed, frame != binding.previousFrame, frame != binding.adjustedFrame else { return }

            let previous = binding.previousFrame
            let size = previous.flatMap {
                Self.targetSize(for: frame, after: $0, binding: binding, displays: displays, work: work,
                                source: "windowGeometry")
            }
            guard revisions.ifCurrent(work.revision, { _ in
                binding.observedGeometryChange = true
                binding.previousFrame = frame
                binding.adjustedFrame = size.map { CGRect(origin: frame.origin, size: $0) }
            }) else { return }
            if let size { Self.write(size, from: frame, binding: binding, reader: reader, work: work, source: "windowGeometry") }
        }
    }

    func invalidateLayout() {
        guard binding != nil else { return }
        revisions.current.withLock { $0.layout &+= 1 }
    }

    func stop() {
        revisions.current.withLock { $0.binding &+= 1 }
        binding = nil
    }

    private func nextWork(receivedAt: TimeInterval? = nil, isGeometry: Bool = false) -> Work {
        let revision = revisions.current.withLock { value in
            if isGeometry { value.geometry &+= 1 }
            return value
        }
        #if DEBUG
        sequence &+= 1
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        return Work(revision: revision, id: sequence, receivedAt: receivedAt ?? enqueuedAt, enqueuedAt: enqueuedAt)
        #else
        return Work(revision: revision)
        #endif
    }

    nonisolated private static func applyCreation(
        _ creation: Creation, verifiedBy verification: (work: Work, frame: CGRect?)?, binding: Binding,
        displays: [WindowAdjustmentDisplay], reader: AXWindowReader, revisions: Revisions
    ) {
        let work = verification?.work ?? creation.work
        guard revisions.ifCurrent(work.revision), !binding.handledCreation else { return }
        guard let first = binding.firstFrame, first.work.revision.matches(work.revision),
              !binding.observedGeometryChange, binding.adjustedFrame == nil,
              verification.map({ $0.frame == first.frame }) ?? true else {
            _ = revisions.ifCurrent(work.revision) { _ in
                binding.handledCreation = true
                binding.pendingCreation = nil
            }
            #if DEBUG
            logger.notice("height-skip reason=first-frame-unavailable-or-obsolete event=\(creation.work.id) source=\(creation.evidence, privacy: .public) pid=\(binding.ownerPID) window=\(binding.window.hashValue)")
            #endif
            return
        }
        #if DEBUG
        if tracesEnabled {
            recordFrame(first.frame, window: binding, work: work, notification: creation.evidence, displays: displays,
                        origin: "creation-event=\(creation.work.id) first-AX-event=\(first.work.id)")
        }
        #endif
        let size = targetSize(for: first.frame, after: nil, binding: binding, displays: displays, work: work,
                              source: creation.evidence)
        var admitted = false
        guard revisions.ifCurrent(work.revision, { current in
            guard current.geometry == work.revision.geometry else {
                binding.pendingCreation = creation
                return
            }
            binding.handledCreation = true
            binding.pendingCreation = nil
            if let size { binding.adjustedFrame = CGRect(origin: first.frame.origin, size: size) }
            admitted = true
        }), admitted, let size else { return }
        write(size, from: first.frame, binding: binding, reader: reader, work: work, source: creation.evidence)
    }

    nonisolated private static func targetSize(
        for frame: CGRect, after previous: CGRect?, binding: Binding, displays: [WindowAdjustmentDisplay],
        work: Work, source: String
    ) -> CGSize? {
        let display = owningDisplay(for: frame, displays: displays)
        switch adjustedSize(for: frame, after: previous, display: display, displays: displays) {
        case let .success(value):
            return value
        case let .failure(reason):
            #if DEBUG
            logger.log(level: previous == nil ? .default : .debug, "height-skip reason=\(reason.rawValue, privacy: .public) event=\(work.id) source=\(source, privacy: .public) pid=\(binding.ownerPID) window=\(binding.window.hashValue) height=\(frame.height)")
            #endif
            return nil
        }
    }

    nonisolated private static func write(_ size: CGSize, from frame: CGRect, binding: Binding, reader: AXWindowReader,
                                          work: Work, source: String) {
        #if DEBUG
        let result = reader.writeWindowSize(size, to: binding.window.e)
        guard tracesEnabled else { return }
        binding.pendingWriteObservation = work
        logger.notice("AXSize attempted source=\(source, privacy: .public) pid=\(binding.ownerPID) window=\(binding.window.hashValue) event=\(work.id) binding=\(work.revision.binding) layout=\(work.revision.layout) before=\(describe(frame), privacy: .public) width=\(size.width) old-height=\(frame.height) height=\(size.height) result=\(result.rawValue) completed-at=\(ProcessInfo.processInfo.systemUptime) immediate-post-frame=unmeasured next-existing-AX-read=pending")
        #else
        _ = reader.writeWindowSize(size, to: binding.window.e)
        #endif
    }

    #if DEBUG
    nonisolated private static func recordAXRead(_ frame: CGRect?, window: Binding, work: Work, notification: String,
                                                displays: [WindowAdjustmentDisplay]?) {
        guard tracesEnabled else { return }
        let observedAt = ProcessInfo.processInfo.systemUptime
        recordFrame(frame, window: window, work: work, notification: notification, displays: displays,
                    origin: "AX-observed-at=\(observedAt)")
        guard let written = window.pendingWriteObservation else { return }
        window.pendingWriteObservation = nil
        logger.notice("height-next-existing-AX-read write-event=\(written.id) read-event=\(work.id) same-layout=\(written.revision.layout == work.revision.layout) outcome=\(frame == nil ? "unavailable" : "observed", privacy: .public)")
    }

    nonisolated private static func recordFrame(_ frame: CGRect?, window: Binding, work: Work, notification: String,
                                                displays: [WindowAdjustmentDisplay]?, origin: String) {
        let display = displays.flatMap { candidates in
            frame.flatMap { owningDisplay(for: $0, displays: candidates) }.map { candidates[$0] }
        }
        let displayObservedAt = displays == nil ? "unmeasured" : String(work.enqueuedAt)
        logger.notice("height-AX-frame event=\(work.id) notification=\(notification, privacy: .public) pid=\(window.ownerPID) window=\(window.window.hashValue) binding=\(work.revision.binding) layout=\(work.revision.layout) received-at=\(work.receivedAt) display-observed-at=\(displayObservedAt, privacy: .public) \(origin, privacy: .public) AX-frame=\(describe(frame), privacy: .public) display=\(describe(display?.frame), privacy: .public) working=\(describe(display?.visibleFrame), privacy: .public) panel=\(describe(display?.panelFrame), privacy: .public)")
    }

    nonisolated private static func describe(_ frame: CGRect?) -> String {
        guard let frame else { return "unavailable" }
        return "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
    }
    #endif

    nonisolated private static func owningDisplay(for frame: CGRect, displays: [WindowAdjustmentDisplay]) -> Int? {
        WindowDisplayAttribution.owningDisplayIndex(for: frame, screenCGFrames: displays.lazy.map(\.frame))
    }

    nonisolated private static func adjustedSize(
        for frame: CGRect, after previous: CGRect?, display index: Int?, displays: [WindowAdjustmentDisplay]
    ) -> Result<CGSize, Skip> {
        guard let index else { return .failure(.noOwningDisplay) }
        let display = displays[index]
        let area = display.visibleFrame
        guard frame.minY == area.minY else { return .failure(.topEdgeMismatch) }
        guard frame.maxY == area.maxY else { return .failure(.bottomEdgeMismatch) }
        guard let panel = display.panelFrame else { return .failure(.panelUnavailable) }
        guard !frame.intersection(panel).isEmpty else { return .failure(.panelNotOverlapped) }

        if let previous, previous.minY == area.minY, previous.maxY == area.maxY,
           owningDisplay(for: previous, displays: displays) == index {
            return .failure(.alreadyAtWorkingHeight)
        }

        let height = panel.minY - frame.minY
        guard height > 0, height < frame.height else { return .failure(.invalidTargetHeight) }
        return .success(CGSize(width: frame.width, height: height))
    }
}
