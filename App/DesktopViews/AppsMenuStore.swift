import AppKit

struct AppsMenuApplication: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let category: String
}

struct AppsMenuCatalog: Equatable, Sendable {
    let installed: [AppsMenuApplication]
    let all: [AppsMenuApplication]?
    let allUnavailable: Bool
}

struct AppsMenuIndexedApplication: Sendable {
    let url: URL
    let displayName: String?
    let hiddenBySystem: Bool
}

struct AppsMenuPin: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String?
    var applicationIDs: [String]
}

enum AppsMenuCatalogMode: String, CaseIterable, Codable {
    case category
    case grid
    case list
}

@MainActor
final class AppsMenuStore {
    static let shared = AppsMenuStore()

    private static let pinsKey = "deskmote.appsMenu.pins"
    private static let catalogModeKey = "deskmote.appsMenu.catalogMode"
    private static let expandedKey = "deskmote.appsMenu.expanded"
    private static let catalogKey = "deskmote.appsMenu.catalog.v1"
    private static let maxCatalogCacheBytes = 1_048_576
    private static let concurrentIconReads = 4

    private struct StoredCatalog: Codable {
        let directories: [URL]?
        let applications: [AppsMenuApplication]
        let allApplications: [AppsMenuApplication]?
    }

    typealias ReadIndex = @MainActor ([URL]) async -> [AppsMenuIndexedApplication]?

    private let defaults: UserDefaults
    private let applicationDirectories: [URL]?
    private let readIndex: ReadIndex?
    private let suppliedSystemFileManager: AppsMenuApplication?
    private let openApplication: @MainActor (URL) -> Void
    private let runningApplicationSnapshot: () -> [NSRunningApplication]
    private let readIcon: @MainActor (URL) async -> NSImage
    private let applicationIcons = NSCache<NSURL, NSImage>()
    private var iconCompletions: [URL: [(NSImage) -> Void]] = [:]
    private var queuedIconURLs: [URL] = []
    private var activeIconReads = 0
    private var catalogRead: Task<AppsMenuCatalog, Never>?
    private var lastCatalogRefresh: ContinuousClock.Instant?
    private(set) var catalogSnapshot: AppsMenuCatalog?

    private(set) var pins: [AppsMenuPin]
    var catalogMode: AppsMenuCatalogMode {
        didSet {
            guard catalogMode != oldValue else { return }
            defaults.set(catalogMode.rawValue, forKey: Self.catalogModeKey)
        }
    }
    var expanded: Bool {
        didSet {
            guard expanded != oldValue else { return }
            defaults.set(expanded, forKey: Self.expandedKey)
        }
    }

