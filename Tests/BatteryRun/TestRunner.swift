import Foundation
import AppKit

@main
struct TestRunner {
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        var tests = journalProjectionTests + reportedWattsTests + runtimeTests + journalRefreshTests + journalAppKitTests
        if CommandLine.arguments.contains("--without-battery") {
            print("SKIP physical IOKit battery check (hardware-free run)")
        } else {
            tests += batteryHardwareTests
        }
        if let filter = CommandLine.arguments.first(where: { $0.hasPrefix("--filter=") }) {
            let prefix = filter.dropFirst("--filter=".count)
            tests = tests.filter { !prefix.isEmpty && $0.name.hasPrefix(prefix) }
            guard !tests.isEmpty else { exit(2) }
        }
        for test in tests {
            do {
                try test.run()
                print("PASS \(test.name)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        exit(failures == 0 ? 0 : 1)
    }
}
