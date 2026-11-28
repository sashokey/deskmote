import CoreGraphics
import Foundation
import XCTest

@MainActor
final class WindowReplayTests: XCTestCase {
    func testAllCommittedReplays() throws {
        let directory = try fixtureDirectory()
        let expected: Set<String> = [
            "accessibility-streak-replay", "cg-window-number-reuse-replay", "chromium-group-title-replay",
            "close-timeout-replay", "coarse-conflict-replay", "finder-title-tab-replay", "focused-active-replay",
            "hide-unhide-replay", "minimize-restore-expired-replay", "minimize-restore-replay", "minimize-restore",
            "placement-close-release-replay", "placement-permanent-hold-replay", "stale-ax-signature-replay",
            "title-change-replay",
        ]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "controls.json" }
        XCTAssertEqual(Set(files.map { $0.deletingPathExtension().lastPathComponent }), expected)
        for path in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: path)
            let mode = try JSONDecoder().decode(ReplayHeader.self, from: data).mode
            XCTAssertGreaterThan(try WindowReplay.evaluate(mode, data).assertions, 0, path.lastPathComponent)
        }
    }

    func testInvalidAndCompetingObservationControls() throws {
        let path = try fixtureDirectory().appendingPathComponent("controls.json")
        let controls = try JSONDecoder().decode([ReplayControl].self, from: Data(contentsOf: path))
        XCTAssertEqual(controls.count, 43)
        XCTAssertEqual(Set(controls.map(\.name)).count, 43)
        for control in controls {
            do {
                let result = try WindowReplay.evaluate(control.mode, Data(control.payload.utf8))
                XCTAssertTrue(control.accepted, control.name)
                XCTAssertGreaterThan(result.assertions, 0, control.name)
                if let expected = control.lastIdentity { XCTAssertEqual(result.identity, expected, control.name) }
                if let expected = control.lastStatus { XCTAssertEqual(result.status, expected, control.name) }
            } catch {
                XCTAssertFalse(control.accepted, "\(control.name): \(error)")
                if let expected = control.error {
                    XCTAssertTrue(String(describing: error).contains(expected), "\(control.name): \(error)")
                }
                if let expected = control.lastStatus {
                    XCTAssertEqual((error as? ReplayFailure)?.status, expected, control.name)
                }
            }
        }
    }

    private func fixtureDirectory() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReplayFixtures", withExtension: nil))
    }
}

private enum ReplayMode: String, Decodable {
    case replay, placementReplay, transitionReplay
}

private struct ReplayHeader: Decodable {
    let mode: ReplayMode
}

private struct ReplayControl: Decodable {
    let name: String
    let mode: ReplayMode
    let payload: String
    let accepted: Bool
    let error: String?
    let lastIdentity: String?
    let lastStatus: String?
}

private struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
    let status: String?

    init(_ description: String, status: String? = nil) {
        self.description = description
        self.status = status
    }
}

@MainActor
private enum WindowReplay {
    struct Evidence {
        var assertions: Int
        var identity: String? = nil
        var status: String? = nil
    }

    static func evaluate(_ mode: ReplayMode, _ data: Data) throws -> Evidence {
        let decoder = JSONDecoder()
        switch mode {
        case .replay: return try verifyIdentity(decoder.decode(ReplayScenario.self, from: data))
        case .placementReplay: return try verifyPlacement(decoder.decode(PlacementReplayScenario.self, from: data))
        case .transitionReplay: return try verifyTransition(decoder.decode(TransitionReplayScenario.self, from: data))
        }
    }

    private static func observation(_ replay: ReplayScenario.ReplayObservation) throws -> SystemObservation {
        guard let kind = SystemObservation.ObservationKind(rawValue: replay.kind),
              let source = SystemObservation.ObservationSource(rawValue: replay.source),
              (replay.atSeconds ?? 0).isFinite, replay.cgWindowID != kCGNullWindowID else {
            throw ReplayFailure("Invalid observation kind, source, window number or timestamp")
        }
        return SystemObservation(timestamp: Date(timeIntervalSince1970: replay.atSeconds ?? 0), kind: kind,
            source: source, pid: replay.pid, bundleIdentifier: replay.bundleIdentifier, cgWindowID: replay.cgWindowID,
            title: replay.title, appName: replay.appName, bounds: try WindowLabInput.bounds(replay.bounds),
            isMinimized: replay.isMinimized, isFocusedWindow: replay.isFocusedWindow ?? false)
    }

    private static func verifyIdentity(_ scenario: ReplayScenario) throws -> Evidence {
        guard let first = scenario.steps.first, let last = scenario.steps.last,
              let tracked = first.trackedObservation, last.trackedObservation != nil else {
            throw ReplayFailure("replay scenario requires tracked endpoints")
        }
        let engine = WindowIdentityEngine()
        var before: IdentityDecision?
        var after: IdentityDecision?
        var assertions = 0
        for (index, step) in scenario.steps.enumerated() {
            for row in step.observations {
                let result = engine.identify(observation: try observation(row))
                for (actual, expected) in [(result.kind.rawValue, row.expectedDecision),
                                           (result.reason, row.expectedReason),
                                           (result.confidence.rawValue, row.expectedConfidence)] {
                    guard let expected else { continue }
                    guard actual == expected else { throw ReplayFailure("Unexpected identity decision: \(actual)") }
                    assertions += 1
                }
                if step.tracks(row) {
                    if index == 0 { before = result }
                    if index == scenario.steps.count - 1 { after = result }
                }
            }
        }
        guard scenario.steps.count > 1 || assertions > 0 else {
            throw ReplayFailure("single-step replay requires a decision expectation")
        }
        guard let before, let after, !before.windowID.rawValue.isEmpty, !after.windowID.rawValue.isEmpty else {
            throw ReplayFailure("replay scenario requires tracked endpoints")
        }
        if scenario.steps.count == 1 {
            guard before.isConfirmed || tracked.expectedDecision == DecisionKind.ambiguous.rawValue else {
                throw ReplayFailure("single-step replay requires an explicit ambiguous decision for an unconfirmed endpoint")
            }
        } else if !before.isConfirmed || !after.isConfirmed {
            throw ReplayFailure("replay scenario requires confirmed endpoint identities")
        }
        guard (before.windowID == after.windowID) == scenario.expectedStableIdentity else {
            throw ReplayFailure("replay scenario failed")
        }
        return Evidence(assertions: assertions + 1, identity: after.windowID.rawValue)
    }

