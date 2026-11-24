import ApplicationServices
import Foundation
import CoreGraphics

struct AnalyzedObservation {
    let observation: SystemObservation
    let identity: IdentityDecision
}

enum LabMode: String {
    case observe, minimizeRestore, closeTarget, replay, placementReplay, transitionReplay
}

enum WindowLabInputError: Error {
    case invalidMode, invalidSelectorArguments, unexpectedArguments(LabMode)
    case invalidScenarioName, invalidGeometry, invalidScenario, duplicateWindowID
}

enum WindowLabInput {
    static func candidateOffset(_ raw: String, count: Int) -> Int? {
        guard let index = Int(raw), index > 0, index <= count else { return nil }
        return index - 1
    }

    static func didClose(windowID: CGWindowID, pid: pid_t, windowInfo: [[String: Any]]?) -> Bool? {
        isWindowAbsent(windowID: windowID, pid: pid, windowInfo: windowInfo)
    }

    static func didMinimize(windowID: CGWindowID, pid: pid_t, windowInfo: [[String: Any]]?) -> Bool {
        isWindowAbsent(windowID: windowID, pid: pid, windowInfo: windowInfo) == true
    }

    static func permitsCommand(_ record: WindowRecord, pid: pid_t, windowID: CGWindowID?, element: AXUIElement?,
                               reader: AXWindowReader = AXWindowReader(),
                               system: any WindowSystemAccess = NativeWindowSystem()) -> Bool {
        guard pid == record.pid, windowID == record.cgWindowID, let element else { return false }
        return WindowCommandIdentity.validate(record, element: element, reader: reader, system: system)
    }

    static func restoredWindow(
        in observations: [AnalyzedObservation], identity: WindowID, pid: pid_t,
        confirmsWindow: (CGWindowID) -> Bool
    ) -> AnalyzedObservation? {
        observations.first { candidate in
            let observation = candidate.observation
            guard observation.source == .coreGraphics, observation.kind != .disappeared,
                  observation.pid == pid, let number = observation.cgWindowID, number != kCGNullWindowID,
                  candidate.identity.kind != .ambiguous, candidate.identity.windowID == identity else { return false }
            return confirmsWindow(number)
        }
    }

    static func analyzeRestoration(
        _ observations: [SystemObservation], for record: WindowRecord, using identity: WindowIdentityEngine,
        confirmsWindow: (CGWindowID) -> Bool
    ) -> (observations: [AnalyzedObservation], match: AnalyzedObservation?) {
        func currentNumber(_ observation: SystemObservation) -> CGWindowID? {
            guard observation.source == .coreGraphics, observation.kind != .disappeared, !observation.isMinimized,
                  observation.pid == record.pid, let number = observation.cgWindowID, number != kCGNullWindowID else {
                return nil
            }
            return number
        }
        let confirmed = Set(observations.compactMap(currentNumber)).sorted().filter(confirmsWindow)
        let restoredNumber = confirmed.count == 1 ? confirmed.first : nil
        let oldNumber: CGWindowID?
        if let restoredNumber, let restored = observations.first(where: { currentNumber($0) == restoredNumber }),
           identity.bindConfirmedRestoration(observation: restored, of: record) {
            oldNumber = record.cgWindowID
        } else {
            oldNumber = nil
        }
        let analyzed = observations.compactMap { observation -> AnalyzedObservation? in
            if let oldNumber, observation.source == .accessibility, observation.kind == .disappeared,
               observation.pid == record.pid, observation.cgWindowID == oldNumber {
                return nil
            }
            return AnalyzedObservation(observation: observation, identity: identity.identify(observation: observation))
        }
        let match = restoredWindow(in: analyzed, identity: record.id, pid: record.pid) { $0 == restoredNumber }
        return (analyzed, match)
    }

    static func diagnosticLine(_ value: String) -> String {
        let singleLine = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        return singleLine.unicodeScalars.map { scalar in
            if scalar.properties.generalCategory == .control {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
    }

    private static func isWindowAbsent(windowID: CGWindowID, pid: pid_t, windowInfo: [[String: Any]]?) -> Bool? {
        guard let windowInfo else { return nil }
        for info in windowInfo {
            guard let id = nativeWindowNumber(in: info) else { return nil }
            guard id == windowID else { continue }
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            if owner == pid { return false }
        }
        return true
    }

    static func mode(_ arguments: [String]) throws -> LabMode {
        guard let value = arguments.first, let mode = LabMode(rawValue: value) else { throw WindowLabInputError.invalidMode }
        switch mode {
        case .observe:
            guard arguments.count == 1 else { throw WindowLabInputError.unexpectedArguments(mode) }
        case .closeTarget, .minimizeRestore:
            guard arguments.count <= 2 else { throw WindowLabInputError.invalidSelectorArguments }
        case .replay, .placementReplay, .transitionReplay:
            guard arguments.count <= 2 else { throw WindowLabInputError.unexpectedArguments(mode) }
        }
        return mode
    }

    static func scenarioURL(root: URL, name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw WindowLabInputError.invalidScenarioName
        }
        return root.appendingPathComponent("Tools/DeskMoteWindowLab/ReplayFixtures/\(name).json")
    }

    static func bounds(_ raw: String?) throws -> CGRect? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0) }
        guard parts.count == 4, values.count == 4 else { throw WindowLabInputError.invalidGeometry }
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard WindowFrameMatchPolicy.isValid(frame) else { throw WindowLabInputError.invalidGeometry }
        return frame
    }
}


extension WindowLabInput {
    static func requireUniqueWindowIDs(_ ids: [String]) throws {
        guard ids.count <= 10_000, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw WindowLabInputError.duplicateWindowID
        }
    }

    static func decode<Scenario: Decodable>(_ type: Scenario.Type, from url: URL) throws -> Scenario {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else { throw WindowLabInputError.invalidScenario }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
