import Synchronization
import XCTest

final class DebugSwitchTests: XCTestCase {
    func testKillSwitchIsOnUnlessExplicitlyZero() {
        let s = DebugSwitch.axElementCache
        XCTAssertEqual(s.kind, .killSwitch)
        XCTAssertTrue(s.isEnabled(in: [:]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "false"]), "Only the literal \"0\" disables this option")
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "0"]))
    }

    func testTraceIsOffUnlessExplicitlyOne() {
        let s = DebugSwitch.hoverTrace
        XCTAssertEqual(s.kind, .trace)
        XCTAssertFalse(s.isEnabled(in: [:]))
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "true"]), "Only the literal \"1\" enables this option")
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
    }

    func testValueReturnsRawStringOrNil() {
        let s = DebugSwitch.reconcileAxTimeoutMs
        XCTAssertEqual(s.kind, .value)
        XCTAssertNil(s.value(in: [:]))
        XCTAssertEqual(s.value(in: [s.rawValue: " 250 "]), " 250 ")
    }

    func testEveryCaseHasDockPrefixAndUniqueRawValue() {
        let raws = DebugSwitch.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for raw in raws { XCTAssertTrue(raw.hasPrefix("DOCK_"), raw) }
    }
}

#if DEBUG
final class ClickLatencyTraceTests: XCTestCase {
    func testCancelledCaptureCannotWriteStagesToReplacementTrace() async throws {
        let journal = Mutex<[Data]>([])
        let trace = ClickLatencyTrace.Runtime(writeLine: { line in journal.withLock { $0.append(line) } })
        let windowID = "fixture-window"
        let original = UUID()
        let replacement = UUID()
        let captureStarted = expectation(description: "capture started")
        let releaseCapture = DispatchSemaphore(value: 0)
        defer { releaseCapture.signal() }
        let cancellation = OperationCancellation()

        trace.begin(windowID: windowID, token: original, kind: "activateWindow", status: "inactive", bundleID: nil, at: 10)
        let blocked = Task {
            await AsyncWorkScope.performBlocking(cancellation: cancellation) {
                XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
                return trace.withOperation(windowID: windowID, token: original) {
                    captureStarted.fulfill()
                    guard releaseCapture.wait(timeout: .now() + 3) == .success else { return false }
                    ClickLatencyTrace.markCurrent("handle", detail: "fallback")
                    ClickLatencyTrace.markCurrent("earlyFocus")
                    return true
                }
            }
        }
        await fulfillment(of: [captureStarted], timeout: 2)
        cancellation.cancel()
        trace.begin(windowID: windowID, token: replacement, kind: "minimizeWindow", status: "active", bundleID: nil, at: 11)
        releaseCapture.signal()
        let completed = await blocked.value
        XCTAssertEqual(completed, true)

        trace.end(windowID: windowID, token: original, success: false, at: 12)
        trace.mark(windowID: windowID, token: replacement, stage: "execStart", detail: nil, at: 13)
        let replacementCompleted = await AsyncWorkScope.performBlocking {
            trace.withOperation(windowID: windowID, token: replacement) {
                ClickLatencyTrace.markCurrent("verified", detail: "replacement")
                return true
            }
        }
        XCTAssertEqual(replacementCompleted, true)
        trace.end(windowID: windowID, token: replacement, success: true, at: 14)
        trace.flush()

        let lines = journal.withLock { $0 }
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(record["kind"] as? String, "minimizeWindow")
        XCTAssertEqual(record["success"] as? Bool, true)
        XCTAssertEqual(record["execStartMs"] as? Double, 2000)
        XCTAssertEqual(record["verifiedDetail"] as? String, "replacement")
        XCTAssertNil(record["handleMs"])
        XCTAssertNil(record["handleDetail"])
        XCTAssertNil(record["earlyFocusMs"])
    }

    func testReplacementTraceFinishesWhenOriginalTraceNeverEnds() throws {
        let journal = Mutex<[Data]>([])
        let trace = ClickLatencyTrace.Runtime(writeLine: { line in journal.withLock { $0.append(line) } })
        let windowID = "fixture-window"
        let original = UUID()
        let replacement = UUID()

        trace.begin(windowID: windowID, token: original, kind: "activateWindow", status: "inactive", bundleID: nil, at: 10)
        trace.mark(windowID: windowID, token: original, stage: "handle", detail: "cached", at: 11)
        trace.begin(windowID: windowID, token: replacement, kind: "minimizeWindow", status: "active", bundleID: nil, at: 12)
        trace.end(windowID: windowID, token: replacement, success: true, at: 13)
        trace.flush()

        let lines = journal.withLock { $0 }
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(record["kind"] as? String, "minimizeWindow")
        XCTAssertEqual(record["totalMs"] as? Double, 1000)
        XCTAssertNil(record["handleDetail"])
    }
}
#endif
