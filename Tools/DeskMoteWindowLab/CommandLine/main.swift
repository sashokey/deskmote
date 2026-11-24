import Foundation
import CoreGraphics

struct LabTarget {
    let displayName: String
    let pid: Int32
    let baselineIdentity: WindowID
    let baselineCGWindowID: UInt32?
    let title: String?
    let bounds: CGRect?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var cgSource = CoreGraphicsSource()
let axSource = AccessibilitySource()
let finderSource = FinderSource()
let axActionExecutor = AccessibilityWindowActionExecutor()
let identityEngine = WindowIdentityEngine()
let formatter = ISO8601DateFormatter()

let rawArguments = Array(CommandLine.arguments.dropFirst())
let mode: LabMode = {
    do { return try WindowLabInput.mode(rawArguments) }
    catch WindowLabInputError.invalidSelectorArguments { fail("Use a single quoted window selector") }
    catch WindowLabInputError.unexpectedArguments(let mode) { fail("Unexpected arguments for \(mode.rawValue)") }
    catch { fail("Specify a mode: observe, minimizeRestore, closeTarget, replay, placementReplay or transitionReplay") }
}()
let modeArguments = Array(rawArguments.dropFirst())

@MainActor
func loadScenarioURL(named scenarioName: String) -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let preferred: URL
    do { preferred = try WindowLabInput.scenarioURL(root: currentDirectory, name: scenarioName) }
    catch { fail("Invalid scenario name") }
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let fallbackRoot = executableURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fallback: URL
    do { fallback = try WindowLabInput.scenarioURL(root: fallbackRoot, name: scenarioName) }
    catch { fail("Invalid scenario name") }
    return FileManager.default.fileExists(atPath: preferred.path) ? preferred : fallback
}

@MainActor
func analyze(_ observation: SystemObservation) -> AnalyzedObservation {
    AnalyzedObservation(
        observation: observation,
        identity: identityEngine.identify(observation: observation)
    )
}

@MainActor
func analyze(_ observations: [SystemObservation]) -> [AnalyzedObservation] {
    observations.map(analyze)
}

@MainActor
func frameString(for observation: SystemObservation) -> String {
    WindowFrameMatchPolicy.signature(for: observation.bounds)
}

private func printDiagnostic(_ line: String) {
    Swift.print(WindowLabInput.diagnosticLine(line))
}

@MainActor
func displayName(for analyzed: AnalyzedObservation) -> String {
    analyzed.observation.title ?? analyzed.observation.appName ?? analyzed.identity.windowID.rawValue
}

@MainActor
func printObservation(_ analyzed: AnalyzedObservation, label: String) {
    let observation = analyzed.observation
    let identity = analyzed.identity
    let title = WindowLabInput.diagnosticLine(observation.title ?? "")
    let frame = frameString(for: observation)
    printDiagnostic("[\(formatter.string(from: Date()))] [\(label):\(observation.kind.rawValue.uppercased())] identity=\(identity.windowID.rawValue) confidence=\(identity.confidence.rawValue.uppercased())")
    printDiagnostic("  signals: pid=\(observation.pid) cg_id=\(observation.cgWindowID ?? 0) title=\"\(title)\" frame=\(frame)")
    printDiagnostic("  source: \(observation.source.rawValue) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow)")
    printDiagnostic("  decision: \(identity.kind.rawValue.uppercased()) (\(identity.reason))")
}

@discardableResult
@MainActor
func printObservation(_ observation: SystemObservation, label: String) -> IdentityDecision {
    let analyzed = analyze(observation)
    printObservation(analyzed, label: label)
    return analyzed.identity
}

@MainActor
func collectRealObservations() -> (observations: [SystemObservation], windowInfo: [[String: Any]]?) {
    let cg = cgSource.observe()
    let ax = axSource.observe()
    let finder = finderSource.observe(cgObservations: cg?.observations ?? [])
    return ((cg?.observations ?? []) + ax + finder, cg?.windowInfo)
}

@MainActor
func collectAnalyzedRealObservations() -> (observations: [AnalyzedObservation], windowInfo: [[String: Any]]?) {
    let captured = collectRealObservations()
    return (analyze(captured.observations), captured.windowInfo)
}

