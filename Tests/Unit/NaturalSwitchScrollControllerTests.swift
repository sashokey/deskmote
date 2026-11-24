import CoreFoundation
import Testing
@testable import NaturalSwitch

@Suite @MainActor
struct ScrollControllerTests {
    @Test func missingLibraryFailsBeforeMonitoringStarts() {
        #expect(throws: (any Error).self) { try ScrollController(path: "/nonexistent/NaturalSwitch.framework/NaturalSwitch") }
    }

    @Test func libraryWithoutScrollingSymbolsIsRejected() {
        #expect(throws: (any Error).self) { try ScrollController(path: "/usr/lib/libSystem.B.dylib") }
    }
}

@MainActor
private final class PreferenceFixture {
    var value: CFPropertyList?
    var runtime = false
    var runtimeWrites: [Bool] = []
    var writeRuntime: ((Bool) -> Void)?
    var synchronize: (() -> Bool)?

    var controller: ScrollController {
        .init(
            getter: { self.runtime },
            setter: {
                self.runtimeWrites.append($0)
                self.writeRuntime?($0)
            },
            preferences: .init(
                read: { self.value },
                write: { self.value = $0 },
                synchronize: { self.synchronize?() ?? true }
            )
        )
    }
}

extension ScrollControllerTests {
    @Test func unconfirmedRuntimeChangeRemovesAnInitiallyAbsentPreference() {
        let fixture = PreferenceFixture()
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value == nil)
        #expect(fixture.runtimeWrites == [true])
    }

    @Test func unconfirmedRuntimeChangeRestoresThePreviousPreference() {
        let fixture = PreferenceFixture()
        fixture.value = kCFBooleanFalse
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? Bool == false)
        #expect(fixture.runtimeWrites == [true])
    }

    @Test func failureAfterTheRuntimeUpdateRestoresBothLayers() {
        let fixture = PreferenceFixture()
        fixture.value = kCFBooleanFalse
        fixture.writeRuntime = { [unowned fixture] in fixture.runtime = $0 }
        var synchronizations = 0
        fixture.synchronize = { synchronizations += 1; return synchronizations != 3 }
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? Bool == false)
        #expect(fixture.runtime == false)
        #expect(fixture.runtimeWrites == [true, false])
    }

    @Test func failedPersistDoesNotOverwriteAnIndependentlyChangedDurableValue() {
        var cache: CFPropertyList? = kCFBooleanFalse
        var durable: CFPropertyList? = kCFBooleanFalse
        let outsideValue = "external" as CFString
        var writes = 0
        let controller = ScrollController(
            getter: { false }, setter: { _ in Issue.record("Runtime setter called after failed persistence") },
            preferences: .init(
                read: { cache },
                write: { value in writes += 1; cache = value },
                synchronize: {
                    if writes == 1 {
                        durable = outsideValue
                        return false
                    }
                    if writes > 1 { durable = cache }
                    return true
                }
            )
        )
        #expect(throws: (any Error).self) { try controller.setNatural(true) }
        #expect(writes == 1)
        #expect(durable as? String == "external")
    }

    @Test func unconfirmedDurableStatePreventsUnsafeRuntimeRestoration() {
        let fixture = PreferenceFixture()
        fixture.value = kCFBooleanFalse
        fixture.writeRuntime = { [unowned fixture] direction in
            fixture.runtime = direction
            fixture.value = "external" as CFString
        }
        fixture.synchronize = { [unowned fixture] in !fixture.runtime }
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? String == "external")
        #expect(fixture.runtime)
        #expect(fixture.runtimeWrites == [true])
    }

    @Test func preferenceChangedDuringRuntimeRestorationIsPreserved() {
        let fixture = PreferenceFixture()
        fixture.value = kCFBooleanFalse
        var synchronizations = 0
        fixture.synchronize = { synchronizations += 1; return synchronizations != 3 }
        fixture.writeRuntime = { [unowned fixture] direction in
            fixture.runtime = direction
            if !direction { fixture.value = "external" as CFString }
        }
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? String == "external")
        #expect(fixture.runtime == false)
    }

    @Test(arguments: [true, false]) func runtimeSetterSideEffectDoesNotReplaceTheExactPreviousPreference(
        _ initiallyAbsent: Bool
    ) {
        let fixture = PreferenceFixture()
        fixture.value = initiallyAbsent ? nil : kCFBooleanTrue
        var synchronizations = 0
        fixture.synchronize = { synchronizations += 1; return synchronizations != 3 }
        fixture.writeRuntime = { [unowned fixture] direction in
            fixture.runtime = direction
            fixture.value = direction ? kCFBooleanTrue : kCFBooleanFalse
        }

        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.runtimeWrites == [true, false])
        #expect(fixture.runtime == false)
        if initiallyAbsent {
            #expect(fixture.value == nil)
        } else {
            #expect(fixture.value as? Bool == true)
        }
    }

    @Test func runtimeSetterCannotOverwriteAnObservedIndependentPreference() {
        let fixture = PreferenceFixture()
        fixture.value = kCFBooleanFalse
        var synchronizations = 0
        fixture.synchronize = { synchronizations += 1; return synchronizations != 3 }
        fixture.writeRuntime = { [unowned fixture] direction in
            fixture.runtime = direction
            fixture.value = direction ? "external" as CFString : kCFBooleanFalse
        }

        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? String == "external")
        #expect(fixture.runtimeWrites == [true])
    }

    @Test func independentPreferenceChangeSurvivesAFailedUpdate() {
        let fixture = PreferenceFixture()
        fixture.writeRuntime = { [unowned fixture] _ in fixture.value = kCFBooleanFalse }
        #expect(throws: (any Error).self) { try fixture.controller.setNatural(true) }
        #expect(fixture.value as? Bool == false)
        #expect(fixture.runtimeWrites == [true])
    }
}
