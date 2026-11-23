import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

func expectNear(_ actual: Double?, _ expected: Double, _ message: String) throws {
    try expect(actual.map { abs($0 - expected) < 0.001 } == true, message)
}

struct TestCase: Sendable {
    let name: String
    let run: @Sendable () throws -> Void
}
