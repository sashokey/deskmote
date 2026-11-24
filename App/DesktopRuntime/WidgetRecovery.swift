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
                        readInode: (String) -> UInt64? = fileInode,
                        readProcesses: ([String]) -> String? = mappedExecutables,
                        stopProcess: (pid_t, String) -> Bool = stopStaleProcess) -> Bool {
        let path = executable.path
        guard let inode = readInode(path),
              let records = readProcesses(["-c", String(executable.lastPathComponent.prefix(15))]),
              let mappings = textMappings(in: records, executablePath: path) else { return false }
        let stopped = mappings.filter { $0.value != inode }.keys.map { stopProcess($0, path) }
        return stopped.allSatisfy { $0 }
    }

    private static func textMappings(in records: String, executablePath: String,
                                     onlyPID: pid_t? = nil) -> [pid_t: UInt64]? {
        if records.isEmpty { return [:] }
        guard records.hasSuffix("\0\n") else { return nil }
        let encodedPath = lsofPath(executablePath)
        var mappings: [pid_t: UInt64] = [:]
        var seenPIDs: Set<pid_t> = []
        var pid: pid_t?
        var hasFile = false

        for set in records.dropLast().split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = set.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.last?.isEmpty == true else { return nil }
            if fields.count == 2, fields[0].first == "p" {
                guard (pid == nil || hasFile), let nextPID = pid_t(fields[0].dropFirst()), nextPID > 1,
                      onlyPID == nil || onlyPID == nextPID,
                      seenPIDs.insert(nextPID).inserted else { return nil }
                pid = nextPID
                hasFile = false
                continue
            }
            guard let pid, fields.count == 4, fields[0] == "ftxt",
                  fields[1].first == "i", let inode = UInt64(fields[1].dropFirst()), inode > 0,
                  fields[2].hasPrefix("n/"), fields[2].utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
            let name = fields[2].dropFirst()
            guard !name.hasSuffix(")") || !name.contains(" (") else { return nil }
            hasFile = true
            if name == encodedPath {
                guard mappings[pid] == nil || mappings[pid] == inode else { return nil }
                mappings[pid] = inode
            }
        }
        return hasFile ? mappings : nil
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

        return stopStaleProcess(pid, at: path,
                                readProcesses: { mappedExecutables(matching: ["-p", String(pid)]) },
                                readInode: { fileInode(at: path) },
                                readPath: { processPath(pid) },
                                hasExited: { exited.wait(timeout: .now()) == .success },
                                terminate: {
                                    guard kill(pid, SIGTERM) == 0 else { return errno == ESRCH }
                                    return exited.wait(timeout: .now() + 2) == .success
                                })
    }

    static func stopStaleProcess(_ pid: pid_t, at path: String,
                                 readProcesses: () -> String?, readInode: () -> UInt64?,
                                 readPath: () -> String?, hasExited: () -> Bool,
                                 terminate: () -> Bool) -> Bool {
        let records = readProcesses()
        let inode = readInode()
        let observedPath = readPath()
        if hasExited() { return true }
        guard let observedPath else { return false }
        if observedPath != path { return true }
        guard let inode, let records,
              let mappings = textMappings(in: records, executablePath: path, onlyPID: pid),
              let mappedInode = mappings[pid] else { return false }
        return mappedInode == inode || hasExited() || terminate()
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let bytes = path.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:))
        guard bytes.first == UInt8(ascii: "/") else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func fileInode(at path: String) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func mappedExecutables(matching filters: [String]) -> String? {
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        let arguments = ["-nP", "-a", "-u", String(getuid()), "-d", "txt", "-F0pfin"] + filters
        guard let result = readProcessOutput(executable: executable, arguments: arguments, timeout: 3),
              !result.hadDiagnostics,
              (result.status == 0 && !result.data.isEmpty) || (result.status == 1 && result.data.isEmpty) else { return nil }
        return String(data: result.data, encoding: .utf8)
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
