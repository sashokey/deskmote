import AppKit
#if DEBUG
import os
#endif

@MainActor
final class AppsMenuView: NSGlassEffectView, NSSearchFieldDelegate {
    private static let designWidth: CGFloat = 642
    private static let searchBottom: CGFloat = 65
    private static let footerHeight: CGFloat = 65
    private static let rowPitch: CGFloat = 42
    private static let tilePitch: CGFloat = 84
    private static let tileIconSize: CGFloat = 38
    private static let pinShiftAnimationKey = "apps-pin-shift"
    #if DEBUG
    private static let pinDropLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "apps-pins")
    #endif

    private struct PinnedLayout: Equatable {
        let pins: [AppsMenuPin]
        let expanded: Bool
    }

    private enum PinDrop: Equatable {
        case group(UUID)
        case insert(beside: UUID, after: Bool)

        var groupTarget: UUID? {
            if case .group(let target) = self { return target }
            return nil
        }
    }

    private struct PinDrag {
        let source: UUID
        let order: [UUID]
        let frames: [UUID: CGRect]
        let canGroup: Bool
        var drop: PinDrop?

        func insertionIndex(in order: [UUID], beside target: UUID, after: Bool) -> Int? {
            order.firstIndex(of: target).map { $0 + (after ? 1 : 0) }
        }
    }

    private struct CatalogContent {
        let document: AppsMenuCanvas
        let height: CGFloat
        let buttons: [AppsMenuButton]
        let pinButtons: [UUID: AppsMenuButton]
    }

    private enum CatalogTransition {
        case none, pinned, expand, content
    }

    private let store: AppsMenuStore
    private let presentViewModes: (NSMenu, NSView) -> Void
    private let reduceMotion: () -> Bool
    private let runningWindows: (pid_t) -> [TaskbarWindowPresentation]
    private let activateWindow: (WindowActionIdentity) -> Void
    private let dismiss: () -> Void
    private let surface = AppsMenuCanvas()
    private let searchBacking = AppsMenuBox(radius: 16, fill: .white.withAlphaComponent(0.08),
                                          border: .white.withAlphaComponent(0.17))
    private let searchField = NSSearchField()
    private let catalogScroll = AppsMenuScrollView(horizontal: false)
    private let browsingDocument = AppsMenuCanvas()
    private let hoverEffects = [AppsMenuHoverEffect(), AppsMenuHoverEffect()]
    private var activeHoverEffect: AppsMenuHoverEffect?
    private let footer = AppsMenuCanvas()
    private let footerRule = AppsMenuBox(radius: 0, fill: .white.withAlphaComponent(0.12))
    private let runningScroll = AppsMenuRunningScrollView(horizontal: true)
    private var fileManagerButton: AppsMenuButton?
    private var runningTooltip: AppsMenuRunningTooltip?
    private var catalog: AppsMenuCatalog?
    private var applications: [AppsMenuApplication]? { catalog?.all }
    private var catalogNotice: String? {
        catalog?.allUnavailable == true ? String(localized: "macOS app catalog is unavailable.") : nil
    }
    private var applicationsByID: [String: AppsMenuApplication] = [:]
    private var runningApps: [NSRunningApplication] = []
    private var runningObservation: NSKeyValueObservation?
    private var frontmostObservation: NSKeyValueObservation?
    private var activationObservations: [(application: NSRunningApplication, token: NSKeyValueObservation)] = []
    private var catalogTask: Task<Void, Never>?
    private var viewModePreparation: Task<Void, Never>?
    private var lastSize = CGSize.zero
    private var query = ""
    private(set) var searchResults: [AppsMenuApplication] = []
    private var browsingPosition = CGPoint.zero
    private var alphabetAnchor: String?
    private var alphabetPosition = CGPoint.zero
    private var category: AppsMenuCategory?
    private var categoryPosition = CGPoint.zero
    private var catalogWidth: CGFloat?
    private var pinnedLayout: PinnedLayout?
    private var pinnedContent: CatalogContent?
    private var allContents: [AppsMenuCatalogMode: CatalogContent] = [:]
    private weak var displayedPinned: AppsMenuCanvas?
    private weak var displayedAll: AppsMenuCanvas?
    private var folderID: UUID?
    private var folderShield: AppsMenuCanvas?
    private var folderGlass: NSGlassEffectView?
    private var folderScroll: AppsMenuScrollView?
    private var renameField: NSTextField?
    private var catalogButtons: [AppsMenuButton] = []
    private var pinButtons: [UUID: AppsMenuButton] = [:]
    private var pinDrag: PinDrag?
    #if DEBUG
    private var pinDragResources: ActionResourceLog.Span?
    #endif
    private weak var hoveredButton: AppsMenuButton?
    private var acceptsMenuActions = true
    private(set) var catalogDeferredUntilFrame: Bool
    private var hasPresented = false
    private var displayedMode: AppsMenuCatalogMode?

    #if DESKMOTE_TEST
    var preparedViewModes: Set<AppsMenuCatalogMode> { Set(allContents.keys) }
    #endif

    init(frame: CGRect, store: AppsMenuStore,
         presentViewModes: @escaping (NSMenu, NSView) -> Void = { menu, anchor in
             menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 3), in: anchor)
         },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         runningWindows: @escaping (pid_t) -> [TaskbarWindowPresentation] = { _ in [] },
         activateWindow: @escaping (WindowActionIdentity) -> Void = { _ in },
         deferCatalog: Bool = false,
         dismiss: @escaping () -> Void) {
        self.store = store
        self.presentViewModes = presentViewModes
        self.reduceMotion = reduceMotion
        self.runningWindows = runningWindows
        self.activateWindow = activateWindow
        self.dismiss = dismiss
        catalogDeferredUntilFrame = deferCatalog
        super.init(frame: frame)
        style = .regular
        cornerRadius = 20
        surface.autoresizingMask = [.width, .height]
        surface.clipsToBounds = true
        contentView = surface
        surface.addSubview(searchBacking)
        surface.addSubview(searchField)
        surface.addSubview(catalogScroll)
        catalogScroll.clipsToBounds = true
        surface.addSubview(footer)
        footer.addSubview(footerRule)
        footer.addSubview(runningScroll)
        catalogScroll.onClipChanged = { [weak self] in
            self?.renderVisibleCatalogButtons()
            self?.refreshHover()
        }
        runningScroll.onClipChanged = { [weak self] in self?.refreshHover() }
        searchField.cell = AppsMenuSearchFieldCell(textCell: "")
        searchField.isEditable = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        let placeholder = String(localized: "Search for apps")
        searchField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
            .baselineOffset: -1.75,
        ])
        searchField.setAccessibilityLabel(placeholder)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.delegate = self
        if !deferCatalog {
            if let snapshot = store.catalogSnapshot { applyCatalog(snapshot) }
            runningApps = store.runningApplications()
        }
        layoutContents()
        if !deferCatalog { loadCatalog() }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        #if DEBUG
        pinDragResources?.finish()
        #endif
        stopObservingApplications()
        catalogTask?.cancel()
        viewModePreparation?.cancel()
    }

    override func layout() {
        super.layout()
        if bounds.size != lastSize { layoutContents() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingApplications()
        guard window != nil, !catalogDeferredUntilFrame else {
            refreshHover()
            return
        }
        startObservingApplications()
    }

    private func startObservingApplications() {
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeApplicationPolicies() }
        }
        frontmostObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshRunningApps() }
        }
        observeApplicationPolicies()
    }

    func prepareForPresentation(size: CGSize) {
        acceptsMenuActions = true
        var rebuild = false
        if hasPresented {
            rebuild = !query.isEmpty || alphabetAnchor != nil || category != nil
            query = ""
            alphabetAnchor = nil
            category = nil
            browsingPosition = .zero
            alphabetPosition = .zero
            categoryPosition = .zero
            searchField.stringValue = ""
            clearFolder()
        }
        if !catalogDeferredUntilFrame {
            if let latest = store.catalogSnapshot, catalog != latest {
                applyCatalog(latest)
                rebuild = true
            }
            rebuild = rebuild || displayedMode != store.catalogMode ||
                pinnedLayout != PinnedLayout(pins: store.pins, expanded: store.expanded)
        }
        hasPresented = true
        setFrameSize(size)
        if size != lastSize {
            layoutContents()
        } else if rebuild {
            rebuildCatalog(position: .zero)
        }
        if catalogScroll.contentView.bounds.origin != .zero { scroll(catalogScroll, to: .zero) }
        if runningScroll.contentView.bounds.origin != .zero { scroll(runningScroll, to: .zero) }
        if !catalogDeferredUntilFrame { loadCatalog() }
    }

    func presentedFirstFrame() {
        guard catalogDeferredUntilFrame, acceptsMenuActions, window != nil else { return }
        catalogDeferredUntilFrame = false
        startObservingApplications()
        if fileManagerButton == nil { rebuildRunningFooter() }
        loadCatalog()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func stopMenuActions() {
        acceptsMenuActions = false
        catalogTask?.cancel()
        catalogTask = nil
        viewModePreparation?.cancel()
        viewModePreparation = nil
        resetPinDrag()
        runningTooltip?.removeFromSuperview()
    }

    private func loadCatalog() {
        catalogTask?.cancel()
        let store = self.store
        catalogTask = Task { [weak self] in
            let snapshot = await store.loadCatalog()
            guard !Task.isCancelled, let self, self.catalog != snapshot else { return }
            applyCatalog(snapshot)
            rebuildCatalog()
        }
    }

    private func applyCatalog(_ snapshot: AppsMenuCatalog) {
        viewModePreparation?.cancel()
        viewModePreparation = nil
        catalog = snapshot
        let available = snapshot.installed + (snapshot.all ?? [])
        applicationsByID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pinnedContent = nil
        allContents.removeAll()
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
        #if DEBUG
        let span = ActionResourceLog.begin("apps.search")
        defer { span?.finish() }
        #endif
        let changesScreen = query.isEmpty != newQuery.isEmpty
        if query.isEmpty {
            browsingPosition = alphabetAnchor == nil ? catalogScroll.contentView.bounds.origin : alphabetPosition
            alphabetAnchor = nil
        }
        query = newQuery
        rebuildCatalog(position: newQuery.isEmpty ? browsingPosition : .zero,
                       transition: changesScreen ? .content : .none)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { searchFieldChanged() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renameField else { return }
        Task { @MainActor [weak self, weak field] in
            guard let self, let field, field === renameField else { return }
            finishRenaming()
        }
    }

    private func rebuildCatalog(position: CGPoint? = nil, reveal identifier: String? = nil,
                                transition: CatalogTransition = .none) {
        #if DEBUG
        let span = ActionResourceLog.begin("apps.catalog.render")
        defer { span?.finish() }
        #endif
        resetPinDrag()
        let previousPins = transition == .pinned || transition == .expand ? pinButtons : [:]
        let scrollPosition = position ?? catalogScroll.contentView.bounds.origin
        let height = query.isEmpty ? footer.frame.minY : surface.bounds.height
        footer.isHidden = !query.isEmpty
        catalogScroll.frame = CGRect(x: 0, y: Self.searchBottom, width: surface.bounds.width,
                                     height: max(0, height - Self.searchBottom))
        let width = surface.bounds.width
        if catalogWidth != width {
            viewModePreparation?.cancel()
            viewModePreparation = nil
            catalogWidth = width
            pinnedContent = nil
            allContents.removeAll()
        }
        searchResults = []
        if query.isEmpty, alphabetAnchor != nil {
            let content = buildContent(using: buildAlphabetIndex)
            catalogButtons = content.buttons
            setDocument(content.document, height: content.height + 12, in: catalogScroll, position: scrollPosition)
            if transition == .content { animateEntry(content.document) }
        } else if query.isEmpty {
            let layout = PinnedLayout(pins: store.pins, expanded: store.expanded)
            if pinnedLayout != layout {
                pinnedLayout = layout
                pinnedContent = nil
            }
            let pinned = pinnedContent ?? buildContent(using: buildPinned)
            pinnedContent = pinned
            let cacheable = category == nil && applications != nil
            let mode = store.catalogMode
            displayedMode = mode
            let all = (cacheable ? allContents[mode] : nil) ?? buildContent { buildAll(in: $0, mode: mode) }
            if cacheable { allContents[mode] = all }
            if displayedPinned !== pinned.document {
                displayedPinned?.removeFromSuperview()
                browsingDocument.addSubview(pinned.document)
                displayedPinned = pinned.document
            }
            if displayedAll !== all.document {
                displayedAll?.removeFromSuperview()
                browsingDocument.addSubview(all.document)
                displayedAll = all.document
            }
            pinned.document.frame = CGRect(x: 0, y: 0, width: width, height: pinned.height)
            all.document.frame = CGRect(x: 0, y: pinned.height, width: width, height: all.height)
            catalogButtons = pinned.buttons + all.buttons
            pinButtons = pinned.pinButtons
            setDocument(browsingDocument, height: pinned.height + all.height + 12, in: catalogScroll, position: scrollPosition)
            if transition == .pinned || transition == .expand {
                animatePinnedTiles(previous: previousPins, current: pinned.pinButtons,
                                   animateRemoval: transition == .pinned)
            } else if transition == .content {
                animateEntry(all.document)
            }
        } else {
            let content = buildContent(using: buildSearch)
            catalogButtons = content.buttons
            setDocument(content.document, height: content.height + 12, in: catalogScroll, position: scrollPosition)
            if transition == .content { animateEntry(content.document) }
        }
        if let identifier, folderID == nil,
           let button = catalogButtons.first(where: { $0.identifier?.rawValue == identifier }) {
            button.scrollToVisible(button.bounds)
        }
        prepareViewModes()
    }

    private func prepareViewModes() {
        guard acceptsMenuActions, applications != nil, category == nil, viewModePreparation == nil,
              allContents.count < AppsMenuCatalogMode.allCases.count else { return }
        viewModePreparation = Task(priority: .utility) { [weak self] in
            for mode in AppsMenuCatalogMode.allCases {
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                if category == nil, allContents[mode] == nil {
                    allContents[mode] = buildContent { buildAll(in: $0, mode: mode) }
                }
            }
            self?.viewModePreparation = nil
        }
    }

    private func animatePinnedTiles(previous: [UUID: AppsMenuButton], current: [UUID: AppsMenuButton], animateRemoval: Bool) {
        guard window != nil, !reduceMotion() else { return }
        for (id, tile) in current where previous[id] == nil && tile.pendingContent == nil {
            tile.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.35
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            tile.layer?.add(fade, forKey: "apps-pin-fade")
        }
        guard animateRemoval else { return }
        for (id, tile) in previous where current[id] == nil && tile.pendingContent == nil {
            let opacity = tile.layer?.presentation()?.opacity ?? 1
            tile.isEnabled = false
            tile.setAccessibilityHidden(true)
            tile.removeFromSuperview()
            browsingDocument.addSubview(tile)
            tile.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            fade.duration = 0.13
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak tile] in
                Task { @MainActor in tile?.removeFromSuperview() }
            }
            tile.layer?.add(fade, forKey: "apps-pin-fade")
            CATransaction.commit()
        }
    }

    private func animateEntry(_ view: NSView) {
        guard window != nil, !reduceMotion() else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let duration = TaskbarMotion.reorderTransition
        let timing = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.refreshHover() }
        }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = layer.superlayer?.isGeometryFlipped == true ? 6 : -6
        move.toValue = 0
        move.duration = duration
        move.timingFunction = timing
        layer.add(move, forKey: AppsMenuCanvas.moveAnimationKey)
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0.55
        appear.toValue = 1
        appear.duration = duration
        appear.timingFunction = timing
        layer.add(appear, forKey: "apps-catalog-fade")
        CATransaction.commit()
        refreshHover()
    }

    private func buildContent(using build: (AppsMenuCanvas) -> CGFloat) -> CatalogContent {
        let document = AppsMenuCanvas()
        let currentButtons = catalogButtons
        let currentPins = pinButtons
        defer {
            catalogButtons = currentButtons
            pinButtons = currentPins
        }
        catalogButtons.removeAll()
        pinButtons.removeAll()
        let height = build(document)
        return CatalogContent(document: document, height: height, buttons: catalogButtons, pinButtons: pinButtons)
    }

    private func buildSearch(in document: AppsMenuCanvas) -> CGFloat {
        let notice = catalogNotice
        guard let applications else {
            return addStatus(notice ?? String(localized: "Loading apps…"), at: 12, to: document)
        }
        if let notice { _ = addStatus(notice, at: 12, to: document) }
        let noticeOffset: CGFloat = notice == nil ? 0 : 40
        searchResults = applications.filter { $0.name.localizedStandardContains(query) }
        if searchResults.isEmpty {
            return addStatus(String(localized: "No matching apps"), at: 12 + noticeOffset, to: document)
        }
        return buildRows(searchResults, top: 6 + noticeOffset, in: document)
    }

    private func buildPinned(in document: AppsMenuCanvas) -> CGFloat {
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
                rebuildCatalog(reveal: "expand", transition: .expand)
            }
            button.toolTip = title
        }
        for (index, entry) in visiblePins.enumerated() {
            let (pin, apps) = entry
            let x = horizontal(81 + CGFloat(index % 6) * 96)
            let y = 76 + CGFloat(index / 6) * Self.tilePitch
            let button = addTile(name: pin.name == nil ? apps[0].name : displayName(for: pin),
                                 apps: apps, isFolder: pin.name != nil, x: x, top: y,
                                 pitch: horizontal(96), in: document, pinned: true) { [weak self] _ in
                if pin.name == nil { self?.launch(apps[0]) } else { self?.openFolder(pin.id) }
            }
            button.identifier = NSUserInterfaceItemIdentifier("pin-\(pin.id)")
            pinButtons[pin.id] = button
            button.onDrag = { [weak self] start, event, finished in
                self?.dragPin(pin.id, from: start, event: event, finished: finished)
            }
            button.contextMenu = { [weak self] in
                if pin.name == nil { self?.appMenu(for: apps[0], topLevelPin: pin.id) }
                else { self?.folderMenu(pin) }
            }
        }
        return 103 + CGFloat((visiblePins.count + 5) / 6) * Self.tilePitch
    }

    private func buildAll(in document: AppsMenuCanvas, mode: AppsMenuCatalogMode) -> CGFloat {
        addHeading(String(localized: "All"), y: 0, to: document)
        let title = String.localizedStringWithFormat(String(localized: "View: %@"), mode.title)
        _ = addTrailingControl(title, icon: "chevron.down", y: 10,
                               id: "mode", in: document) { [weak self] button in
            self?.showViewModes(at: button)
        }
        let notice = catalogNotice
        if let notice {
            let height = addStatus(notice, at: 42, to: document)
            if applications?.isEmpty != false { return height }
        }
        guard let applications else {
            return addStatus(String(localized: "Loading apps…"), at: 42, to: document)
        }
        guard !applications.isEmpty else {
            return addStatus(String(localized: "No apps available"), at: 42, to: document)
        }
        let noticeOffset: CGFloat = notice == nil ? 0 : 34
        switch mode {
        case .list, .grid:
            return buildAlphabetical(applications, grid: mode == .grid, top: 44.5 + noticeOffset, in: document)
        case .category:
            return buildCategories(applications, top: 34 + noticeOffset, in: document)
        }
    }

    private func buildAlphabetical(_ apps: [AppsMenuApplication], grid: Bool,
                                   top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        var y = top
        let groups = Dictionary(grouping: apps, by: alphabetKey)
        for key in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let group = groups[key] else { continue }
            let leading = horizontal(53)
            let button = AppsMenuButton(title: key, style: .glassRow) { [weak self] _ in self?.openAlphabet(at: key) }
            button.identifier = NSUserInterfaceItemIdentifier("section-\(key)")
            button.frame = CGRect(x: leading, y: y - 10, width: max(0, surface.bounds.width - leading * 2), height: 40)
            let heading = makeLabel(key, size: 13)
            heading.frame = CGRect(x: horizontal(12), y: 10, width: 42, height: 19)
            heading.setAccessibilityElement(false)
            button.addSubview(heading)
            register(button, in: document)
            y += 40
            if grid {
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

    private func alphabetKey(_ app: AppsMenuApplication) -> String {
        guard let initial = app.name.first, initial.isLetter else { return "#" }
        return String(initial).folding(options: .diacriticInsensitive, locale: .current).localizedUppercase
    }

    private func openAlphabet(at letter: String) {
        alphabetAnchor = letter
        alphabetPosition = catalogScroll.contentView.bounds.origin
        rebuildCatalog(position: .zero, reveal: "jump-\(letter)", transition: .content)
    }

    private func closeAlphabet(jumpTo letter: String? = nil) {
        let anchor = alphabetAnchor
        alphabetAnchor = nil
        rebuildCatalog(position: alphabetPosition, reveal: (letter ?? anchor).map { "section-\($0)" },
                       transition: .content)
        guard let letter, let heading = catalogButtons.first(where: { $0.identifier?.rawValue == "section-\(letter)" }) else { return }
        let origin = heading.convert(heading.bounds, to: browsingDocument).minY
        scroll(catalogScroll, to: CGPoint(x: 0, y: max(0, origin - 14)))
    }

    private func buildAlphabetIndex(in document: AppsMenuCanvas) -> CGFloat {
        addHeading(String(localized: "All"), y: 24, to: document)
        _ = addTrailingControl(String(localized: "Back"), icon: "chevron.left", y: 35, id: "alphabet-back",
                               in: document, backStyle: true) { [weak self] _ in self?.closeAlphabet() }
        let available = Set((applications ?? []).map(alphabetKey))
        let latin = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        let letters = latin + available.subtracting(latin).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let columns = 6
        let pitch = min(50, surface.bounds.width / CGFloat(columns + 1))
        let left = (surface.bounds.width - CGFloat(columns) * pitch) / 2
        for (index, letter) in letters.enumerated() {
            let button = AppsMenuButton(title: letter) { [weak self] _ in self?.closeAlphabet(jumpTo: letter) }
            button.identifier = NSUserInterfaceItemIdentifier("jump-\(letter)")
            button.usesNativeContent = true
            button.font = .systemFont(ofSize: 17)
            button.isEnabled = available.contains(letter)
            button.frame = CGRect(x: left + CGFloat(index % columns) * pitch, y: 70 + CGFloat(index / columns) * pitch,
                                  width: pitch, height: pitch)
            register(button, in: document)
        }
        return 84 + CGFloat((letters.count + columns - 1) / columns) * pitch
    }

    private func buildRows(_ apps: [AppsMenuApplication], top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        for (index, app) in apps.enumerated() {
            let button = AppsMenuButton(title: app.name, style: .glassRow) { [weak self] _ in self?.launch(app) }
            button.identifier = applicationIdentifier(app, inFolder: false)
            button.contextMenu = { [weak self] in self?.appMenu(for: app) }
            let leading = horizontal(62)
            button.frame = CGRect(x: leading, y: top + CGFloat(index) * Self.rowPitch - 6,
                                  width: max(0, surface.bounds.width - leading * 2), height: 40)
            button.pendingContent = { [weak self] button in
                guard let self else { return }
                let icon = AppsMenuListIconView(frame: CGRect(x: horizontal(6), y: 8, width: 24, height: 24),
                                               artworkSize: Self.tileIconSize)
                icon.setAccessibilityElement(false)
                button.addSubview(icon)
                store.requestIcon(at: app.url) { [weak icon] artwork in icon?.artwork = artwork }
                let text = makeLabel(app.name, size: 12, weight: .medium)
                let textX = max(33, horizontal(45))
                text.frame = CGRect(x: textX, y: 11, width: max(0, button.frame.width - textX - 6), height: 18)
                text.setAccessibilityElement(false)
                button.addSubview(text)
            }
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
                button.pendingContent = { [weak self] button in
                    guard let self else { return }
                    addFileIcon(app.url, at: CGRect(x: 4, y: (48 - iconSize) / 2,
                                                   width: iconSize, height: iconSize), to: button)
                }
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
            let mode = catalogButtons.first { $0.identifier?.rawValue == "mode" }
            let y = (mode?.convert(.zero, to: browsingDocument).y ?? 0) - 20
            rebuildCatalog(position: CGPoint(x: 0, y: max(0, y)), reveal: "category-back", transition: .content)
        } else {
            rebuildCatalog(position: categoryPosition, reveal: oldCategory.map { "category-\($0)" }, transition: .content)
        }
    }

    private func showViewModes(at button: AppsMenuButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in AppsMenuCatalogMode.allCases {
            let item = TaskbarNativeMenuFactory.actionItem(title: mode.title) { [weak self, weak menu] in
                menu?.cancelTrackingWithoutAnimation()
                DispatchQueue.main.async { [weak self] in
                    guard let self, store.catalogMode != mode || category != nil else { return }
                    store.catalogMode = mode
                    category = nil
                    rebuildCatalog(reveal: "mode")
                }
            }
            item.state = store.catalogMode == mode ? .on : .off
            menu.addItem(item)
        }
        presentViewModes(menu, button)
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
                                    in view: NSView, backStyle: Bool = false,
                                    action: @escaping (AppsMenuButton) -> Void) -> AppsMenuButton {
        let button = AppsMenuButton(title: title, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        let fontSize: CGFloat = backStyle ? 13 : 12
        let label = makeLabel(title, size: fontSize)
        let font = NSFont.systemFont(ofSize: fontSize)
        let text = (title as NSString).size(withAttributes: [.font: font])
        let padding: CGFloat = 8
        let spacing: CGFloat = backStyle ? 8 : 6
        let iconSize: CGFloat = backStyle ? 10 : 9
        let overhead = 2 * padding + spacing + iconSize
        let width = max(backStyle ? 64 : 86, min(horizontal(235), ceil(text.width) + overhead))
        let height: CGFloat = backStyle ? 26 : 22
        let captionWidth = min(ceil(text.width), width - overhead)
        let captionHeight = ceil(text.height)
        let leading = (width - captionWidth - spacing - iconSize) / 2
        button.frame = CGRect(x: horizontal(backStyle ? 565 : 584) - width, y: y - height / 2, width: width, height: height)
        let captionX = backStyle ? leading + iconSize + spacing : leading
        let caption = CGRect(x: captionX, y: (height - captionHeight) / 2, width: captionWidth, height: captionHeight)
        label.frame = label.frame(forAlignmentRect: caption)
        label.setAccessibilityElement(false)
        button.addSubview(label)
        let iconX = backStyle ? leading : caption.maxX + spacing
        let image = addIcon(menuSymbol(icon, size: iconSize),
                            at: CGRect(x: iconX, y: (height - iconSize) / 2, width: iconSize, height: iconSize),
                            to: button)
        if backStyle { image.contentTintColor = label.textColor }
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
                         pitch: CGFloat, in view: NSView, folder: Bool = false, pinned: Bool = false,
                         action: @escaping (AppsMenuButton) -> Void) -> AppsMenuButton {
        let width = max(1, pitch - (pinned ? 0 : 2))
        let topPadding: CGFloat = pinned ? 5 : 0
        let button = AppsMenuButton(title: name, style: pinned ? .pinned : .glassRow, action: action)
        button.frame = CGRect(x: x - width / 2, y: top - 7 - topPadding, width: width, height: 79 + topPadding)
        let artworkSize = isFolder ? 32 : min(Self.tileIconSize, width)
        let artwork = CGRect(x: (width - artworkSize) / 2, y: (isFolder ? 7 : 4) + topPadding,
                             width: artworkSize, height: artworkSize)
        if pinned { button.pinArtwork = artwork }
        let renderArtwork: (AppsMenuButton) -> Void = { [weak self] button in
            guard let self else { return }
            if isFolder {
                let preview = AppsMenuBox(radius: 8, fill: .white.withAlphaComponent(0.14))
                preview.frame = artwork
                button.addSubview(preview)
                for (index, app) in apps.prefix(4).enumerated() {
                    let x = preview.frame.minX + 3 + CGFloat(index % 2) * 13
                    let y = preview.frame.minY + 3 + CGFloat(index / 2) * 13
                    addFileIcon(app.url, at: CGRect(x: x, y: y, width: 13, height: 13), to: button)
                }
            } else if let app = apps.first {
                addFileIcon(app.url, at: artwork, to: button)
            }
        }
        if folder { renderArtwork(button) } else { button.pendingContent = renderArtwork }
        let label = makeLabel(name, size: folder ? 11 : 11.5, alignment: .center)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.frame = CGRect(x: 1, y: 46.5 + topPadding, width: max(0, width - 2), height: 29)
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
        guard acceptsMenuActions else { return }
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
                rebuildCatalog(transition: .pinned)
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
        if folderID == nil, let button = pinButtons[id] { button.scrollToVisible(button.bounds) }
    }

    func dragPin(_ id: UUID, from start: CGPoint, event: NSEvent, finished: Bool) {
        guard acceptsMenuActions, let source = pinButtons[id], let parent = source.superview else { return }
        if pinDrag == nil, !finished {
            let order = store.pins.map(\.id).filter { pinButtons[$0] != nil }
            guard order.count > 1, let pin = store.pins.first(where: { $0.id == id }) else { return }
            #if DEBUG
            pinDragResources = ActionResourceLog.begin("apps.pin.drag")
            #endif
            pinDrag = PinDrag(source: id, order: order, frames: pinButtons.mapValues(\.frame),
                              canGroup: pin.name == nil && pin.applicationIDs.count == 1)
            source.wantsLayer = true
            source.layer?.zPosition = 1
            refreshHover()
        }
        guard let drag = pinDrag, drag.source == id, let originalFrame = drag.frames[id] else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        let clip = catalogScroll.contentView
        let inViewport = clip.bounds.contains(clip.convert(event.locationInWindow, from: nil))
        let drop = inViewport ? pinDrop(at: point, in: drag) : nil
        if finished {
            #if DEBUG
            let previous = store.pins
            #endif
            resetPinDrag()
            switch drop {
            case .group(let target):
                updatePins { $0.groupPin(id, into: target) }
            case .insert(let target, let after):
                let order = store.pins.map(\.id).filter { $0 != id }
                if let index = drag.insertionIndex(in: order, beside: target, after: after) {
                    updatePins { $0.movePin(id, to: index) }
                }
            case nil:
                break
            }
            #if DEBUG
            let outcome = switch drop {
            case .group: "group"
            case .insert: "insert"
            case nil: inViewport ? "no-target" : "outside-viewport"
            }
            Self.pinDropLogger.info("drop outcome=\(outcome, privacy: .public) changed=\(previous != self.store.pins, privacy: .public) before=\(previous.count, privacy: .public) after=\(self.store.pins.count, privacy: .public)")
            #endif
            refreshHover()
            return
        }
        if drag.drop != drop {
            pinDrag?.drop = drop
            showPinDrop(drop, in: drag)
        }
        let initial = parent.convert(start, from: nil)
        let frame = originalFrame.offsetBy(dx: point.x - initial.x, dy: point.y - initial.y)
        if source.frame != frame { source.frame = frame }
    }

    private func pinDrop(at point: CGPoint, in drag: PinDrag) -> PinDrop? {
        guard let target = drag.order.first(where: { drag.frames[$0]?.contains(point) == true }),
              target != drag.source, let slot = drag.frames[target] else { return nil }
        if drag.canGroup, let artwork = pinButtons[target]?.pinArtwork,
           artwork.offsetBy(dx: slot.minX, dy: slot.minY).contains(point) {
            return .group(target)
        }
        return .insert(beside: target, after: point.x >= slot.midX)
    }

    private func showPinDrop(_ drop: PinDrop?, in drag: PinDrag) {
        if let target = drag.drop?.groupTarget { pinButtons[target]?.isPinDropTarget = false }
        if let target = drop?.groupTarget { pinButtons[target]?.isPinDropTarget = true }
        var reordered = drag.order
        if case .insert(let target, let after) = drop {
            reordered.removeAll { $0 == drag.source }
            if let index = drag.insertionIndex(in: reordered, beside: target, after: after) {
                reordered.insert(drag.source, at: index)
            }
        }
        let animate = window != nil && !reduceMotion()
        for (pin, slot) in zip(reordered, drag.order) where pin != drag.source {
            guard let button = pinButtons[pin], let frame = drag.frames[slot], button.frame != frame else { continue }
            if animate { slidePin(button, to: frame) }
            else { button.frame = frame }
        }
    }

    private func slidePin(_ button: AppsMenuButton, to frame: CGRect) {
        button.wantsLayer = true
        guard let layer = button.layer else { button.frame = frame; return }
        let position = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.frame = frame
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: position)
        slide.toValue = NSValue(point: layer.position)
        slide.duration = TaskbarMotion.reorderTransition
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(slide, forKey: Self.pinShiftAnimationKey)
        CATransaction.commit()
    }

    func resetPinDrag() {
        guard let drag = pinDrag else { return }
        #if DEBUG
        let span = pinDragResources
        pinDragResources = nil
        defer { span?.finish() }
        #endif
        if let target = drag.drop?.groupTarget { pinButtons[target]?.isPinDropTarget = false }
        for (id, frame) in drag.frames {
            pinButtons[id]?.layer?.removeAnimation(forKey: Self.pinShiftAnimationKey)
            pinButtons[id]?.frame = frame
        }
        pinButtons[drag.source]?.layer?.zPosition = 0
        pinButtons[drag.source]?.cancelDragTracking()
        pinDrag = nil
    }

    func updatePins(_ update: (AppsMenuStore) -> Void) {
        let previous = store.pins
        update(store)
        guard store.pins != previous else { return }
        rebuildCatalog(transition: .pinned)
        if folderID != nil { rebuildFolder() }
    }

    func openFolder(_ id: UUID, rename: Bool = false) {
        guard store.pins.contains(where: { $0.id == id && $0.name != nil }) else { return }
        #if DEBUG
        let span = ActionResourceLog.begin("apps.folder.open")
        defer { span?.finish() }
        #endif
        folderID = id
        var draft: String?
        if rename, let folder = store.pins.first(where: { $0.id == id }) {
            draft = displayName(for: folder)
        }
        rebuildFolder(draft: draft)
        if let folderGlass { animateEntry(folderGlass) }
    }

    private func clearFolder() {
        guard folderID != nil else { return }
        folderID = nil
        renameField = nil
        folderScroll = nil
        folderGlass?.removeFromSuperview()
        folderGlass = nil
        folderShield?.removeFromSuperview()
        folderShield = nil
        setCatalogAccessibilityHidden(false)
    }

    func closeFolder() {
        #if DEBUG
        let span = folderID == nil ? nil : ActionResourceLog.begin("apps.folder.close")
        defer { span?.finish() }
        #endif
        let closedID = folderID
        clearFolder()
        if let document = catalogScroll.documentView { animateEntry(document) }
        refreshHover()
        if let closedID, let button = pinButtons[closedID] {
            button.scrollToVisible(button.bounds)
        } else {
            focusSearch()
        }
    }

    func rebuildFolder(draft: String? = nil) {
        guard let id = folderID, let folder = store.pins.first(where: { $0.id == id && $0.name != nil }) else {
            closeFolder()
            return
        }
        let apps = folder.applicationIDs.compactMap { applicationsByID[$0] }
        let position = folderScroll?.contentView.bounds.origin ?? .zero
        let editing = draft ?? renameField?.stringValue
        renameField = nil
        folderGlass?.removeFromSuperview()
        folderShield?.removeFromSuperview()
        setCatalogAccessibilityHidden(true)
        let shield = AppsMenuCanvas(frame: surface.bounds)
        shield.setAccessibilityElement(false)
        shield.onClick = { [weak self] in
            self?.finishRenaming()
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
        if editing == nil { register(title, in: body, folder: true) }
        let scroll = AppsMenuScrollView(horizontal: false)
        scroll.onClipChanged = { [weak self] in self?.refreshHover() }
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
    }

    func setCatalogAccessibilityHidden(_ hidden: Bool) {
        searchField.setAccessibilityHidden(hidden)
        catalogScroll.setAccessibilityHidden(hidden)
        footer.setAccessibilityHidden(hidden)
    }

    func observeApplicationPolicies() {
        guard window != nil else { return }
        stopObservingActivationPolicies()
        activationObservations = NSWorkspace.shared.runningApplications.map { app in
            let token = app.observe(\.activationPolicy, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshRunningApps() }
            }
            return (app, token)
        }
        refreshRunningApps()
    }

    func stopObservingActivationPolicies() {
        for observer in activationObservations { observer.token.invalidate() }
        activationObservations.removeAll()
    }

    func stopObservingApplications() {
        stopObservingActivationPolicies()
        frontmostObservation?.invalidate()
        frontmostObservation = nil
        runningObservation?.invalidate()
        runningObservation = nil
    }

    func finishRenaming() {
        guard let field = renameField, let id = folderID else { return }
        renameField = nil
        if let folder = store.pins.first(where: { $0.id == id }), field.stringValue != displayName(for: folder) {
            store.renameFolder(id, to: field.stringValue)
            rebuildCatalog()
        }
        rebuildFolder()
    }

    func refreshRunningApps() {
        let new = store.runningApplications()
        guard new != runningApps else { return }
        runningApps = new
        rebuildRunningFooter()
    }

    func rebuildRunningFooter() {
        let pitch: CGFloat = 46
        let available = max(0, surface.bounds.width - horizontal(108))
        let manager = catalogDeferredUntilFrame ? nil : store.systemFileManager
        let managerProcess = manager.flatMap { manager in
            runningApps.first { $0.bundleIdentifier == manager.id }
        }
        let applications = runningApps.filter { manager == nil || $0.bundleIdentifier != manager?.id }
        let fixedWidth = manager == nil ? 0 : min(pitch, available)
        let scrollAvailable = available - fixedWidth
        let total = CGFloat(applications.count) * pitch
        let nextIconPreview: CGFloat = 28
        let width = total > scrollAvailable && scrollAvailable >= pitch + nextIconPreview
            ? floor((scrollAvailable - nextIconPreview) / pitch) * pitch + nextIconPreview
            : min(total, scrollAvailable)
        let position = runningScroll.contentView.bounds.origin
        let left = (surface.bounds.width - width - fixedWidth) / 2
        runningScroll.frame = CGRect(x: left + fixedWidth, y: 6, width: width, height: 56)
        let document = AppsMenuCanvas(frame: CGRect(x: 0, y: 0, width: total, height: 56))
        let iconSize = Self.tileIconSize
        let iconTopInset: CGFloat = 3
        let dotSize: CGFloat = 3
        let dotGap: CGFloat = 2
        let pairHeight = iconSize + dotGap + dotSize
        let iconTop = (footer.bounds.height - pairHeight - iconTopInset) / 2 - runningScroll.frame.minY
        let iconFrame = CGRect(x: (pitch - iconSize) / 2, y: iconTop, width: iconSize, height: iconSize)
        let dotFrame = CGRect(x: (pitch - dotSize) / 2, y: iconFrame.maxY + dotGap, width: dotSize, height: dotSize)
        fileManagerButton?.removeFromSuperview()
        fileManagerButton = nil
        if let manager, fixedWidth > 0 {
            let button = makeFooterButton(name: manager.name, url: manager.url, process: managerProcess,
                                          iconFrame: iconFrame, dotFrame: dotFrame, allowsQuit: false) { [store] in
                store.launch(manager)
            }
            button.identifier = NSUserInterfaceItemIdentifier("running-system-file-manager")
            button.frame = CGRect(x: left, y: runningScroll.frame.minY, width: fixedWidth, height: 50)
            footer.addSubview(button)
            fileManagerButton = button
        }
        for (index, app) in applications.enumerated() {
            let name = app.localizedName ?? app.bundleIdentifier ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? String(app.processIdentifier)
            let button = makeFooterButton(name: name, url: app.bundleURL, process: app, iconFrame: iconFrame,
                                          dotFrame: dotFrame, allowsQuit: true) { [store] in
                store.reopen(app)
            }
            button.identifier = NSUserInterfaceItemIdentifier("running-\(app.processIdentifier)")
            button.frame = CGRect(x: CGFloat(index) * pitch, y: 0, width: pitch, height: 50)
            document.addSubview(button)
        }
        runningScroll.hasHorizontalScroller = total > width && width > 0
        runningScroll.documentView = document
        scroll(runningScroll, to: position)
    }

    private func makeFooterButton(name: String, url: URL?, process: NSRunningApplication?,
                                  iconFrame: CGRect, dotFrame: CGRect, allowsQuit: Bool,
                                  open: @escaping () -> Void) -> AppsMenuButton {
        let button = AppsMenuButton(title: name, style: .running) { [weak self] _ in
            guard let self, acceptsMenuActions else { return }
            dismiss()
            open()
        }
        if let url {
            addFileIcon(url, at: iconFrame, to: button)
        } else {
            addIcon(process?.icon ?? NSImage(named: NSImage.applicationIconName), at: iconFrame, to: button)
        }
        if let process {
            button.contextMenu = { [weak self] in self?.runningAppMenu(for: process, allowsQuit: allowsQuit) }
            let indicator = AppsMenuBox(radius: dotFrame.width / 2, fill: .labelColor.withAlphaComponent(0.76))
            indicator.frame = dotFrame
            button.addSubview(indicator)
        }
        attachHover(to: button)
        return button
    }

    private func runningAppMenu(for app: NSRunningApplication, allowsQuit: Bool) -> NSMenu? {
        guard acceptsMenuActions, !app.isTerminated else { return nil }
        #if DEBUG
        let span = ActionResourceLog.begin("apps.menu.runningApplication")
        defer { span?.finish() }
        #endif
        let menu = NSMenu()
        menu.autoenablesItems = false
        let windows = runningWindows(app.processIdentifier)
        for window in windows {
            let target = window.item.actionIdentity
            let entry = TaskbarNativeMenuFactory.actionItem(title: window.title) { [weak self] in
                guard let self, acceptsMenuActions, !app.isTerminated else { return }
                dismiss()
                activateWindow(target)
            }
            entry.state = window.isActive ? .on : .off
            menu.addItem(entry)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        if let url = app.bundleURL {
            let options = NSMenu(title: String(localized: "Options"))
            options.autoenablesItems = false
            options.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Show in Finder")) { [weak self] in
                guard let self, acceptsMenuActions else { return }
                dismiss()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            let item = NSMenuItem(title: options.title, action: nil, keyEquivalent: "")
            item.submenu = options
            menu.addItem(item)
        }
        let show = app.isHidden
        let visibilityTitle = show ? String(localized: "Show") : String(localized: "Hide")
        menu.addItem(TaskbarNativeMenuFactory.actionItem(title: visibilityTitle) { [weak self] in
            guard let self, acceptsMenuActions, !app.isTerminated, app.isHidden == show else { return }
            dismiss()
            if show { app.activate(options: []) } else { app.hide() }
        })
        if allowsQuit {
            menu.addItem(TaskbarNativeMenuFactory.actionItem(title: String(localized: "Quit")) { [weak self] in
                guard let self, acceptsMenuActions, !app.isTerminated else { return }
                #if DEBUG
                let span = ActionResourceLog.begin("apps.application.quit")
                defer { span?.finish() }
                #endif
                dismiss()
                app.terminate()
            })
        }
        return menu
    }

    func setDocument(_ document: NSView, height: CGFloat, in scroller: NSScrollView, position: CGPoint) {
        document.frame = CGRect(x: 0, y: 0, width: scroller.frame.width, height: max(height, scroller.frame.height))
        scroller.hasVerticalScroller = height > scroller.frame.height
        if scroller.documentView !== document { scroller.documentView = document }
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
        attachHover(to: button)
        if !folder { catalogButtons.append(button) }
    }

    func renderVisibleCatalogButtons() {
        guard let document = catalogScroll.documentView else { return }
        let visible = catalogScroll.documentVisibleRect.insetBy(dx: 0, dy: -84)
        for button in catalogButtons where button.pendingContent != nil {
            guard let parent = button.superview, parent === document || parent.isDescendant(of: document),
                  parent.convert(button.frame, to: document).intersects(visible) else { continue }
            button.renderPendingContent()
        }
    }

    func attachHover(to button: AppsMenuButton) {
        button.onPointerChanged = { [weak self] in self?.refreshHover() }
    }

    func refreshHover() {
        let target: AppsMenuButton?
        if pinDrag == nil, let window, window.isKeyWindow, let parent = surface.superview {
            let point = parent.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            target = surface.hitTest(point) as? AppsMenuButton
        } else {
            target = nil
        }
        if let target, !target.usesGlassHover, acceptsMenuActions {
            let tooltip = runningTooltip ?? AppsMenuRunningTooltip()
            runningTooltip = tooltip
            tooltip.show(above: target, in: surface)
        } else {
            runningTooltip?.removeFromSuperview()
        }
        guard target !== hoveredButton else { return }
        let animated = window != nil && !reduceMotion()
        let previous = activeHoverEffect
        previous?.hide(animated: animated)
        activeHoverEffect = nil
        hoveredButton = target
        if let target, target.usesGlassHover {
            let effect = hoverEffects.first { $0 !== previous && $0.superview == nil }
                ?? hoverEffects.first { $0 !== previous }
            effect?.show(in: target, animated: animated)
            activeHoverEffect = effect
        }
    }

    func applicationIdentifier(_ app: AppsMenuApplication, inFolder: Bool) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier((inFolder ? "folder-app-" : "catalog-app-") + app.id)
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

    func addFileIcon(_ url: URL, at frame: CGRect, to view: NSView) {
        let icon = addIcon(nil, at: frame, to: view)
        store.requestIcon(at: url) { [weak icon] image in icon?.image = image }
    }

    @discardableResult
    func addIcon(_ image: NSImage?, at frame: CGRect, to view: NSView) -> NSImageView {
        let icon = NSImageView(frame: frame)
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        view.addSubview(icon)
        return icon
    }

    func menuSymbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }
}

private final class AppsMenuListIconView: NSImageView {
    private let artworkSize: CGFloat
    private var renderedScale: CGFloat?
    private var renderedAppearance: NSAppearance?

    var artwork: NSImage? {
        didSet {
            renderedScale = nil
            updateArtwork()
        }
    }

    init(frame: CGRect, artworkSize: CGFloat) {
        self.artworkSize = artworkSize
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateArtwork()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateArtwork()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateArtwork()
    }

    private func updateArtwork() {
        guard let artwork else {
            image = nil
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let appearance = effectiveAppearance
        guard renderedScale != scale || renderedAppearance !== appearance else { return }
        renderedScale = scale
        renderedAppearance = appearance
        let pixels = Int((artworkSize * scale).rounded(.up))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            image = artwork
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.clear(CGRect(x: 0, y: 0, width: artworkSize, height: artworkSize))
        appearance.performAsCurrentDrawingAppearance {
            artwork.draw(in: CGRect(x: 0, y: 0, width: artworkSize, height: artworkSize))
        }
        NSGraphicsContext.restoreGraphicsState()

        let rendered = NSImage(size: bounds.size)
        bitmap.size = bounds.size
        rendered.addRepresentation(bitmap)
        image = rendered
    }
}

private final class AppsMenuCanvas: NSView {
    static let moveAnimationKey = "apps-catalog-move"
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard layer?.animation(forKey: Self.moveAnimationKey) == nil else { return nil }
        return super.hitTest(point)
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

private final class AppsMenuHoverEffect: NSView {
    private static let animationKey = "apps-hover-opacity"
    private let glass = NSGlassEffectView()
    private var revision = 0
    private var duration = TaskbarMotion.buttonTransition

    init() {
        super.init(frame: .zero)
        glass.style = .regular
        glass.contentView = NSView()
        glass.autoresizingMask = [.width, .height]
        glass.setAccessibilityElement(false)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(glass)
    }

    required init?(coder: NSCoder) { nil }

    func show(in button: AppsMenuButton, animated: Bool) {
        revision &+= 1
        layer?.removeAnimation(forKey: Self.animationKey)
        removeFromSuperview()
        frame = button.bounds
        layer?.cornerRadius = button.selectionCornerRadius
        glass.cornerRadius = button.selectionCornerRadius
        glass.frame = bounds
        duration = button.hoverTransitionDuration
        button.addSubview(self, positioned: .below, relativeTo: nil)
        if animated { fade(from: 0, to: 1) }
    }

    func hide(animated: Bool) {
        revision &+= 1
        guard animated, superview != nil, let layer else {
            removeFromSuperview()
            return
        }
        let revision = self.revision
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.revision == revision else { return }
                self.removeFromSuperview()
            }
        }
        fade(from: layer.presentation()?.opacity ?? 1, to: 0)
        CATransaction.commit()
    }

    private func fade(from: Float, to: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if to == 0 {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer?.add(animation, forKey: Self.animationKey)
    }
}

private final class AppsMenuRunningTooltip: NSGlassEffectView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 13
        setAccessibilityElement(false)
        let body = NSView()
        body.autoresizingMask = [.width, .height]
        contentView = body
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        body.addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(above button: NSButton, in surface: NSView) {
        if label.stringValue != button.title { label.stringValue = button.title }
        let anchor = button.convert(button.bounds, to: surface)
        let height: CGFloat = 26
        let inset: CGFloat = 8
        let width = min(label.intrinsicContentSize.width + 24, max(0, surface.bounds.width - inset * 2))
        let x = min(max(inset, anchor.midX - width / 2), surface.bounds.width - inset - width)
        frame = CGRect(x: x, y: anchor.minY - height - 8, width: width, height: height)
        contentView?.frame = bounds
        label.frame = bounds.insetBy(dx: min(inset, width / 2), dy: 4)
        if superview !== surface { surface.addSubview(self) }
    }
}

private final class AppsMenuButton: NSButton {
    enum Style {
        case standard, pinned, running, glassRow
    }

    let onActivate: (AppsMenuButton) -> Void
    var contextMenu: (() -> NSMenu?)?
    var onPointerChanged: (() -> Void)?
    var onDrag: ((CGPoint, NSEvent, Bool) -> Void)?
    var pinArtwork: CGRect?
    var isPinDropTarget = false {
        didSet {
            if oldValue != isPinDropTarget { updateSelection() }
        }
    }
    var pendingContent: ((AppsMenuButton) -> Void)?
    var usesNativeContent = false { didSet { isTransparent = !usesNativeContent } }
    private let selection: AppsMenuBox
    private let style: Style
    var usesGlassHover: Bool { style != .running }
    var selectionCornerRadius: CGFloat { selection.cornerRadius }
    var hoverTransitionDuration: TimeInterval { style == .pinned ? 0.09 : TaskbarMotion.buttonTransition }
    private var tracking: NSTrackingArea?
    private var pressed = false
    private var mouseDownPoint: CGPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(title: String, style: Style = .standard, action: @escaping (AppsMenuButton) -> Void) {
        onActivate = action
        self.style = style
        selection = AppsMenuBox(radius: style == .pinned ? 4 : 5, fill: .clear)
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

    func renderPendingContent() {
        let render = pendingContent
        pendingContent = nil
        render?(self)
    }

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

    override func mouseEntered(with event: NSEvent) { onPointerChanged?() }

    override func mouseExited(with event: NSEvent) { onPointerChanged?() }

    override func mouseDown(with event: NSEvent) {
        guard onDrag != nil else { super.mouseDown(with: event); return }
        guard isEnabled else { return }
        mouseDownPoint = event.locationInWindow
        dragged = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        guard dragged || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragged = true
        highlight(false)
        onDrag?(start, event, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let wasDragged = dragged
        mouseDownPoint = nil
        dragged = false
        highlight(false)
        if wasDragged {
            onDrag?(start, event, true)
        } else if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) {
            invoke()
        }
    }

    func cancelDragTracking() {
        mouseDownPoint = nil
        dragged = false
        highlight(false)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        updateSelection()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled && super.hitTest(point) != nil ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?() ?? super.menu(for: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu?() else { return false }
        return menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.maxY), in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
    }

    private func updateSelection() {
        selection.frame = bounds
        if isPinDropTarget {
            selection.fillColor = .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
            selection.borderColor = .separatorColor
            selection.borderWidth = 1
        } else {
            selection.fillColor = pressed && usesGlassHover
                ? .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.25) : .clear
            selection.borderWidth = 0
        }
    }

    @objc private func invoke() { onActivate(self) }
}

private final class AppsMenuSearchFieldCell: NSSearchFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        let text = searchTextRect(forBounds: controlView.bounds).intersection(rect)
        super.select(withFrame: text, in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        let text = searchTextRect(forBounds: controlView.bounds).intersection(rect)
        super.edit(withFrame: text, in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: rect)
        for button in [searchButtonRect(forBounds: rect), cancelButtonRect(forBounds: rect)] where !button.isEmpty {
            if button.midX < rect.midX {
                let left = min(text.maxX, max(text.minX, button.maxX + 6))
                text.size.width = text.maxX - left
                text.origin.x = left
            } else {
                text.size.width = max(0, min(text.maxX, button.minX - 6) - text.minX)
            }
        }
        return text
    }
}

private final class AppsMenuVerticalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = documentView?.frame.minX ?? 0
        return bounds
    }
}

private class AppsMenuScrollView: NSScrollView {
    var onClipChanged: (() -> Void)?

    init(horizontal: Bool) {
        super.init(frame: .zero)
        if !horizontal { contentView = AppsMenuVerticalClipView() }
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

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        if clip === contentView { onClipChanged?() }
    }
}

private final class AppsMenuRunningScrollView: AppsMenuScrollView {
    private let fade = CAGradientLayer()

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
