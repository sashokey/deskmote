import AppKit

struct AppsMenuApplication: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let category: String
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

    private let defaults: UserDefaults
    private let applicationDirectories: [URL]?
    private let runningApplicationSnapshot: () -> [NSRunningApplication]

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
         runningApplicationSnapshot: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }) {
        self.defaults = defaults
        self.applicationDirectories = applicationDirectories
        self.runningApplicationSnapshot = runningApplicationSnapshot
        pins = defaults.data(forKey: Self.pinsKey)
            .flatMap { try? JSONDecoder().decode([AppsMenuPin].self, from: $0) } ?? []
        catalogMode = defaults.string(forKey: Self.catalogModeKey).flatMap(AppsMenuCatalogMode.init(rawValue:)) ?? .list
        expanded = defaults.bool(forKey: Self.expandedKey)
    }

    func installedApplications() -> [AppsMenuApplication] {
        Self.installedApplications(in: applicationDirectories)
    }

    func loadInstalledApplications() async -> [AppsMenuApplication] {
        await Self.discoverInstalledApplications(in: applicationDirectories)
    }

    @concurrent
    private nonisolated static func discoverInstalledApplications(in directories: [URL]?) async -> [AppsMenuApplication] {
        installedApplications(in: directories)
    }

    private nonisolated static func installedApplications(in directories: [URL]?) -> [AppsMenuApplication] {
        let fileManager = FileManager.default
        var paths: Set<URL> = []
        var identifiers: Set<String> = []
        var applications: [AppsMenuApplication] = []

        func appendApplication(at candidate: URL, isSystemFinder: Bool = false) {
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard paths.insert(url).inserted,
                  let bundle = Bundle(url: url),
                  let metadata = bundle.infoDictionary,
                  let packageType = metadata["CFBundlePackageType"] as? String,
                  packageType == "APPL" || (isSystemFinder && packageType == "FNDR"),
                  metadata["LSBackgroundOnly"] as? Bool != true else { return }
            let identifier = nonEmpty(bundle.bundleIdentifier) ?? url.path
            guard !isSystemFinder || identifier == "com.apple.finder",
                  identifiers.insert(identifier).inserted else { return }

            let local = bundle.localizedInfoDictionary
            let name = nonEmpty(local?["CFBundleDisplayName"] as? String)
                ?? nonEmpty(local?["CFBundleName"] as? String)
                ?? nonEmpty(metadata["CFBundleDisplayName"] as? String)
                ?? nonEmpty(metadata["CFBundleName"] as? String)
                ?? fileManager.displayName(atPath: url.path)
            let displayName = name.lowercased().hasSuffix(".app") && name.count > 4
                ? String(name.dropLast(4)) : name
            let categoryPrefix = "public.app-category."
            let category = (metadata["LSApplicationCategoryType"] as? String)
                .flatMap { $0.hasPrefix(categoryPrefix) ? nonEmpty(String($0.dropFirst(categoryPrefix.count))) : nil }
                ?? "other"
            applications.append(.init(id: identifier, name: displayName, url: url, category: category))
        }

        guard !Task.isCancelled else { return [] }
        if directories == nil, let coreServices = fileManager.urls(for: .coreServiceDirectory, in: .systemDomainMask).first {
            appendApplication(at: coreServices.appendingPathComponent("Finder.app", isDirectory: true), isSystemFinder: true)
        }
        let applicationDirectories = directories ?? fileManager.urls(for: .applicationDirectory,
                                                                      in: [.userDomainMask, .localDomainMask, .systemDomainMask])
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
        return applications.sorted {
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

    func icon(for application: AppsMenuApplication) -> NSImage {
        NSWorkspace.shared.icon(forFile: application.url.path)
    }

    func launch(_ application: AppsMenuApplication) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration, completionHandler: nil)
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
        var updated = pins
        edit(&updated)
        guard updated != pins, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.pinsKey)
        pins = updated
    }
}
