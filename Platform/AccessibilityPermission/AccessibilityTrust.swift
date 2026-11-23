import ApplicationServices
import Foundation

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
