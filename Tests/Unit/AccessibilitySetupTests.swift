import Synchronization
import XCTest

@MainActor
final class PermissionOnboardingTests: XCTestCase {
    func testHeldProbeCannotReopenAfterStopAndRestart() throws {
        let clock = WatchdogTestClock()
        let access = RuntimeAccessibilityAccess()
        let ready = Mutex(0)
        let watchdog = RuntimePermissionWatchdog(
            access: access, now: { clock.now }, schedule: clock.schedule,
            requestQuit: { XCTFail("A retired probe cannot quit") },
            forceExit: { XCTFail("A held passive probe cannot force exit") },
            notifyReady: { ready.withLock { $0 += 1 } }
        )
        access.activateRuntime { _ in watchdog.requiredPermissionLost() }
        let firstRun = watchdog.start()
        let retired = try XCTUnwrap(watchdog.beginProbe(for: firstRun))
        watchdog.stop()
        let currentRun = watchdog.start()
        XCTAssertNil(watchdog.beginProbe(for: currentRun))
        clock.advance(to: 5)
        watchdog.completeProbe(retired, verdict: true)
        XCTAssertFalse(watchdog.isReady)
        XCTAssertEqual(ready.withLock { $0 }, 0)
        XCTAssertNil(watchdog.beginProbe(for: firstRun))
        let current = try XCTUnwrap(watchdog.beginProbe(for: currentRun))
        watchdog.completeProbe(current, verdict: true)
        XCTAssertTrue(watchdog.isReady)
        XCTAssertEqual(ready.withLock { $0 }, 1)
    }

    func testConfirmedLossRetainsTheThreeSecondExitFallback() throws {
        for loss in [RuntimeAccessibilityAccess.Loss.negativeProbe, .nativeAPIDisabled] {
            let clock = WatchdogTestClock()
            let access = RuntimeAccessibilityAccess()
            let quits = Mutex(0)
            let exits = Mutex(0)
            let watchdog = RuntimePermissionWatchdog(
                access: access, now: { clock.now }, schedule: clock.schedule,
                requestQuit: { quits.withLock { $0 += 1 } },
                forceExit: { exits.withLock { $0 += 1 } }
            )
            access.activateRuntime { _ in watchdog.requiredPermissionLost() }
            watchdog.start()
            if loss == .negativeProbe {
                watchdog.completeProbe(try XCTUnwrap(watchdog.beginProbe()), verdict: false)
            } else {
                XCTAssertEqual(access.call { .apiDisabled }, .apiDisabled)
            }
            XCTAssertFalse(access.allowsCalls)
            XCTAssertEqual(quits.withLock { $0 }, 1)
            watchdog.requiredPermissionLost()
            watchdog.stop()
            clock.advance(to: 2)
            XCTAssertEqual(exits.withLock { $0 }, 0)
            clock.advance(to: 3)
            clock.advance(to: 5)
            XCTAssertEqual(exits.withLock { $0 }, 1)
            XCTAssertEqual(quits.withLock { $0 }, 1)
        }
    }

    func testOrdinaryWatchdogStopDoesNotArmEmergencyExit() throws {
        let clock = WatchdogTestClock()
        let access = RuntimeAccessibilityAccess()
        access.activateRuntime { _ in }
        let exits = Mutex(0)
        let watchdog = RuntimePermissionWatchdog(
            access: access, now: { clock.now }, schedule: clock.schedule,
            requestQuit: { XCTFail("Ordinary stop must not request quit") },
            forceExit: { exits.withLock { $0 += 1 } }
        )
        watchdog.start()
        let startup = try XCTUnwrap(watchdog.beginProbe())
        watchdog.completeProbe(startup, verdict: true)
        watchdog.stop()
        clock.advance(to: 3)
        XCTAssertEqual(exits.withLock { $0 }, 0)
        XCTAssertFalse(watchdog.isReady)
    }

    func testNativeDenialBlocksLaterCallsEvenWithAStalePositiveProbe() {
        let access = RuntimeAccessibilityAccess()
        XCTAssertEqual(access.call { .cannotComplete }, .cannotComplete)
        XCTAssertEqual(access.call { .success }, .success)
        XCTAssertEqual(access.call { .apiDisabled }, .apiDisabled)
        access.updateTrust(true)

        XCTAssertEqual(access.call {
            XCTFail("A native denial must block AX work for this runtime")
            return .success
        }, .apiDisabled)

        access.updateTrust(false)
        access.updateTrust(true)
        XCTAssertEqual(access.call { .success }, .success)
    }

    func testLateNativeDenialDoesNotOverrideRestoredTrust() {
        let access = RuntimeAccessibilityAccess()
        XCTAssertEqual(access.call {
            access.updateTrust(false)
            access.updateTrust(true)
            return .apiDisabled
        }, .apiDisabled)

        XCTAssertEqual(access.call { .success }, .success)
    }