@MainActor
func baselineCandidates(from analyzed: [AnalyzedObservation]) -> [AnalyzedObservation] {
    analyzed
        .filter { analyzed in
            analyzed.observation.source == .coreGraphics
                && analyzed.observation.kind != .disappeared
                && analyzed.identity.kind != .ambiguous
        }
        .sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
}

@MainActor
func printPhaseObservations(_ analyzed: [AnalyzedObservation], phase: String) {
    for item in analyzed.prefix(12) {
        let label = item.observation.source == .coreGraphics ? "CG-\(phase)" : "AX-\(phase)"
        printObservation(item, label: label)
    }
}

@MainActor
func printCandidateList(_ candidates: [AnalyzedObservation],
                        positions: [Int]? = nil,
                        name: @MainActor (AnalyzedObservation) -> String = displayName(for:)) {
    printDiagnostic("# candidate windows:")
    for (index, candidate) in candidates.enumerated() {
        let observation = candidate.observation
        printDiagnostic(
            "  [\(positions?[index] ?? index + 1)] \(WindowLabInput.diagnosticLine(name(candidate))) | identity=\(candidate.identity.windowID.rawValue) pid=\(observation.pid) cg_id=\(observation.cgWindowID ?? 0)"
        )
    }
}

@MainActor
func selectCandidate(from candidates: [AnalyzedObservation], preferredKeyword: String?,
                     name: @MainActor (AnalyzedObservation) -> String = displayName(for:)) -> AnalyzedObservation? {
    if let preferredKeyword {
        let trimmed = preferredKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            if trimmed.hasPrefix("index:") {
                return candidateByIndexSelector(trimmed, from: candidates)
            }

            if trimmed.hasPrefix("cg:") {
                return candidateByCGSelector(trimmed, from: candidates)
            }

            let matches = candidates.enumerated().filter { _, candidate in
                name(candidate).localizedCaseInsensitiveContains(trimmed) ||
                    displayName(for: candidate).localizedCaseInsensitiveContains(trimmed)
            }

            if matches.isEmpty {
                fputs("no candidate matched keyword\n", stderr)
                return nil
            }

            if matches.count > 1 {
                printDiagnostic("# keyword matched multiple windows:")
                printCandidateList(matches.map(\.element), positions: matches.map { $0.offset + 1 }, name: name)
                fputs("ambiguous target keyword\n", stderr)
                return nil
            }

            return matches[0].element
        }
    }

    printDiagnostic("# type a candidate index, then press Return")
    guard let raw = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          let offset = WindowLabInput.candidateOffset(raw, count: candidates.count) else {
        fputs("invalid candidate selection\n", stderr)
        return nil
    }

    return candidates[offset]
}

@MainActor
func candidateByIndexSelector(_ selector: String, from candidates: [AnalyzedObservation]) -> AnalyzedObservation? {
    guard selector.hasPrefix("index:") else { return nil }
    let raw = String(selector.dropFirst("index:".count))
    guard let offset = WindowLabInput.candidateOffset(raw, count: candidates.count) else {
        fputs("invalid index selector\n", stderr)
        return nil
    }
    return candidates[offset]
}

@MainActor
func candidateByCGSelector(_ selector: String, from candidates: [AnalyzedObservation]) -> AnalyzedObservation? {
    guard selector.hasPrefix("cg:") else { return nil }
    let raw = String(selector.dropFirst("cg:".count))
    guard let cgWindowID = UInt32(raw) else {
        fputs("invalid cg selector\n", stderr)
        return nil
    }

    guard let candidate = candidates.first(where: { $0.observation.cgWindowID == cgWindowID }) else {
        fputs("cg selector did not match any candidate\n", stderr)
        return nil
    }

    return candidate
}

@MainActor
func trackedObservation(in analyzed: [AnalyzedObservation], target: LabTarget) -> AnalyzedObservation? {
    if let sameIdentityCurrent = analyzed.first(where: {
        $0.identity.windowID == target.baselineIdentity && $0.observation.kind != .disappeared
    }) {
        return sameIdentityCurrent
    }

    if let sameIdentity = analyzed.first(where: { $0.identity.windowID == target.baselineIdentity }) {
        return sameIdentity
    }

    return analyzed.first {
        $0.observation.pid == target.pid && displayName(for: $0) == target.displayName
    }
}

