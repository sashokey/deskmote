import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
    @Published private(set) var launchAtLoginState: LaunchAtLoginState?

    private let store: AppSettingsStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private var launchRefreshGeneration: UInt64 = 0


    init(store: AppSettingsStore, launchAtLoginService: LaunchAtLoginServicing) {
        self.store = store
        self.launchAtLoginService = launchAtLoginService
    }

    @discardableResult
    func refreshLaunchAtLoginState() async -> Bool {
        launchRefreshGeneration &+= 1
        let generation = launchRefreshGeneration
        let next = await launchAtLoginService.currentState()
        guard !Task.isCancelled, generation == launchRefreshGeneration else { return false }
        if launchAtLoginState != next { launchAtLoginState = next }
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) -> Result<Void, Error> {
        launchRefreshGeneration &+= 1
        do {
            try launchAtLoginService.setEnabled(enabled)
            store.setLaunchAtLogin(enabled)
            launchAtLoginState = nil
            refreshLaunchAtLoginStateSoon()
            return .success(())
        } catch {
            refreshLaunchAtLoginStateSoon()
            return .failure(error)
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func selectLaunchAtLogin() async -> Result<Void, Error> {
        let current = await launchAtLoginService.currentState()
        guard !Task.isCancelled else { return .success(()) }
        if current == .requiresApproval {
            launchRefreshGeneration &+= 1
            if launchAtLoginState != current { launchAtLoginState = current }
            openLoginItemsSettings()
            return .success(())
        }
        return setLaunchAtLogin(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: current))
    }

    private func refreshLaunchAtLoginStateSoon() {
        Task { @MainActor [weak self] in
            _ = await self?.refreshLaunchAtLoginState()
        }
    }
}