    init(defaults: UserDefaults = .standard, applicationDirectories: [URL]? = nil,
         runningApplicationSnapshot: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications },
         readIcon: (@MainActor (URL) async -> NSImage)? = nil,
         readIndex: ReadIndex? = nil,
         systemFileManager: AppsMenuApplication? = nil,
         openApplication: (@MainActor (URL) -> Void)? = nil) {
        let catalogIndex: ReadIndex?
        if let readIndex {
            catalogIndex = readIndex
        } else if applicationDirectories == nil {
            catalogIndex = AppsMenuSpotlightQuery().read
        } else {
            catalogIndex = nil
        }
        self.defaults = defaults
        self.applicationDirectories = applicationDirectories
        self.readIndex = catalogIndex
        suppliedSystemFileManager = systemFileManager
        self.openApplication = openApplication ?? Self.openWorkspaceApplication
        self.runningApplicationSnapshot = runningApplicationSnapshot
        self.readIcon = readIcon ?? { await Self.workspaceIcon(at: $0) }
        applicationIcons.countLimit = 256
        if let data = defaults.data(forKey: Self.catalogKey), data.count <= Self.maxCatalogCacheBytes,
           let catalog = try? JSONDecoder().decode(StoredCatalog.self, from: data),
           catalog.directories == applicationDirectories {
            let installed = Self.disambiguatedCatalog(catalog.applications) ?? catalog.applications
            catalogSnapshot = AppsMenuCatalog(installed: installed,
                all: catalogIndex == nil ? installed : catalog.allApplications, allUnavailable: false)
        }
        pins = defaults.data(forKey: Self.pinsKey)
            .flatMap { try? JSONDecoder().decode([AppsMenuPin].self, from: $0) } ?? []
        catalogMode = defaults.string(forKey: Self.catalogModeKey).flatMap(AppsMenuCatalogMode.init(rawValue:)) ?? .list
        expanded = defaults.bool(forKey: Self.expandedKey)
    }

    func installedApplications() -> [AppsMenuApplication] {
        Self.installedApplications(in: applicationDirectories, fileManagerApplication: systemFileManager)
    }

    var systemFileManager: AppsMenuApplication? {
        suppliedSystemFileManager ?? (applicationDirectories == nil ? Self.builtInFileManager : nil)
    }

    func loadCatalog() async -> AppsMenuCatalog {
        if let catalogSnapshot, let lastCatalogRefresh, lastCatalogRefresh.duration(to: .now) < .seconds(5) {
            return catalogSnapshot
        }
        return await (catalogRead ?? beginCatalogRead()).value
    }

    func preloadCatalog() {
        if lastCatalogRefresh == nil, catalogRead == nil { _ = beginCatalogRead() }
    }

    private func beginCatalogRead() -> Task<AppsMenuCatalog, Never> {
        let directories = applicationDirectories
        let readIndex = readIndex
        let suppliedSystemFileManager = suppliedSystemFileManager
        let read = Task { [weak self] in
            #if DEBUG
            let span = ActionResourceLog.begin("apps.catalog.read")
            defer { span?.finish() }
            #endif
            async let installed = Self.discoverInstalledApplications(in: directories, fileManager: suppliedSystemFileManager)
            let all: [AppsMenuApplication]?
            if let readIndex {
                let roots = directories ?? Self.defaultApplicationDirectories()
                let indexed = await readIndex(roots)
                all = await Self.discoverIndexedApplications(indexed, in: roots)
            } else {
                all = await installed
            }
            let snapshot = AppsMenuCatalog(installed: await installed, all: all ?? self?.catalogSnapshot?.all,
                                           allUnavailable: all == nil)
            self?.updateCatalogSnapshot(snapshot)
            return snapshot
        }
        catalogRead = read
        return read
    }

    private func updateCatalogSnapshot(_ snapshot: AppsMenuCatalog) {
        catalogRead = nil
        lastCatalogRefresh = .now
        guard snapshot != catalogSnapshot else { return }
        catalogSnapshot = snapshot
        let catalog = StoredCatalog(directories: applicationDirectories, applications: snapshot.installed,
                                    allApplications: readIndex == nil ? nil : snapshot.all)
        if let data = try? JSONEncoder().encode(catalog), data.count <= Self.maxCatalogCacheBytes {
            defaults.set(data, forKey: Self.catalogKey)
        }
    }

    @concurrent
    private nonisolated static func discoverInstalledApplications(
        in directories: [URL]?, fileManager: AppsMenuApplication?
    ) async -> [AppsMenuApplication] {
        installedApplications(in: directories, fileManagerApplication: fileManager ?? (directories == nil ? builtInFileManager : nil))
    }

    private nonisolated static func defaultApplicationDirectories() -> [URL] {
        FileManager.default.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
    }

    @concurrent
    private nonisolated static func discoverIndexedApplications(
        _ indexed: [AppsMenuIndexedApplication]?, in directories: [URL]
    ) async -> [AppsMenuApplication]? {
        guard let indexed else { return nil }
        let roots = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let ordered = indexed.map { entry in
            let url = entry.url.standardizedFileURL.resolvingSymlinksInPath()
            let rank = roots.firstIndex { url.path.hasPrefix($0 + "/") } ?? roots.count
            return (entry: entry, url: url, rank: rank)
        }.sorted { ($0.rank, $0.url.path) < ($1.rank, $1.url.path) }
        var paths = Set<URL>()
        var identifiers = Set<String>()
        var applications: [AppsMenuApplication] = []
        for (entry, url, _) in ordered {
            guard !Task.isCancelled else { return nil }
            guard !entry.hiddenBySystem, entry.url.isFileURL, url.pathExtension.lowercased() == "app",
                  !url.pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }),
                  paths.insert(url).inserted, let bundle = Bundle(url: url),
                  let metadata = bundle.infoDictionary,
                  (metadata["LSBackgroundOnly"] as? Bool != true || metadata["LSUIElement"] as? Bool == true) else { continue }
            let identifier = nonEmpty(bundle.bundleIdentifier) ?? url.path
            guard identifier != "com.apple.apps.launcher", !ApplicationIdentity.isDeskMote(identifier),
                  identifiers.insert(identifier).inserted else { continue }
            let name = nonEmpty(entry.displayName) ?? FileManager.default.displayName(atPath: url.path)
            applications.append(.init(id: identifier, name: displayTitle(name), url: url,
                                      category: applicationCategory(metadata)))
        }
        return sortedCatalog(applications)
    }

    private nonisolated static let builtInFileManager: AppsMenuApplication? = {
        let fileManager = FileManager.default
        guard let coreServices = fileManager.urls(for: .coreServiceDirectory, in: .systemDomainMask).first,
              let children = try? fileManager.contentsOfDirectory(at: coreServices, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else { return nil }
        let candidates = children.compactMap { path -> AppsMenuApplication? in
            guard path.pathExtension.lowercased() == "app", let bundle = Bundle(url: path),
                  let identifier = nonEmpty(bundle.bundleIdentifier), let metadata = bundle.infoDictionary,
                  metadata["CFBundlePackageType"] as? String == "FNDR" else { return nil }
            let url = path.standardizedFileURL.resolvingSymlinksInPath()
            return .init(id: identifier, name: bundleDisplayTitle(bundle, metadata: metadata, url: url), url: url,
                         category: applicationCategory(metadata))
        }
        return candidates.count == 1 ? candidates.first : nil
    }()

    private nonisolated static func installedApplications(
        in directories: [URL]?, fileManagerApplication: AppsMenuApplication?
    ) -> [AppsMenuApplication] {
        let fileManager = FileManager.default
        var paths: Set<URL> = []
        var identifiers: Set<String> = []
        var applications: [AppsMenuApplication] = []

        func appendApplication(at candidate: URL) {
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard paths.insert(url).inserted,
                  let bundle = Bundle(url: url),
                  let metadata = bundle.infoDictionary,
                  metadata["CFBundlePackageType"] as? String == "APPL",
                  metadata["LSBackgroundOnly"] as? Bool != true else { return }
            let identifier = nonEmpty(bundle.bundleIdentifier) ?? url.path
            guard identifiers.insert(identifier).inserted else { return }
            applications.append(.init(id: identifier, name: bundleDisplayTitle(bundle, metadata: metadata, url: url), url: url,
                                      category: applicationCategory(metadata)))
        }

        guard !Task.isCancelled else { return [] }
        if let fileManagerApplication {
            paths.insert(fileManagerApplication.url)
            identifiers.insert(fileManagerApplication.id)
            applications.append(fileManagerApplication)
        }
        let applicationDirectories = directories ?? defaultApplicationDirectories()
        for directory in applicationDirectories {
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                           errorHandler: { _, _ in true }) else { continue }
            for case let candidate as URL in enumerator {
                guard !Task.isCancelled else { return [] }
                guard candidate.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                appendApplication(at: candidate)
            }
        }
        return disambiguatedCatalog(applications) ?? sortedCatalog(applications)
    }

    private nonisolated static func displayTitle(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") && name.count > 4 ? String(name.dropLast(4)) : name
    }

    private nonisolated static func bundleDisplayTitle(_ bundle: Bundle, metadata: [String: Any], url: URL) -> String {
        let local = bundle.localizedInfoDictionary
        let name = nonEmpty(local?["CFBundleDisplayName"] as? String)
            ?? nonEmpty(local?["CFBundleName"] as? String)
            ?? nonEmpty(metadata["CFBundleDisplayName"] as? String)
            ?? nonEmpty(metadata["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return displayTitle(name)
    }

    private nonisolated static func applicationCategory(_ metadata: [String: Any]) -> String {
        let prefix = "public.app-category."
        return (metadata["LSApplicationCategoryType"] as? String)
            .flatMap { $0.hasPrefix(prefix) ? nonEmpty(String($0.dropFirst(prefix.count))) : nil } ?? "other"
    }

    private nonisolated static func disambiguatedCatalog(_ applications: [AppsMenuApplication]) -> [AppsMenuApplication]? {
        let displayNames = applications.reduce(into: [String: Int]()) { counts, application in
            counts[application.name, default: 0] += 1
        }
        guard displayNames.count < applications.count else { return nil }

        let bundleNames = applications.map { $0.url.deletingPathExtension().lastPathComponent }
        let bundleNameCounts = bundleNames.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }
        let renamed = zip(applications, bundleNames).map { application, bundleName in
            guard displayNames[application.name, default: 0] > 1, nonEmpty(bundleName) != nil,
                  displayNames[bundleName] == nil, bundleNameCounts[bundleName] == 1 else { return application }
            return AppsMenuApplication(id: application.id, name: bundleName, url: application.url, category: application.category)
        }
        return sortedCatalog(renamed)
    }

    private nonisolated static func sortedCatalog(_ applications: [AppsMenuApplication]) -> [AppsMenuApplication] {
        applications.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private nonisolated static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    struct RunningApplicationState {
        let pid: pid_t
        let bundleIdentifier: String?
        let url: URL?
        let policy: NSApplication.ActivationPolicy
        let isTerminated: Bool
        let isActive: Bool
    }

    static func runningApplications<Application>(in snapshot: [Application],
                                                  state: (Application) -> RunningApplicationState) -> [Application] {
        var indices: [String: Int] = [:]
        var applications: [(application: Application, isActive: Bool)] = []
        for application in snapshot {
            let info = state(application)
            guard info.pid > 0, info.policy == .regular, !info.isTerminated else { continue }
            let identity: String
            if let bundleID = nonEmpty(info.bundleIdentifier) {
                identity = "bundle:\(bundleID)"
            } else if let url = info.url, url.isFileURL {
                identity = "path:\(url.standardizedFileURL.resolvingSymlinksInPath().path)"
            } else {
                identity = "pid:\(info.pid)"
            }
            if let index = indices[identity] {
                if info.isActive, !applications[index].isActive {
                    applications[index] = (application, true)
                }
            } else {
                indices[identity] = applications.count
                applications.append((application, info.isActive))
            }
        }
        return applications.map(\.application)
    }

    func runningApplications() -> [NSRunningApplication] {
        Self.runningApplications(in: runningApplicationSnapshot()) { application in
            .init(pid: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
                  url: application.bundleURL, policy: application.activationPolicy,
                  isTerminated: application.isTerminated, isActive: application.isActive)
        }
    }

    func requestIcon(at url: URL, completion: @escaping (NSImage) -> Void) {
        if let icon = applicationIcons.object(forKey: url as NSURL) {
            completion(icon)
            return
        }
        if iconCompletions[url] != nil {
            iconCompletions[url]?.append(completion)
            return
        }
        iconCompletions[url] = [completion]
        queuedIconURLs.append(url)
        startNextIconRead()
    }

    private func startNextIconRead() {
        guard activeIconReads < Self.concurrentIconReads, !queuedIconURLs.isEmpty else { return }
        let url = queuedIconURLs.removeFirst()
        activeIconReads += 1
        let readIcon = self.readIcon
        Task { [weak self] in
            let icon = await readIcon(url)
            guard let self else { return }
            applicationIcons.setObject(icon, forKey: url as NSURL)
            let completions = iconCompletions.removeValue(forKey: url) ?? []
            activeIconReads -= 1
            for completion in completions { completion(icon) }
            startNextIconRead()
        }
    }

    @concurrent
    private nonisolated static func workspaceIcon(at url: URL) async -> sending NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let icon = source.copy() as? NSImage ?? source
        icon.size = CGSize(width: 64, height: 64)
        return icon
    }

    func launch(_ application: AppsMenuApplication) {
        openApplication(application.url)
    }

    func reopen(_ application: NSRunningApplication) {
        if let url = application.bundleURL, url.isFileURL {
            openApplication(url)
        } else {
            #if DEBUG
            let span = ActionResourceLog.begin("apps.application.activate")
            defer { span?.finish() }
            #endif
            application.activate(options: [])
        }
    }

    private static func openWorkspaceApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?
        #if DEBUG
        if let span = ActionResourceLog.begin("apps.application.open") {
            completion = { _, _ in span.finish() }
        } else {
            completion = nil
        }
        #else
        completion = nil
        #endif
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
    }

    func pin(_ application: AppsMenuApplication) {
        guard location(of: application.id) == nil else { return }
        updatePins { $0.append(.init(id: UUID(), name: nil, applicationIDs: [application.id])) }
    }

    func unpin(_ appID: String) {
        guard let location = location(of: appID) else { return }
        updatePins { Self.removeApp(at: location, from: &$0) }
    }

    func createFolder(from pinID: UUID) -> UUID? {
        guard let index = pins.firstIndex(where: { $0.id == pinID }), pins[index].name == nil else { return nil }
        updatePins { $0[index].name = "" }
        return pinID
    }

    func groupPin(_ id: UUID, into targetID: UUID) {
        guard id != targetID,
              let source = pins.firstIndex(where: { $0.id == id }),
              let target = pins.firstIndex(where: { $0.id == targetID }),
              pins[source].name == nil, pins[source].applicationIDs.count == 1,
              let applicationID = pins[source].applicationIDs.first else { return }
        updatePins {
            $0[target].name = $0[target].name ?? ""
            $0[target].applicationIDs.append(applicationID)
            $0.remove(at: source)
        }
    }

    func moveApp(_ appID: String, to folderID: UUID) {
        guard let location = location(of: appID),
              let target = pins.firstIndex(where: { $0.id == folderID && $0.name != nil }),
              location.pin != target else { return }
        updatePins {
            $0[target].applicationIDs.append(appID)
            Self.removeApp(at: location, from: &$0)
        }
    }

    func removeFromFolder(_ appID: String) {
        guard let location = location(of: appID), pins[location.pin].name != nil else { return }
        updatePins {
            if $0[location.pin].applicationIDs.count == 1 {
                $0[location.pin].name = nil
            } else {
                Self.removeApp(at: location, from: &$0)
                $0.insert(.init(id: UUID(), name: nil, applicationIDs: [appID]), at: location.pin + 1)
            }
        }
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard Self.nonEmpty(name) != nil,
              let index = pins.firstIndex(where: { $0.id == id && $0.name != nil }) else { return }
        updatePins { $0[index].name = name }
    }

    func movePin(_ id: UUID, to index: Int) {
        guard let source = pins.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index, 0), pins.count - 1)
        guard source != destination else { return }
        updatePins {
            let pin = $0.remove(at: source)
            $0.insert(pin, at: destination)
        }
    }

    func unpinEntry(_ id: UUID) {
        updatePins { $0.removeAll { $0.id == id } }
    }

    private func location(of appID: String) -> (pin: Int, member: Int)? {
        for (index, pin) in pins.enumerated() {
            if let member = pin.applicationIDs.firstIndex(of: appID) {
                return (index, member)
            }
        }
        return nil
    }

    private static func removeApp(at location: (pin: Int, member: Int), from entries: inout [AppsMenuPin]) {
        entries[location.pin].applicationIDs.remove(at: location.member)
        switch entries[location.pin].applicationIDs.count {
        case 0: entries.remove(at: location.pin)
        case 1: entries[location.pin].name = nil
        default: break
        }
    }

    private func updatePins(_ edit: (inout [AppsMenuPin]) -> Void) {
        #if DEBUG
        let span = ActionResourceLog.begin("apps.pin.persist")
        defer { span?.finish() }
        #endif
        var updated = pins
        edit(&updated)
        guard updated != pins, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.pinsKey)
        pins = updated
    }
}

