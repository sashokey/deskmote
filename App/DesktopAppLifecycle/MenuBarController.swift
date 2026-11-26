import AppKit
import Combine

@MainActor
protocol StatusItemPresenting: AnyObject {
    var isVisible: Bool { get set }
    var menu: NSMenu? { get set }
    func configureAutosaveName(_ name: NSStatusItem.AutosaveName)
    func configureButtonImage(_ image: NSImage?)
}

extension NSStatusItem: StatusItemPresenting {
    func configureAutosaveName(_ name: NSStatusItem.AutosaveName) { autosaveName = name }
    func configureButtonImage(_ image: NSImage?) { button?.image = image }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: any StatusItemPresenting
    private let quit: @MainActor () -> Void
    private let modules: [DeskMoteModule]
    private lazy var toggleItems: [NSMenuItem] = modules.compactMap { module in
        guard case let .toggle(toggle) = module else { return nil }
        let item = TaskbarNativeMenuFactory.actionItem(title: toggle.title, action: toggle.choose)
        toggle.$isRunning
            .sink { [weak item] running in item?.state = running ? .on : .off }
            .store(in: &subscriptions)
        return item
    }
    private lazy var utilityItems = modules.compactMap { module -> NSMenuItem? in
        guard case let .utility(title, show) = module else { return nil }
        return TaskbarNativeMenuFactory.actionItem(title: title, action: show)
    }
    private lazy var menu = TaskbarNativeMenuFactory.statusMenu(
        launchAtLogin: launchAtLoginItem, hideStatusBarIcon: hideStatusBarIconItem,
        input: toggleItems, utilities: utilityItems, quit: quit
    )
    private let settingsCoordinator: SettingsCoordinator
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let hideStatusBarIconItem = NSMenuItem(title: String(localized: "Hide Status Bar Icon"), action: #selector(toggleStatusBarIcon), keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var launchActionTask: Task<Void, Never>?

    init(
        settingsCoordinator: SettingsCoordinator,
        statusItem: any StatusItemPresenting = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
        modules: [DeskMoteModule] = [],
        quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.settingsCoordinator = settingsCoordinator
        self.statusItem = statusItem
        self.modules = modules
        self.quit = quit
        super.init()

        statusItem.configureAutosaveName("DeskMote.StatusBarIcon")
        let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "DeskMote")
        image?.isTemplate = true
        statusItem.configureButtonImage(image)
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false

        launchAtLoginItem.target = self
        hideStatusBarIconItem.target = self
        updateStatusBarIconState()

        settingsCoordinator.$launchAtLoginState
            .sink { [weak self] state in self?.updateLaunchAtLogin(state) }
            .store(in: &subscriptions)
        refreshSystemState()
    }

    func popUpFromTaskbar(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func menuWillOpen(_ menu: NSMenu) {
        #if DEBUG
        let resources = ActionResourceLog.begin("statusMenu.open")
        defer { resources?.finish() }
        #endif
        updateStatusBarIconState()
        refreshSystemState()
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshSystemState()
    }

    func showStatusBarIcon() {
        statusItem.isVisible = true
        updateStatusBarIconState()
    }

    @objc private func toggleStatusBarIcon() {
        #if DEBUG
        let resources = ActionResourceLog.begin("statusMenu.toggleIcon")
        defer { resources?.finish() }
        #endif
        statusItem.isVisible.toggle()
        updateStatusBarIconState()
    }

    private func updateStatusBarIconState() {
        hideStatusBarIconItem.state = statusItem.isVisible ? .off : .on
    }

    private func updateLaunchAtLogin(_ state: LaunchAtLoginState?) {
        guard let state else {
            launchAtLoginItem.toolTip = nil
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .off
            return
        }
        let presentation = LaunchAtLoginMenuPresentation(state: state)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.toolTip = presentation.help
        launchAtLoginItem.isEnabled = presentation.isEnabled
        launchAtLoginItem.state = presentation.isChecked ? .on : .off
    }

    private func refreshSystemState() {
        guard launchActionTask == nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            let resources = ActionResourceLog.begin("statusMenu.readLoginItem")
            defer { resources?.finish() }
            #endif
            await settingsCoordinator.refreshLaunchAtLoginState()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard launchActionTask == nil else { return }
        refreshTask?.cancel()
        launchActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { launchActionTask = nil }
            #if DEBUG
            let resources = ActionResourceLog.begin("statusMenu.changeLoginItem")
            #endif
            let result = await settingsCoordinator.selectLaunchAtLogin()
            #if DEBUG
            resources?.finish()
            #endif
            if case let .failure(error) = result {
                reportLaunchAtLoginFailure(error)
            }
        }
    }

    private func reportLaunchAtLoginFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t Change Open at Login")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
