import AppKit
import XCTest
#if DEBUG && !DESKMOTE_BASE
@testable import DeskMoteApps
#endif

@MainActor
final class TaskbarLeadingSlotTests: XCTestCase {
    private final class DetachedPanel: NSPanel {
        override func orderFrontRegardless() {}
        override func makeKey() {}
        override func orderOut(_ sender: Any?) {}
        override func close() {}
    }

    private func makeOrchestrator(snapshot: @escaping @MainActor () -> ScreenTopologySnapshot) -> TaskbarScreenOrchestrator {
        TaskbarScreenOrchestrator(runtime: AppRuntime(tracker: BehaviorInventory(BehaviorDesktop())), stripOrderStore: StripOrderStore(),
                                 displayTopologyStore: DisplayTopologyStore(initialSnapshot: snapshot()),
                                 spaceStore: TaskbarSpaceStore(read: { _ in nil }, notifications: NotificationCenter()),
                                 topologySnapshotProvider: snapshot, startCoordinator: { coordinator in
            coordinator.setupDockPanel(makeTaskbarView: {
                TaskbarView(frame: $0, popup: BehaviorPopup(), contextMenu: BehaviorMenu())
            }, makeDockPanel: Self.makePanel)
        }, windowAdjustmentEnabled: false)
    }

    private static func makePanel(_ frame: CGRect) -> NSPanel {
        DetachedPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    #if DESKMOTE_BASE
    func testBaseUsesOriginalInsetAndHasNoLeadingSlot() throws {
        _ = try XCTUnwrap(NSScreen.main)
        var called = false
        let initial = ScreenTopologySnapshot(physicalDisplayCount: 1, identifiedDisplayUUIDs: [], attributionTable: .empty)
        let orchestrator = makeOrchestrator { initial }
        orchestrator.leadingSlotFactory = DeskMoteModuleRegistry.makeLeadingSlotFactory {
            called = true
            return { _ in
                TaskbarLeadingSlot(view: NSView(), leadingInset: 41, isPresented: { false },
                                  update: { _, _ in }, dismiss: { _ in })
            }
        }
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        let content = try XCTUnwrap(orchestrator.units.first?.coordinator.taskbarView?.taskbarContent)
        XCTAssertFalse(called)
        XCTAssertFalse(content.subviews.contains { $0.accessibilityIdentifier() == "DeskMote.Apps" })
        XCTAssertEqual(TaskbarMetrics.leadingInset, 10)
        XCTAssertEqual(TaskbarMetrics.trailingInset, 10)
        XCTAssertEqual(TaskbarMetrics.buttonSpacing, 2)
    }
    #endif

    #if DEBUG && !DESKMOTE_BASE
    func testFullLeadingSlotPreservesFramesAndDisplayLifecycle() throws {
        _ = try XCTUnwrap(NSScreen.main)
        var snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        let orchestrator = makeOrchestrator { snapshot }
        let module = AppsModule(store: makeAppsFixtureStore(), appearance: appsTaskbarAppearance,
                                makePanel: Self.makePanel, makeMenuItem: TaskbarNativeMenuFactory.actionItem,
                                observeWorkspace: false, reduceMotion: { true })
        orchestrator.leadingSlotFactory = DeskMoteModuleRegistry.makeLeadingSlotFactory {
            makeFullLeadingSlotFactory(module: module)
        }
        defer { orchestrator.suspendAndRelease() }
        orchestrator.start()
        XCTAssertTrue(orchestrator.units.isEmpty)

        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 2, identifiedDisplayUUIDs: ["A", "B"],
                                          attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(orchestrator.units.map(\.key), ["A", "B"])
        let first = try XCTUnwrap(orchestrator.units.first?.coordinator.taskbarView?.taskbarContent)
        let last = try XCTUnwrap(orchestrator.units.last?.coordinator.taskbarView?.taskbarContent)
        let firstButton = try XCTUnwrap(first.subviews.compactMap { $0 as? NSButton }.first)
        let lastButton = try XCTUnwrap(last.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertFalse(firstButton === lastButton)
        XCTAssertEqual(firstButton.frame.origin.x, 0)
        XCTAssertEqual(firstButton.frame.width, 39)
        XCTAssertEqual(AppsMenuGeometry.windowLeadingInset, 41)
        firstButton.performClick(nil)
        XCTAssertTrue(first.hasExplicitPopup)
        lastButton.performClick(nil)
        XCTAssertFalse(first.hasExplicitPopup)
        XCTAssertTrue(last.hasExplicitPopup)

        snapshot = ScreenTopologySnapshot(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(orchestrator.units.isEmpty)
        XCTAssertFalse(last.hasExplicitPopup)
    }
    #endif
}