@MainActor
private final class AppsMenuSpotlightQuery {
    private struct Entry: Sendable {
        let url: URL
        let displayName: String?
    }

    private var query: NSMetadataQuery?
    private var observer: (any NSObjectProtocol)?
    private var timeout: Task<Void, Never>?
    private var visibilityRead: Task<Void, Never>?
    private var completion: CheckedContinuation<[AppsMenuIndexedApplication]?, Never>?

    func read(in roots: [URL]) async -> [AppsMenuIndexedApplication]? {
        guard completion == nil, visibilityRead == nil else { return nil }
        let scopes = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !scopes.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            completion = continuation
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
            query.searchScopes = scopes
            self.query = query
            let queryID = ObjectIdentifier(query)
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishGathering(queryID: queryID) }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.finish(nil) }
            }
            if !query.start() { finish(nil) }
        }
    }

    private func finishGathering(queryID: ObjectIdentifier) {
        guard let query, ObjectIdentifier(query) == queryID else { return }
        query.disableUpdates()
        let results = query.results
        let entries: [Entry] = results.compactMap { result in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  path.hasPrefix("/") else { return nil }
            return Entry(url: URL(fileURLWithPath: path),
                         displayName: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
        }
        stopQuery()
        guard !entries.isEmpty, entries.count == results.count else {
            finish(nil)
            return
        }
        visibilityRead = Task { [weak self] in
            let indexed = await Self.checkVisibility(entries)
            guard let self else { return }
            visibilityRead = nil
            finish(indexed)
        }
    }

    private func finish(_ indexed: [AppsMenuIndexedApplication]?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        visibilityRead?.cancel()
        stopQuery()
        completion.resume(returning: indexed)
    }

    private func stopQuery() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let query = query
        self.query = nil
        query?.stop()
    }

    @concurrent
    private nonisolated static func checkVisibility(_ entries: [Entry]) async -> [AppsMenuIndexedApplication]? {
        let key = "_NSURLIsHiddenBySystemKey" as CFString
        var indexed: [AppsMenuIndexedApplication] = []
        indexed.reserveCapacity(entries.count)
        for entry in entries {
            guard !Task.isCancelled else { return nil }
            let url = entry.url.standardizedFileURL.resolvingSymlinksInPath()
            var value: Unmanaged<CFTypeRef>?
            let succeeded = CFURLCopyResourcePropertyForKey(url as CFURL, key, &value, nil)
            let hidden = value?.takeRetainedValue()
            guard succeeded else {
                if !FileManager.default.fileExists(atPath: url.path) { continue }
                return nil
            }
            let hiddenBySystem: Bool
            if let hidden {
                guard let flag = hidden as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
                hiddenBySystem = flag.boolValue
            } else {
                hiddenBySystem = false
            }
            indexed.append(.init(url: url, displayName: entry.displayName, hiddenBySystem: hiddenBySystem))
        }
        return indexed.isEmpty ? nil : indexed
    }
}
