import AppKit
import XCTest

@MainActor
final class AppsMenuStoreTests: XCTestCase {
    func testPinnedOrderFolderNameAndCatalogPreferencesSurviveRestart() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppsMenuStore(defaults: defaults)
        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertEqual(store.catalogMode, .list)
        XCTAssertFalse(store.expanded)

        store.pin(application("notes"))
        store.pin(application("terminal"))
        store.pin(application("safari"))
        let safari = try XCTUnwrap(store.pins.last)
        store.movePin(safari.id, to: 0)
        let notes = store.pins[1]
        let folder = try XCTUnwrap(store.createFolder(from: notes.id))
        store.moveApp("terminal", to: folder)
        store.renameFolder(folder, to: "  Work tools  ")
        store.renameFolder(folder, to: " \n\t ")
        store.pin(application("notes"))
        store.expanded = true
        store.catalogMode = .grid

        let restored = AppsMenuStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.pins.map(\.applicationIDs), [["safari"], ["notes", "terminal"]])
        XCTAssertEqual(restored.pins.last?.id, folder)
        XCTAssertEqual(restored.pins.last?.name, "  Work tools  ")
        XCTAssertEqual(restored.catalogMode, .grid)
        XCTAssertTrue(restored.expanded)
    }

    func testRemovingAppsFromFolderPreservesPinsAndDissolvesTheFolder() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppsMenuStore(defaults: defaults)
        for id in ["notes", "terminal", "safari", "mail"] { store.pin(application(id)) }

        let folder = try XCTUnwrap(store.createFolder(from: store.pins[0].id))
        XCTAssertEqual(store.pins[0].name, "")
        XCTAssertEqual(store.pins[0].applicationIDs, ["notes"])
        store.moveApp("terminal", to: folder)
        store.moveApp("safari", to: folder)
        store.moveApp("notes", to: folder)
        store.removeFromFolder("terminal")
        XCTAssertEqual(store.pins.map(\.applicationIDs), [["notes", "safari"], ["terminal"], ["mail"]])
        XCTAssertEqual(store.pins[0].id, folder)
        XCTAssertEqual(store.pins[0].name, "")

        store.removeFromFolder("safari")
        XCTAssertEqual(store.pins.map(\.applicationIDs), [["notes"], ["safari"], ["terminal"], ["mail"]])
        XCTAssertTrue(store.pins.allSatisfy { $0.name == nil })
        XCTAssertEqual(store.pins[0].id, folder)
    }

    func testUnpinAndMoveBetweenFoldersOnlyAffectTheRequestedApplications() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppsMenuStore(defaults: defaults)
        for id in ["notes", "terminal", "safari", "mail"] { store.pin(application(id)) }
        let first = try XCTUnwrap(store.createFolder(from: store.pins[0].id))
        let second = try XCTUnwrap(store.createFolder(from: store.pins[2].id))
        store.moveApp("terminal", to: first)
        store.moveApp("mail", to: second)
        store.moveApp("terminal", to: second)
        XCTAssertEqual(store.pins.map(\.applicationIDs), [["notes"], ["safari", "mail", "terminal"]])
        XCTAssertNil(store.pins[0].name)

        store.unpin("mail")
        store.movePin(second, to: .min)
        XCTAssertEqual(store.pins.map(\.applicationIDs), [["safari", "terminal"], ["notes"]])
        store.unpinEntry(second)
        XCTAssertEqual(store.pins.map(\.applicationIDs), [["notes"]])
        XCTAssertNil(store.createFolder(from: second))
    }

    func testInstalledCatalogReadsBundleMetadataAndDeduplicatesCanonicalApplications() async throws {
        let location = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let userApplications = location.appendingPathComponent("User")
        let localApplications = location.appendingPathComponent("Local")
        let preferred = userApplications.appendingPathComponent("Utilities/Preferred.app")
        let fallback = localApplications.appendingPathComponent("Fallback.app")
        try createApplication(at: preferred, identifier: "test.tools", name: "Development Tool",
                              category: "public.app-category.developer-tools")
        try createApplication(at: fallback)
        try createApplication(at: localApplications.appendingPathComponent("Copy.app"), identifier: "test.tools")
        try createApplication(at: preferred.appendingPathComponent("Contents/Helpers/Embedded.app"),
                              identifier: "test.helper")
        try FileManager.default.createSymbolicLink(at: localApplications.appendingPathComponent("Alias.app"),
                                                   withDestinationURL: preferred)

        let store = AppsMenuStore(applicationDirectories: [userApplications, localApplications])
        let catalog = await store.loadCatalog().installed
        XCTAssertEqual(catalog.map(\.name), ["Development Tool", "Fallback"])
        XCTAssertEqual(catalog.map(\.id), ["test.tools", fallback.resolvingSymlinksInPath().path])
        XCTAssertEqual(catalog.map(\.url.path), [preferred, fallback].map { $0.resolvingSymlinksInPath().path })
        XCTAssertEqual(catalog.map(\.category), ["developer-tools", "other"])
    }

    func testDefaultInstalledCatalogIncludesSystemFinderOnce() async {
        let catalog = await AppsMenuStore(readIndex: { _ in [] }).loadCatalog().installed
        let finderURLs = catalog.filter { $0.id == "com.apple.finder" }.map(\.url.path)
        XCTAssertEqual(finderURLs, ["/System/Library/CoreServices/Finder.app"])
    }

    func testAllUsesIndexedApplicationsAndTheirDisplayNames() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let passwords = directory.appendingPathComponent("Passwords.app")
        let browser = directory.appendingPathComponent("Game/Utils/Browser.app")
        let errorReporter = directory.appendingPathComponent("Game/Utils/Error.app")
        let game = directory.appendingPathComponent("Game/Game.app")
        let embedded = game.appendingPathComponent("Contents/Applications/Helper.app")
        let hidden = directory.appendingPathComponent("Hidden.app")
        let launcher = directory.appendingPathComponent("Apps.app")
        let own = directory.appendingPathComponent("DeskMote.app")
        try createApplication(at: passwords, identifier: "test.passwords", attributes: ["CFBundlePackageType": "XPC!"])
        try createApplication(at: browser, identifier: "test.browser",
                              attributes: ["LSBackgroundOnly": true, "LSUIElement": true])
        try createApplication(at: errorReporter, identifier: "test.error", attributes: ["LSBackgroundOnly": true])
        try createApplication(at: game, identifier: "test.game", name: "Internal Game")
        try createApplication(at: embedded, identifier: "test.helper")
        try createApplication(at: hidden, identifier: "test.hidden")
        try createApplication(at: launcher, identifier: "com.apple.apps.launcher")
        try createApplication(at: own, identifier: ApplicationIdentity.properWMDevelopmentIdentifier)

        let entries = [passwords, browser, errorReporter, game, embedded, hidden, launcher, own].map {
            AppsMenuIndexedApplication(url: $0, displayName: $0 == game ? "Game Display Name.app" : $0.lastPathComponent,
                                       hiddenBySystem: $0 == hidden)
        }
        let store = AppsMenuStore(defaults: defaults, applicationDirectories: [directory], readIndex: { _ in entries })
        let catalog = await store.loadCatalog()
        let all = try XCTUnwrap(catalog.all)
        XCTAssertEqual(all.map(\.id), ["test.browser", "test.game", "test.passwords"])
        XCTAssertEqual(all.map(\.name), ["Browser", "Game Display Name", "Passwords"])
        XCTAssertFalse(catalog.allUnavailable)
        XCTAssertEqual(catalog.installed.first { $0.id == "test.game" }?.name, "Internal Game")
        XCTAssertTrue(catalog.installed.contains { $0.id == "test.hidden" })
    }

    func testAllReportsIndexFailureAndKeepsOnlyTheLastIndexedSnapshot() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexed = directory.appendingPathComponent("Indexed.app")
        try createApplication(at: indexed, identifier: "test.indexed")
        try createApplication(at: directory.appendingPathComponent("Folder Only.app"), identifier: "test.folder")

        let original = AppsMenuStore(defaults: defaults, applicationDirectories: [directory])
        _ = await original.loadCatalog()
        let failing = AppsMenuStore(defaults: defaults, applicationDirectories: [directory], readIndex: { _ in nil })
        XCTAssertNil(failing.catalogSnapshot?.all)
        let firstFailure = await failing.loadCatalog()
        XCTAssertNil(firstFailure.all)
        XCTAssertTrue(firstFailure.allUnavailable)
        XCTAssertEqual(Set(firstFailure.installed.map(\.id)), ["test.indexed", "test.folder"])

        let successful = AppsMenuStore(defaults: defaults, applicationDirectories: [directory], readIndex: { _ in
            [.init(url: indexed, displayName: "Indexed.app", hiddenBySystem: false)]
        })
        let successfulCatalog = await successful.loadCatalog()
        let recovered = try XCTUnwrap(successfulCatalog.all)
        XCTAssertEqual(recovered.map(\.id), ["test.indexed"])
        let restarted = AppsMenuStore(defaults: defaults, applicationDirectories: [directory], readIndex: { _ in nil })
        XCTAssertEqual(restarted.catalogSnapshot?.all, recovered)
        let laterFailure = await restarted.loadCatalog()
        XCTAssertEqual(laterFailure.all, recovered)
        XCTAssertTrue(laterFailure.allUnavailable)
    }

    func testCollidingDisplayNamesUseDistinctBundleNamesInBothSavedAndFreshCatalogs() async throws {
        struct LegacyCatalog: Encodable {
            let directories: [URL]
            let applications: [AppsMenuApplication]
        }

        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = [
            (id: "io.github.sashokey.deskmote", name: "DeskMote", file: "DeskMote"),
            (id: "io.github.sashokey.deskmote.dev", name: "DeskMote", file: "DeskMote Dev"),
            (id: "com.apple.siri.launcher", name: "Siri", file: "Siri"),
            (id: "com.apple.campo", name: "Siri", file: "Siri AI"),
            (id: "test.localized", name: "Localized Name", file: "Internal Name"),
        ]
        let oldApplications = try installed.map { item in
            let url = directory.appendingPathComponent(item.file + ".app")
            try createApplication(at: url, identifier: item.id, name: item.name)
            return AppsMenuApplication(id: item.id, name: item.name, url: url, category: "other")
        }
        let oldCache = LegacyCatalog(directories: [directory], applications: oldApplications)
        defaults.set(try JSONEncoder().encode(oldCache), forKey: "deskmote.appsMenu.catalog.v1")

        let store = AppsMenuStore(defaults: defaults, applicationDirectories: [directory])
        let expected = [
            "io.github.sashokey.deskmote": "DeskMote",
            "io.github.sashokey.deskmote.dev": "DeskMote Dev",
            "com.apple.siri.launcher": "Siri",
            "com.apple.campo": "Siri AI",
            "test.localized": "Localized Name",
        ]
        let cached = try XCTUnwrap(store.catalogSnapshot?.installed)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0.name) }), expected)

        let refreshed = await store.loadCatalog().installed
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0.name) }), expected)
        XCTAssertEqual(Set(refreshed.map(\.url.path)), Set(oldApplications.map(\.url.path)))
    }

    func testNewStoreHasSavedCatalogBeforeRefreshingInstalledApps() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("First.app")
        try createApplication(at: first, identifier: "test.first")
        let original = AppsMenuStore(defaults: defaults, applicationDirectories: [directory])
        let firstScan = await original.loadCatalog().installed
        XCTAssertEqual(firstScan.map(\.id), ["test.first"])

        try FileManager.default.removeItem(at: first)
        try createApplication(at: directory.appendingPathComponent("Second.app"), identifier: "test.second")
        let restarted = AppsMenuStore(defaults: defaults, applicationDirectories: [directory])
        XCTAssertEqual(restarted.catalogSnapshot?.installed, firstScan)
        let refreshed = await restarted.loadCatalog().installed
        XCTAssertEqual(refreshed.map(\.id), ["test.second"])
        XCTAssertEqual(AppsMenuStore(defaults: defaults, applicationDirectories: [directory]).catalogSnapshot?.installed, refreshed)
    }

    func testRunningCatalogIncludesWindowlessRegularAppsOnceAndExcludesTerminatedAndAccessoryApps() async {
        let path = URL(fileURLWithPath: "/Applications/Windowless.app")
        let otherSpace = URL(fileURLWithPath: "/Applications/OtherSpace.app")
        let applications: [AppsMenuStore.RunningApplicationState] = [
            .init(pid: 1, bundleIdentifier: "closed", url: nil, policy: .regular, isTerminated: true, isActive: false),
            .init(pid: 2, bundleIdentifier: "menu", url: nil, policy: .accessory, isTerminated: false, isActive: false),
            .init(pid: 3, bundleIdentifier: "daemon", url: nil, policy: .prohibited, isTerminated: false, isActive: false),
            .init(pid: 4, bundleIdentifier: "other-space", url: otherSpace, policy: .regular, isTerminated: false, isActive: false),
            .init(pid: 5, bundleIdentifier: nil, url: path, policy: .regular, isTerminated: false, isActive: false),
            .init(pid: 6, bundleIdentifier: "other-space", url: otherSpace, policy: .regular, isTerminated: false, isActive: true),
            .init(pid: 7, bundleIdentifier: nil, url: path, policy: .regular, isTerminated: false, isActive: false),
            .init(pid: 8, bundleIdentifier: nil, url: nil, policy: .regular, isTerminated: false, isActive: false),
            .init(pid: -1, bundleIdentifier: nil, url: nil, policy: .regular, isTerminated: false, isActive: false)
        ]
        let running = AppsMenuStore.runningApplications(in: applications, state: { $0 })
        XCTAssertEqual(running.map(\.pid), [6, 5, 8])
    }

    private func application(_ id: String) -> AppsMenuApplication {
        AppsMenuApplication(id: id, name: id, url: URL(fileURLWithPath: "/Applications/\(id).app"),
                            category: "other")
    }

    private func createApplication(at url: URL, identifier: String? = nil, name: String? = nil,
                                   category: String? = nil, attributes: [String: Any] = [:]) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var metadata: [String: Any] = ["CFBundlePackageType": "APPL"]
        metadata["CFBundleIdentifier"] = identifier
        metadata["CFBundleDisplayName"] = name
        metadata["LSApplicationCategoryType"] = category
        metadata.merge(attributes) { _, supplied in supplied }
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
