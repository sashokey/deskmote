import ApplicationServices
import Foundation
import Synchronization

final class RuntimeAccessibilityAccess: Sendable {
    enum Loss: Equatable, Sendable {
        case negativeProbe
        case nativeAPIDisabled
    }

    private struct State {
        var trusted: Bool
        var apiDisabled = false
        var generation: UInt64 = 0
        var onLoss: (@Sendable (Loss) -> Void)?

        var allowsCalls: Bool { trusted && !apiDisabled }
    }

    static let shared = RuntimeAccessibilityAccess()
    private let state: Mutex<State>

    init(initiallyTrusted: Bool = true) {
        state = Mutex(State(trusted: initiallyTrusted))
    }

    var allowsCalls: Bool { state.withLock { $0.allowsCalls } }
    var trustGeneration: UInt64 { state.withLock { $0.generation } }
    private var admissionGeneration: UInt64? { state.withLock { $0.allowsCalls ? $0.generation : nil } }

    func activateRuntime(onLoss: @escaping @Sendable (Loss) -> Void) {
        state.withLock {
            guard $0.onLoss == nil else { return }
            $0.onLoss = onLoss
            $0.trusted = true
            $0.apiDisabled = false
            $0.generation &+= 1
        }
    }

    func commitLoss(_ loss: Loss, for generation: UInt64) -> (@Sendable () -> Void)? {
        state.withLock {
            guard $0.generation == generation, $0.allowsCalls, let onLoss = $0.onLoss else { return nil }
            $0.trusted = false
            $0.apiDisabled = true
            $0.generation &+= 1
            return { onLoss(loss) }
        }
    }

    func acceptsResult(for generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation && $0.allowsCalls }
    }

    @discardableResult
    func updateTrust(_ trusted: Bool, for expectedGeneration: UInt64? = nil) -> Bool? {
        state.withLock {
            guard expectedGeneration == nil || expectedGeneration == $0.generation else { return nil }
            guard $0.onLoss == nil else { return false }
            guard $0.trusted != trusted else { return false }
            $0.trusted = trusted
            $0.generation &+= 1
            if trusted { $0.apiDisabled = false }
            return true
        }
    }

    func checkTrust(_ read: () -> Bool, retainStandaloneDenial: Bool = true) -> Bool {
        let (allowed, runtime, generation) = state.withLock { ($0.allowsCalls, $0.onLoss != nil, $0.generation) }
        guard allowed else { return false }
        if runtime { return true }
        guard read() else {
            if retainStandaloneDenial { updateTrust(false, for: generation) }
            return false
        }
        return acceptsResult(for: generation)
    }

    func call<Result>(denied: Result, status: (Result) -> AXError, _ operation: () -> Result) -> Result {
        guard let generation = admissionGeneration else { return denied }
        let result = operation()
        if status(result) == .apiDisabled {
            if let delivery = commitLoss(.nativeAPIDisabled, for: generation) {
                delivery()
            } else {
                state.withLock {
                    guard $0.onLoss == nil, $0.generation == generation, $0.allowsCalls else { return }
                    $0.apiDisabled = true
                    $0.generation &+= 1
                }
            }
        }
        return acceptsResult(for: generation) ? result : denied
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
