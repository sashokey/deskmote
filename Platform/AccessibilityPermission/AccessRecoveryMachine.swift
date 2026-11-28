import Foundation

enum PermissionActivationPolicy: Equatable {
    case accessory
    case regular
}

enum PermissionEpisodePurpose: Equatable {
    case initialLaunch
}

enum PermissionPhase: Equatable {
    case idle
    case transientShell(AppInstallLocation)
    case onboarding(episode: UInt64)
    case running
    case terminating
}

enum PermissionEvent: Equatable {
    case launched(location: AppInstallLocation, trusted: Bool)
    case grantObserved(episode: UInt64)
    case recheckRequested
    case quitRequested
    case terminationRequested
}

enum PermissionEffect: Equatable {
    case startApp
    case setActivationPolicy(PermissionActivationPolicy)
    case showGuide
    case closeGuide
    case startPermissionEpisode(purpose: PermissionEpisodePurpose, episode: UInt64)
    case stopPermissionEpisode
    case requestSystemPrompt
    case recheckNow
    case startWatchdog
    case stopWatchdog
    case terminateSelf
}

enum PermissionPresentation: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
}

struct PermissionRecoveryMachine: Equatable {
    private(set) var phase: PermissionPhase = .idle
    private var episodeCounter: UInt64 = 0

    init() {}

    mutating func handle(_ event: PermissionEvent) -> [PermissionEffect] {
        guard phase != .terminating else { return [] }
        switch event {
        case .terminationRequested:
            phase = .terminating
            return [.stopWatchdog, .stopPermissionEpisode]
        case .quitRequested:
            phase = .terminating
            return [.stopWatchdog, .stopPermissionEpisode, .terminateSelf]
        case let .launched(location, trusted):
            guard phase == .idle else { return [] }
            if location.isTransient {
                phase = .transientShell(location)
                return [.setActivationPolicy(.regular), .showGuide]
            }
            if trusted {
                phase = .running
                return [.setActivationPolicy(.accessory), .startApp, .startWatchdog]
            }
            episodeCounter &+= 1
            phase = .onboarding(episode: episodeCounter)
            return [.setActivationPolicy(.accessory),
                    .startPermissionEpisode(purpose: .initialLaunch, episode: episodeCounter), .requestSystemPrompt]
        case let .grantObserved(episode):
            guard phase == .onboarding(episode: episode) else { return [] }
            phase = .running
            return [.stopPermissionEpisode, .closeGuide, .setActivationPolicy(.accessory), .startApp, .startWatchdog]
        case .recheckRequested:
            guard case .onboarding = phase else { return [] }
            return [.recheckNow]
        }
    }

    static func presentation(phase: PermissionPhase, onboarding _: PermissionOnboardingState) -> PermissionPresentation? {
        if case let .transientShell(location) = phase { return .moveToApplications(location) }
        return nil
    }
}
