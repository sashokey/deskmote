import Darwin
import Foundation
import Synchronization
import WidgetKit

enum WidgetRecovery {
    static func run() {
        guard let executable = Bundle.main.builtInPlugInsURL
            .flatMap({ Bundle(url: $0.appendingPathComponent("DeskMoteWidgets.appex")) })?
            .executableURL?.resolvingSymlinksInPath(),
            recover(executable: executable) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func recover(executable: URL,
                        readProcesses: ([String]) -> String? = mappedExecutables,
                        stopProcess: (pid_t, String) -> Bool = stopStaleProcess) -> Bool {
        let path = executable.path
        guard let inode = fileInode(at: path) else { return true }
        guard let records = readProcesses(["-c", String(executable.lastPathComponent.prefix(15))]) else { return false }
        let stopped = staleProcesses(in: records, executablePath: path, inode: inode).map { stopProcess($0, path) }
        return stopped.allSatisfy { $0 }
    }

    static func staleProcesses(in records: String, executablePath: String, inode: UInt64) -> Set<pid_t> {
        let encodedPath = lsofPath(executablePath)
        var stale: Set<pid_t> = []
        var pid: pid_t?
        var mappedInode: UInt64?

        for rawField in records.split(separator: "\0") {
            let field = rawField.first == "\n" ? rawField.dropFirst() : rawField
            switch field.first {
            case "p":
                pid = pid_t(field.dropFirst())
                mappedInode = nil
            case "f":
                mappedInode = nil
            case "i":
                mappedInode = UInt64(field.dropFirst())
            case "n":
                if let pid, pid > 1, let mappedInode, mappedInode != inode,
                   field.dropFirst() == encodedPath {
                    stale.insert(pid)
                }
            default:
                break
            }
        }
        return stale
    }

    private static func lsofPath(_ path: String) -> String {
        path.utf8.map { byte in
            switch byte {
            case 8: "\\b"
            case 9: "\\t"
            case 10: "\\n"
            case 12: "\\f"
            case 13: "\\r"
            case 0...31: "^" + String(UnicodeScalar(byte + 64))
            case 92: "\\\\"
            case 32...126: String(UnicodeScalar(byte))
            case 255: "^?"
            default: String(format: "\\x%02x", byte)
            }
        }.joined()
    }

    private static func stopStaleProcess(_ pid: pid_t, at path: String) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        watcher.setEventHandler { exited.signal() }
        watcher.activate()
        defer { watcher.cancel() }

        guard let records = mappedExecutables(matching: ["-p", String(pid)]) else {
            return exited.wait(timeout: .now()) == .success
        }
        var processPath = [CChar](repeating: 0, count: 4096)
        guard let inode = fileInode(at: path),
              staleProcesses(in: records, executablePath: path, inode: inode).contains(pid),
              proc_pidpath(pid, &processPath, UInt32(processPath.count)) > 0,
              String(decoding: processPath.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self) == path,
              exited.wait(timeout: .now()) == .timedOut else { return true }

        guard kill(pid, SIGTERM) == 0 else { return errno == ESRCH }
        return exited.wait(timeout: .now() + 2) == .success
    }

    private static func fileInode(at path: String) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func mappedExecutables(matching filters: [String]) -> String? {
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        let arguments = ["-nP", "-a", "-u", String(getuid()), "-d", "txt", "-F0pfin"] + filters
        guard let result = readProcessOutput(executable: executable, arguments: arguments, timeout: 3),
              result.status == 0 || (result.status == 1 && result.data.isEmpty && !result.hadDiagnostics) else { return nil }
        return String(decoding: result.data, as: UTF8.self)
    }

    static func readProcessOutput(executable: URL, arguments: [String], timeout: TimeInterval)
        -> (data: Data, status: Int32, hadDiagnostics: Bool)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["LC_ALL": "C"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return nil
        }
        let completed = DispatchSemaphore(value: 0)
        let result = Mutex<(Data, Int32, Bool)?>(nil)
        let diagnostics = Mutex(false)
        let stderrFinished = DispatchGroup()
        stderrFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { stderrFinished.leave() }
            let file = errors.fileHandleForReading
            defer { try? file.close() }
            do {
                while let chunk = try file.read(upToCount: 4096), !chunk.isEmpty {
                    diagnostics.withLock { $0 = true }
                }
            } catch {
                diagnostics.withLock { $0 = true }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            defer { completed.signal() }
            let file = output.fileHandleForReading
            defer { try? file.close() }
            var data = Data()
            do {
                while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard data.count + chunk.count <= 4 * 1024 * 1024 else {
                        if process.isRunning { process.terminate() }
                        return
                    }
                    data.append(chunk)
                }
            } catch {
                if process.isRunning { process.terminate() }
                return
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit else { return }
            stderrFinished.wait()
            result.withLock { $0 = (data, process.terminationStatus, diagnostics.withLock { $0 }) }
        }
        guard completed.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        return result.withLock { $0 }
    }
}
