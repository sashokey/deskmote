import AppKit

@MainActor
final class AppsMenuView: NSGlassEffectView, NSSearchFieldDelegate {
    private static let designWidth: CGFloat = 642
    private static let searchBottom: CGFloat = 65
    private static let footerHeight: CGFloat = 65
    private static let rowPitch: CGFloat = 42
    private static let tilePitch: CGFloat = 84

    private let store: AppsMenuStore
    private let dismiss: () -> Void
    private let surface = AppsMenuCanvas()
    private let searchBacking = AppsMenuBox(radius: 16, fill: .white.withAlphaComponent(0.08),
                                          border: .white.withAlphaComponent(0.17))
    private let searchField = NSSearchField()
    private let catalogScroll = AppsMenuScrollView(horizontal: false)
    private let footer = AppsMenuCanvas()
    private let footerRule = AppsMenuBox(radius: 0, fill: .white.withAlphaComponent(0.12))
    private let runningScroll = AppsMenuRunningScrollView(horizontal: true)
    private var applications: [AppsMenuApplication]?
    private var applicationsByID: [String: AppsMenuApplication] = [:]
    private var applicationIcons: [String: NSImage] = [:]
    private var runningApps: [NSRunningApplication] = []
    private var runningObservation: NSKeyValueObservation?
    private var frontmostObservation: NSKeyValueObservation?
    private var activationObservations: [NSKeyValueObservation] = []
    private var catalogTask: Task<Void, Never>?
    private var lastSize = CGSize.zero
    private var query = ""
    private var searchResults: [AppsMenuApplication] = []
    private var browsingPosition = CGPoint.zero
    private var category: AppsMenuCategory?
    private var categoryPosition = CGPoint.zero
    private var folderID: UUID?
    private var folderShield: AppsMenuCanvas?
    private var folderGlass: NSGlassEffectView?
    private var folderScroll: AppsMenuScrollView?
    private var folderTitle: AppsMenuButton?
    private var renameField: NSTextField?
    private var catalogButtons: [AppsMenuButton] = []
    private var pinButtons: [UUID: AppsMenuButton] = [:]
    private var runningButtons: [AppsMenuButton] = []
    private var folderButtons: [AppsMenuButton] = []

    init(frame: CGRect, store: AppsMenuStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
        super.init(frame: frame)
        style = .regular
        cornerRadius = 20
        surface.autoresizingMask = [.width, .height]
        surface.clipsToBounds = true
        contentView = surface
        surface.addSubview(searchBacking)
        surface.addSubview(searchField)
        surface.addSubview(catalogScroll)
        surface.addSubview(footer)
        footer.addSubview(footerRule)
        footer.addSubview(runningScroll)
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.placeholderString = String(localized: "Search for apps")
        searchField.setAccessibilityLabel(searchField.placeholderString)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.delegate = self
        runningApps = store.runningApplications()
        layoutContents()
        loadCatalog()
    }

    required init?(coder: NSCoder) { nil }

    deinit { catalogTask?.cancel() }

