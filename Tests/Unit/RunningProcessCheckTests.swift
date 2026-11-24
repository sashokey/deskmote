import Darwin
import Foundation
import Synchronization
import XCTest

final class ProcessLivenessTests: XCTestCase {

    func testInvalidPIDsAreNeverPassedThroughAsAlive() {
        XCTAssertFalse(ProcessLiveness.isAlive(pid: 0))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: -1))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: -42))
        XCTAssertNil(ProcessLiveness.startTime(pid: 0))
        XCTAssertNil(ProcessLiveness.startTime(pid: -1))
    }


    func testInterpretSyscallSuccessIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: 0, errorCode: 0))
    }

    func testInterpretESRCHIsDead() {
        XCTAssertFalse(ProcessLiveness.interpret(result: -1, errorCode: ESRCH))
    }

    func testInterpretEPERMIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EPERM))
    }

    func testInterpretEINTRIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EINTR))
    }

    func testInterpretEINVALIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EINVAL))
    }

    func testInterpretEAGAINIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EAGAIN))
    }

    func testInterpretUnknownErrnoIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: 9999))
    }


    func testGenerationCacheServesOnlyTheSameProcessGeneration() {
        let starts = Mutex<[pid_t: timeval]>([42: timeval(tv_sec: 100, tv_usec: 5)])
        let cache = ProcessGenerationCache<String>(startTime: { pid in starts.withLock { $0[pid] } })
        XCTAssertNil(cache.value(for: 42))
        cache.remember("psn", for: 42)
        XCTAssertEqual(cache.value(for: 42), "psn")
        starts.withLock { $0[42] = timeval(tv_sec: 100, tv_usec: 6) }
        XCTAssertNil(cache.value(for: 42))
        starts.withLock { $0[42] = timeval(tv_sec: 100, tv_usec: 5) }
        XCTAssertNil(cache.value(for: 42))
        cache.remember("dead", for: 7)
        starts.withLock { $0[7] = timeval(tv_sec: 1, tv_usec: 0) }
        XCTAssertNil(cache.value(for: 7))
    }

    func testGenerationCacheSupportsConcurrentReadersAndWriters() {
        let cache = ProcessGenerationCache<Int>(startTime: { _ in timeval(tv_sec: 100, tv_usec: 0) })
        let mismatches = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 512) { index in
            let pid = pid_t(index + 1)
            cache.remember(index, for: pid)
            if cache.value(for: pid) != index {
                mismatches.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(mismatches.withLock { $0 }, 0)
        for index in 0..<512 {
            XCTAssertEqual(cache.value(for: pid_t(index + 1)), index)
        }
    }

    func testStaleGenerationReadCannotDeleteAConcurrentlyRememberedSerial() {
        let start = Mutex(timeval(tv_sec: 100, tv_usec: 5))
        let shouldBlock = Mutex(false)
        let captured = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let observed = Mutex<String?>(nil)
        let cache = ProcessGenerationCache<String>(startTime: { _ in
            let time = start.withLock { $0 }
            let block = shouldBlock.withLock {
                let block = $0
                $0 = false
                return block
            }
            if block {
                captured.signal()
                guard release.wait(timeout: .now() + 5) == .success else { return nil }
            }
            return time
        })
        cache.remember("previous serial", for: 42)
        shouldBlock.withLock { $0 = true }
        DispatchQueue.global().async {
            let value = cache.value(for: 42)
            observed.withLock { $0 = value }
            finished.signal()
        }
        XCTAssertEqual(captured.wait(timeout: .now() + 5), .success)
        start.withLock { $0 = timeval(tv_sec: 200, tv_usec: 10) }
        cache.remember("new serial", for: 42)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(observed.withLock { $0 })
        XCTAssertEqual(cache.value(for: 42), "new serial")
    }

    func testStaleRememberCannotReplaceOrDeleteAConcurrentlyRememberedSerial() {
        let initialTimes: [timeval?] = [timeval(tv_sec: 100, tv_usec: 5), nil]
        for initialTime in initialTimes {
            let start = Mutex(initialTime)
            let shouldBlock = Mutex(true)
            let captured = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let timedOut = Mutex(false)
            let cache = ProcessGenerationCache<String>(startTime: { _ in
                let time = start.withLock { $0 }
                let block = shouldBlock.withLock {
                    let block = $0
                    $0 = false
                    return block
                }
                if block {
                    captured.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
                }
                return time
            })
            DispatchQueue.global().async {
                cache.remember("previous serial", for: 42)
                finished.signal()
            }
            XCTAssertEqual(captured.wait(timeout: .now() + 5), .success)
            start.withLock { $0 = timeval(tv_sec: 200, tv_usec: 10) }
            cache.remember("new serial", for: 42)
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertFalse(timedOut.withLock { $0 })
            XCTAssertEqual(cache.value(for: 42), "new serial")
        }
    }

    func testRememberRecoversFromConcurrentEvictionOnlyWhileItsGenerationIsCurrent() {
        for generationChangesAgain in [false, true] {
            let start = Mutex(timeval(tv_sec: 100, tv_usec: 5))
            let shouldBlock = Mutex(false)
            let captured = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let timedOut = Mutex(false)
            let cache = ProcessGenerationCache<String>(startTime: { _ in
                let time = start.withLock { $0 }
                let block = shouldBlock.withLock {
                    let block = $0
                    $0 = false
                    return block
                }
                if block {
                    captured.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
                }
                return time
            })
            cache.remember("first serial", for: 42)
            start.withLock { $0 = timeval(tv_sec: 200, tv_usec: 10) }
            shouldBlock.withLock { $0 = true }
            DispatchQueue.global().async {
                cache.remember("second serial", for: 42)
                finished.signal()
            }

            XCTAssertEqual(captured.wait(timeout: .now() + 5), .success)
            XCTAssertNil(cache.value(for: 42))
            XCTAssertEqual(cache.countForTesting, 0)
            if generationChangesAgain {
                start.withLock { $0 = timeval(tv_sec: 300, tv_usec: 15) }
            }
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertFalse(timedOut.withLock { $0 })
            XCTAssertEqual(cache.countForTesting, generationChangesAgain ? 0 : 1)
            XCTAssertEqual(cache.value(for: 42), generationChangesAgain ? nil : "second serial")
        }
    }


    func testCurrentProcessIsAlive() {
        let pid = getpid()
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid))
    }

    func testReapedChildProcessIsDead() {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/true"),
            nil,
        ]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        let spawnResult = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, envp)
        XCTAssertEqual(spawnResult, 0, "posix_spawn of /usr/bin/true should succeed")

        var status: Int32 = 0
        let waitResult = waitpid(pid, &status, 0)
        XCTAssertEqual(waitResult, pid, "waitpid should reap the child")

        XCTAssertFalse(ProcessLiveness.isAlive(pid: pid))
    }
}
