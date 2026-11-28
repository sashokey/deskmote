import Darwin
import Foundation
import Synchronization

enum ProcessLiveness {
    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return interpret(result: kill(pid, 0), errorCode: errno)
    }

    static func interpret(result: Int32, errorCode: Int32) -> Bool {
        if result == 0 { return true }
        return errorCode != ESRCH
    }

    static func startTime(pid: pid_t) -> timeval? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}

final class ProcessGenerationCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let startTime: timeval
        let value: Value
        let sequence: UInt64
    }

    private struct Storage: Sendable {
        var entries: [pid_t: Entry] = [:]
        var sequence: UInt64 = 0

        mutating func store(_ value: Value, for pid: pid_t, startTime: timeval, capacity: Int) {
            sequence &+= 1
            entries[pid] = Entry(startTime: startTime, value: value, sequence: sequence)
            while entries.count > capacity, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                entries[oldest] = nil
            }
        }
    }

    private let storage = Mutex(Storage())
    private let capacity: Int
    private let startTime: @Sendable (pid_t) -> timeval?

    init(capacity: Int = 512, startTime: @escaping @Sendable (pid_t) -> timeval? = ProcessLiveness.startTime(pid:)) {
        self.capacity = max(0, capacity)
        self.startTime = startTime
    }

    func remember(_ value: Value, for pid: pid_t) {
        guard capacity > 0 else { return }
        let sequence = storage.withLock { $0.entries[pid]?.sequence }
        let start = startTime(pid)
        if sequence == nil, start != nil { pruneExpired() }
        let wasEvicted = storage.withLock { state in
            guard state.entries[pid]?.sequence == sequence else { return state.entries[pid] == nil }
            if let start {
                state.store(value, for: pid, startTime: start, capacity: capacity)
            } else {
                state.entries[pid] = nil
            }
            return false
        }
        guard wasEvicted, let start, let current = startTime(pid), Self.matches(start, current) else { return }
        storage.withLock { state in
            guard state.entries[pid] == nil else { return }
            state.store(value, for: pid, startTime: start, capacity: capacity)
        }
    }

    func value(for pid: pid_t) -> Value? {
        guard let sequence = storage.withLock({ $0.entries[pid]?.sequence }) else { return nil }
        let start = startTime(pid)
        return storage.withLock { state in
            guard let entry = state.entries[pid] else { return nil }
            guard let start, Self.matches(entry.startTime, start) else {
                if entry.sequence == sequence { state.entries[pid] = nil }
                return nil
            }
            return entry.value
        }
    }

    private func pruneExpired() {
        let entries = storage.withLock { $0.entries }
        let expired = entries.filter { pid, entry in
            guard let current = startTime(pid) else { return true }
            return !Self.matches(entry.startTime, current)
        }
        storage.withLock { state in
            for (pid, entry) in expired where state.entries[pid]?.sequence == entry.sequence {
                state.entries[pid] = nil
            }
        }
    }

    private static func matches(_ lhs: timeval, _ rhs: timeval) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_usec == rhs.tv_usec
    }

    #if DESKMOTE_TEST
    var countForTesting: Int { storage.withLock { $0.entries.count } }
    #endif
}
