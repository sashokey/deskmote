import ApplicationServices
import Foundation
import OSLog
import Synchronization

final class RuntimeAccessibilityAccess: Sendable {
    private struct State {
        var trusted = true
        var apiDisabled = false
        var generation: UInt64 = 0

        var allowsCalls: Bool { trusted && !apiDisabled }
    }

    static let shared = RuntimeAccessibilityAccess()
    private static let logger = Logger(subsystem: "io.github.sashokey.deskmote", category: "permissions")
    private let state = Mutex(State())

    var allowsCalls: Bool { state.withLock { $0.allowsCalls } }
    var trustGeneration: UInt64 { state.withLock { $0.generation } }
    private var admissionGeneration: UInt64? { state.withLock { $0.allowsCalls ? $0.generation : nil } }

    @discardableResult
    func updateTrust(_ trusted: Bool, for expectedGeneration: UInt64? = nil) -> Bool? {
        state.withLock {
            guard expectedGeneration == nil || expectedGeneration == $0.generation else { return nil }
            guard $0.trusted != trusted else { return false }
            $0.trusted = trusted
            $0.generation &+= 1
            if trusted { $0.apiDisabled = false }
            return true
        }
    }

    func checkTrust(_ read: () -> Bool) -> Bool {
        guard let generation = admissionGeneration else { return false }
        guard read() else {
            if updateTrust(false, for: generation) == true {
                Self.logger.notice("accessibility-runtime-disabled reason=native-trust-negative")
            }
            return false
        }
        return allowsCalls
    }

    func call<Result>(denied: Result, status: (Result) -> AXError, _ operation: () -> Result) -> Result {
        guard let generation = admissionGeneration else { return denied }
        let result = operation()
        if status(result) == .apiDisabled {
            let firstDenial = state.withLock {
                guard $0.generation == generation, !$0.apiDisabled else { return false }
                $0.apiDisabled = true
                return true
            }
            if firstDenial { Self.logger.notice("accessibility-runtime-disabled reason=native-api-disabled") }
        }
        return result
    }

    func call(_ operation: () -> AXError) -> AXError {
        call(denied: .apiDisabled, status: { $0 }, operation)
    }
}

struct PermissionService {
    private let trustCheck: () -> Bool
    private let promptRequest: () -> Bool
    private let readOnlyVolumeCheck: (URL) -> Bool?

    init(
        trustCheck: @escaping () -> Bool = AXIsProcessTrusted,
        promptRequest: @escaping () -> Bool = PermissionService.systemPromptRequest,
        readOnlyVolumeCheck: @escaping (URL) -> Bool? = PermissionService.systemReadOnlyVolumeCheck
    ) {
        self.trustCheck = trustCheck
        self.promptRequest = promptRequest
        self.readOnlyVolumeCheck = readOnlyVolumeCheck
    }

    func hasRequiredPermissions() -> Bool {
        trustCheck()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        promptRequest()
    }

    func isReadOnlyVolume(_ url: URL) -> Bool? {
        readOnlyVolumeCheck(url)
    }

    private static func systemPromptRequest() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func systemReadOnlyVolumeCheck(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
    }
}