    override func layout() {
        super.layout()
        if bounds.size != lastSize { layoutContents() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        runningObservation?.invalidate()
        runningObservation = nil
        frontmostObservation?.invalidate()
        frontmostObservation = nil
        activationObservations.removeAll()
        guard window != nil else { return }
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeApplicationPolicies() }
        }
        frontmostObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshRunningApps() }
        }
        observeApplicationPolicies()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    override func cancelOperation(_ sender: Any?) {
        if renameField != nil {
            finishRenaming(save: false)
        } else if folderID != nil {
            closeFolder()
        } else if !query.isEmpty {
            searchField.stringValue = ""
            searchField.currentEditor()?.string = ""
            searchFieldChanged()
            focusSearch()
        } else if category != nil {
            showCategory(nil)
        } else {
            dismiss()
        }
    }

    private func loadCatalog() {
        let store = self.store
        catalogTask = Task { [weak self] in
            let applications = await store.loadInstalledApplications()
            guard !Task.isCancelled, let self else { return }
            self.applications = applications
            applicationsByID = Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildCatalog()
        }
    }

    private func layoutContents() {
        lastSize = bounds.size
        surface.frame = bounds
        let width = surface.bounds.width
        let height = surface.bounds.height
        let inset = horizontal(33)
        searchBacking.frame = CGRect(x: inset, y: 17, width: max(0, width - inset * 2), height: 32)
        searchField.frame = searchBacking.frame.insetBy(dx: min(8, searchBacking.frame.width / 2), dy: 6)
        footer.frame = CGRect(x: 0, y: max(Self.searchBottom, height - Self.footerHeight),
                              width: width, height: Self.footerHeight)
        footerRule.frame = CGRect(x: 1, y: 0, width: max(0, width - 2), height: 1)
        rebuildCatalog()
        rebuildRunningFooter()
        if folderID != nil { rebuildFolder() }
    }

    private func horizontal(_ value: CGFloat) -> CGFloat {
        value * min(1, surface.bounds.width / Self.designWidth)
    }

    @objc private func searchFieldChanged() {
        let newQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newQuery != query else { return }
        if query.isEmpty { browsingPosition = catalogScroll.contentView.bounds.origin }
        query = newQuery
        rebuildCatalog(position: newQuery.isEmpty ? browsingPosition : .zero)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { searchFieldChanged() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renameField else { return }
        Task { @MainActor [weak self, weak field] in
            guard let self, let field, field === renameField else { return }
            finishRenaming(save: true, focusTitle: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelOperation(control)
            return true
        }
        if control === renameField, commandSelector == #selector(insertNewline(_:)) {
            finishRenaming(save: true)
            return true
        }
        guard control === searchField, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(moveDown(_:)), let button = catalogButtons.first {
            focus(button)
            return true
        }
        if commandSelector == #selector(insertNewline(_:)), let app = searchResults.first {
            launch(app)
            return true
        }
        return false
    }

    private func rebuildCatalog(position: CGPoint? = nil, restoreFocus: String? = nil) {
        let focusID = restoreFocus ?? focusedIdentifier(in: catalogButtons)
        let scrollPosition = position ?? catalogScroll.contentView.bounds.origin
        let height = query.isEmpty ? footer.frame.minY : surface.bounds.height
        footer.isHidden = !query.isEmpty
        catalogScroll.frame = CGRect(x: 0, y: Self.searchBottom, width: surface.bounds.width,
                                     height: max(0, height - Self.searchBottom))
        let document = AppsMenuCanvas()
        catalogButtons.removeAll()
        pinButtons.removeAll()
        searchResults = []
        let bottom: CGFloat
        if query.isEmpty {
            bottom = buildCatalog(in: document)
        } else if let applications {
            searchResults = applications.filter { $0.name.localizedStandardContains(query) }
            if searchResults.isEmpty {
                bottom = addStatus(String(localized: "No matching apps"), at: 12, to: document)
            } else {
                bottom = buildRows(searchResults, top: 6, in: document)
            }
        } else {
            bottom = addStatus(String(localized: "Loading apps…"), at: 12, to: document)
        }
        setDocument(document, height: bottom + 12, in: catalogScroll, position: scrollPosition)
        updateKeyLoop()
        if let focusID, folderID == nil { self.restoreFocus(on: focusID, in: catalogButtons) }
    }

    private func buildCatalog(in document: AppsMenuCanvas) -> CGFloat {
        addHeading(String(localized: "Pinned"), y: 31, to: document)
        let pins = store.pins.compactMap { pin -> (AppsMenuPin, [AppsMenuApplication])? in
            let apps = pin.applicationIDs.compactMap { applicationsByID[$0] }
            return apps.isEmpty ? nil : (pin, apps)
        }
        let visiblePins = store.expanded ? pins : Array(pins.prefix(12))
        if pins.count > 12 {
            let expanded = store.expanded
            let title = expanded ? String(localized: "Show less") : String(localized: "Show all")
            let button = addTrailingControl(title, icon: expanded ? "chevron.up" : "chevron.down", y: 39,
                                            id: "expand", in: document) { [weak self] _ in
                guard let self else { return }
                store.expanded.toggle()
                rebuildCatalog(restoreFocus: "expand")
            }
            button.toolTip = title
        }
        for (index, entry) in visiblePins.enumerated() {
            let (pin, apps) = entry
            let x = horizontal(81 + CGFloat(index % 6) * 96)
            let y = 76 + CGFloat(index / 6) * Self.tilePitch
            let button = addTile(name: pin.name == nil ? apps[0].name : displayName(for: pin),
                                 apps: apps, isFolder: pin.name != nil, x: x, top: y,
                                 pitch: horizontal(96), in: document) { [weak self] _ in
                if pin.name == nil { self?.launch(apps[0]) } else { self?.openFolder(pin.id) }
            }
            button.identifier = NSUserInterfaceItemIdentifier("pin-\(pin.id)")
            pinButtons[pin.id] = button
            button.contextMenu = { [weak self] in
                if pin.name == nil { self?.appMenu(for: apps[0], topLevelPin: pin.id) }
                else { self?.folderMenu(pin) }
            }
        }
        let allTop = 103 + CGFloat((visiblePins.count + 5) / 6) * Self.tilePitch
        addHeading(String(localized: "All"), y: allTop, to: document)
        let title = String.localizedStringWithFormat(String(localized: "View: %@"), store.catalogMode.title)
        _ = addTrailingControl(title, icon: "chevron.up.chevron.down", y: allTop + 10,
                               id: "mode", filled: true, in: document) { [weak self] button in
            self?.showViewModes(at: button)
        }
        guard let applications else {
            return addStatus(String(localized: "Loading apps…"), at: allTop + 42, to: document)
        }
        guard !applications.isEmpty else {
            return addStatus(String(localized: "No apps available"), at: allTop + 42, to: document)
        }
        switch store.catalogMode {
        case .list, .grid:
            return buildAlphabetical(applications, top: allTop + 44.5, in: document)
        case .category:
            return buildCategories(applications, top: allTop + 34, in: document)
        }
    }

    private func buildAlphabetical(_ apps: [AppsMenuApplication], top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        var y = top
        let groups = Dictionary(grouping: apps) { app in
            guard let first = app.name.first, first.isLetter else { return "#" }
            return String(first).folding(options: .diacriticInsensitive, locale: .current).localizedUppercase
        }
        for key in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let group = groups[key] else { continue }
            let heading = makeLabel(key, size: 13)
            heading.frame = CGRect(x: horizontal(63), y: y, width: 42, height: 19)
            document.addSubview(heading)
            y += 40
            if store.catalogMode == .grid {
                for (index, app) in group.enumerated() {
                    let x = horizontal(81 + CGFloat(index % 6) * 96)
                    addAppTile(app, x: x, top: y + CGFloat(index / 6) * Self.tilePitch,
                               pitch: horizontal(96), in: document)
                }
                y += CGFloat((group.count + 5) / 6) * Self.tilePitch + 16
            } else {
                y = buildRows(group, top: y, in: document) + 10
            }
        }
        return y
    }

    private func buildRows(_ apps: [AppsMenuApplication], top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        for (index, app) in apps.enumerated() {
            let button = AppsMenuButton(title: app.name) { [weak self] _ in self?.launch(app) }
            button.identifier = applicationIdentifier(app, inFolder: false)
            button.contextMenu = { [weak self] in self?.appMenu(for: app) }
            let leading = horizontal(62)
            button.frame = CGRect(x: leading, y: top + CGFloat(index) * Self.rowPitch - 6,
                                  width: max(0, surface.bounds.width - leading * 2), height: 40)
            addIcon(icon(for: app), at: CGRect(x: horizontal(6), y: 8, width: 24, height: 24), to: button)
            let text = makeLabel(app.name, size: 12, weight: .medium)
            let textX = max(33, horizontal(45))
            text.frame = CGRect(x: textX, y: 11, width: max(0, button.frame.width - textX - 6), height: 18)
            text.setAccessibilityElement(false)
            button.addSubview(text)
            register(button, in: document)
        }
        return top + CGFloat(apps.count) * Self.rowPitch
    }

    private func buildCategories(_ apps: [AppsMenuApplication], top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        let groups = Dictionary(grouping: apps) { AppsMenuCategory(key: $0.category) }
        if let category, let group = groups[category] {
            let back = AppsMenuButton(title: category.title) { [weak self] _ in self?.showCategory(nil) }
            back.setAccessibilityLabel(String(localized: "Back"))
            back.image = menuSymbol("chevron.left", size: 10)
            back.imagePosition = .imageLeading
            back.font = .systemFont(ofSize: 13, weight: .semibold)
            back.usesNativeContent = true
            back.identifier = NSUserInterfaceItemIdentifier("category-back")
            back.frame = CGRect(x: horizontal(63), y: top, width: min(190, horizontal(260)), height: 26)
            register(back, in: document)
            return buildRows(group, top: top + 43, in: document)
        }
        let categories = AppsMenuCategory.allCases.filter { groups[$0] != nil }
        for (index, group) in categories.enumerated() {
            guard let groupApps = groups[group] else { continue }
            let left = horizontal(66 + CGFloat(index % 3) * 178)
            let y = top + CGFloat(index / 3) * 204
            let size = horizontal(154)
            let categoryButton = AppsMenuButton(title: group.title) { [weak self] _ in self?.showCategory(group) }
            categoryButton.identifier = NSUserInterfaceItemIdentifier("category-\(group)")
            categoryButton.frame = CGRect(x: left, y: y, width: size, height: 192)
            let tile = AppsMenuBox(radius: 9, fill: .white.withAlphaComponent(0.075))
            tile.frame = CGRect(x: 0, y: 0, width: size, height: 154)
            categoryButton.addSubview(tile)
            let name = makeLabel(group.title, size: 12, alignment: .center)
            name.frame = CGRect(x: 0, y: 165, width: size, height: 25)
            name.setAccessibilityElement(false)
            categoryButton.addSubview(name)
            register(categoryButton, in: document)
            for (appIndex, app) in groupApps.prefix(4).enumerated() {
                let button = AppsMenuButton(title: app.name) { [weak self] _ in self?.launch(app) }
                button.identifier = applicationIdentifier(app, inFolder: false)
                button.contextMenu = { [weak self] in self?.appMenu(for: app) }
                button.toolTip = app.name
                let iconSize = max(0, min(40, size / 2 - 10))
                let x = left + size * (appIndex % 2 == 0 ? 0.28 : 0.72)
                button.frame = CGRect(x: x - iconSize / 2 - 4, y: y + 21 + CGFloat(appIndex / 2) * 68,
                                      width: iconSize + 8, height: 48)
                addIcon(icon(for: app), at: CGRect(x: 4, y: (48 - iconSize) / 2,
                                                  width: iconSize, height: iconSize), to: button)
                register(button, in: document)
            }
        }
        return top + CGFloat((categories.count + 2) / 3) * 204
    }

    private func showCategory(_ selection: AppsMenuCategory?) {
        let oldCategory = category
        if oldCategory == nil { categoryPosition = catalogScroll.contentView.bounds.origin }
        category = selection
        if selection != nil {
            let y = (catalogButtons.first { $0.identifier?.rawValue == "mode" }?.frame.minY ?? 0) - 20
            rebuildCatalog(position: CGPoint(x: 0, y: max(0, y)), restoreFocus: "category-back")
        } else {
            rebuildCatalog(position: categoryPosition, restoreFocus: oldCategory.map { "category-\($0)" })
        }
    }

    private func showViewModes(at button: AppsMenuButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in AppsMenuCatalogMode.allCases {
            let item = TaskbarNativeMenuFactory.actionItem(title: mode.title) { [weak self] in
                guard let self else { return }
                store.catalogMode = mode
                category = nil
                rebuildCatalog(restoreFocus: "mode")
            }
            item.state = store.catalogMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
    }

    private func addHeading(_ title: String, y: CGFloat, to view: NSView) {
        let label = makeLabel(title, size: 13, weight: .semibold)
        label.frame = CGRect(x: horizontal(62), y: y, width: horizontal(175), height: 22)
        view.addSubview(label)
    }

    private func addStatus(_ title: String, at y: CGFloat, to view: NSView) -> CGFloat {
        let label = makeLabel(title, size: 12)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: horizontal(63), y: y, width: horizontal(515), height: 22)
        view.addSubview(label)
        return y + 30
    }

    private func addTrailingControl(_ title: String, icon: String, y: CGFloat, id: String,
                                    filled: Bool = false, in view: NSView,
                                    action: @escaping (AppsMenuButton) -> Void) -> AppsMenuButton {
        let button = AppsMenuButton(title: title, action: action)
        button.image = menuSymbol(icon, size: 9)
        button.imagePosition = .imageTrailing
        button.font = .systemFont(ofSize: 12)
        button.usesNativeContent = true
        button.hasBackground = filled
        button.identifier = NSUserInterfaceItemIdentifier(id)
        let width = max(86, min(horizontal(235), button.intrinsicContentSize.width + 14))
        button.frame = CGRect(x: horizontal(584) - width, y: y - 11, width: width, height: 22)
        register(button, in: view)
        return button
    }

    @discardableResult
    private func addAppTile(_ app: AppsMenuApplication, x: CGFloat, top: CGFloat, pitch: CGFloat,
                            in view: NSView, folder: Bool = false) -> AppsMenuButton {
        let button = addTile(name: app.name, apps: [app], isFolder: false, x: x, top: top,
                             pitch: pitch, in: view, folder: folder) { [weak self] _ in
            self?.launch(app)
        }
        button.identifier = applicationIdentifier(app, inFolder: folder)
        button.contextMenu = { [weak self] in self?.appMenu(for: app) }
        return button
    }

    private func addTile(name: String, apps: [AppsMenuApplication], isFolder: Bool, x: CGFloat, top: CGFloat,
                         pitch: CGFloat, in view: NSView, folder: Bool = false,
                         action: @escaping (AppsMenuButton) -> Void) -> AppsMenuButton {
        let width = max(1, pitch - 2)
        let button = AppsMenuButton(title: name, action: action)
        button.frame = CGRect(x: x - width / 2, y: top - 7, width: width, height: 79)
        button.toolTip = name
        if isFolder {
            let preview = AppsMenuBox(radius: 8, fill: .white.withAlphaComponent(0.14))
            preview.frame = CGRect(x: (width - 32) / 2, y: 7, width: 32, height: 32)
            button.addSubview(preview)
            for (index, app) in apps.prefix(4).enumerated() {
                let x = preview.frame.minX + 3 + CGFloat(index % 2) * 13
                let y = preview.frame.minY + 3 + CGFloat(index / 2) * 13
                addIcon(icon(for: app), at: CGRect(x: x, y: y, width: 13, height: 13), to: button)
            }
        } else if let app = apps.first {
            let size = min(38, width)
            addIcon(icon(for: app), at: CGRect(x: (width - size) / 2, y: 4, width: size, height: size), to: button)
        }
        let label = makeLabel(name, size: folder ? 11 : 11.5, alignment: .center)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.frame = CGRect(x: 1, y: 46.5, width: max(0, width - 2), height: 29)
        label.setAccessibilityElement(false)
        button.addSubview(label)
        register(button, in: view, folder: folder)
        return button
    }

    private func displayName(for folder: AppsMenuPin) -> String {
        guard let name = folder.name, !name.isEmpty else { return String(localized: "Folder") }
        return name
    }

    private func launch(_ app: AppsMenuApplication) {
        dismiss()
        store.launch(app)
    }
}

