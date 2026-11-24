import AppKit
import XCTest

@MainActor
final class AppsMenuViewTests: XCTestCase {
    func testCatalogRowsRetainKeyboardFocusAfterLayoutRebuild() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let frame = CGRect(x: 0, y: 0, width: 642, height: 676)
        let window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AppsMenuView(frame: frame, store: fixture.store) {}
        window.contentView = view
        try await waitForButton("Café Viewer", in: view)
        let original = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertTrue(window.makeFirstResponder(original))

        window.setContentSize(CGSize(width: 600, height: 676))
        view.layoutSubtreeIfNeeded()

        let replacement = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertFalse(original === replacement)
        XCTAssertTrue(replacement === window.firstResponder)
        XCTAssertGreaterThan(replacement.frame.width, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testSearchUsesApplicationRowsAndReclaimsFooterSpace() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        XCTAssertFalse(search.drawsBackground)
        try await waitForButton("Café Viewer", in: view)
        let regularRow = try XCTUnwrap(button("Café Viewer", in: view))
        let regularScroll = try XCTUnwrap(regularRow.enclosingScrollView)
        XCTAssertEqual(regularScroll.frame.maxY, 611)

        search.stringValue = "cafe"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))

        let searchRow = try XCTUnwrap(button("Café Viewer", in: view))
        XCTAssertEqual(searchRow.frame.width, regularRow.frame.width)
        XCTAssertEqual(searchRow.frame.height, regularRow.frame.height)
        XCTAssertEqual(searchRow.enclosingScrollView?.frame.maxY, 676)
        XCTAssertNil(button("Calculator", in: view))
        XCTAssertEqual(view.frame.size, CGSize(width: 642, height: 676))

        search.stringValue = ""
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let restoredRow = try XCTUnwrap(button("Calculator", in: view))
        XCTAssertEqual(restoredRow.enclosingScrollView?.frame.maxY, 611)
    }

    func testEscapeClearsSearchBeforeDismissing() async throws {
        let fixture = try makeCatalog()
        defer { fixture.cleanUp() }
        var dismissCount = 0
        let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {
            dismissCount += 1
        }
        let search = try XCTUnwrap(descendants(of: view, as: NSSearchField.self).first)
        search.stringValue = "cafe"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitForButton("Café Viewer", in: view)

        view.cancelOperation(nil)

        XCTAssertEqual(search.stringValue, "")
        XCTAssertEqual(dismissCount, 0)
        XCTAssertNotNil(button("Calculator", in: view))

        view.cancelOperation(nil)

        XCTAssertEqual(dismissCount, 1)
    }

    func testPinnedHeadingAndAllFollowVisiblePinRows() async throws {
        let names = (1...16).map { "Test App \($0)" }
        let fixture = try makeCatalog(names: names)
        defer { fixture.cleanUp() }
        let apps = fixture.store.installedApplications()
        XCTAssertEqual(apps.count, 16)
        let cases: [(pins: Int, expanded: Bool, allY: CGFloat, toggle: String?)] = [
            (0, false, 103, nil), (3, false, 187, nil),
            (16, false, 271, "Show all"), (16, true, 355, "Show less"),
        ]
        for entry in cases {
            apps.prefix(entry.pins).forEach(fixture.store.pin)
            fixture.store.expanded = entry.expanded
            let view = AppsMenuView(frame: CGRect(x: 0, y: 0, width: 642, height: 676), store: fixture.store) {}
            try await waitForButton("Test App 1", in: view)
            let labels = descendants(of: view, as: NSTextField.self)
            let pinned = try XCTUnwrap(labels.first { $0.stringValue == "Pinned" })
            let all = try XCTUnwrap(labels.first { $0.stringValue == "All" })
            XCTAssertEqual(pinned.frame.minY, 31)
            XCTAssertEqual(all.frame.minY, entry.allY)
            let toggle = ["Show all", "Show less"].first { button($0, in: view) != nil }
            XCTAssertEqual(toggle, entry.toggle)
        }
    }

    private func makeCatalog(names: [String] = ["Café Viewer", "Calculator"]) throws -> (store: AppsMenuStore, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "DeskMote.AppsMenuViewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for (id, name) in names.enumerated() {
            let contents = directory.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let properties = ["CFBundleIdentifier": "test.apps.\(id)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let store = AppsMenuStore(defaults: defaults, applicationDirectories: [directory], runningApplicationSnapshot: { [] })
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func waitForButton(_ name: String, in view: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while button(name, in: view) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(button(name, in: view))
    }

    private func button(_ name: String, in view: NSView) -> NSButton? {
        descendants(of: view, as: NSButton.self).first { $0.title == name }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, as: type)
        }
    }
}
