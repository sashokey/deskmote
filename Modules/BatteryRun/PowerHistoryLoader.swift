import Foundation
import Darwin

enum PowerHistoryLoader {
    private static let queue = DispatchQueue(label: "DeskMote.BatteryRun.PowerHistory", qos: .utility)

    static func loadSnapshot(
        readJournal: @escaping @Sendable () -> String?,
        readWatts: @escaping @Sendable () -> PowerWatts
    ) async -> BatteryDisplaySnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let report = readJournal().map { PowerHistory(from: $0, before: Date()).batteryReport() }
                continuation.resume(returning: BatteryDisplaySnapshot(report: report, watts: readWatts()))
            }
        }
    }

    static func run(executable: URL = URL(fileURLWithPath: "/usr/bin/pmset"), arguments: [String] = ["-g", "log"], timeout: TimeInterval = 5, limit: Int = 16 * 1024 * 1024) -> String? {
        guard timeout > 0, limit > 0 else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? pipe.fileHandleForReading.close()
        }
        var data = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard data.count + chunk.count <= limit else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return nil
                }
                data.append(chunk)
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
