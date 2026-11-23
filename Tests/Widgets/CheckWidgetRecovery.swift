import Foundation

@main
struct CheckWidgetRecovery {
    static func main() {
        let path = "/Applications/DeskMote.app/Contents/PlugIns/DeskMoteWidgets.appex/Contents/MacOS/DeskMoteWidgets"
        let records = [
            "p101", "\nftxt", "i123", "n\(path)",
            "\np102", "\nftxt", "i456", "n\(path)",
            "\np103", "\nftxt", "i123", "n/tmp/Other.app/AirQualityWidget",
            "\np104", "\nftxt", "i123", "n\(path).backup",
            "\np105", "\nftxt", "n\(path)",
            "\np106", "\nftxt", "i123", "n/tmp/foreign\np107\ni123\nn\(path)",
            "\np108", "\nftxt", "i123", "n/tmp/loader", "\nftxt", "n\(path)"
        ].joined(separator: "\0")
        precondition(WidgetRecovery.staleProcesses(in: records, executablePath: path, inode: 456) == [101])
        precondition(WidgetRecovery.staleProcesses(in: "", executablePath: path, inode: 456).isEmpty)
        let unusual = #"/Applications/Utilities\Tools/DeskMoteWidgets"#
        let escaped = #"n/Applications/Utilities\\Tools/DeskMoteWidgets"#
        let escapedRecord = ["p109", "ftxt", "i123", escaped].joined(separator: "\0")
        precondition(WidgetRecovery.staleProcesses(in: escapedRecord, executablePath: unusual, inode: 456) == [109],
                     "A backslash in the installation path must match lsof output")

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let attributes = try! FileManager.default.attributesOfItem(atPath: executable.path)
        let inode = (attributes[.systemFileNumber] as! NSNumber).uint64Value
        let stale = [101, 102].flatMap { pid in ["p\(pid)", "ftxt", "i\(inode &+ 1)", "n\(executable.path)"] }
            .joined(separator: "\0")
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
        let echo = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/echo"),
                                                    arguments: ["fixture"], timeout: 3)
        precondition(echo?.data == Data("fixture\n".utf8) && echo?.status == 0)
        let errors = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf failure >&2; exit 1"], timeout: 3)
        precondition(errors?.status == 1 && errors?.data.isEmpty == true && errors?.hadDiagnostics == true)
        let stalled = WidgetRecovery.readProcessOutput(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                       arguments: ["3"], timeout: 0.1)
        precondition(stalled == nil, "A stalled scan must not delay widget recovery indefinitely")
        print("Widget recovery checks passed")
    }
}