    func testTrustRecoveryReopensCallsAfterATransientNegativeProbe() {
        let access = RuntimeAccessibilityAccess()
        access.updateTrust(false)
        XCTAssertEqual(access.call {
            XCTFail("The runtime must pause AX work after a negative probe")
            return .success
        }, .apiDisabled)

        access.updateTrust(true)
        XCTAssertEqual(access.call { .success }, .success)
    }

    func testNativeNegativeTrustRejectsAnOverlappingPositiveProbe() {
        let access = RuntimeAccessibilityAccess()
        let generation = access.trustGeneration
        XCTAssertFalse(access.checkTrust { false })
        XCTAssertNil(access.updateTrust(true, for: generation))
        XCTAssertFalse(access.allowsCalls)

        XCTAssertEqual(access.updateTrust(true, for: access.trustGeneration), true)
        XCTAssertTrue(access.allowsCalls)
    }

    func testClassifiesStableLocations() {
        XCTAssertEqual(location("/Applications/DeskMote.app"), .applications)
        XCTAssertEqual(location("/Applications/AppTranslocation/DeskMote.app"), .applications)
        XCTAssertEqual(
            location(NSHomeDirectory() + "/Applications/DeskMote.app"),
            .applications
        )
        XCTAssertEqual(location("/Volumes/External SSD/DeskMote.app", readOnly: false), .other)
        XCTAssertEqual(location("/Users/someone/Downloads/DeskMote.app"), .other)
    }

    func testClassifiesTransientLocations() {
        XCTAssertEqual(location("/Volumes/DeskMote 0.7.0/DeskMote.app", readOnly: true), .readOnlyVolume)
        XCTAssertEqual(
            location("/private/var/folders/ab/AppTranslocation/XYZ/d/DeskMote.app", readOnly: true),
            .appTranslocation
        )
    }

    func testReadOnlyMountedVolumeInsideApplicationsRemainsTransient() {
        for path in ["/Applications/Mounted/DeskMote.app", NSHomeDirectory() + "/Applications/Mounted/DeskMote.app"] {
            XCTAssertEqual(location(path, readOnly: true), .readOnlyVolume)
        }
    }

    func testTranslocationRequiresACompatibleSystemMount() {
        XCTAssertEqual(
            location("/Volumes/Foo/AppTranslocation/XYZ/d/DeskMote.app", readOnly: false),
            .other
        )
        XCTAssertEqual(
            location("/Applications/AppTranslocation/Archive/d/DeskMote.app"),
            .applications
        )
        XCTAssertEqual(
            location("/private/var/folders/ab/AppTranslocation/XYZ/d/DeskMote.app", readOnly: nil),
            .appTranslocation
        )
    }

    func testUnknownVolumeReadabilityIsTreatedAsWritable() {
        XCTAssertEqual(location("/Volumes/Whatever/DeskMote.app", readOnly: nil), .other)
    }

    func testTransientLocationsRejectAccessibilityPrompt() {
        XCTAssertFalse(AppInstallLocation.readOnlyVolume.allowsAccessibilityPrompt)
        XCTAssertFalse(AppInstallLocation.appTranslocation.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.applications.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.other.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.readOnlyVolume.isTransient)
        XCTAssertTrue(AppInstallLocation.appTranslocation.isTransient)
        XCTAssertFalse(AppInstallLocation.applications.isTransient)
    }

    func testRelocationWinsEvenWhenTransientCopyIsAlreadyTrusted() {
        let state = PermissionOnboardingState.initial(installLocation: .readOnlyVolume, isTrusted: true)
        XCTAssertEqual(state, .moveToApplications(.readOnlyVolume))
    }