@MainActor
func targetRelatedObservations(in analyzed: [AnalyzedObservation], target: LabTarget) -> [AnalyzedObservation] {
    analyzed.filter { candidate in
        let observation = candidate.observation

        if candidate.identity.windowID == target.baselineIdentity {
            return true
        }

        guard observation.pid == target.pid else { return false }

        if let baselineCGWindowID = target.baselineCGWindowID,
           observation.cgWindowID == baselineCGWindowID {
            return true
        }

        if let title = target.title,
           observation.title == title {
            return true
        }

        if let targetBounds = target.bounds,
           let bounds = observation.bounds,
           areClose(bounds, targetBounds) {
            return true
        }

        return false
    }
}

@MainActor
func printTargetDiagnostics(phase: String, analyzed: [AnalyzedObservation], target: LabTarget) {
    let related = targetRelatedObservations(in: analyzed, target: target)
    let cgMatches = related.filter { $0.observation.source == .coreGraphics }
    let axMatches = related.filter { $0.observation.source == .accessibility }

    printDiagnostic("# target diagnostics (\(phase)):")
    if cgMatches.isEmpty {
        printDiagnostic("  CG: <none>")
    } else {
        for match in cgMatches {
            let observation = match.observation
            printDiagnostic(
                "  CG: kind=\(observation.kind.rawValue) identity=\(match.identity.windowID.rawValue) cg_id=\(observation.cgWindowID ?? 0) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow) title=\"\(WindowLabInput.diagnosticLine(observation.title ?? ""))\" frame=\(frameString(for: observation))"
            )
        }
    }

    if axMatches.isEmpty {
        printDiagnostic("  AX: <none>")
    } else {
        for match in axMatches {
            let observation = match.observation
            printDiagnostic(
                "  AX: kind=\(observation.kind.rawValue) identity=\(match.identity.windowID.rawValue) cg_id=\(observation.cgWindowID ?? 0) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow) title=\"\(WindowLabInput.diagnosticLine(observation.title ?? ""))\" frame=\(frameString(for: observation))"
            )
        }
    }
}

@MainActor
func areClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= 4
        && abs(lhs.origin.y - rhs.origin.y) <= 4
        && abs(lhs.width - rhs.width) <= 4
        && abs(lhs.height - rhs.height) <= 4
}

