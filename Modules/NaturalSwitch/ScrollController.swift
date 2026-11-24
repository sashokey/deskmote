import Foundation
import Darwin
import CoreFoundation

@MainActor
final class ScrollController: ScrollControlling {
    @MainActor
    struct Preferences {
        let read: () -> CFPropertyList?
        let write: (CFPropertyList?) -> Void
        let synchronize: () -> Bool

        private static let key = "com.apple.swipescrolldirection" as CFString

        static let system = Self(
            read: { CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) },
            write: { CFPreferencesSetValue(key, $0, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) },
            synchronize: { CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
        )
    }

    private let library: UnsafeMutableRawPointer?
    private let getter: () -> Bool
    private let setter: (Bool) -> Void
    private let preferences: Preferences

    init(path: String = "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport") throws {
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw NaturalSwitchError.unavailableAPI }
        guard let read = dlsym(library, "swipeScrollDirection"), let write = dlsym(library, "setSwipeScrollDirection") else {
            dlclose(library)
            throw NaturalSwitchError.unavailableAPI
        }
        self.library = library
        preferences = .system
        getter = unsafeBitCast(read, to: (@convention(c) () -> Bool).self)
        setter = unsafeBitCast(write, to: (@convention(c) (Bool) -> Void).self)
    }

    init(getter: @escaping () -> Bool, setter: @escaping (Bool) -> Void, preferences: Preferences) {
        library = nil
        self.getter = getter
        self.setter = setter
        self.preferences = preferences
    }

    isolated deinit {
        if let library { dlclose(library) }
    }

    func isNatural() throws -> Bool {
        try synchronize()
        return getter()
    }

    func setNatural(_ enabled: Bool) throws {
        try synchronize()
        let previousPreference = preferences.read()
        let previousDirection = getter()
        let attemptedValue: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        preferences.write(attemptedValue)
        try synchronize()

        setter(enabled)
        do {
            guard try isNatural() == enabled else { throw NaturalSwitchError.preferences }
        } catch {
            let restoreRuntime = previousDirection != enabled && getter() == enabled
            if currentPreferenceMatches(attemptedValue) {
                if restoreRuntime { setter(previousDirection) }
                let restoredValue: CFBoolean = previousDirection ? kCFBooleanTrue : kCFBooleanFalse
                if !restoreRuntime || currentPreferenceMatches(attemptedValue, or: restoredValue) {
                    preferences.write(previousPreference)
                    _ = preferences.synchronize()
                }
            }
            throw error
        }
    }

    private func currentPreferenceMatches(_ expected: CFBoolean, or alternate: CFBoolean? = nil) -> Bool {
        guard preferences.synchronize(), let current = preferences.read(),
              CFGetTypeID(current) == CFBooleanGetTypeID() else { return false }
        return CFEqual(current, expected) || alternate.map { CFEqual(current, $0) } == true
    }

    private func synchronize() throws {
        guard preferences.synchronize() else {
            throw NaturalSwitchError.preferences
        }
    }
}
