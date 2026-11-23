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