@MainActor
func runObserveMode(rounds: Int = 3) {
    for round in 0..<rounds {
        let capture = cgSource.observe()
        if let capture {
            let observations = capture.observations.filter { $0.kind != .unchanged || round > 0 }
            for observation in observations.prefix(10) {
                printObservation(observation, label: "CG")
            }
        } else {
            fputs("CG observation unavailable in round \(round + 1)\n", stderr)
        }

        if round == 0 {
            for observation in axSource.observe().prefix(10) {
                printObservation(observation, label: "AX")
            }
            for observation in finderSource.observe(cgObservations: capture?.observations ?? []).prefix(10) {
                printObservation(observation, label: "FINDER-AX")
            }
        }

        if round < rounds - 1 {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

@MainActor
func selectActionCandidate(from candidates: [AnalyzedObservation], preferredKeyword: String?)
    -> (AnalyzedObservation, AccessibilityWindowActionExecutor, AccessibilityWindowActionExecutor.WindowHandle, WindowRecord)? {
    let system = NativeWindowSystem()
    guard !candidates.isEmpty else {
        fputs("no visible CG candidates found\n", stderr)
        return nil
    }
    let selector = preferredKeyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let exact: AnalyzedObservation?
    if selector.hasPrefix("index:") || selector.hasPrefix("cg:") {
        guard let candidate = selectCandidate(from: candidates, preferredKeyword: selector) else { return nil }
        exact = candidate
    } else {
        exact = nil
    }
    let reader = AXWindowReader()
    let groups = Dictionary(grouping: exact.map { [$0] } ?? candidates, by: { $0.observation.pid })
    var captured: [CGWindowID: (record: WindowRecord, handle: AccessibilityWindowActionExecutor.WindowHandle)] = [:]
    for (pid, group) in groups {
        guard pid != ProcessInfo.processInfo.processIdentifier, let generation = system.generation(pid) else { continue }
        let handles: [CGWindowID: AccessibilityWindowActionExecutor.WindowHandle]
        if let exact, let number = exact.observation.cgWindowID, number != kCGNullWindowID {
            let target = AccessibilityWindowActionExecutor.WindowTarget(
                pid: pid, title: exact.observation.title, bounds: exact.observation.bounds, cgWindowID: number)
            guard let handle = axActionExecutor.captureHandleByCGWindowID(number, pid: pid, title: target.title, bounds: target.bounds)
                ?? axActionExecutor.captureHandle(for: target) else { continue }
            handles = [number: handle]
        } else {
            guard case let .success(windows) = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.5) else { continue }
            let observed = Dictionary(grouping: windows, by: \.cgWindowID)
            handles = Dictionary(uniqueKeysWithValues: observed.compactMap { number, choices in
                guard let number, choices.count == 1, let window = choices.first else { return nil }
                return (number, AccessibilityWindowActionExecutor.WindowHandle.captured(from: window))
            })
        }
        guard system.generation(pid) == generation else { continue }
        for candidate in group {
            let observation = candidate.observation
            guard let number = observation.cgWindowID, number != kCGNullWindowID,
                  let handle = handles[number] else { continue }
            let expected = observation.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = handle.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if exact == nil, let expected, !expected.isEmpty, let actual, !actual.isEmpty, expected != actual { continue }
            let record = WindowRecord(id: candidate.identity.windowID,
                appID: AppID(rawValue: observation.bundleIdentifier ?? String(pid)), pid: pid,
                bundleIdentifier: observation.bundleIdentifier, title: handle.title ?? "",
                bounds: handle.bounds, status: .inactive, cgWindowID: number,
                processGeneration: generation, actionTarget: WindowActionTarget(element: handle.elementKey))
            captured[number] = (record, handle)
        }
    }
    let name: @MainActor (AnalyzedObservation) -> String = { candidate in
        let title = candidate.observation.cgWindowID.flatMap { captured[$0]?.handle.title }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? displayName(for: candidate)
    }
    printCandidateList(candidates, name: name)
    if let preferredKeyword, !preferredKeyword.isEmpty {
        printDiagnostic("# target keyword: \(WindowLabInput.diagnosticLine(preferredKeyword))")
    }
    guard let selected = exact ?? selectCandidate(from: candidates, preferredKeyword: preferredKeyword, name: name) else { return nil }
    guard let selectedNumber = selected.observation.cgWindowID,
          let binding = captured[selectedNumber], binding.record.pid == selected.observation.pid else {
        fputs("selected candidate has no confirmed AX identity\n", stderr)
        return nil
    }
    let (record, handle) = binding
    let executor = axActionExecutor.withCancellation(OperationCancellation()) { pid, windowID, element in
        WindowLabInput.permitsCommand(record, pid: pid, windowID: windowID, element: element, system: system)
    }
    return (selected, executor, handle, record)
}

@MainActor
func runMinimizeRestoreMode() {
    let preferredKeyword = modeArguments.first

    printDiagnostic("# minimize-restore acceptance")
    printDiagnostic("# goal: the tracked window must disappear from the CG list after minimize and restore with the same identity")
    printDiagnostic("# step 1: collect baseline windows")
    let baseline = analyze(cgSource.observe()?.observations ?? [])
    printPhaseObservations(baseline, phase: "BASE")

    guard let (selected, executor, actionHandle, boundRecord) = selectActionCandidate(
        from: baselineCandidates(from: baseline), preferredKeyword: preferredKeyword),
          let windowID = selected.observation.cgWindowID else { exit(1) }

    let target = LabTarget(
        displayName: displayName(for: selected),
        pid: selected.observation.pid,
        baselineIdentity: selected.identity.windowID,
        baselineCGWindowID: windowID,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )

    printDiagnostic("# selected target: \(WindowLabInput.diagnosticLine(target.displayName))")
    printDiagnostic("# baseline identity: \(target.baselineIdentity.rawValue)")
    printDiagnostic("# baseline cg id: \(target.baselineCGWindowID ?? 0)")

    printDiagnostic("# step 2: minimize the target window via AX")
    let minimizeExecution = executor.minimize(actionHandle)
    printDiagnostic(
        "# minimize action: mechanism=\(minimizeExecution.mechanism) verified_minimized=\(String(describing: minimizeExecution.verifiedMinimized)) success=\(minimizeExecution.success)"
    )
    guard minimizeExecution.success else {
        fputs("failed to minimize selected target via AX\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.8)

    printDiagnostic("# step 3: collect minimized-state windows")
    let minimized = collectAnalyzedRealObservations()
    printPhaseObservations(minimized.observations, phase: "MIN")
    printTargetDiagnostics(phase: "minimized", analyzed: minimized.observations, target: target)
    let disappearedFromCG = WindowLabInput.didMinimize(windowID: windowID, pid: target.pid,
                                                     windowInfo: minimized.windowInfo)

    let minimizedMatch = trackedObservation(in: minimized.observations, target: target)
    printDiagnostic("# target during minimize:")
    if let minimizedMatch {
        printDiagnostic(
            "  identity=\(minimizedMatch.identity.windowID.rawValue) source=\(minimizedMatch.observation.source.rawValue) cg_id=\(minimizedMatch.observation.cgWindowID ?? 0)"
        )
    } else {
        printDiagnostic("  <not directly observed>")
    }
    printDiagnostic("# baseline cg id disappeared: \(disappearedFromCG)")

    printDiagnostic("# step 4: restore the target window via AX")
    let restoredTarget = executor.activate(actionHandle, knownCGWindowID: target.baselineCGWindowID, knownMinimized: true)
    printDiagnostic("# restore action: success=\(restoredTarget)")
    Thread.sleep(forTimeInterval: 0.8)

    printDiagnostic("# step 5: collect restored-state windows")
    let captured = collectRealObservations()
    let system = NativeWindowSystem()
    let restored = WindowLabInput.analyzeRestoration(captured.observations, for: boundRecord, using: identityEngine) { number in
        guard disappearedFromCG, let generation = boundRecord.processGeneration, system.generation(target.pid) == generation,
              system.windowDescriptions(for: [number])?.contains(where: {
                  nativeWindowNumber(in: $0) == number && $0[kCGWindowOwnerPID as String] as? pid_t == target.pid
              }) == true else { return false }
        return axActionExecutor.captureHandleByCGWindowID(number, pid: target.pid, title: nil, bounds: nil,
                                                           expectedElement: actionHandle.elementKey) != nil
            && system.generation(target.pid) == generation
    }
    printPhaseObservations(restored.observations, phase: "RESTORE")
    printTargetDiagnostics(phase: "restored", analyzed: restored.observations, target: target)

    let restoredMatch = restored.match
    let restoredIdentity = restoredMatch?.identity.windowID.rawValue ?? "<missing>"
    let stableIdentity = restoredMatch != nil && system.generation(target.pid) == boundRecord.processGeneration
    let confirmedReplacement = restoredMatch.map { $0.observation.cgWindowID != windowID } == true
    printDiagnostic("# restored target: \(WindowLabInput.diagnosticLine(restoredMatch.map(displayName(for:)) ?? "<missing>"))")
    if let restoredMatch {
        printDiagnostic(
            "# restored source: \(restoredMatch.observation.source.rawValue) cg_id=\(restoredMatch.observation.cgWindowID ?? 0) confidence=\(restoredMatch.identity.confidence.rawValue.uppercased())"
        )
    }
    printDiagnostic("# baseline identity: \(target.baselineIdentity.rawValue)")
    printDiagnostic("# restored identity: \(restoredIdentity)")
    printDiagnostic("# stable identity after restore: \(stableIdentity)")

    let accepted = disappearedFromCG && stableIdentity && (restoredTarget || confirmedReplacement)
    printDiagnostic("# acceptance passed: \(accepted)")
    if accepted == false {
        fputs("minimize-restore acceptance failed\n", stderr)
        exit(1)
    }
}

@MainActor
func runCloseTargetMode() {
    let preferredKeyword = modeArguments.first

    printDiagnostic("# close-target acceptance")
    printDiagnostic("# goal: the tracked window should disappear from live observations after close")
    printDiagnostic("# step 1: collect baseline windows")
    let baseline = analyze(cgSource.observe()?.observations ?? [])
    printPhaseObservations(baseline, phase: "BASE")

    guard let (selected, executor, actionHandle, _) = selectActionCandidate(
        from: baselineCandidates(from: baseline), preferredKeyword: preferredKeyword) else { exit(1) }

    let target = LabTarget(
        displayName: displayName(for: selected),
        pid: selected.observation.pid,
        baselineIdentity: selected.identity.windowID,
        baselineCGWindowID: selected.observation.cgWindowID,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )

    printDiagnostic("# selected target: \(WindowLabInput.diagnosticLine(target.displayName))")
    printDiagnostic("# baseline identity: \(target.baselineIdentity.rawValue)")
    printDiagnostic("# baseline cg id: \(target.baselineCGWindowID ?? 0)")

    printDiagnostic("# step 2: close the target window via AX")
    let closeSucceeded = executor.close(actionHandle)
    printDiagnostic("# close action: success=\(closeSucceeded)")
    guard closeSucceeded else {
        fputs("failed to close selected target via AX\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 1.2)

    printDiagnostic("# step 3: collect post-close windows")
    let afterClose = collectAnalyzedRealObservations().observations
    printPhaseObservations(afterClose, phase: "CLOSE")
    printTargetDiagnostics(phase: "closed", analyzed: afterClose, target: target)

    let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    guard let windowID = target.baselineCGWindowID,
          let closed = WindowLabInput.didClose(windowID: windowID, pid: target.pid, windowInfo: windowInfo) else {
        fputs("unable to verify the selected window after close\n", stderr)
        exit(1)
    }
    printDiagnostic("# selected window closed: \(closed)")
    if !closed {
        fputs("close-target acceptance failed\n", stderr)
        exit(1)
    }
}

struct ReplayScenario: Decodable {
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

struct PlacementReplayScenario: Decodable {
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

struct TransitionReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let observation: ReplayScenario.ReplayObservation
        let expectedStatus: String
        let trackCloseAtSeconds: Double?
    }

    let name: String
    let steps: [Step]
}

@MainActor
func parseBounds(_ raw: String?) -> CGRect? {
    do { return try WindowLabInput.bounds(raw) }
    catch { fail("Invalid scenario geometry") }
}

@MainActor
func systemObservation(from replay: ReplayScenario.ReplayObservation) -> SystemObservation {
    guard let kind = SystemObservation.ObservationKind(rawValue: replay.kind),
          let source = SystemObservation.ObservationSource(rawValue: replay.source),
          (replay.atSeconds ?? 0).isFinite else { fail("Invalid observation kind, source or timestamp") }
    guard replay.cgWindowID != kCGNullWindowID else { fail("Invalid native window number") }
    let timestamp = Date(timeIntervalSince1970: replay.atSeconds ?? 0)
    return SystemObservation(
        timestamp: timestamp,
        kind: kind,
        source: source,
        pid: replay.pid,
        bundleIdentifier: replay.bundleIdentifier,
        cgWindowID: replay.cgWindowID,
        title: replay.title,
        appName: replay.appName,
        bounds: parseBounds(replay.bounds),
        isMinimized: replay.isMinimized,
        isFocusedWindow: replay.isFocusedWindow ?? false
    )
}

@MainActor
func runReplayMode() {
    let replayScenarioName = modeArguments.first ?? "minimize-restore-replay"
    let root = loadScenarioURL(named: replayScenarioName)
    let scenario: ReplayScenario
    do { scenario = try WindowLabInput.decode(ReplayScenario.self, from: root) }
    catch { fail("Unable to read a valid scenario JSON file") }
    guard let first = scenario.steps.first, let last = scenario.steps.last,
          let firstTrackedObservation = first.trackedObservation, last.trackedObservation != nil else {
        fputs("replay scenario requires tracked endpoints\n", stderr)
        exit(1)
    }
    printDiagnostic("# replay scenario: \(scenario.name)")

    var trackedKey = ""
    var beforeDecision: IdentityDecision?
    var finalDecision: IdentityDecision?

    for (stepIndex, step) in scenario.steps.enumerated() {
        printDiagnostic("# step: \(step.label)")
        for replayObservation in step.observations {
            let observation = systemObservation(from: replayObservation)
            let identity = printObservation(observation, label: "REPLAY")
            if let expectedDecision = replayObservation.expectedDecision,
               identity.kind.rawValue != expectedDecision {
                fputs("unexpected decision kind\n", stderr)
                exit(1)
            }
            if let expectedReason = replayObservation.expectedReason,
               identity.reason != expectedReason {
                fputs("unexpected decision reason\n", stderr)
                exit(1)
            }
            if let expectedConfidence = replayObservation.expectedConfidence,
               identity.confidence.rawValue != expectedConfidence {
                fputs("unexpected decision confidence\n", stderr)
                exit(1)
            }
            let key = observation.title ?? observation.appName ?? "untitled"
            if step.tracks(replayObservation) {
                trackedKey = key
                if stepIndex == 0 {
                    beforeDecision = identity
                }
                if stepIndex == scenario.steps.count - 1 {
                    finalDecision = identity
                }
            }
        }
    }

    guard scenario.steps.count > 1 || first.observations.contains(where: {
        $0.expectedDecision != nil || $0.expectedReason != nil || $0.expectedConfidence != nil
    }) else {
        fputs("single-step replay requires a decision expectation\n", stderr)
        exit(1)
    }
    guard let beforeDecision, let finalDecision,
          !beforeDecision.windowID.rawValue.isEmpty, !finalDecision.windowID.rawValue.isEmpty else {
        fputs("replay scenario requires tracked endpoints\n", stderr)
        exit(1)
    }
    if scenario.steps.count == 1 {
        if !beforeDecision.isConfirmed, firstTrackedObservation.expectedDecision != DecisionKind.ambiguous.rawValue {
            fputs("single-step replay requires an explicit ambiguous decision for an unconfirmed endpoint\n", stderr)
            exit(1)
        }
    } else if !beforeDecision.isConfirmed || !finalDecision.isConfirmed {
        fputs("replay scenario requires confirmed endpoint identities\n", stderr)
        exit(1)
    }
    let stable = beforeDecision.windowID == finalDecision.windowID
    printDiagnostic("# tracked key: \(trackedKey)")
    printDiagnostic("# before identity: \(beforeDecision.windowID.rawValue)")
    printDiagnostic("# final identity: \(finalDecision.windowID.rawValue)")
    printDiagnostic("# stable identity: \(stable)")
    if stable != scenario.expectedStableIdentity {
        fputs("replay scenario failed\n", stderr)
        exit(1)
    }
}

@MainActor
func runPlacementReplayMode() {
    let placementScenarioName = modeArguments.first ?? "placement-permanent-hold-replay"
    let root = loadScenarioURL(named: placementScenarioName)
    let scenario: PlacementReplayScenario
    do { scenario = try WindowLabInput.decode(PlacementReplayScenario.self, from: root) }
    catch { fail("Unable to read a valid scenario JSON file") }
    guard !scenario.steps.isEmpty else { fail("Scenario must contain at least one step") }
    do { try WindowLabInput.requireUniqueWindowIDs(scenario.initialOrderedWindowIDs) }
    catch { fail("Initial window IDs must be unique and nonempty") }
    let engine = PlacementEngine()

    var snapshot = DockSnapshot(
        windows: Dictionary(
            uniqueKeysWithValues: scenario.initialOrderedWindowIDs.map { rawID in
                let id = WindowID(rawValue: rawID)
                return (
                    id,
                    WindowRecord(
                        id: id,
                        appID: AppID(rawValue: "placement-lab"),
                        pid: 0,
                        bundleIdentifier: nil,
                        title: rawID,
                        bounds: nil,
                        status: .inactive
                    )
                )
            }
        ),
        orderedWindowIDs: scenario.initialOrderedWindowIDs.map { WindowID(rawValue: $0) }
    )

    printDiagnostic("# placement replay scenario: \(scenario.name)")
    printDiagnostic("# initial order: \(scenario.initialOrderedWindowIDs.joined(separator: ","))")

    for step in scenario.steps {
        guard let status = WindowStatus(rawValue: step.newStatus), step.atSeconds.isFinite else { fail("Invalid lifecycle status or timestamp") }
        do { try WindowLabInput.requireUniqueWindowIDs(step.expectedOrder) }
        catch { fail("Expected order must contain unique window IDs") }
        let lifecycle = LifecycleDecision(
            windowID: WindowID(rawValue: step.windowID),
            newStatus: status,
            requests: [],
            observedAt: Date(timeIntervalSince1970: step.atSeconds)
        )
        let result = engine.place(snapshot: snapshot, lifecycle: lifecycle)
        let actualOrder = result.orderedWindowIDs.map { $0.rawValue }
        printDiagnostic("# step: \(step.label)")
        printDiagnostic("  lifecycle: window=\(step.windowID) status=\(step.newStatus) at=\(step.atSeconds)")
        printDiagnostic("  order: \(actualOrder.joined(separator: ","))")

        if actualOrder != step.expectedOrder {
            fputs("unexpected placement order\n", stderr)
            exit(1)
        }

        snapshot = nextSnapshot(from: snapshot, lifecycle: lifecycle, orderedWindowIDs: result.orderedWindowIDs)
    }
}

@MainActor
func runTransitionReplayMode() {
    let scenarioName = modeArguments.first ?? "focused-active-replay"
    let root = loadScenarioURL(named: scenarioName)
    let scenario: TransitionReplayScenario
    do { scenario = try WindowLabInput.decode(TransitionReplayScenario.self, from: root) }
    catch { fail("Unable to read a valid scenario JSON file") }
    guard !scenario.steps.isEmpty else { fail("Scenario must contain at least one step") }

    let state = DockState()
    let identity = WindowIdentityEngine()
    let transitions = LifecycleTransitionEngine()
    let placement = PlacementEngine()
    let pendingCloseTracker = PendingCloseTracker()
    let pipeline = ObservationPipeline(
        state: state,
        identity: identity,
        transitions: transitions,
        placement: placement,
        pendingCloseTracker: pendingCloseTracker
    )

    printDiagnostic("# transition replay scenario: \(scenario.name)")
    for step in scenario.steps {
        printDiagnostic("# step: \(step.label)")
        let observation = systemObservation(from: step.observation)
        let closeRequestedAt = step.trackCloseAtSeconds.map { Date(timeIntervalSince1970: $0) }
        guard let processed = pipeline.process(observation, closeRequestedAt: closeRequestedAt) else {
            printDiagnostic("  status: discarded")
            if step.expectedStatus == "discarded" { continue }
            fputs("observation was discarded\n", stderr)
            exit(1)
        }

        let lifecycle = processed.lifecycle
        let snapshot = state.snapshot
        let committedStatus = snapshot.windows[lifecycle.windowID]?.status
        let committed = lifecycle.newStatus == .closedPending
            ? committedStatus == nil && !snapshot.orderedWindowIDs.contains(lifecycle.windowID)
            : committedStatus == lifecycle.newStatus
        printDiagnostic("  identity: \(lifecycle.windowID.rawValue)")
        printDiagnostic("  status: \(lifecycle.newStatus.rawValue)")

        if !committed || lifecycle.newStatus.rawValue != step.expectedStatus {
            fputs("unexpected lifecycle status\n", stderr)
            exit(1)
        }
    }
}

@MainActor
func nextSnapshot(
    from snapshot: DockSnapshot,
    lifecycle: LifecycleDecision,
    orderedWindowIDs: [WindowID]
) -> DockSnapshot {
    var windows = snapshot.windows
    switch lifecycle.newStatus {
    case .disappeared, .closedPending:
        windows.removeValue(forKey: lifecycle.windowID)
    default:
        let existing = windows[lifecycle.windowID]
        windows[lifecycle.windowID] = WindowRecord(
            id: lifecycle.windowID,
            appID: existing?.appID ?? AppID(rawValue: "placement-lab"),
            pid: existing?.pid ?? 0,
            bundleIdentifier: existing?.bundleIdentifier,
            title: existing?.title ?? lifecycle.windowID.rawValue,
            bounds: existing?.bounds,
            status: lifecycle.newStatus
        )
    }

    return DockSnapshot(
        windows: windows,
        orderedWindowIDs: orderedWindowIDs
    )
}

switch mode {
case .observe:
    runObserveMode()
case .minimizeRestore:
    runMinimizeRestoreMode()
case .closeTarget:
    runCloseTargetMode()
case .replay:
    runReplayMode()
case .placementReplay:
    runPlacementReplayMode()
case .transitionReplay:
    MainActor.assumeIsolated { runTransitionReplayMode() }
}
