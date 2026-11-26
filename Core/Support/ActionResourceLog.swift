#if DEBUG
import Darwin
import Foundation
import os
import Synchronization

enum ActionResourceLog {
    struct Sample {
        let wallTicks: UInt64
        let cpuTicks: UInt64?
        let footprintBytes: UInt64?

        static func capture() -> Self {
            let wallTicks = mach_absolute_time()
            var usage = rusage_info_v0()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
                }
            }
            guard status == 0 else {
                return Self(wallTicks: wallTicks, cpuTicks: nil, footprintBytes: nil)
            }
            let (cpu, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
            return Self(wallTicks: wallTicks, cpuTicks: overflow ? nil : cpu, footprintBytes: usage.ri_phys_footprint)
        }
    }

    struct Delta {
        let elapsedMilliseconds: Double?
        let cpuMilliseconds: Double?
        let cpuPercentOneCore: Double?
        let footprintDeltaBytes: Int64?

        init(before: Sample, after: Sample, nanosecondsPerTick: Double?) {
            let wallTicks = Self.difference(after.wallTicks, before.wallTicks)
            let cpuTicks = Self.difference(after.cpuTicks, before.cpuTicks)
            elapsedMilliseconds = Self.milliseconds(wallTicks, nanosecondsPerTick: nanosecondsPerTick)
            cpuMilliseconds = Self.milliseconds(cpuTicks, nanosecondsPerTick: nanosecondsPerTick)
            if let wallTicks, wallTicks > 0, let cpuTicks {
                cpuPercentOneCore = Double(cpuTicks) * 100 / Double(wallTicks)
            } else {
                cpuPercentOneCore = nil
            }
            if let before = before.footprintBytes, let after = after.footprintBytes {
                footprintDeltaBytes = after >= before
                    ? Int64(clamping: after - before)
                    : -Int64(clamping: before - after)
            } else {
                footprintDeltaBytes = nil
            }
        }

        private static func difference(_ after: UInt64?, _ before: UInt64?) -> UInt64? {
            guard let after, let before, after >= before else { return nil }
            return after - before
        }

        private static func milliseconds(_ ticks: UInt64?, nanosecondsPerTick: Double?) -> Double? {
            guard let ticks, let nanosecondsPerTick else { return nil }
            return Double(ticks) * nanosecondsPerTick / 1_000_000
        }
    }

    final class Span: Sendable {
        private let operation: String
        private let correlation: String
        private let before: Sample
        private let interval: OSSignpostIntervalState?
        private let traceID: UInt64?
        private let finished = Mutex(false)

        fileprivate init(operation: String, correlation: String?) {
            self.operation = operation
            self.correlation = correlation ?? "-"
            before = Sample.capture()
            let signposter = ActionResourceLog.signposter
            if signposter.isEnabled {
                let id = signposter.makeSignpostID()
                traceID = id.rawValue
                interval = signposter.beginInterval("DeskMote Action", id: id,
                    "operation=\(operation, privacy: .public) correlation=\(self.correlation, privacy: .public)")
            } else {
                interval = nil
                traceID = nil
            }
        }

        func finish() {
            guard finished.withLock({ value in
                guard !value else { return false }
                value = true
                return true
            }) else { return }

            let after = Sample.capture()
            if let interval {
                ActionResourceLog.signposter.endInterval("DeskMote Action", interval)
            }
            let delta = Delta(before: before, after: after, nanosecondsPerTick: ActionResourceLog.nanosecondsPerTick)
            let elapsed = Self.decimal(delta.elapsedMilliseconds)
            let cpu = Self.decimal(delta.cpuMilliseconds)
            let percent = Self.decimal(delta.cpuPercentOneCore)
            let footprintBefore = before.footprintBytes.map { String($0) } ?? "unavailable"
            let footprintAfter = after.footprintBytes.map { String($0) } ?? "unavailable"
            let footprintDelta = delta.footprintDeltaBytes.map { String($0) } ?? "unavailable"
            let trace = traceID.map { String($0) } ?? "-"
            ActionResourceLog.logger.notice("operation=\(self.operation, privacy: .public) correlation=\(self.correlation, privacy: .public) scope=process elapsed-ms=\(elapsed, privacy: .public) cpu-ms=\(cpu, privacy: .public) cpu-percent-one-core=\(percent, privacy: .public) footprint-before-bytes=\(footprintBefore, privacy: .public) footprint-after-bytes=\(footprintAfter, privacy: .public) footprint-delta-bytes=\(footprintDelta, privacy: .public) gpu-ms=unavailable gpu-percent=unavailable trace-id=\(trace, privacy: .public)")
        }

        private static func decimal(_ value: Double?) -> String {
            value.map { String(($0 * 1_000).rounded() / 1_000) } ?? "unavailable"
        }
    }

    private static let enabled = Bundle.main.bundleIdentifier == ApplicationIdentity.properWMDevelopmentIdentifier
    private static let subsystem = ApplicationIdentity.properWMIdentifier
    private static let logger = Logger(subsystem: subsystem, category: "action-resources")
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    private static let nanosecondsPerTick: Double? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return nil }
        return Double(info.numer) / Double(info.denom)
    }()

    static func begin(_ operation: String, correlation: String? = nil) -> Span? {
        guard enabled else { return nil }
        return Span(operation: operation, correlation: correlation)
    }
}
#endif
