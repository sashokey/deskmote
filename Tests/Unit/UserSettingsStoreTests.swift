import XCTest

@MainActor
final class LegacyLaunchSettingsTests: XCTestCase {
    func testSelectingLoginRechecksForApprovalAfterPublishingAnEnabledState() async throws {
        let service = StoreRegressionLoginService()
        let coordinator = SettingsCoordinator(launchAtLoginService: service)
        let initialAccepted = await coordinator.refreshLaunchAtLoginState()
        XCTAssertTrue(initialAccepted)
        XCTAssertEqual(coordinator.launchAtLoginState, .on)

        service.state = .requiresApproval
        let result = await coordinator.selectLaunchAtLogin()
        try result.get()
        XCTAssertEqual(coordinator.launchAtLoginState, .requiresApproval)
        XCTAssertTrue(service.registrationRequests.isEmpty)
        XCTAssertEqual(service.settingsOpens, 1)
    }
}

@MainActor
private final class StoreRegressionLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState = .on
    private(set) var registrationRequests: [Bool] = []
    private(set) var settingsOpens = 0

    func currentState() async -> LaunchAtLoginState { state }
    func setEnabled(_ enabled: Bool) throws { registrationRequests.append(enabled) }
    func openSystemSettings() { settingsOpens += 1 }
}