    private static func verifyPlacement(_ scenario: PlacementReplayScenario) throws -> Evidence {
        guard !scenario.steps.isEmpty else { throw ReplayFailure("Scenario must contain at least one step") }
        try WindowLabInput.requireUniqueWindowIDs(scenario.initialOrderedWindowIDs)
        let engine = PlacementEngine()
        let initial = scenario.initialOrderedWindowIDs.map { WindowID(rawValue: $0) }
        var snapshot = DockSnapshot(windows: Dictionary(uniqueKeysWithValues: initial.map { ($0, record($0, .inactive)) }),
                                    orderedWindowIDs: initial)
        for step in scenario.steps {
            guard let status = WindowStatus(rawValue: step.newStatus), step.atSeconds.isFinite else {
                throw ReplayFailure("Invalid lifecycle status or timestamp")
            }
            try WindowLabInput.requireUniqueWindowIDs(step.expectedOrder)
            let id = WindowID(rawValue: step.windowID)
            let lifecycle = LifecycleDecision(windowID: id, newStatus: status, requests: [],
                observedAt: Date(timeIntervalSince1970: step.atSeconds))
            let result = engine.place(snapshot: snapshot, lifecycle: lifecycle)
            guard result.orderedWindowIDs.map(\.rawValue) == step.expectedOrder else {
                throw ReplayFailure("Unexpected placement order")
            }
            var windows = snapshot.windows
            if status == .disappeared || status == .closedPending { windows.removeValue(forKey: id) }
            else { windows[id] = record(id, status) }
            snapshot = DockSnapshot(windows: windows, orderedWindowIDs: result.orderedWindowIDs)
        }
        return Evidence(assertions: scenario.steps.count)
    }

    private static func record(_ id: WindowID, _ status: WindowStatus) -> WindowRecord {
        WindowRecord(id: id, appID: AppID(rawValue: "placement-fixture"), pid: 0, bundleIdentifier: nil,
                     title: id.rawValue, bounds: nil, status: status)
    }

    private static func verifyTransition(_ scenario: TransitionReplayScenario) throws -> Evidence {
        guard !scenario.steps.isEmpty else { throw ReplayFailure("Scenario must contain at least one step") }
        let state = DockState()
        let pipeline = ObservationPipeline(state: state, identity: WindowIdentityEngine(),
            transitions: LifecycleTransitionEngine(), placement: PlacementEngine(), pendingCloseTracker: PendingCloseTracker())
        var evidence = Evidence(assertions: 0)
        for step in scenario.steps {
            let close = step.trackCloseAtSeconds.map { Date(timeIntervalSince1970: $0) }
            guard let processed = pipeline.process(try observation(step.observation), closeRequestedAt: close) else {
                guard step.expectedStatus == "discarded" else {
                    throw ReplayFailure("observation was discarded", status: "discarded")
                }
                evidence.status = "discarded"
                evidence.assertions += 1
                continue
            }
            let lifecycle = processed.lifecycle
            let snapshot = state.snapshot
            let stored = snapshot.windows[lifecycle.windowID]?.status
            let committed = lifecycle.newStatus == .closedPending
                ? stored == nil && !snapshot.orderedWindowIDs.contains(lifecycle.windowID)
                : stored == lifecycle.newStatus
            let observed = lifecycle.newStatus.rawValue
            guard committed, observed == step.expectedStatus else {
                throw ReplayFailure("unexpected lifecycle status", status: observed)
            }
            evidence.identity = lifecycle.windowID.rawValue
            evidence.status = observed
            evidence.assertions += 1
        }
        return evidence
    }
}

private struct ReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let observations: [ReplayObservation]

        func tracks(_ observation: ReplayObservation) -> Bool {
            observation.track ?? (observations.count == 1)
        }

        var trackedObservation: ReplayObservation? {
            let tracked = observations.filter(tracks)
            return tracked.count == 1 ? tracked.first : nil
        }
    }

    struct ReplayObservation: Decodable {
        let kind: String
        let source: String
        let pid: Int32
        let bundleIdentifier: String?
        let cgWindowID: UInt32?
        let title: String?
        let appName: String?
        let bounds: String?
        let isMinimized: Bool
        let isFocusedWindow: Bool?
        let track: Bool?
        let atSeconds: Double?
        let expectedDecision: String?
        let expectedReason: String?
        let expectedConfidence: String?
    }

    let name: String
    let expectedStableIdentity: Bool
    let steps: [Step]
}

private struct PlacementReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let windowID: String
        let newStatus: String
        let atSeconds: Double
        let expectedOrder: [String]
    }

    let name: String
    let initialOrderedWindowIDs: [String]
    let steps: [Step]
}

private struct TransitionReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let observation: ReplayScenario.ReplayObservation
        let expectedStatus: String
        let trackCloseAtSeconds: Double?
    }

    let name: String
    let steps: [Step]
}
