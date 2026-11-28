import AppKit
import Combine
import Foundation

#if !DESKMOTE_BASE && !DESKMOTE_TEST
import BatteryRun
import CommandShift
import NaturalSwitch
#endif

typealias UtilityWindowRegistration = @MainActor (NSWindow) -> Void

@MainActor
enum DeskMoteModule {
    case toggle(DeskMoteModuleToggle)
    case utility(title: String, show: @MainActor () -> Void)
}

@MainActor
final class DeskMoteModuleToggle {
    enum StartResult {
        case running
        case permissionRequired
        case unavailable
    }

    let title: String
    @Published private(set) var isRunning = false
    private let key: String
    private let defaults: UserDefaults
    private let requiresAccessibility: Bool
    private let startAction: (Bool) -> StartResult
    private let stopAction: () -> Void
    private var waitingForPermission = false
    var mayStartWithAccessibility: () -> Bool = { true }
    var requestStartupPermission: () -> Void = {}

    init(id: String, title: String, defaults: UserDefaults, requiresAccessibility: Bool = false,
         start: @escaping (Bool) -> StartResult, stop: @escaping () -> Void) {
        key = "deskmote.module.\(id)"
        self.title = title
        self.defaults = defaults
        self.requiresAccessibility = requiresAccessibility
        startAction = start
        stopAction = stop
    }

    func restore() {
        if defaults.bool(forKey: key) { activate(prompt: false) }
    }

    func choose() {
        if isRunning || waitingForPermission {
            stop()
            defaults.set(false, forKey: key)
        } else {
            activate(prompt: true)
        }
    }

    func retryWaiting() {
        if waitingForPermission { activate(prompt: false) }
    }

    func accessibilityChanged(trusted: Bool, canResume: () -> Bool = { true }) {
        guard requiresAccessibility else { return }
        if trusted {
            if waitingForPermission, canResume() { retryWaiting() }
        } else if isRunning {
            stop()
            waitingForPermission = defaults.bool(forKey: key)
        }
    }

    func stop() {
        if isRunning { stopAction() }
        isRunning = false
        waitingForPermission = false
    }

    func moduleStopped(_ reason: StartResult) {
        guard isRunning else { return }
        switch reason {
        case .running:
            break
        case .permissionRequired:
            isRunning = false
            waitingForPermission = defaults.bool(forKey: key)
        case .unavailable:
            isRunning = false
            waitingForPermission = false
            defaults.set(false, forKey: key)
        }
    }

    private func activate(prompt: Bool) {
        guard !isRunning else { return }
        if requiresAccessibility, !mayStartWithAccessibility() {
            waitingForPermission = true
            if prompt {
                defaults.set(true, forKey: key)
                requestStartupPermission()
            }
            return
        }
        switch startAction(prompt) {
        case .running:
            isRunning = true
            waitingForPermission = false
            defaults.set(true, forKey: key)
        case .permissionRequired:
            waitingForPermission = true
        case .unavailable:
            waitingForPermission = false
        }
    }
}

@MainActor
enum DeskMoteModuleRegistry {
    static func makeLeadingSlotFactory(
        makeFull: (@MainActor () -> TaskbarLeadingSlotFactory)? = nil
    ) -> TaskbarLeadingSlotFactory? {
        #if DESKMOTE_BASE
        nil
        #elseif DESKMOTE_TEST
        makeFull?()
        #else
        makeFull?() ?? makeProductionLeadingSlotFactory()
        #endif
    }

    static func production(registerWindow: @escaping UtilityWindowRegistration,
                           watchdog: RuntimePermissionWatchdog) -> [DeskMoteModule] {
        #if DESKMOTE_BASE || DESKMOTE_TEST
        []
        #else
        [commandShift(watchdog: watchdog), naturalSwitch(), batteryRun(registerWindow: registerWindow)]
        #endif
    }

    #if !DESKMOTE_BASE && !DESKMOTE_TEST
    private static func commandShift(watchdog: RuntimePermissionWatchdog) -> DeskMoteModule {
        let service = CommandShiftModule(hasPermission: { watchdog.isReady })
        let toggle = DeskMoteModuleToggle(
            id: "command-shift", title: String(localized: "Use Shift–Command to Switch Input Sources"),
            defaults: .standard, requiresAccessibility: true,
            start: { prompt in
                switch service.start(requestPermission: prompt) {
                case .running: .running
                case .permissionRequired: .permissionRequired
                case .unavailable: .unavailable
                }
            }, stop: service.stop
        )
        service.onInterruption = { [weak toggle] permissionRequired in
            toggle?.moduleStopped(permissionRequired ? .permissionRequired : .unavailable)
        }
        return .toggle(toggle)
    }

    private static func naturalSwitch() -> DeskMoteModule {
        let service = NaturalSwitchModule()
        let toggle = DeskMoteModuleToggle(
            id: "natural-switch", title: String(localized: "Auto-Switch Scroll Direction"), defaults: .standard,
            start: { prompt in service.start(presentStartupError: prompt) ? .running : .unavailable },
            stop: service.stop
        )
        service.onInterruption = { [weak toggle] in toggle?.moduleStopped(.unavailable) }
        return .toggle(toggle)
    }

    private static func batteryRun(registerWindow: @escaping UtilityWindowRegistration) -> DeskMoteModule {
        let service = BatteryRunModule(windowPresented: registerWindow)
        return .utility(title: String(localized: "Show Battery Runtime Estimates"), show: service.showWindow)
    }
    #endif
}
