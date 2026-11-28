import Foundation

let runtimeTests = [
    TestCase(name: "history loader reads actual command output") {
        let output = PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["battery history"])
        try expect(output == "battery history", "successful subprocess output must be returned")
    },
    TestCase(name: "history loader rejects a failed subprocess") {
        try expect(PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil, "nonzero exit must not become valid history")
    },
    TestCase(name: "history loader bounds output memory") {
        try expect(PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["too much output"], limit: 4) == nil, "oversized history must fall back safely")
    },
    TestCase(name: "history loader kills a stalled command within its timeout") {
        let start = Date()
        let result = PowerHistoryLoader.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
        try expect(result == nil, "timeout must not return valid history")
        try expect(Date().timeIntervalSince(start) < 1, "timeout must stop the child rather than waiting five seconds")
    },
]