    func testWaitingBecomesStalledAtEightSecondsAndGrantedWhenTrusted() {
        let waiting = PermissionOnboardingState.waiting
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 7.999, stallAfter: 8), .waiting)
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 8, stallAfter: 8), .stalled)
        XCTAssertEqual(waiting.updated(isTrusted: true, elapsed: 99, stallAfter: 8), .granted)
    }

    func testMoveToApplicationsNeverLeavesItsBranch() {
        let state = PermissionOnboardingState.moveToApplications(.appTranslocation)
        XCTAssertEqual(state.updated(isTrusted: true, elapsed: 99, stallAfter: 8), state)
    }

    func testTransientCopyNeverChecksOrRequestsPermission() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .readOnlyVolume,
            initialTrusted: false,
            now: { 0 }
        )
        model.startPolling()
        model.requestSystemPromptIfNeeded()
        model.checkNow()

        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertEqual(model.state, .moveToApplications(.readOnlyVolume))
    }

    func testStableCopyRequestsNativePromptAtMostOnce() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        model.requestSystemPromptIfNeeded()
        model.requestSystemPromptIfNeeded()

        XCTAssertEqual(spy.promptCount, 1)
    }

    func testPollingTransitionsToStalledAfterEightSeconds() {
        let spy = PermissionSpy(trusted: false)
        var clock: TimeInterval = 0
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { clock },
            stallAfter: 8
        )
        model.startPolling()
        XCTAssertEqual(model.state, .waiting)

        clock = 7.999
        model.checkNow()
        XCTAssertEqual(model.state, .waiting)

        clock = 8
        model.checkNow()
        XCTAssertEqual(model.state, .stalled)
        model.stop()
    }

    func testActivationRechecksAndGrantCallbackIsOneShot() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        var grants = 0
        model.onGranted = { grants += 1 }
        model.startPolling()
        XCTAssertEqual(grants, 0)

        spy.trusted = true
        model.applicationDidBecomeActive()
        model.applicationDidBecomeActive()
        model.checkNow()

        XCTAssertEqual(grants, 1)
        XCTAssertEqual(model.state, .granted)
    }

    func testTransientLaunchNeverPromptsOrStartsApp() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .readOnlyVolume, trusted: false))

        XCTAssertEqual(machine.phase, .transientShell(.readOnlyVolume))
        XCTAssertEqual(effects, [.setActivationPolicy(.regular), .showGuide])
        XCTAssertFalse(effects.contains(.requestSystemPrompt))
        XCTAssertFalse(effects.contains(.startApp))
    }

    func testTrustedLaunchStartsAppAndWatchdog() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .applications, trusted: true))

        XCTAssertEqual(machine.phase, .running)
        XCTAssertEqual(effects, [.setActivationPolicy(.accessory), .startApp, .startWatchdog])
    }

    func testInitialUntrustedLaunchRequestsOnlyTheSystemPrompt() {
        for location: AppInstallLocation in [.applications, .other] {
            var machine = PermissionRecoveryMachine()
            let effects = machine.handle(.launched(location: location, trusted: false))
            guard case let .onboarding(episode) = machine.phase else { return XCTFail("expected onboarding") }
            XCTAssertEqual(effects, [
                .setActivationPolicy(.accessory),
                .startPermissionEpisode(purpose: .initialLaunch, episode: episode),
                .requestSystemPrompt,
            ])
            for state: PermissionOnboardingState in [.waiting, .stalled, .granted] {
                XCTAssertNil(PermissionRecoveryMachine.presentation(phase: machine.phase, onboarding: state))
            }
        }
    }

    func testMissingInitialGrantNeverOpensAnAppGuideOrRepeatsThePrompt() {
        var clock: TimeInterval = 0
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let model = AccessibilityPermissionModel(permissionService: spy.service, installLocation: .applications, now: { clock })
        let coordinator = PermissionRecoveryCoordinator(handler: handler, permissionService: spy.service,
                                                        installLocation: .applications, makeModel: { _, _ in model })
        defer { coordinator.quit() }
        coordinator.launched(trusted: false)
        for elapsed: TimeInterval in [0, 8, 60, 86_400] {
            clock = elapsed
            model.checkNow()
            coordinator.applicationDidBecomeActive()
            coordinator.recheck()
            XCTAssertNil(coordinator.presentation)
            XCTAssertFalse(handler.calls.contains("showGuide"))
            XCTAssertFalse(handler.calls.contains("updateGuide"))
            XCTAssertFalse(handler.calls.contains("startApp"))
            XCTAssertEqual(spy.promptCount, 1)
        }
        XCTAssertEqual(handler.calls, ["policy:accessory"])
    }

    func testLateInitialGrantStartsTheTaskbarOnceWithoutEverOpeningTheGuide() {
        var clock: TimeInterval = 0
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let model = AccessibilityPermissionModel(permissionService: spy.service, installLocation: .applications, now: { clock })
        let coordinator = PermissionRecoveryCoordinator(handler: handler, permissionService: spy.service,
                                                        installLocation: .applications, makeModel: { _, _ in model })
        defer { coordinator.quit() }
        coordinator.launched(trusted: false)
        clock = 120
        model.checkNow()
        spy.trusted = true
        coordinator.applicationDidBecomeActive()
        coordinator.recheck()
        model.checkNow()
        XCTAssertEqual(coordinator.phase, .running)
        XCTAssertNil(coordinator.presentation)
        XCTAssertEqual(handler.calls.filter { $0 == "startApp" }.count, 1)
        XCTAssertEqual(handler.calls.filter { $0 == "startWatchdog" }.count, 1)
        XCTAssertFalse(handler.calls.contains("showGuide"))
        XCTAssertFalse(handler.calls.contains("launchNewInstance"))
        XCTAssertEqual(spy.promptCount, 1)
    }

    func testGrantBetweenLaunchCheckAndPollingDoesNotFlashEitherPrompt() {
        let spy = PermissionSpy(trusted: true)
        let handler = EffectSpy()
        let coordinator = PermissionRecoveryCoordinator(handler: handler, permissionService: spy.service, installLocation: .applications)
        defer { coordinator.quit() }
        coordinator.launched(trusted: false)
        XCTAssertEqual(coordinator.phase, .running)
        XCTAssertNil(coordinator.presentation)
        XCTAssertFalse(handler.calls.contains("showGuide"))
        XCTAssertEqual(handler.calls.filter { $0 == "startApp" }.count, 1)
        XCTAssertEqual(spy.promptCount, 0)
    }

    func testQuittingWhileWaitingForInitialPermissionPreventsALateStartup() {
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let model = AccessibilityPermissionModel(permissionService: spy.service, installLocation: .applications)
        let coordinator = PermissionRecoveryCoordinator(handler: handler, permissionService: spy.service,
                                                        installLocation: .applications, makeModel: { _, _ in model })
        coordinator.launched(trusted: false)
        coordinator.quit()
        spy.trusted = true
        model.checkNow()
        coordinator.applicationDidBecomeActive()
        XCTAssertEqual(coordinator.phase, .terminating)
        XCTAssertNil(coordinator.presentation)
        XCTAssertFalse(handler.calls.contains("showGuide"))
        XCTAssertFalse(handler.calls.contains("startApp"))
        XCTAssertEqual(handler.calls.filter { $0 == "terminateSelf" }.count, 1)
    }

    func testInitialGrantContinuesInProcessWithoutRelaunch() {
        var machine = PermissionRecoveryMachine()
        _ = machine.handle(.launched(location: .applications, trusted: false))
        guard case let .onboarding(episode) = machine.phase else { return XCTFail("expected onboarding") }

        let effects = machine.handle(.grantObserved(episode: episode))
        XCTAssertEqual(machine.phase, .running)
        XCTAssertTrue(effects.contains(.startApp))
    }

    func testTransientCopyCoordinatorNeitherTerminatesNorPrompts() {
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let coordinator = PermissionRecoveryCoordinator(
            handler: handler,
            permissionService: spy.service,
            installLocation: .appTranslocation
        )

        coordinator.launched(trusted: false)

        XCTAssertEqual(coordinator.presentation, .moveToApplications(.appTranslocation))
        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertFalse(handler.calls.contains("startApp"))
        XCTAssertFalse(handler.calls.contains("startWatchdog"))
    }

    private func location(_ path: String, readOnly: Bool? = false) -> AppInstallLocation {
        AppInstallLocation(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            isReadOnlyVolume: { _ in readOnly }
        )
    }

}

