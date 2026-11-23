import Foundation
import Darwin
import CoreFoundation

@MainActor
final class ScrollController: ScrollControlling {
    private let library: UnsafeMutableRawPointer
    private let getter: @convention(c) () -> Bool
    private let setter: @convention(c) (Bool) -> Void

    init(path: String = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport") throws {
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw NaturalSwitchError.unavailableAPI }
        guard let read = dlsym(library, "swipeScrollDirection"), let write = dlsym(library, "setSwipeScrollDirection") else {
            dlclose(library)
            throw NaturalSwitchError.unavailableAPI
        }
        self.library = library
        getter = unsafeBitCast(read, to: (@convention(c) () -> Bool).self)
        setter = unsafeBitCast(write, to: (@convention(c) (Bool) -> Void).self)
    }

    isolated deinit { dlclose(library) }

    func isNatural() throws -> Bool {
        try synchronize()
        return getter()
    }

    func setNatural(_ enabled: Bool) throws {
        CFPreferencesSetValue(
            "com.apple.swipescrolldirection" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        try synchronize()
        setter(enabled)
        guard try isNatural() == enabled else { throw NaturalSwitchError.preferences }
    }

    private func synchronize() throws {
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NaturalSwitchError.preferences
        }
    }
}
