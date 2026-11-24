import Foundation

@main
struct CheckWidgetRecovery {
    static func main() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let attributes = try! FileManager.default.attributesOfItem(atPath: executable.path)
        let inode = (attributes[.systemFileNumber] as! NSNumber).uint64Value
        let stale = [101, 102].map { pid in "p\(pid)\0\nftxt\0i\(inode &+ 1)\0n\(executable.path)\0\n" }.joined()
        var stopped: [pid_t] = []
        let recovered = WidgetRecovery.recover(executable: executable, readProcesses: { _ in stale },
                                               stopProcess: { pid, _ in
            stopped.append(pid)
            return stopped.count > 1
        })
        precondition(!recovered)
        precondition(Set(stopped) == [101, 102], "A failed stop must not skip other stale processes")
        precondition(!WidgetRecovery.recover(executable: executable, readProcesses: { _ in nil },
                                             stopProcess: { _, _ in preconditionFailure() }),
                     "A failed scan must not be treated as a confirmed empty scan")
        var failures = 0
        func check(_ success: Bool, _ name: String) {
            if !success {
                print("FAILED: \(name)")
                failures += 1
            }
        }
        let recordsForCurrentExecutable = "p101\0\nftxt\0i\(inode)\0n\(executable.path)\0\n"
        let valid = [
            ("empty lsof output", ""),
            ("complete current mapping", recordsForCurrentExecutable),
            ("complete text mappings for unrelated paths", "p101\0\nftxt\0i13\0n/tmp/other\0\nftxt\0i14\0n/tmp/loader\0\n"),
            ("a path with the same prefix", "p101\0\nftxt\0i13\0n\(executable.path).backup\0\n")
        ]
        for (name, scan) in valid {
            check(WidgetRecovery.recover(executable: executable, readProcesses: { _ in scan },
                                         stopProcess: { _, _ in preconditionFailure() }), name)
        }
        let unusualPath = #"/Applications/Utilities\Tools/DeskMoteWidgets"#
        let escapedPath = #"/Applications/Utilities\\Tools/DeskMoteWidgets"#
        var stoppedEscapedPath = false
        check(WidgetRecovery.recover(executable: URL(fileURLWithPath: unusualPath), readInode: { _ in 456 },
            readProcesses: { _ in "p109\0\nftxt\0i123\0n\(escapedPath)\0\n" },
            stopProcess: { pid, path in
                stoppedEscapedPath = pid == 109 && path == unusualPath
                return true
            }) && stoppedEscapedPath, "lsof escaping must preserve an exact path match")
        check(!WidgetRecovery.recover(executable: executable, readInode: { _ in nil },
            readProcesses: { _ in preconditionFailure() }, stopProcess: { _, _ in preconditionFailure() }),
            "missing installed inode is uncertain")
        let invalid = [
            ("unreadable region in NAME", "p101\0\nftxt\0nregion info error: Operation not permitted\0\n"),
            ("diagnostic NAME beside a valid inode", "p101\0\nftxt\0i13\0nregion info error: Input/output error\0\n"),
            ("mount fallback in NAME", "p101\0\nftxt\0i13\0n/System/Volumes/Data (/dev/disk3s5)\0\n"),
            ("missing NAME", "p101\0\nftxt\0i13\0\n"),
            ("missing inode", "p101\0\nftxt\0n\(executable.path)\0\n"),
            ("invalid inode", "p101\0\nftxt\0iinvalid\0n\(executable.path)\0\n"),
            ("invalid PID", "pinvalid\0\nftxt\0i13\0n/tmp/loader\0\n"),
            ("missing file set", "p101\0\n"),
            ("incomplete final set", recordsForCurrentExecutable + "p102\0\nftxt\0i13"),
            ("duplicated NAME", "p101\0\nftxt\0i13\0n/tmp/loader\0n/tmp/other\0\n"),
            ("mixed current and stale mappings", recordsForCurrentExecutable + "ftxt\0i\(inode &+ 1)\0n\(executable.path)\0\n"),
            ("embedded record delimiter in NAME", "p101\0\nftxt\0i13\0n/tmp/other\np107\ni13\nn\(executable.path)\0\n")
        ]
        for (name, scan) in invalid {
            var signaled = false
            let result = WidgetRecovery.recover(executable: executable, readProcesses: { _ in scan },
                                                stopProcess: { _, _ in signaled = true; return true })
            check(!result && !signaled, name)
        }
        let exactStaleMapping = "p101\0\nftxt\0i\(inode &+ 1)\0n\(executable.path)\0\n"
        let diagnostic = "p101\0\nftxt\0nregion info error: Operation not permitted\0\n"
        let revalidations: [(name: String, records: String?, fileInode: UInt64?, path: String?,
                             exited: Bool, result: Bool, signal: Bool)] = [
            ("complete stale identity", exactStaleMapping, inode, executable.path, false, true, true),
            ("complete current identity", recordsForCurrentExecutable, inode, executable.path, false, true, false),
            ("positively distinct executable", diagnostic, nil, "/tmp/different", false, true, false),
            ("confirmed exit", diagnostic, nil, nil, true, true, false),
            ("scan failed without exit", nil, inode, executable.path, false, false, false),
            ("successful empty scan without exit", "", inode, executable.path, false, false, false),
            ("incomplete scan without exit", diagnostic, inode, executable.path, false, false, false),
            ("unexpected PID in revalidation", exactStaleMapping + "p102\0\nftxt\0i13\0n/tmp/other\0\n",
             inode, executable.path, false, false, false),
            ("unknown executable identity", exactStaleMapping, inode, nil, false, false, false),
            ("unknown file identity", exactStaleMapping, nil, executable.path, false, false, false)
        ]
        for item in revalidations {
            var signaled = false
            let result = WidgetRecovery.stopStaleProcess(101, at: executable.path,
                readProcesses: { item.records }, readInode: { item.fileInode },
                readPath: { item.path }, hasExited: { item.exited }, terminate: {
                    signaled = true
                    return true
                })
            check(result == item.result && signaled == item.signal, item.name)
        }
        var exitChecks = 0
        var signaledAfterExit = false
        let recoveredAfterExit = WidgetRecovery.stopStaleProcess(101, at: executable.path,
            readProcesses: { exactStaleMapping }, readInode: { inode }, readPath: { executable.path },
            hasExited: {
                exitChecks += 1
                return exitChecks == 2
            }, terminate: {
                signaledAfterExit = true
                return false
            })
        check(recoveredAfterExit && !signaledAfterExit && exitChecks == 2,
              "a stale PID exiting during revalidation must not receive a signal")
        if failures > 0 { exit(1) }

        if !CommandLine.arguments.contains("--fixtures-only") {
            let echo = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/echo"),
                                                        arguments: ["fixture"], timeout: 3)
            precondition(echo?.data == Data("fixture\n".utf8) && echo?.status == 0)
            let errors = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf failure >&2; exit 1"], timeout: 3)
            precondition(errors?.status == 1 && errors?.data.isEmpty == true && errors?.hadDiagnostics == true)
            let stalled = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                           arguments: ["3"], timeout: 0.1)
            precondition(stalled == nil, "A stalled scan must not delay widget recovery indefinitely")
        }
        print("Widget recovery checks passed")
    }
}
