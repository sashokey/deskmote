import Foundation
import Synchronization

enum FullscreenAXObservation: Sendable {
    case unknown
    case window(role: String, isFullscreen: Bool, frame: CGRect, id: UInt32?, layer: Int?)

    func probe(on screen: CGRect) -> FullscreenAXProbe {
        switch self {
        case .unknown:
            return FullscreenAXProbe(verdict: .unknown, overlayWindowID: nil)
        case let .window(role, isFullscreen, frame, id, layer):
            let verdict = FullscreenWindowClassifier.classify(
                role: role, isAXFullscreen: isFullscreen, windowFrame: frame,
                windowLayer: layer, displayWindowServerFrame: screen
            )
            return FullscreenAXProbe(verdict: verdict,
                                     overlayWindowID: verdict == .fullscreen && !isFullscreen ? id : nil)
        }
    }
}

final class FullscreenReadBatch: Sendable {
    private struct Sample {
        let observation: FullscreenAXObservation
        let uptime: TimeInterval
    }

    private static let freshnessInterval: TimeInterval = 0.25
    private let observations = Mutex<[pid_t: Sample]>([:])
    private let read: @Sendable (pid_t) -> FullscreenAXObservation
    private let readCG: (@MainActor () -> [[String: Any]]?)?
    private let uptime: @Sendable () -> TimeInterval
    @MainActor private var cgSample: (windows: [[String: Any]]?, uptime: TimeInterval)?

    init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readCG: (@MainActor () -> [[String: Any]]?)? = nil,
         read: @escaping @Sendable (pid_t) -> FullscreenAXObservation) {
        self.read = read
        self.readCG = readCG
        self.uptime = uptime
    }

    @MainActor
    func cgWindows(
        isImmediateSpaceChange: Bool = false, fallback: () -> [[String: Any]]?
    ) -> [[String: Any]]? {
        guard let readCG else { return fallback() }
        if let sample = cgSample, isImmediateSpaceChange || uptime() - sample.uptime <= Self.freshnessInterval {
            return sample.windows
        }
        let windows = readCG()
        cgSample = (windows, uptime())
        return windows
    }

    func observation(for pid: pid_t?) -> FullscreenAXObservation {
        guard let pid else { return .unknown }
        return observations.withLock { stored in
            if let sample = stored[pid], uptime() - sample.uptime <= Self.freshnessInterval {
                return sample.observation
            }
            let observation = read(pid)
            stored[pid] = Sample(observation: observation, uptime: uptime())
            return observation
        }
    }
}

struct FullscreenProbeRequest: Sendable {
    let pid: pid_t?
    let screenFrame: CGRect
    let generation: UInt64
    let spaceGeneration: UInt64?
    let finalConfirmation: Bool
    let source: String
    let displayUUID: String?
    let sharedRead: FullscreenReadBatch?

    init(pid: pid_t?, screenFrame: CGRect, generation: UInt64, spaceGeneration: UInt64?,
         finalConfirmation: Bool, source: String, displayUUID: String? = nil,
         sharedRead: FullscreenReadBatch? = nil) {
        self.pid = pid
        self.screenFrame = screenFrame
        self.generation = generation
        self.spaceGeneration = spaceGeneration
        self.finalConfirmation = finalConfirmation
        self.source = source
        self.displayUUID = displayUUID
        self.sharedRead = sharedRead
    }
}

struct FullscreenAXProbe: Sendable {
    let verdict: FullscreenAXVerdict
    let overlayWindowID: UInt32?
    let spaceVerdict: Bool?

    init(verdict: FullscreenAXVerdict, overlayWindowID: UInt32?, spaceVerdict: Bool? = nil) {
        self.verdict = verdict
        self.overlayWindowID = overlayWindowID
        self.spaceVerdict = spaceVerdict
    }
}

@MainActor
final class FullscreenProbeWorker {
    private let read: @Sendable (FullscreenProbeRequest) -> FullscreenAXProbe
    private let readSpace: @Sendable (FullscreenProbeRequest) -> Bool?
    private let deliver: (FullscreenProbeRequest, FullscreenAXProbe) -> Void
    private let work = AsyncWorkScope()
    private var inFlight = false
    private var pending: FullscreenProbeRequest?

    init(read: @escaping @Sendable (FullscreenProbeRequest) -> FullscreenAXProbe,
         readSpace: @escaping @Sendable (FullscreenProbeRequest) -> Bool? = { _ in nil },
         deliver: @escaping (FullscreenProbeRequest, FullscreenAXProbe) -> Void) {
        self.read = read
        self.readSpace = readSpace
        self.deliver = deliver
    }

    func request(_ request: FullscreenProbeRequest) {
        guard work.isActive else { return }
        guard !inFlight else { pending = request; return }
        inFlight = true
        let read = read
        let readSpace = readSpace
        let cancellation = OperationCancellation()
        work.launch { [weak self] generation in
            let completed = await AsyncWorkScope.performBlocking(on: .global(qos: .utility), cancellation: cancellation) { () -> FullscreenAXProbe? in
                let probe = read(request)
                guard !cancellation.isCancelled else { return nil }
                let spaceVerdict = probe.verdict == .fullscreen ? nil : readSpace(request)
                return FullscreenAXProbe(verdict: probe.verdict, overlayWindowID: probe.overlayWindowID,
                                         spaceVerdict: spaceVerdict)
            }
            guard let result = completed ?? nil else { return }
            await MainActor.run { [weak self] in
                guard let self, self.work.isCurrent(generation) else { return }
                self.inFlight = false
                if let pending = self.pending {
                    self.pending = nil
                    self.request(pending)
                } else {
                    self.deliver(request, result)
                }
            }
        }
    }

    func stop() {
        work.stop()
        pending = nil
        inFlight = false
    }

    #if DEBUG
    var pendingWorkForTesting: [Task<Void, Never>] { work.pendingForTesting }
    #endif

    isolated deinit { stop() }
}