final class WatchdogTestClock: Sendable {
    private struct State {
        var now = DispatchTime(uptimeNanoseconds: 1)
        var jobs: [(DispatchTime, @Sendable () -> Void)] = []
    }
    private let state = Mutex(State())

    var now: DispatchTime { state.withLock { $0.now } }

    func schedule(_ deadline: DispatchTime, _ run: @escaping @Sendable () -> Void) {
        state.withLock { $0.jobs.append((deadline, run)) }
    }

    func advance(to seconds: Int) {
        let limit = DispatchTime(uptimeNanoseconds: UInt64(seconds) * 1_000_000_000 + 1)
        while let run = state.withLock({ state -> (@Sendable () -> Void)? in
            guard let index = state.jobs.indices.min(by: {
                state.jobs[$0].0 < state.jobs[$1].0
            }), state.jobs[index].0 <= limit else {
                state.now = limit
                return nil
            }
            let (deadline, run) = state.jobs.remove(at: index)
            state.now = deadline
            return run
        }) {
            run()
        }
    }
}

@MainActor
private final class EffectSpy: PermissionEffectHandler {
    var calls: [String] = []
    var onGuideUpdate: (() -> Void)?

    func startApp() { calls.append("startApp") }
    func setActivationPolicy(_ policy: PermissionActivationPolicy) { calls.append("policy:\(policy)") }
    func showGuideWindow() { calls.append("showGuide") }
    func updateGuideWindow() { calls.append("updateGuide"); onGuideUpdate?() }
    func closeGuideWindow() { calls.append("closeGuide") }
    func openAccessibilitySettings() { calls.append("openSettings") }
    func openApplicationsFolder() { calls.append("openApplications") }
    func startWatchdog() { calls.append("startWatchdog") }
    func stopWatchdog() { calls.append("stopWatchdog") }
    func terminateSelf() { calls.append("terminateSelf") }
}

private final class PermissionSpy {
    var trusted: Bool
    private(set) var promptCount = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    var service: PermissionService {
        PermissionService(
            trustCheck: { self.trusted },
            promptRequest: {
                self.promptCount += 1
                return self.trusted
            },
            readOnlyVolumeCheck: { _ in false }
        )
    }
}