private extension AppsMenuView {
    func appMenu(for app: AppsMenuApplication, topLevelPin: UUID? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let membership = store.pins.first { $0.applicationIDs.contains(app.id) }
        if membership == nil {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Pin")) { [weak self] in
                self?.updatePins { $0.pin(app) }
            })
        } else {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Unpin")) { [weak self] in
                self?.updatePins { $0.unpin(app.id) }
            })
        }
        if let pin = membership, pin.name == nil {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Create Folder")) { [weak self] in
                guard let self, let folder = store.createFolder(from: pin.id) else { return }
                rebuildCatalog()
                openFolder(folder)
            })
        }
        let destinations = membership.map { pin in store.pins.filter { $0.name != nil && $0.id != pin.id } } ?? []
        if !destinations.isEmpty {
            let name = String(localized: "Move to Folder")
            let submenu = NSMenu(title: name)
            submenu.autoenablesItems = false
            for folder in destinations {
                submenu.addItem(TaskbarNativeMenuFactory.actionItem(title: displayName(for: folder)) { [weak self] in
                    self?.updatePins { $0.moveApp(app.id, to: folder.id) }
                })
            }
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if membership?.name != nil {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Remove from Folder")) { [weak self] in
                self?.updatePins { $0.removeFromFolder(app.id) }
            })
        }
        if let topLevelPin { addReordering(to: menu, for: topLevelPin) }
        return menu
    }

    func folderMenu(_ pin: AppsMenuPin) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Rename Folder")) { [weak self] in
            self?.openFolder(pin.id, rename: true)
        })
        menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Unpin")) { [weak self] in
            self?.updatePins { $0.unpinEntry(pin.id) }
        })
        addReordering(to: menu, for: pin.id)
        return menu
    }

    func addReordering(to menu: NSMenu, for id: UUID) {
        let pins = store.pins
        guard let index = pins.firstIndex(where: { $0.id == id }), pins.count > 1 else { return }
        menu.addItem(.separator())
        if index > 0 {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Move Earlier")) { [weak self] in
                self?.movePin(id, offset: -1)
            })
        }
        if index < pins.count - 1 {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Move Later")) { [weak self] in
                self?.movePin(id, offset: 1)
            })
        }
    }

    func movePin(_ id: UUID, offset: Int) {
        guard let index = store.pins.firstIndex(where: { $0.id == id }) else { return }
        updatePins { $0.movePin(id, to: index + offset) }
        if folderID == nil, let button = pinButtons[id] { focus(button) }
    }

    func updatePins(_ update: (AppsMenuStore) -> Void) {
        update(store)
        rebuildCatalog()
        if folderID != nil { rebuildFolder() }
    }

    func openFolder(_ id: UUID, rename: Bool = false) {
        guard store.pins.contains(where: { $0.id == id && $0.name != nil }) else { return }
        folderID = id
        var draft: String?
        if rename, let folder = store.pins.first(where: { $0.id == id }) {
            draft = displayName(for: folder)
        }
        rebuildFolder(draft: draft)
        if !rename, let folderTitle { focus(folderTitle) }
    }

    func closeFolder() {
        let closedID = folderID
        folderID = nil
        renameField = nil
        folderScroll = nil
        folderTitle = nil
        folderButtons.removeAll()
        folderGlass?.removeFromSuperview()
        folderGlass = nil
        folderShield?.removeFromSuperview()
        folderShield = nil
        setCatalogAccessibilityHidden(false)
        updateKeyLoop()
        if let closedID, let button = pinButtons[closedID] { focus(button) } else { focusSearch() }
    }

    func rebuildFolder(draft: String? = nil) {
        guard let id = folderID, let folder = store.pins.first(where: { $0.id == id && $0.name != nil }) else {
            closeFolder()
            return
        }
        let apps = folder.applicationIDs.compactMap { applicationsByID[$0] }
        let position = folderScroll?.contentView.bounds.origin ?? .zero
        let editing = draft ?? renameField?.stringValue
        let focused = focusedIdentifier(in: folderButtons)
        renameField = nil
        folderButtons.removeAll()
        folderGlass?.removeFromSuperview()
        folderShield?.removeFromSuperview()
        setCatalogAccessibilityHidden(true)
        let shield = AppsMenuCanvas(frame: surface.bounds)
        shield.setAccessibilityElement(false)
        shield.onClick = { [weak self] in
            self?.finishRenaming(save: true, focusTitle: false)
            self?.closeFolder()
        }
        folderShield = shield
        surface.addSubview(shield)
        let size = CGSize(width: min(450, max(0, surface.bounds.width - 32)),
                          height: min(378, max(0, surface.bounds.height - 32)))
        let glass = NSGlassEffectView(frame: CGRect(x: (surface.bounds.width - size.width) / 2,
                                                    y: (surface.bounds.height - size.height) / 2,
                                                    width: size.width, height: size.height))
        glass.style = .regular
        glass.cornerRadius = 16
        let body = AppsMenuCanvas(frame: CGRect(origin: .zero, size: size))
        body.autoresizingMask = [.width, .height]
        body.clipsToBounds = true
        glass.contentView = body
        folderGlass = glass
        surface.addSubview(glass)
        let titleWidth = min(320, max(0, size.width - 24))
        let renameFrame = CGRect(x: (size.width - titleWidth) / 2, y: 33, width: titleWidth, height: 40)
        let title = AppsMenuButton(title: displayName(for: folder)) { [weak self] _ in self?.openFolder(id, rename: true) }
        title.contextMenu = { [weak self] in self?.folderMenu(folder) }
        title.toolTip = String(localized: "Rename Folder")
        title.identifier = NSUserInterfaceItemIdentifier("folder-title")
        title.usesNativeContent = true
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.frame = renameFrame
        folderTitle = title
        if editing == nil { register(title, in: body, folder: true) }
        let scroll = AppsMenuScrollView(horizontal: false)
        scroll.frame = CGRect(x: 0, y: 87, width: size.width, height: max(0, size.height - 96))
        body.addSubview(scroll)
        folderScroll = scroll
        let document = AppsMenuCanvas()
        let pitch = min(96, size.width / 4)
        let start = (size.width - 3 * pitch) / 2
        for (index, app) in apps.enumerated() {
            addAppTile(app, x: start + CGFloat(index % 4) * pitch, top: 17 + CGFloat(index / 4) * Self.tilePitch,
                       pitch: pitch, in: document, folder: true)
        }
        let height = 17 + CGFloat((apps.count + 3) / 4) * Self.tilePitch
        setDocument(document, height: height, in: scroll, position: position)
        if let editing {
            let backing = AppsMenuBox(radius: 12, fill: .white.withAlphaComponent(0.08),
                                      border: .keyboardFocusIndicatorColor.withAlphaComponent(0.56))
            backing.frame = renameFrame
            body.addSubview(backing)
            let field = NSTextField(string: editing)
            field.setAccessibilityLabel(String(localized: "Rename Folder"))
            field.font = .systemFont(ofSize: 18, weight: .semibold)
            field.alignment = .center
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.backgroundColor = .clear
            field.focusRingType = .none
            field.delegate = self
            let line = renameFrame.insetBy(dx: 8, dy: 9)
            field.frame = field.frame(forAlignmentRect: line)
            renameField = field
            body.addSubview(field)
            if draft != nil { field.selectText(nil) } else { window?.makeFirstResponder(field) }
        }
        updateKeyLoop()
        if let focused, editing == nil {
            if let button = folderButtons.first(where: { $0.identifier?.rawValue == focused }) { focus(button) }
            else { focus(title) }
        }
    }

    func setCatalogAccessibilityHidden(_ hidden: Bool) {
        searchField.setAccessibilityHidden(hidden)
        catalogScroll.setAccessibilityHidden(hidden)
        footer.setAccessibilityHidden(hidden)
    }

    func observeApplicationPolicies() {
        guard window != nil else { return }
        activationObservations = NSWorkspace.shared.runningApplications.map { app in
            app.observe(\.activationPolicy, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshRunningApps() }
            }
        }
        refreshRunningApps()
    }

    func finishRenaming(save: Bool, focusTitle: Bool = true) {
        guard let field = renameField, let id = folderID else { return }
        renameField = nil
        if save, let folder = store.pins.first(where: { $0.id == id }), field.stringValue != displayName(for: folder) {
            store.renameFolder(id, to: field.stringValue)
            rebuildCatalog()
        }
        rebuildFolder()
        if focusTitle, let folderTitle { focus(folderTitle) }
    }

    func refreshRunningApps() {
        let new = store.runningApplications()
        guard new != runningApps else { return }
        runningApps = new
        rebuildRunningFooter()
    }

    func rebuildRunningFooter() {
        let focusID = focusedIdentifier(in: runningButtons)
        let pitch: CGFloat = 46
        let available = max(0, surface.bounds.width - horizontal(108))
        let total = CGFloat(runningApps.count) * pitch
        let nextIconPreview: CGFloat = 28
        let width = total > available && available >= pitch + nextIconPreview
            ? floor((available - nextIconPreview) / pitch) * pitch + nextIconPreview
            : min(total, available)
        let position = runningScroll.contentView.bounds.origin
        runningScroll.frame = CGRect(x: (surface.bounds.width - width) / 2, y: 6, width: width, height: 56)
        let document = AppsMenuCanvas(frame: CGRect(x: 0, y: 0, width: total, height: 56))
        runningButtons.removeAll()
        for (index, app) in runningApps.enumerated() {
            let name = app.localizedName ?? app.bundleIdentifier ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? String(app.processIdentifier)
            let button = AppsMenuButton(title: name) { [weak self] _ in
                self?.dismiss()
                app.activate(options: [])
            }
            button.toolTip = name
            button.identifier = NSUserInterfaceItemIdentifier("running-\(app.processIdentifier)")
            button.frame = CGRect(x: CGFloat(index) * pitch, y: 0, width: pitch, height: 50)
            let image = app.icon ?? NSImage(named: NSImage.applicationIconName)
            addIcon(image, at: CGRect(x: 2, y: 0, width: 42, height: 42), to: button)
            let indicator = AppsMenuBox(radius: 1.5, fill: .labelColor.withAlphaComponent(0.76))
            indicator.frame = CGRect(x: 21.5, y: 44, width: 3, height: 3)
            button.addSubview(indicator)
            document.addSubview(button)
            attachNavigation(to: button)
            runningButtons.append(button)
        }
        runningScroll.hasHorizontalScroller = total > width && width > 0
        runningScroll.documentView = document
        scroll(runningScroll, to: position)
        updateKeyLoop()
        if let focusID, folderID == nil, query.isEmpty { restoreFocus(on: focusID, in: runningButtons) }
    }

    func setDocument(_ document: NSView, height: CGFloat, in scroller: NSScrollView, position: CGPoint) {
        document.frame = CGRect(x: 0, y: 0, width: scroller.frame.width, height: max(height, scroller.frame.height))
        scroller.hasVerticalScroller = height > scroller.frame.height
        scroller.documentView = document
        scroll(scroller, to: position)
    }

    func scroll(_ view: NSScrollView, to position: CGPoint) {
        let clip = view.contentView
        let constrained = clip.constrainBoundsRect(CGRect(origin: position, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        view.reflectScrolledClipView(clip)
    }

    func register(_ button: AppsMenuButton, in view: NSView, folder: Bool = false) {
        view.addSubview(button)
        attachNavigation(to: button)
        if folder { folderButtons.append(button) } else { catalogButtons.append(button) }
    }

    func attachNavigation(to button: AppsMenuButton) {
        button.onNavigate = { [weak self, weak button] direction in
            guard let self, let button else { return false }
            return navigate(from: button, toward: direction)
        }
        button.onEscape = { [weak self] in self?.cancelOperation(nil) }
    }

    var activeButtons: [AppsMenuButton] {
        if folderID != nil { return folderButtons }
        return query.isEmpty ? catalogButtons + runningButtons : catalogButtons
    }

    func updateKeyLoop() {
        var views: [NSView] = activeButtons
        if let renameField {
            views.insert(renameField, at: 0)
        } else if folderID == nil {
            views.insert(searchField, at: 0)
        }
        for (index, view) in views.enumerated() {
            view.nextKeyView = views[(index + 1) % views.count]
        }
    }

    func focus(_ button: AppsMenuButton) {
        guard let window, window.makeFirstResponder(button) else { return }
        button.scrollToVisible(button.bounds)
    }

    func focusedIdentifier(in buttons: [AppsMenuButton]) -> String? {
        guard let responder = window?.firstResponder as? AppsMenuButton,
              buttons.contains(where: { $0 === responder }) else { return nil }
        return responder.identifier?.rawValue
    }

    func restoreFocus(on identifier: String, in buttons: [AppsMenuButton]) {
        if let button = buttons.first(where: { $0.identifier?.rawValue == identifier }) { focus(button) }
        else { focusSearch() }
    }

    func applicationIdentifier(_ app: AppsMenuApplication, inFolder: Bool) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier((inFolder ? "folder-app-" : "catalog-app-") + app.id)
    }

    func icon(for app: AppsMenuApplication) -> NSImage {
        if let cached = applicationIcons[app.id] { return cached }
        let image = store.icon(for: app)
        applicationIcons[app.id] = image
        return image
    }

    func navigate(from button: AppsMenuButton, toward direction: AppsMenuDirection) -> Bool {
        let frame = button.convert(button.bounds, to: surface)
        func nearest(in buttons: [AppsMenuButton]) -> AppsMenuButton? {
            var best: (button: AppsMenuButton, distance: CGFloat)?
            for candidate in buttons where candidate !== button {
                let rect = candidate.convert(candidate.bounds, to: surface)
                let dx = rect.midX - frame.midX
                let dy = rect.midY - frame.midY
                let distance: CGFloat
                switch direction {
                case .left: distance = dx < -0.5 ? -dx + abs(dy) * 3 : .infinity
                case .right: distance = dx > 0.5 ? dx + abs(dy) * 3 : .infinity
                case .up: distance = dy < -0.5 ? -dy + abs(dx) * 3 : .infinity
                case .down: distance = dy > 0.5 ? dy + abs(dx) * 3 : .infinity
                }
                if distance < (best?.distance ?? .infinity) { best = (candidate, distance) }
            }
            return best?.button
        }
        let inFooter = runningButtons.contains { $0 === button }
        let sameArea = folderID != nil ? folderButtons : inFooter ? runningButtons : catalogButtons
        let otherArea: [AppsMenuButton]
        if folderID == nil, query.isEmpty, direction == (inFooter ? .up : .down) {
            otherArea = inFooter ? catalogButtons : runningButtons
        } else { otherArea = [] }
        if let target = nearest(in: sameArea) ?? nearest(in: otherArea) {
            focus(target)
            return true
        }
        if direction == .up, folderID == nil {
            focusSearch()
            return true
        }
        return false
    }

    func makeLabel(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        label.alignment = alignment
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func addIcon(_ image: NSImage?, at frame: CGRect, to view: NSView) {
        let icon = NSImageView(frame: frame)
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        view.addSubview(icon)
    }

    func menuSymbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }
}

