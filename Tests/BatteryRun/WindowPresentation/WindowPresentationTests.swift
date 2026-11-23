import AppKit
import CoreFoundation
import Foundation

@MainActor
enum WindowSystem {
    static var activations = 0
    static var controllerShows = 0
    static var keyShows = 0
    static var fallbackShows = 0
    static var controllers = 0
    static var foreground = false
    static weak var currentWindow: NSWindow?

    static var presentations: Int { controllerShows + keyShows + fallbackShows }

    static func runMenuTracking(_ event: (@MainActor @Sendable () -> Void)? = nil) {
        let mode = RunLoop.Mode.eventTracking
        let trackingMode = CFRunLoopMode(rawValue: mode.rawValue as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), trackingMode)
        let timer = Timer(timeInterval: 0.001, repeats: false) { _ in
            MainActor.assumeIsolated { event?() }
        }
        RunLoop.main.add(timer, forMode: mode)
        _ = CFRunLoopRunInMode(trackingMode, 0.03, false)
        timer.invalidate()
    }

    static func runMainLoop(for duration: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }
}

@MainActor
final class NSApplication: NSObject {
    static let shared = NSApplication()
    static let didBecomeActiveNotification = Notification.Name("TestApplicationDidBecomeActive")
    var isActive = false

    func activate() {
        WindowSystem.activations += 1
    }

    func completeActivation() {
        isActive = true
        NotificationCenter.default.post(name: Self.didBecomeActiveNotification, object: self)
    }
}

@MainActor
final class BatteryMonitor {
    func start() {}
}

@MainActor
public final class NSWindow {
    enum TabbingMode {
        case disallowed
    }

    var tabbingMode = TabbingMode.disallowed
    var isMiniaturized = false

    func deminiaturize(_ sender: Any?) { isMiniaturized = false }

    func makeKeyAndOrderFront(_ sender: Any?) {
        WindowSystem.keyShows += 1
        WindowSystem.foreground = NSApplication.shared.isActive
    }

    func orderFrontRegardless() {
        WindowSystem.fallbackShows += 1
        WindowSystem.foreground = true
    }
}

@MainActor
final class BatteryWindowController {
    let window: NSWindow? = NSWindow()

    init(monitor: BatteryMonitor) {
        WindowSystem.controllers += 1
        WindowSystem.currentWindow = window
    }

    func showWindow(_ sender: Any?) {
        WindowSystem.controllerShows += 1
        WindowSystem.foreground = NSApplication.shared.isActive
    }
}

@main
struct WindowPresentationTest {
    @MainActor
    static func main() {
        var failures: [String] = []
        var presented: [NSWindow] = []
        let module = BatteryRunModule(windowPresented: { window in
            if WindowSystem.presentations <= presented.count { failures.append("window was registered before presentation") }
            presented.append(window)
        })
        let application = NSApplication.shared

        module.showWindow()
        WindowSystem.runMenuTracking()
        if WindowSystem.presentations != 0 { failures.append("window was shown while menu was tracking") }
        WindowSystem.runMainLoop()
        if WindowSystem.activations != 1 { failures.append("first opening did not request activation") }
        if WindowSystem.presentations != 0 { failures.append("first opening presented the window before activation settled") }
        WindowSystem.runMenuTracking { application.completeActivation() }
        if WindowSystem.presentations != 0 { failures.append("activation showed the window while another menu was tracking") }
        WindowSystem.runMainLoop()
        if WindowSystem.keyShows != 1 || !WindowSystem.foreground { failures.append("activation did not bring the first window forward") }
        WindowSystem.runMainLoop(for: 0.30)
        if WindowSystem.presentations != 1 { failures.append("first opening presented the window more than once") }

        application.isActive = false
        WindowSystem.foreground = false
        let beforeRepeat = WindowSystem.presentations
        module.showWindow()
        WindowSystem.runMainLoop()
        if WindowSystem.presentations != beforeRepeat { failures.append("repeat opening presented before AppKit could activate") }
        WindowSystem.runMainLoop(for: 0.30)
        if !WindowSystem.foreground { failures.append("repeat opening left the window behind without activation") }
        if WindowSystem.fallbackShows != 1 || WindowSystem.presentations != beforeRepeat + 1 {
            failures.append("repeat opening did not use exactly one fallback presentation")
        }
        application.completeActivation()
        WindowSystem.runMainLoop()
        if WindowSystem.presentations != beforeRepeat + 1 { failures.append("late activation raised the window again") }

        let beforeActiveReopen = WindowSystem.presentations
        module.showWindow()
        WindowSystem.runMainLoop()
        if WindowSystem.activations != 2 || WindowSystem.presentations != beforeActiveReopen + 1 {
            failures.append("already active reopen did not show the existing window once")
        }
        let beforeRestore = WindowSystem.presentations
        WindowSystem.currentWindow?.isMiniaturized = true
        WindowSystem.foreground = false
        module.showWindow()
        WindowSystem.runMainLoop()
        if WindowSystem.currentWindow?.isMiniaturized != false || !WindowSystem.foreground ||
            WindowSystem.presentations != beforeRestore + 1 {
            failures.append("opening the minimized window did not restore and raise it")
        }

        if WindowSystem.controllers != 1 { failures.append("reopening created a second window controller") }
        if presented.count != WindowSystem.presentations || presented.isEmpty ||
            presented.contains(where: { $0 !== WindowSystem.currentWindow }) {
            failures.append("each presentation must register the same exact window once")
        }

        for failure in failures { print("FAIL \(failure)") }
        if failures.isEmpty { print("PASS activation-aware first and repeat Battery Run presentations") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
