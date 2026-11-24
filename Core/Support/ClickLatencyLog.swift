#if DEBUG
import Foundation

enum ClickLatencyTrace {
    private static let currentOperation = TaskLocal<Operation?>(wrappedValue: nil)
    static let live: Runtime? = {
        guard DebugSwitch.clickTrace.isEnabled(in: ProcessInfo.processInfo.environment) else { return nil }
        let file = PrivateJSONLinesFile(directory: PrivateJSONLinesFile.liveDirectory, name: "click-latency.jsonl")
        return Runtime(writeLine: { try? file.append($0) })
    }()

    private struct Operation: Sendable {
        let runtime: Runtime
        let windowID: String
        let token: UUID
    }

    static func markCurrent(_ stage: String, detail: String? = nil) {
        guard let operation = currentOperation.get() else { return }
        operation.runtime.mark(windowID: operation.windowID, token: operation.token, stage: stage,
                               detail: detail)
    }

    final class Runtime: @unchecked Sendable {
        private let queue = BoundedDiagnosticQueue(label: "io.github.sashokey.deskmote.click-latency-trace")
        private let writeLine: @Sendable (Data) -> Void
        private var sessions: [String: Session] = [:]

        init(writeLine: @escaping @Sendable (Data) -> Void) {
            self.writeLine = writeLine
        }

        func flush() {
            queue.flush()
        }

        func withOperation<Result>(windowID: String, token: UUID, _ execute: () -> Result) -> Result {
            ClickLatencyTrace.currentOperation.withValue(.init(runtime: self, windowID: windowID, token: token),
                                                         operation: execute)
        }

        private struct Session {
            let token: UUID
            let kind: String
            let status: String
            let bundleID: String?
            let startedAt: TimeInterval
            var stages: [(String, TimeInterval, String?)] = []
        }

        func begin(windowID: String, token: UUID, kind: String, status: String, bundleID: String?,
                   at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            queue.submit { [self] in
                if sessions.count >= 128, let oldest = sessions.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                    sessions.removeValue(forKey: oldest)
                }
                sessions[windowID] = Session(token: token, kind: kind, status: status, bundleID: bundleID, startedAt: at)
            }
        }

        func mark(windowID: String, token: UUID, stage: String, detail: String? = nil,
                  at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            queue.submit { [self] in
                guard let session = sessions[windowID], session.token == token, session.stages.count < 32 else { return }
                sessions[windowID]?.stages.append((stage, at, detail))
            }
        }

        func end(windowID: String, token: UUID, success: Bool,
                 at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            queue.submit { [self] in
                guard sessions[windowID]?.token == token else { return }
                guard let session = sessions.removeValue(forKey: windowID) else { return }
                func ms(_ time: TimeInterval) -> DiagnosticValue { .number(((time - session.startedAt) * 100_000).rounded() / 100) }
                var fields: [String: DiagnosticValue] = ["kind": .text(session.kind), "status": .text(session.status),
                    "bundleID": session.bundleID.map(DiagnosticValue.text) ?? .null,
                    "success": .flag(success), "totalMs": ms(at)]
                for (stage, at, detail) in session.stages {
                    fields[stage + "Ms"] = ms(at)
                    if let detail { fields[stage + "Detail"] = .text(detail) }
                }
                if let data = DiagnosticJSON.line(fields) { writeLine(data) }
            }
        }
    }
}
#endif
