import Foundation
import AppKit

@main
struct TestRunner {
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        var tests = sessionTests + historyTests + batteryReaderTests + runtimeTests + monitorTests + dashboardTests + appKitTests
        if CommandLine.arguments.contains("--without-battery") {
            print("SKIP physical IOKit battery check (hardware-free run)")
        } else {
            tests += batteryHardwareTests
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