private final class AppsMenuCanvas: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

private final class AppsMenuBox: NSBox {
    init(radius: CGFloat, fill: NSColor, border: NSColor? = nil) {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        contentViewMargins = .zero
        fillColor = fill
        cornerRadius = radius
        borderWidth = border == nil ? 0 : 1
        if let border { borderColor = border }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum AppsMenuDirection: String {
    case left = "\u{f702}"
    case right = "\u{f703}"
    case up = "\u{f700}"
    case down = "\u{f701}"
}

private final class AppsMenuButton: NSButton {
    let onActivate: (AppsMenuButton) -> Void
    var contextMenu: (() -> NSMenu?)?
    var onNavigate: ((AppsMenuDirection) -> Bool)?
    var onEscape: (() -> Void)?
    var usesNativeContent = false { didSet { isTransparent = !usesNativeContent } }
    var hasBackground = false { didSet { updateSelection() } }
    private let selection = AppsMenuBox(radius: 5, fill: .clear)
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private var focused = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    init(title: String, action: @escaping (AppsMenuButton) -> Void) {
        onActivate = action
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        setButtonType(.momentaryPushIn)
        isBordered = false
        isTransparent = true
        focusRingType = .none
        target = self
        self.action = #selector(invoke)
        selection.autoresizingMask = [.width, .height]
        addSubview(selection)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selection.frame = bounds
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateSelection()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateSelection()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        updateSelection()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focused = true
        updateSelection()
        scrollToVisible(bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focused = false
        updateSelection()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?() ?? super.menu(for: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu?() else { return false }
        return menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.maxY), in: self)
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if let direction = AppsMenuDirection(rawValue: characters), onNavigate?(direction) == true { return }
        switch characters {
        case "\u{1b}": onEscape?()
        case "\r", "\u{3}", " ": performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
    }

    private func updateSelection() {
        selection.frame = bounds
        selection.borderWidth = focused ? 1 : 0
        selection.borderColor = .keyboardFocusIndicatorColor
        if pressed || hovered {
            selection.fillColor = .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(pressed ? 0.88 : 0.55)
        } else if hasBackground {
            selection.fillColor = .white.withAlphaComponent(0.08)
        } else {
            selection.fillColor = .clear
        }
    }

    @objc private func invoke() { onActivate(self) }
}

private class AppsMenuScrollView: NSScrollView {
    init(horizontal: Bool) {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = horizontal ? .automatic : .none
        verticalScrollElasticity = horizontal ? .none : .automatic
        scrollerInsets = horizontal ? NSEdgeInsets() : NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 2)
        hasHorizontalScroller = horizontal
        hasVerticalScroller = !horizontal
    }

    required init?(coder: NSCoder) { nil }
}

private final class AppsMenuRunningScrollView: AppsMenuScrollView {
    private let fade = CAGradientLayer()

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
           let documentView, documentView.bounds.width > contentView.bounds.width {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
            let bounds = contentView.bounds.offsetBy(dx: -event.scrollingDeltaY * multiplier, dy: 0)
            contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        let remaining = (documentView?.bounds.width ?? 0) - clip.bounds.maxX
        guard remaining > 0.5, clip.bounds.width > 12 else {
            clip.layer?.mask = nil
            return
        }
        clip.wantsLayer = true
        guard let layer = clip.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.locations = [0, NSNumber(value: 1 - 12 / clip.bounds.width), 1]
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                       CGColor(gray: 0, alpha: 1 - 0.8 * min(1, remaining / 12))]
        layer.mask = fade
        CATransaction.commit()
    }
}

private extension AppsMenuCatalogMode {
    var title: String {
        switch self {
        case .list: String(localized: "List")
        case .grid: String(localized: "Grid")
        case .category: String(localized: "Category")
        }
    }
}

private enum AppsMenuCategory: CaseIterable {
    case utilities, productivity, creativity, reference, developerTools, education, entertainment, games, socialNetworking, other

    init(key: String) {
        switch key {
        case "utilities", "healthcare-fitness", "medical", "weather": self = .utilities
        case "productivity", "business", "finance": self = .productivity
        case "graphics-design", "photography", "music", "video": self = .creativity
        case "reference", "books", "news", "travel", "navigation": self = .reference
        case "developer-tools": self = .developerTools
        case "education": self = .education
        case "entertainment", "lifestyle", "sports": self = .entertainment
        case "games": self = .games
        case _ where key.hasSuffix("-games"): self = .games
        case "social-networking": self = .socialNetworking
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .utilities: String(localized: "Utilities")
        case .productivity: String(localized: "Productivity")
        case .creativity: String(localized: "Creativity")
        case .reference: String(localized: "Reference")
        case .developerTools: String(localized: "Developer Tools")
        case .education: String(localized: "Education")
        case .entertainment: String(localized: "Entertainment")
        case .games: String(localized: "Games")
        case .socialNetworking: String(localized: "Social Networking")
        case .other: String(localized: "Other")
        }
    }
}
