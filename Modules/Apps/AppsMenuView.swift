import AppKit

struct AppsAlphabeticalLayout {
    struct Item: Equatable {
        enum Kind: Hashable {
            case section
            case list
            case grid
        }

        enum Target: Equatable {
            case section(String)
            case application(AppsMenuApplication)
        }

        enum Role: Equatable {
            case section(String)
            case listApp(AppsMenuApplication)
            case gridApp(AppsMenuApplication)

            var kind: Kind {
                switch self {
                case .section: .section
                case .listApp: .list
                case .gridApp: .grid
                }
            }

            var label: String {
                switch self {
                case .section(let letter): letter
                case .listApp(let app), .gridApp(let app): app.name
                }
            }

            var target: Target {
                switch self {
                case .section(let letter): .section(letter)
                case .listApp(let app), .gridApp(let app): .application(app)
                }
            }
        }

        let identifier: NSUserInterfaceItemIdentifier
        let frame: CGRect
        let role: Role
    }

    let items: [Item]
    let height: CGFloat
    private let indices: [NSUserInterfaceItemIdentifier: Int]

    init(items: [Item], height: CGFloat) {
        self.items = items
        self.height = height
        indices = Dictionary(items.enumerated().map { ($0.element.identifier, $0.offset) },
                             uniquingKeysWith: { first, _ in first })
    }

    func frame(for identifier: NSUserInterfaceItemIdentifier) -> CGRect? {
        item(for: identifier)?.frame
    }

    func item(for identifier: NSUserInterfaceItemIdentifier) -> Item? {
        indices[identifier].map { items[$0] }
    }

    func items(intersecting rect: CGRect) -> [Item] {
        guard !rect.isEmpty else { return [] }
        var lower = 0
        var upper = items.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if items[middle].frame.maxY <= rect.minY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return items[lower...].prefix { $0.frame.minY < rect.maxY }.filter { $0.frame.intersects(rect) }
    }
}

@MainActor
private final class AppsAllViewport {
    typealias Item = AppsAlphabeticalLayout.Item

    private struct Binding {
        let item: Item
        let button: AppsMenuButton
    }

    let document = AppsAllDocument()
    private var mounted: [NSUserInterfaceItemIdentifier: Binding] = [:]
    private var ordered: [Binding] = []
    private var parked: [Item.Kind: [Binding]] = [:]
    private var accessibilityItems: [NSUserInterfaceItemIdentifier: AppsAlphabeticalAccessibilityItem] = [:]
    private weak var header: AppsMenuCanvas?

    func showHeader(_ current: AppsMenuCanvas) {
        guard header !== current else { return }
        header?.removeFromSuperview()
        document.addSubview(current, positioned: .below, relativeTo: nil)
        header = current
    }

    func button(for identifier: NSUserInterfaceItemIdentifier) -> AppsMenuButton? {
        mounted[identifier]?.button
    }

    func clearAccessibilityItems() {
        accessibilityItems.removeAll(keepingCapacity: true)
    }

    func accessibilityChildren(
        for layout: AppsAlphabeticalLayout,
        perform: @escaping (Item, AppsAlphabeticalAccessibilityItem.Action) -> Bool
    ) -> [Any] {
        var children: [Any] = header?.subviews ?? []
        var current: [NSUserInterfaceItemIdentifier: AppsAlphabeticalAccessibilityItem] = [:]
        for item in layout.items {
            let element: AppsAlphabeticalAccessibilityItem
            if let previous = accessibilityItems[item.identifier], previous.target == item.role.target {
                element = previous
                element.setAccessibilityFrameInParentSpace(item.frame)
            } else {
                element = AppsAlphabeticalAccessibilityItem(item: item, parent: document) { action in
                    perform(item, action)
                }
            }
            current[item.identifier] = element
            children.append(element)
        }
        accessibilityItems = current
        return children
    }

    func apply(_ layout: AppsAlphabeticalLayout, visibleRect: CGRect,
               bind: (Item, AppsMenuButton?) -> AppsMenuButton) -> [AppsMenuButton] {
        let visible = layout.items(intersecting: visibleRect)
        let wanted = Dictionary(visible.map { ($0.identifier, $0.role.kind) },
                                uniquingKeysWith: { first, _ in first })
        for binding in ordered where wanted[binding.item.identifier] != binding.item.role.kind {
            mounted[binding.item.identifier] = nil
            binding.button.removeFromSuperview()
            parked[binding.item.role.kind, default: []].append(binding)
        }
        var next: [Binding] = []
        next.reserveCapacity(visible.count)
        for item in visible {
            let old = mounted[item.identifier] ?? takeParked(for: item)
            let button: AppsMenuButton
            if let old, old.item.role == item.role, old.item.frame.size == item.frame.size {
                button = old.button
                if button.frame != item.frame { button.frame = item.frame }
            } else {
                button = bind(item, old?.button)
            }
            if button.superview == nil { document.addSubview(button) }
            let binding = Binding(item: item, button: button)
            mounted[item.identifier] = binding
            next.append(binding)
        }
        ordered = next
        for kind in parked.keys {
            if let count = parked[kind]?.count, count > 72 { parked[kind]?.removeFirst(count - 72) }
        }
        return next.map(\.button)
    }

    func clear() {
        for binding in ordered { binding.button.removeFromSuperview() }
        ordered.removeAll(keepingCapacity: true)
        mounted.removeAll(keepingCapacity: true)
        parked.removeAll(keepingCapacity: true)
        header?.removeFromSuperview()
        header = nil
    }

    private func takeParked(for item: Item) -> Binding? {
        let kind = item.role.kind
        guard let bindings = parked[kind], !bindings.isEmpty else { return nil }
        let index = bindings.firstIndex { $0.item.identifier == item.identifier } ?? 0
        return parked[kind]?.remove(at: index)
    }
}

@MainActor
final class AppsMenuView: NSGlassEffectView, NSSearchFieldDelegate {
    private static let designWidth: CGFloat = 642
    private static let searchBottom: CGFloat = 65
    private static let footerHeight: CGFloat = 65
    private static let rowPitch: CGFloat = 42
    private static let tilePitch: CGFloat = 84
    private static let tileIconSize: CGFloat = 38
    private static let pinShiftAnimationKey = "apps-pin-shift"

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
        case none, pinned, expand, content, mode
    }

    private let store: AppsMenuStore
    private let presentViewModes: (NSMenu, NSView) -> Void
    private let reduceMotion: () -> Bool
    private let runningWindows: (pid_t) -> [AppsWindowAction]
    private let makeMenuItem: AppsMenuItemFactory
    private let buttonTransition: TimeInterval
    private let reorderTransition: TimeInterval
    private let dismiss: () -> Void
    private let surface = AppsMenuCanvas()
    private let searchBacking = AppsMenuBox(radius: 16, fill: .white.withAlphaComponent(0.08),
                                          border: .white.withAlphaComponent(0.17))
    private let searchField = NSSearchField()
    private let catalogScroll = AppsMenuScrollView(horizontal: false)
    private let browsingDocument = AppsMenuCanvas()
    private let searchDocument = AppsMenuCanvas()
    private let allViewport = AppsAllViewport()
    private let hoverEffects: [AppsMenuHoverEffect]
    private var activeHoverEffect: AppsMenuHoverEffect?
    private let footer = AppsMenuCanvas()
    private let footerRule = AppsMenuBox(radius: 0, fill: .white.withAlphaComponent(0.12))
    private let runningScroll = AppsMenuRunningScrollView(horizontal: true)
    private let runningDocument = AppsMenuCanvas()
    private var runningTiles: [RunningFooterKey: RunningFooterTile] = [:]
    private var runningExits: [RunningFooterKey: AppsMenuRunningExit] = [:]
    private var runningFooterSettled = false
    private var reconcilingRunningFooter = false
    private var runningTooltip: AppsMenuRunningTooltip?
    private var catalog: AppsMenuCatalog?
    private var applications: [AppsMenuApplication]? { catalog?.all }
    private var catalogNotice: String? {
        catalog?.allUnavailable == true ? String(localized: "macOS app catalog is unavailable.", table: "Apps") : nil
    }
    private var applicationsByID: [String: AppsMenuApplication] = [:]
    private var runningApps: [AppsMenuStore.RunningEntry] = []
    private var runningObservation: NSKeyValueObservation?
    private var frontmostObservation: NSKeyValueObservation?
    private var activationObservations: [(application: NSRunningApplication, token: NSKeyValueObservation)] = []
    private var catalogTask: Task<Void, Never>?
    private var viewModePreparation: Task<Void, Never>?
    private var refreshCatalogAfterOpening = false
    private var defersCatalogClipUpdates = false
    private var lastSize = CGSize.zero
    private var query = ""
    private(set) var searchResults: [AppsMenuApplication] = []
    private var searchMatches: [AppsMenuApplication]?
    private var searchPresentation: SearchPresentation?
    private var searchRows: [String: SearchRow] = [:]
    private var searchStatusViews: [NSView] = []
    private var browsingPosition = CGPoint.zero
    private var alphabetAnchor: String?
    private var alphabetPosition = CGPoint.zero
    private var category: AppsMenuCategory?
    private var categoryPosition = CGPoint.zero
    private var catalogWidth: CGFloat?
    private var pinnedLayout: PinnedLayout?
    private var pinnedContent: CatalogContent?
    private var allContents: [AppsMenuCatalogMode: CatalogContent] = [:]
    private var allLayouts: [AppsMenuCatalogMode: AppsAlphabeticalLayout] = [:]
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
    private weak var hoveredButton: AppsMenuButton?
    private var pointer = AppsPointerPosition()
    private var pointerFrame: NSRect?
    private var acceptsMenuActions = true
    private(set) var catalogDeferredUntilFrame: Bool
    private var hasPresented = false

    private struct SearchPresentation: Equatable {
        let rows: [AppsMenuApplication]
        let notice: String?
        let status: String?
        let width: CGFloat
    }

    private struct SearchRow {
        let app: AppsMenuApplication
        let button: AppsMenuButton
    }


    private enum RunningFooterKey: Hashable {
        case fileManager
        case application(String)
    }

    private struct RunningFooterContent {
        let name: String
        let url: URL?
        let process: NSRunningApplication?
        var fileManager: AppsMenuApplication?
    }

    private struct RunningFooterTile {
        let button: AppsMenuButton
        let content: RunningFooterContent
        let icon: NSImageView
        let indicator: AppsMenuBox?
    }
    private var displayedMode: AppsMenuCatalogMode?

    #if DESKMOTE_TEST
    var preparedViewModes: Set<AppsMenuCatalogMode> { Set(allContents.keys).union(allLayouts.keys) }
    private(set) var catalogClipReconciliationCount = 0
    #endif

    private let observeWorkspace: Bool

    init(observeWorkspace: Bool = true, makeMenuItem: @escaping AppsMenuItemFactory, frame: CGRect, store: AppsMenuStore,
         presentViewModes: @escaping (NSMenu, NSView) -> Void = { menu, anchor in
             menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 3), in: anchor)
         },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         runningWindows: @escaping (pid_t) -> [AppsWindowAction] = { _ in [] },
         buttonTransition: TimeInterval = 0.12, reorderTransition: TimeInterval = 0.16,
         deferCatalog: Bool = false,
         dismiss: @escaping () -> Void) {
        self.observeWorkspace = observeWorkspace
        self.store = store
        self.presentViewModes = presentViewModes
        self.reduceMotion = reduceMotion
        self.runningWindows = runningWindows
        self.makeMenuItem = makeMenuItem
        self.buttonTransition = buttonTransition
        self.reorderTransition = reorderTransition
        hoverEffects = [AppsMenuHoverEffect(duration: buttonTransition), AppsMenuHoverEffect(duration: buttonTransition)]
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
        allViewport.document.setAccessibilityElement(true)
        allViewport.document.setAccessibilityRole(.group)
        allViewport.document.catalogAccessibilityChildren = { [weak self] in
            self?.alphabeticalAccessibilityChildren()
        }
        surface.addSubview(footer)
        footer.addSubview(footerRule)
        footer.addSubview(runningScroll)
        runningScroll.documentView = runningDocument
        catalogScroll.onClipChanged = { [weak self] in self?.reconcileCatalogClip() }
        catalogScroll.onWheel = { [weak self] event in self?.recordPointer(event) }
        runningScroll.onWheel = { [weak self] event in self?.recordPointer(event) }
        runningScroll.onClipChanged = { [weak self] in
            guard let self, !reconcilingRunningFooter else { return }
            refreshHover()
        }
        searchField.cell = AppsMenuSearchFieldCell(textCell: "")
        searchField.isEditable = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        let placeholder = String(localized: "Search for apps", table: "Apps")
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
            runningApps = store.runningEntries()
        }
        layoutContents()
        if !deferCatalog, catalog == nil { loadCatalog() }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        stopObservingApplications()
        catalogTask?.cancel()
        viewModePreparation?.cancel()
    }

    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            clearPointer()
            layoutContents()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPointer()
        stopObservingApplications()
        if window == nil {
            runningFooterSettled = false
            clearRunningFooterAnimations()
        }
        guard window != nil, !catalogDeferredUntilFrame else {
            refreshHover()
            return
        }
        startObservingApplications()
    }

    override func viewDidHide() {
        super.viewDidHide()
        clearPointer()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if frame.origin != newOrigin { clearPointer() }
        super.setFrameOrigin(newOrigin)
    }

    override var frame: NSRect {
        didSet { if frame != oldValue { clearPointer() } }
    }

    private func startObservingApplications() {
        guard observeWorkspace else {
            refreshRunningApps()
            return
        }
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeApplicationPolicies() }
        }
        frontmostObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshRunningApps() }
        }
        observeApplicationPolicies()
    }

    #if DESKMOTE_TEST
    func withTrackedPressForTest(on control: NSButton, _ action: () -> Void) {
        (control as? AppsMenuButton)?.trackNativePress(action)
    }
    #endif

    fileprivate private(set) var presentationRevision: UInt64 = 0

    func prepareForPresentation(size: CGSize) {
        presentationRevision &+= 1
        clearPointer()
        allViewport.clearAccessibilityItems()
        acceptsMenuActions = true
        runningFooterSettled = false
        clearRunningFooterAnimations()
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
        refreshCatalogAfterOpening = !catalogDeferredUntilFrame && catalog != nil
        if !catalogDeferredUntilFrame, catalog == nil { loadCatalog() }
    }

    func presentedFirstFrame() {
        guard catalogDeferredUntilFrame, acceptsMenuActions, window != nil else { return }
        catalogDeferredUntilFrame = false
        startObservingApplications()
        if runningTiles[.fileManager] == nil { rebuildRunningFooter() }
        loadCatalog()
    }

    func presentedOpeningFinished() {
        runningFooterSettled = acceptsMenuActions
        guard acceptsMenuActions, refreshCatalogAfterOpening else { return }
        refreshCatalogAfterOpening = false
        loadCatalog()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func stopMenuActions() {
        acceptsMenuActions = false
        clearPointer()
        runningFooterSettled = false
        clearRunningFooterAnimations()
        refreshCatalogAfterOpening = false
        catalogTask?.cancel()
        catalogTask = nil
        viewModePreparation?.cancel()
        viewModePreparation = nil
        resetPinDrag()
        runningTooltip?.removeFromSuperview()
    }

    func refreshRunningApps() {
        let new = store.runningEntries()
        guard new != runningApps else { return }
        runningApps = new
        rebuildRunningFooter(animateChanges: true)
    }

    private func loadCatalog() {
        catalogTask?.cancel()
        let store = self.store
        catalogTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
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
        searchMatches = nil
        let available = snapshot.installed + (snapshot.all ?? [])
        applicationsByID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        pinnedContent = nil
        allContents.removeAll()
        allLayouts.removeAll()
        allViewport.clear()
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
        let changesScreen = query.isEmpty != newQuery.isEmpty
        if query.isEmpty {
            browsingPosition = alphabetAnchor == nil ? catalogScroll.contentView.bounds.origin : alphabetPosition
            alphabetAnchor = nil
        }
        query = newQuery
        searchMatches = nil
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
        let batchClip = !defersCatalogClipUpdates
        if batchClip { defersCatalogClipUpdates = true }
        let previousPins = transition == .pinned || transition == .expand ? pinButtons : [:]
        var transitionedPins: [UUID: AppsMenuButton]?
        defer {
            if batchClip {
                defersCatalogClipUpdates = false
                reconcileCatalogClip()
            }
            if let transitionedPins {
                animatePinnedTiles(previous: previousPins, current: transitionedPins, animateRemoval: transition == .pinned)
            }
        }
        resetPinDrag()
        let scrollPosition = position ?? catalogScroll.contentView.bounds.origin
        let height = query.isEmpty ? footer.frame.minY : surface.bounds.height
        let hidesFooter = !query.isEmpty
        if footer.isHidden != hidesFooter {
            footer.isHidden = hidesFooter
            if hidesFooter { clearRunningFooterAnimations() }
        }
        let scrollFrame = CGRect(x: 0, y: Self.searchBottom, width: surface.bounds.width,
                                 height: max(0, height - Self.searchBottom))
        if catalogScroll.frame != scrollFrame { catalogScroll.frame = scrollFrame }
        let width = surface.bounds.width
        if catalogWidth != width {
            viewModePreparation?.cancel()
            viewModePreparation = nil
            catalogWidth = width
            pinnedContent = nil
            allContents.removeAll()
            allLayouts.removeAll()
            allViewport.clear()
        }
        if query.isEmpty { clearSearchPresentation() }
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
            let cacheable = category == nil && applications != nil
            let mode = store.catalogMode
            displayedMode = mode
            let cachedAll = cacheable ? allContents[mode] : nil
            let pinned = pinnedContent ?? buildContent(using: buildPinned)
            pinnedContent = pinned
            let header = cachedAll ?? buildContent { buildAll(in: $0, mode: mode) }
            if cacheable { allContents[mode] = header }
            let all: CatalogContent
            if allLayouts[mode] != nil {
                allViewport.showHeader(header.document)
                all = CatalogContent(document: allViewport.document, height: header.height,
                                     buttons: header.buttons, pinButtons: [:])
            } else {
                all = header
            }
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
            let pinnedFrame = CGRect(x: 0, y: 0, width: width, height: pinned.height)
            let allFrame = CGRect(x: 0, y: pinned.height, width: width, height: all.height)
            if pinned.document.frame != pinnedFrame { pinned.document.frame = pinnedFrame }
            if all.document.frame != allFrame { all.document.frame = allFrame }
            if all.document === allViewport.document {
                let headerFrame = CGRect(x: 0, y: 0, width: width, height: 84)
                if header.document.frame != headerFrame { header.document.frame = headerFrame }
            }
            catalogButtons = pinned.buttons + all.buttons
            pinButtons = pinned.pinButtons
            setDocument(browsingDocument, height: pinned.height + all.height + 12, in: catalogScroll, position: scrollPosition)
            if transition == .pinned || transition == .expand {
                transitionedPins = pinned.pinButtons
            } else if transition == .content {
                animateEntry(all.document)
            }
        } else {
            updateSearchPresentation(position: scrollPosition)
            if transition == .content { animateEntry(searchDocument) }
        }
        if let identifier, folderID == nil {
            if let frame = alphabeticalFrameInBrowsingDocument(identifier) {
                browsingDocument.scrollToVisible(frame)
            } else if let button = catalogButtons.first(where: { $0.identifier?.rawValue == identifier }) {
                button.scrollToVisible(button.bounds)
            }
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
        let duration = reorderTransition
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

    private func updateSearchPresentation(position: CGPoint) {
        let notice = catalogNotice
        if searchMatches == nil {
            searchMatches = applications?.filter { $0.name.localizedStandardContains(query) } ?? []
        }
        searchResults = searchMatches ?? []
        let visibleNotice = applications == nil ? nil : notice
        let status: String?
        if applications == nil {
            status = notice ?? String(localized: "Loading apps…", table: "Apps")
        } else {
            status = searchResults.isEmpty ? String(localized: "No matching apps", table: "Apps") : nil
        }
        let presentation = SearchPresentation(rows: searchResults, notice: visibleNotice, status: status,
                                              width: surface.bounds.width)
        let offset: CGFloat = presentation.notice == nil ? 0 : 40
        let top = 6 + offset
        var created = 0
        var retired = 0
        if searchPresentation != presentation {
            let previous = searchPresentation
            if previous?.notice != presentation.notice || previous?.status != presentation.status ||
                previous?.width != presentation.width {
                searchStatusViews.forEach { $0.removeFromSuperview() }
                searchStatusViews = [
                    presentation.notice.map { searchStatus($0, at: 12) },
                    presentation.status.map { searchStatus($0, at: 12 + offset) }
                ].compactMap { $0 }
            }

            let matches = Dictionary(presentation.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, row) in searchRows where matches[id] != row.app {
                retireSearchRow(row.button)
                searchRows[id] = nil
                retired += 1
            }
            for (index, app) in presentation.rows.enumerated() {
                let frame = appRowFrame(index: index, top: top)
                if let existing = searchRows[app.id]?.button {
                    if existing.frame != frame { existing.frame = frame }
                    if previous?.width != presentation.width {
                        for child in existing.subviews {
                            if child is NSTextField { child.frame = appRowTitleFrame(width: frame.width) }
                            if child is AppsMenuListIconView { child.frame.origin.x = horizontal(6) }
                        }
                    }
                    continue
                }
                let row = makeAppRow(app, frame: frame) { [weak self] source in
                    guard let self, self.isCurrentSearchRow(source, app: app) else { return }
                    self.launch(app, from: source)
                }
                let isCurrent = { [weak self, weak row] in
                    guard let self, let row else { return false }
                    return self.isCurrentSearchRow(row, app: app)
                }
                row.contextMenu = { [weak self] in
                    guard isCurrent() else { return nil }
                    return self?.appMenu(for: app, isCurrent: isCurrent)
                }
                searchRows[app.id] = SearchRow(app: app, button: row)
                searchDocument.addSubview(row)
                attachHover(to: row)
                created += 1
            }
            searchPresentation = presentation
        }
        catalogButtons = presentation.rows.compactMap { searchRows[$0.id]?.button }
        let height = presentation.status == nil ? top + CGFloat(presentation.rows.count) * Self.rowPitch : 42 + offset
        setDocument(searchDocument, height: height + 12, in: catalogScroll, position: position)
    }

    private func searchStatus(_ title: String, at y: CGFloat) -> NSView {
        let label = makeLabel(title, size: 12)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: horizontal(63), y: y, width: horizontal(515), height: 22)
        searchDocument.addSubview(label)
        return label
    }

    private func isCurrentSearchRow(_ button: AppsMenuButton, app: AppsMenuApplication) -> Bool {
        guard acceptsMenuActions, !query.isEmpty, catalogScroll.documentView === searchDocument,
              let row = searchRows[app.id] else { return false }
        return row.button === button && row.app == app
    }

    private func retireSearchRow(_ button: AppsMenuButton) {
        if hoveredButton === button {
            activeHoverEffect?.hide(animated: false)
            activeHoverEffect = nil
            hoveredButton = nil
        }
        button.retireCatalogBinding()
        button.removeFromSuperview()
    }

    private func clearSearchPresentation() {
        guard searchPresentation != nil else { return }
        searchRows.values.forEach { retireSearchRow($0.button) }
        searchRows.removeAll(keepingCapacity: true)
        searchStatusViews.forEach { $0.removeFromSuperview() }
        searchStatusViews.removeAll()
        searchResults.removeAll()
        searchMatches = nil
        searchPresentation = nil
    }

    private func buildPinned(in document: AppsMenuCanvas) -> CGFloat {
        addHeading(String(localized: "Pinned", table: "Apps"), y: 31, to: document)
        let pins = store.pins.compactMap { pin -> (AppsMenuPin, [AppsMenuApplication])? in
            let apps = pin.applicationIDs.compactMap { applicationsByID[$0] }
            return apps.isEmpty ? nil : (pin, apps)
        }
        let visiblePins = store.expanded ? pins : Array(pins.prefix(12))
        if pins.count > 12 {
            let expanded = store.expanded
            let title = expanded ? String(localized: "Show less", table: "Apps") : String(localized: "Show all", table: "Apps")
            let button = addCatalogControl(title, icon: expanded ? "chevron.up" : "chevron.down", y: 39,
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
                                 pitch: horizontal(96), in: document, pinned: true) { [weak self] control in
                guard let self, pinButtons[pin.id] === control else { return }
                if pin.name == nil { launch(apps[0], from: control) } else { openFolder(pin.id) }
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
        addHeading(String(localized: "All", table: "Apps"), y: 0, to: document)
        let title = String.localizedStringWithFormat(String(localized: "View: %@", table: "Apps"), mode.title)
        _ = addCatalogControl(title, icon: "chevron.down", y: 10,
                               id: "mode", in: document) { [weak self] button in
            self?.showViewModes(at: button)
        }
        let notice = catalogNotice
        if let notice {
            let height = addStatus(notice, at: 42, to: document)
            if applications?.isEmpty != false { return height }
        }
        guard let applications else {
            return addStatus(String(localized: "Loading apps…", table: "Apps"), at: 42, to: document)
        }
        guard !applications.isEmpty else {
            return addStatus(String(localized: "No apps available", table: "Apps"), at: 42, to: document)
        }
        let noticeOffset: CGFloat = notice == nil ? 0 : 34
        switch mode {
        case .list, .grid:
            let layout = allLayouts[mode] ?? makeAlphabeticalLayout(applications, grid: mode == .grid,
                                                                   top: 44.5 + noticeOffset)
            allLayouts[mode] = layout
            return layout.height
        case .category:
            return buildCategories(applications, top: 34 + noticeOffset, in: document)
        }
    }

    func makeAlphabeticalLayout(_ apps: [AppsMenuApplication], grid: Bool, top: CGFloat) -> AppsAlphabeticalLayout {
        var items: [AppsAlphabeticalLayout.Item] = []
        var y = top
        let groups = Dictionary(grouping: apps, by: alphabetKey)
        let width = surface.bounds.width
        let sectionInset = horizontal(53)
        let rowInset = horizontal(62)
        let tileWidth = max(1, horizontal(96) - 2)
        for key in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let group = groups[key] else { continue }
            let sectionFrame = CGRect(x: sectionInset, y: y - 10, width: max(0, width - sectionInset * 2), height: 40)
            items.append(.init(identifier: NSUserInterfaceItemIdentifier("section-\(key)"),
                               frame: sectionFrame, role: .section(key)))
            y += 40
            for (index, app) in group.enumerated() {
                let identifier = applicationIdentifier(app, inFolder: false)
                if grid {
                    let x = horizontal(81 + CGFloat(index % 6) * 96)
                    let frame = CGRect(x: x - tileWidth / 2, y: y + CGFloat(index / 6) * Self.tilePitch - 7,
                                       width: tileWidth, height: 79)
                    items.append(.init(identifier: identifier, frame: frame, role: .gridApp(app)))
                } else {
                    let frame = CGRect(x: rowInset, y: y + CGFloat(index) * Self.rowPitch - 6,
                                       width: max(0, width - rowInset * 2), height: 40)
                    items.append(.init(identifier: identifier, frame: frame, role: .listApp(app)))
                }
            }
            if grid {
                y += CGFloat((group.count + 5) / 6) * Self.tilePitch + 16
            } else {
                y += CGFloat(group.count) * Self.rowPitch + 10
            }
        }
        return AppsAlphabeticalLayout(items: items, height: y)
    }

    private func alphabeticalFrameInBrowsingDocument(_ identifier: String) -> CGRect? {
        guard query.isEmpty, alphabetAnchor == nil, category == nil, let displayedAll,
              let layout = allLayouts[store.catalogMode],
              let frame = layout.frame(for: NSUserInterfaceItemIdentifier(identifier)) else { return nil }
        return displayedAll.convert(frame, to: browsingDocument)
    }

    private var activeAlphabeticalLayout: AppsAlphabeticalLayout? {
        guard catalogScroll.documentView === browsingDocument, displayedAll === allViewport.document else { return nil }
        return allLayouts[store.catalogMode]
    }

    private func bindAlphabeticalItem(_ item: AppsAlphabeticalLayout.Item, reusing old: AppsMenuButton?) -> AppsMenuButton {
        let button = old ?? AppsMenuButton(title: item.role.label, buttonTransition: buttonTransition, style: .glassRow) { _ in }
        if hoveredButton === button {
            activeHoverEffect?.hide(animated: false)
            activeHoverEffect = nil
            hoveredButton = nil
        }
        button.bindCatalogItem(item) { [weak self] button in
            guard let self, acceptsMenuActions, activeAlphabeticalLayout != nil,
                  button.superview === allViewport.document, button.identifier == item.identifier else { return }
            switch item.role {
            case .section(let letter): openAlphabet(at: letter)
            case .listApp(let app), .gridApp(let app): launch(app, from: button)
            }
        }
        let revision = button.catalogBindingRevision
        let isCurrent = { [weak self, weak button] in
            guard let self, let button else { return false }
            return acceptsMenuActions && activeAlphabeticalLayout != nil &&
                button.catalogBindingRevision == revision && button.superview === allViewport.document
        }
        switch item.role {
        case .section(let letter):
            let heading = makeLabel(letter, size: 13)
            heading.frame = CGRect(x: horizontal(12), y: 10, width: 42, height: 19)
            heading.setAccessibilityElement(false)
            button.addSubview(heading)
        case .listApp(let app):
            configureAppRow(button, for: app)
            button.contextMenu = { [weak self] in
                guard isCurrent() else { return nil }
                return self?.appMenu(for: app, isCurrent: isCurrent)
            }
        case .gridApp(let app):
            configureTile(button, name: app.name, apps: [app])
            button.contextMenu = { [weak self] in
                guard isCurrent() else { return nil }
                return self?.appMenu(for: app, isCurrent: isCurrent)
            }
        }
        if old == nil { attachHover(to: button) }
        return button
    }

    private func alphabeticalAccessibilityChildren() -> [Any]? {
        guard let layout = activeAlphabeticalLayout else { return nil }
        let revision = presentationRevision
        return allViewport.accessibilityChildren(for: layout) { [weak self] item, action in
            guard let self, presentationRevision == revision else { return false }
            return performAlphabeticalAccessibilityAction(item, action: action)
        }
    }

    private func performAlphabeticalAccessibilityAction(
        _ item: AppsAlphabeticalLayout.Item, action: AppsAlphabeticalAccessibilityItem.Action
    ) -> Bool {
        guard acceptsMenuActions, folderID == nil,
              activeAlphabeticalLayout?.item(for: item.identifier)?.role.target == item.role.target,
              let frame = alphabeticalFrameInBrowsingDocument(item.identifier.rawValue) else { return false }
        let clip = catalogScroll.documentVisibleRect
        var position = clip.origin
        if frame.minY < clip.minY {
            position.y = frame.minY
        } else if frame.maxY > clip.maxY {
            position.y = frame.maxY - clip.height
        }
        scroll(catalogScroll, to: position)
        guard let button = allViewport.button(for: item.identifier) else { return false }
        switch action {
        case .focus:
            return true
        case .press:
            guard let action = button.action else { return false }
            return NSApp.sendAction(action, to: button.target, from: button)
        case .contextMenu:
            guard button.window?.isVisible == true else { return false }
            return button.accessibilityPerformShowMenu()
        }
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
        guard let letter, let frame = alphabeticalFrameInBrowsingDocument("section-\(letter)") else { return }
        scroll(catalogScroll, to: CGPoint(x: 0, y: max(0, frame.minY - 14)))
    }

    private func buildAlphabetIndex(in document: AppsMenuCanvas) -> CGFloat {
        addHeading(String(localized: "All", table: "Apps"), y: 24, to: document)
        _ = addCatalogControl(String(localized: "Back", table: "Apps"), icon: "chevron.left", y: 35, id: "alphabet-back",
                               in: document, backStyle: true) { [weak self] _ in self?.closeAlphabet() }
        let available = Set((applications ?? []).map(alphabetKey))
        let latin = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        let letters = latin + available.subtracting(latin).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let columns = 6
        let pitch = min(50, surface.bounds.width / CGFloat(columns + 1))
        let left = (surface.bounds.width - CGFloat(columns) * pitch) / 2
        for (index, letter) in letters.enumerated() {
            let button = AppsMenuButton(title: letter, buttonTransition: buttonTransition) { [weak self] _ in self?.closeAlphabet(jumpTo: letter) }
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
            register(makeAppRow(app, frame: appRowFrame(index: index, top: top)), in: document)
        }
        return top + CGFloat(apps.count) * Self.rowPitch
    }

    private func appRowFrame(index: Int, top: CGFloat) -> CGRect {
        let leading = horizontal(62)
        return CGRect(x: leading, y: top + CGFloat(index) * Self.rowPitch - 6,
                      width: max(0, surface.bounds.width - leading * 2), height: 40)
    }

    private func appRowTitleFrame(width: CGFloat) -> CGRect {
        let x = max(33, horizontal(45))
        return CGRect(x: x, y: 11, width: max(0, width - x - 6), height: 18)
    }

    private func makeAppRow(_ app: AppsMenuApplication, frame: CGRect,
                            activate: ((AppsMenuButton) -> Void)? = nil) -> AppsMenuButton {
        let button = AppsMenuButton(title: app.name, buttonTransition: buttonTransition, style: .glassRow, action: activate ?? { [weak self] control in
            self?.launch(app, from: control)
        })
        button.identifier = applicationIdentifier(app, inFolder: false)
        button.contextMenu = { [weak self] in self?.appMenu(for: app) }
        button.frame = frame
        configureAppRow(button, for: app)
        return button
    }

    private func configureAppRow(_ button: AppsMenuButton, for app: AppsMenuApplication) {
        let revision = button.catalogBindingRevision
        button.pendingContent = { [weak self] button in
            guard let self else { return }
            let icon = AppsMenuListIconView(frame: CGRect(x: horizontal(6), y: 8, width: 24, height: 24),
                                           artworkSize: Self.tileIconSize)
            icon.setAccessibilityElement(false)
            button.addSubview(icon)
            store.requestIcon(at: app.url) { [weak icon, weak button] artwork in
                guard button?.catalogBindingRevision == revision else { return }
                icon?.artwork = artwork
            }
            let text = makeLabel(app.name, size: 12, weight: .medium)
            text.frame = appRowTitleFrame(width: button.frame.width)
            text.setAccessibilityElement(false)
            button.addSubview(text)
        }
    }

    private func buildCategories(_ apps: [AppsMenuApplication], top: CGFloat, in document: AppsMenuCanvas) -> CGFloat {
        let groups = Dictionary(grouping: apps) { AppsMenuCategory(key: $0.category) }
        if let category, let group = groups[category] {
            let back = addCatalogControl(category.title, icon: "chevron.left", y: top + 13, id: "category-back",
                                         in: document, backStyle: true, weight: .semibold,
                                         leftPlacement: (horizontal(63), min(190, horizontal(260)))) { [weak self] _ in
                self?.showCategory(nil)
            }
            back.setAccessibilityLabel(String(localized: "Back", table: "Apps"))
            return buildRows(group, top: top + 43, in: document)
        }
        let categories = AppsMenuCategory.allCases.filter { groups[$0] != nil }
        for (index, group) in categories.enumerated() {
            guard let groupApps = groups[group] else { continue }
            let left = horizontal(66 + CGFloat(index % 3) * 178)
            let y = top + CGFloat(index / 3) * 204
            let size = horizontal(154)
            let categoryButton = AppsMenuButton(title: group.title, buttonTransition: buttonTransition) { [weak self] _ in self?.showCategory(group) }
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
                let button = AppsMenuButton(title: app.name, buttonTransition: buttonTransition) { [weak self] control in self?.launch(app, from: control) }
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
            let item = makeMenuItem(mode.title) { [weak self, weak menu] in
                menu?.cancelTrackingWithoutAnimation()
                DispatchQueue.main.async { [weak self] in
                    guard let self, store.catalogMode != mode || category != nil else { return }
                    store.catalogMode = mode
                    category = nil
                    rebuildCatalog(reveal: "mode", transition: .mode)
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

    private func addCatalogControl(_ title: String, icon: String, y: CGFloat, id: String,
                                   in view: NSView, backStyle: Bool = false, weight: NSFont.Weight = .regular,
                                   leftPlacement: (x: CGFloat, width: CGFloat)? = nil,
                                   action: @escaping (AppsMenuButton) -> Void) -> AppsMenuButton {
        let button = AppsMenuButton(title: title, buttonTransition: buttonTransition, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        let fontSize: CGFloat = backStyle ? 13 : 12
        let label = makeLabel(title, size: fontSize, weight: weight)
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let text = (title as NSString).size(withAttributes: [.font: font])
        let padding: CGFloat = 8
        let spacing: CGFloat = backStyle ? 8 : 6
        let iconSize: CGFloat = backStyle ? 10 : 9
        let overhead = 2 * padding + spacing + iconSize
        let width = leftPlacement?.width ?? max(backStyle ? 64 : 86, min(horizontal(235), ceil(text.width) + overhead))
        let height: CGFloat = backStyle ? 26 : 22
        let captionWidth = max(0, min(ceil(text.width), width - overhead))
        let captionHeight = ceil(text.height)
        let leading = (width - captionWidth - spacing - iconSize) / 2
        let x = leftPlacement?.x ?? horizontal(backStyle ? 565 : 584) - width
        button.frame = CGRect(x: x, y: y - height / 2, width: width, height: height)
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
                             pitch: pitch, in: view, folder: folder) { [weak self] control in
            self?.launch(app, from: control)
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
        let button = AppsMenuButton(title: name, buttonTransition: buttonTransition, style: pinned ? .pinned : .glassRow, action: action)
        button.frame = CGRect(x: x - width / 2, y: top - 7 - topPadding, width: width, height: 79 + topPadding)
        configureTile(button, name: name, apps: apps, isFolder: isFolder, folder: folder, pinned: pinned)
        register(button, in: view, folder: folder)
        return button
    }

    private func configureTile(_ button: AppsMenuButton, name: String, apps: [AppsMenuApplication],
                               isFolder: Bool = false, folder: Bool = false, pinned: Bool = false) {
        let width = button.frame.width
        let topPadding: CGFloat = pinned ? 5 : 0
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
    }

    private func displayName(for folder: AppsMenuPin) -> String {
        guard let name = folder.name, !name.isEmpty else { return String(localized: "Folder", table: "Apps") }
        return name
    }

    private func launch(_ app: AppsMenuApplication, from button: AppsMenuButton) {
        completeAppSelection(from: button) { store.launch(app, intent: .foreground) }
    }

    private func completeAppSelection(from button: AppsMenuButton, open: () -> Void) {
        guard acceptsMenuActions, button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
              button.isDescendant(of: self), folderGlass.map({ button.isDescendant(of: $0) }) ?? true else { return }
        acceptsMenuActions = false
        dismiss()
        open()
    }
}

private extension AppsMenuView {
    func appMenu(for app: AppsMenuApplication, topLevelPin: UUID? = nil,
                 isCurrent: @escaping () -> Bool = { true }) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let membership = store.pins.first { $0.applicationIDs.contains(app.id) }
        if membership == nil {
            menu.addItem(makeMenuItem(String(localized: "Pin", table: "Apps")) { [weak self] in
                guard isCurrent() else { return }
                self?.updatePins { $0.pin(app) }
            })
        } else {
            menu.addItem(makeMenuItem(String(localized: "Unpin", table: "Apps")) { [weak self] in
                guard isCurrent() else { return }
                self?.updatePins { $0.unpin(app.id) }
            })
        }
        if let pin = membership, pin.name == nil {
            menu.addItem(makeMenuItem(String(localized: "Create Folder", table: "Apps")) { [weak self] in
                guard isCurrent(), let self, let folder = store.createFolder(from: pin.id) else { return }
                rebuildCatalog(transition: .pinned)
                openFolder(folder)
            })
        }
        let destinations = membership.map { pin in store.pins.filter { $0.name != nil && $0.id != pin.id } } ?? []
        if !destinations.isEmpty {
            let name = String(localized: "Move to Folder", table: "Apps")
            let submenu = NSMenu(title: name)
            submenu.autoenablesItems = false
            for folder in destinations {
                submenu.addItem(makeMenuItem(displayName(for: folder)) { [weak self] in
                    guard isCurrent() else { return }
                    self?.updatePins { $0.moveApp(app.id, to: folder.id) }
                })
            }
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if membership?.name != nil {
            menu.addItem(makeMenuItem(String(localized: "Remove from Folder", table: "Apps")) { [weak self] in
                guard isCurrent() else { return }
                self?.updatePins { $0.removeFromFolder(app.id) }
            })
        }
        if let topLevelPin { addReordering(to: menu, for: topLevelPin) }
        return menu
    }

    func folderMenu(_ pin: AppsMenuPin) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeMenuItem(String(localized: "Rename Folder", table: "Apps")) { [weak self] in
            self?.openFolder(pin.id, rename: true)
        })
        menu.addItem(makeMenuItem(String(localized: "Unpin", table: "Apps")) { [weak self] in
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
            menu.addItem(makeMenuItem(String(localized: "Move Earlier", table: "Apps")) { [weak self] in
                self?.movePin(id, offset: -1)
            })
        }
        if index < pins.count - 1 {
            menu.addItem(makeMenuItem(String(localized: "Move Later", table: "Apps")) { [weak self] in
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
        slide.duration = reorderTransition
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(slide, forKey: Self.pinShiftAnimationKey)
        CATransaction.commit()
    }

    func resetPinDrag() {
        guard let drag = pinDrag else { return }
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
        let title = AppsMenuButton(title: displayName(for: folder), buttonTransition: buttonTransition) { [weak self] _ in self?.openFolder(id, rename: true) }
        title.contextMenu = { [weak self] in self?.folderMenu(folder) }
        title.toolTip = String(localized: "Rename Folder", table: "Apps")
        title.identifier = NSUserInterfaceItemIdentifier("folder-title")
        title.usesNativeContent = true
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.frame = renameFrame
        if editing == nil { register(title, in: body, folder: true) }
        let scroll = AppsMenuScrollView(horizontal: false)
        scroll.onWheel = { [weak self] event in self?.recordPointer(event) }
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
            field.setAccessibilityLabel(String(localized: "Rename Folder", table: "Apps"))
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
        if hidden { clearRunningFooterAnimations() }
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

    func rebuildRunningFooter(animateChanges: Bool = false) {
        reconcilingRunningFooter = true
        defer {
            reconcilingRunningFooter = false
            refreshHover()
        }
        let pitch: CGFloat = 46
        let available = max(0, surface.bounds.width - horizontal(108))
        let manager = catalogDeferredUntilFrame ? nil : store.systemFileManager
        let managerProcess = manager.flatMap { manager in
            runningApps.first { $0.bundleIdentifier == manager.id }?.application
        }
        let applications = runningApps.filter { manager == nil || $0.bundleIdentifier != manager?.id }
        var liveKeys = Set(applications.map { RunningFooterKey.application($0.id) })
        if manager != nil { liveKeys.insert(.fileManager) }
        let animate = animateChanges && runningFooterSettled && acceptsMenuActions && !footer.isHidden &&
            folderID == nil && window?.isVisible == true && !reduceMotion()
        if !animate { clearRunningFooterAnimations() }
        let inserted = animate ? liveKeys.subtracting(runningTiles.keys) : []
        for key in inserted { runningExits.removeValue(forKey: key)?.removeFromSuperview() }
        for key in runningTiles.keys where !liveKeys.contains(key) {
            guard let tile = runningTiles.removeValue(forKey: key) else { continue }
            if animate, key != .fileManager { animateRunningExit(key, button: tile.button) }
            tile.button.removeFromSuperview()
        }
        let fixedWidth = manager == nil ? 0 : min(pitch, available)
        let scrollAvailable = available - fixedWidth
        let total = CGFloat(applications.count) * pitch
        let nextIconPreview: CGFloat = 28
        let width = total > scrollAvailable && scrollAvailable >= pitch + nextIconPreview
            ? floor((scrollAvailable - nextIconPreview) / pitch) * pitch + nextIconPreview
            : min(total, scrollAvailable)
        let position = runningScroll.contentView.bounds.origin
        let left = (surface.bounds.width - width - fixedWidth) / 2
        let scrollFrame = CGRect(x: left + fixedWidth, y: 6, width: width, height: 56)
        if runningScroll.frame != scrollFrame { runningScroll.frame = scrollFrame }
        let documentFrame = CGRect(x: 0, y: 0, width: total, height: 56)
        if runningDocument.frame != documentFrame { runningDocument.frame = documentFrame }
        let iconSize = Self.tileIconSize
        let iconTopInset: CGFloat = 3
        let dotSize: CGFloat = 3
        let dotGap: CGFloat = 2
        let pairHeight = iconSize + dotGap + dotSize
        let iconTop = (footer.bounds.height - pairHeight - iconTopInset) / 2 - runningScroll.frame.minY
        let iconFrame = CGRect(x: (pitch - iconSize) / 2, y: iconTop, width: iconSize, height: iconSize)
        let dotFrame = CGRect(x: (pitch - dotSize) / 2, y: iconFrame.maxY + dotGap, width: dotSize, height: dotSize)
        if let manager {
            let content = RunningFooterContent(name: manager.name, url: manager.url,
                                               process: managerProcess, fileManager: manager)
            let button = updateRunningTile(.fileManager, content: content, iconFrame: iconFrame, dotFrame: dotFrame)
            let frame = CGRect(x: left, y: scrollFrame.minY, width: fixedWidth, height: 50)
            if button.frame != frame { button.frame = frame }
            button.isHidden = fixedWidth == 0
            if button.superview == nil { footer.addSubview(button) }
        }
        let buttons = applications.enumerated().map { index, app in
            let content = RunningFooterContent(name: app.name, url: app.url, process: app.application)
            let button = updateRunningTile(.application(app.id), content: content, iconFrame: iconFrame, dotFrame: dotFrame)
            let frame = CGRect(x: CGFloat(index) * pitch, y: 0, width: pitch, height: 50)
            if button.frame != frame { button.frame = frame }
            return button
        }
        if !runningDocument.subviews.elementsEqual(buttons, by: { $0 === $1 }) { runningDocument.subviews = buttons }
        let scrollable = total > width && width > 0
        if runningScroll.hasHorizontalScroller != scrollable { runningScroll.hasHorizontalScroller = scrollable }
        scroll(runningScroll, to: position)
        if !inserted.isEmpty {
            let visible = runningScroll.documentVisibleRect
            for key in inserted where key != .fileManager {
                guard let button = runningTiles[key]?.button, button.frame.intersects(visible) else { continue }
                animateRunningOpacity(button, from: 0, to: 1, key: "apps-running-appear")
            }
        }
    }

    private func clearRunningFooterAnimations() {
        for exit in runningExits.values { exit.removeFromSuperview() }
        runningExits.removeAll(keepingCapacity: true)
        for tile in runningTiles.values { tile.button.layer?.removeAnimation(forKey: "apps-running-appear") }
    }

    private func animateRunningExit(_ key: RunningFooterKey, button: AppsMenuButton) {
        let visible = button.convert(runningScroll.documentVisibleRect, from: runningDocument)
        let region = button.bounds.intersection(visible)
        guard !region.isEmpty, let bitmap = button.bitmapImageRepForCachingDisplay(in: region) else { return }
        button.cacheDisplay(in: region, to: bitmap)
        let image = NSImage(size: region.size)
        bitmap.size = region.size
        image.addRepresentation(bitmap)
        let exit = AppsMenuRunningExit(frame: footer.convert(region, from: button))
        exit.image = image
        exit.imageScaling = .scaleAxesIndependently
        exit.setAccessibilityElement(false)
        exit.setAccessibilityHidden(true)
        runningExits.updateValue(exit, forKey: key)?.removeFromSuperview()
        footer.addSubview(exit)
        let opacity = button.layer?.presentation()?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak exit] in
            Task { @MainActor in
                guard let self, let exit, self.runningExits[key] === exit else { return }
                self.runningExits[key] = nil
                exit.removeFromSuperview()
            }
        }
        animateRunningOpacity(exit, from: opacity, to: 0, key: "apps-running-exit")
        CATransaction.commit()
    }

    private func animateRunningOpacity(_ view: NSView, from: Float, to: Float, key: String) {
        view.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = reorderTransition
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = to != 0
        view.layer?.add(fade, forKey: key)
    }

    private func updateRunningTile(
        _ key: RunningFooterKey, content: RunningFooterContent, iconFrame: CGRect, dotFrame: CGRect
    ) -> AppsMenuButton {
        let previous = runningTiles[key]
        let button = previous?.button ?? makeRunningButton(key, title: content.name)
        if let previous {
            let targetChanged = key == .fileManager
                ? previous.content.fileManager?.url != content.fileManager?.url
                : previous.content.process !== content.process || previous.content.url != content.url
            if targetChanged { button.advanceBinding() }
        }
        if button.title != content.name {
            button.title = content.name
            button.setAccessibilityLabel(content.name)
        }
        let identifier = NSUserInterfaceItemIdentifier(key == .fileManager ? "running-system-file-manager" :
            "running-\(content.process?.processIdentifier ?? 0)")
        if button.identifier != identifier { button.identifier = identifier }
        let icon: NSImageView
        if let previous, previous.content.url == content.url,
           content.url != nil || previous.content.process === content.process {
            icon = previous.icon
            if icon.frame != iconFrame { icon.frame = iconFrame }
        } else {
            previous?.icon.removeFromSuperview()
            if let url = content.url {
                icon = addFileIcon(url, at: iconFrame, to: button)
            } else {
                icon = addIcon(content.process?.icon ?? NSImage(named: NSImage.applicationIconName), at: iconFrame, to: button)
            }
        }
        let indicator: AppsMenuBox?
        if content.process != nil {
            let dot = previous?.indicator ?? AppsMenuBox(radius: dotFrame.width / 2, fill: .labelColor.withAlphaComponent(0.76))
            if dot.frame != dotFrame { dot.frame = dotFrame }
            if dot.superview == nil { button.addSubview(dot) }
            indicator = dot
        } else {
            previous?.indicator?.removeFromSuperview()
            indicator = nil
        }
        runningTiles[key] = RunningFooterTile(button: button, content: content, icon: icon, indicator: indicator)
        return button
    }

    private func makeRunningButton(_ key: RunningFooterKey, title: String) -> AppsMenuButton {
        let button = AppsMenuButton(title: title, buttonTransition: buttonTransition, style: .running) { [weak self] button in
            guard let self, acceptsMenuActions, let tile = runningTiles[key], tile.button === button else { return }
            if let manager = tile.content.fileManager {
                launch(manager, from: button)
            } else if let process = tile.content.process, !process.isTerminated {
                completeAppSelection(from: button) { store.reopen(process) }
            }
        }
        button.contextMenu = { [weak self, weak button] in
            guard let self, let button, let tile = runningTiles[key], tile.button === button,
                  let process = tile.content.process else { return nil }
            return runningAppMenu(for: process, key: key, button: button)
        }
        attachHover(to: button)
        return button
    }

    private func runningAppMenu(for app: NSRunningApplication, key: RunningFooterKey, button: AppsMenuButton) -> NSMenu? {
        let isCurrent = { [weak self, weak button] in
            guard let self, let button, acceptsMenuActions, let tile = runningTiles[key], tile.button === button,
                  let process = tile.content.process else { return false }
            return process.isEqual(app) && !app.isTerminated
        }
        guard isCurrent() else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let windows = runningWindows(app.processIdentifier)
        for window in windows {
            let entry = makeMenuItem(window.title) { [weak self] in
                guard let self, isCurrent() else { return }
                dismiss()
                window.activate()
            }
            entry.state = window.isActive ? .on : .off
            menu.addItem(entry)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        if let url = app.bundleURL {
            let options = NSMenu(title: String(localized: "Options", table: "Apps"))
            options.autoenablesItems = false
            options.addItem(makeMenuItem(String(localized: "Show in Finder", table: "Apps")) { [weak self] in
                guard let self, isCurrent() else { return }
                dismiss()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            let item = NSMenuItem(title: options.title, action: nil, keyEquivalent: "")
            item.submenu = options
            menu.addItem(item)
        }
        let show = app.isHidden
        let visibilityTitle = show ? String(localized: "Show", table: "Apps") : String(localized: "Hide", table: "Apps")
        menu.addItem(makeMenuItem(visibilityTitle) { [weak self] in
            guard let self, isCurrent(), app.isHidden == show else { return }
            dismiss()
            if show { app.activate(options: []) } else { app.hide() }
        })
        if key != .fileManager {
            menu.addItem(makeMenuItem(String(localized: "Quit", table: "Apps")) { [store] in
                guard isCurrent() else { return }
                app.terminate()
            })
        }
        return menu
    }

    func setDocument(_ document: NSView, height: CGFloat, in scroller: NSScrollView, position: CGPoint) {
        let frame = CGRect(x: 0, y: 0, width: scroller.frame.width, height: max(height, scroller.frame.height))
        let scrollable = height > scroller.frame.height
        if document.frame != frame { document.frame = frame }
        if scroller.hasVerticalScroller != scrollable { scroller.hasVerticalScroller = scrollable }
        if scroller.documentView !== document { scroller.documentView = document }
        scroll(scroller, to: position)
    }

    func scroll(_ view: NSScrollView, to position: CGPoint) {
        let clip = view.contentView
        let constrained = clip.constrainBoundsRect(CGRect(origin: position, size: clip.bounds.size))
        if clip.bounds.origin != constrained.origin { clip.scroll(to: constrained.origin) }
        view.reflectScrolledClipView(clip)
    }

    func register(_ button: AppsMenuButton, in view: NSView, folder: Bool = false) {
        view.addSubview(button)
        attachHover(to: button)
        if !folder { catalogButtons.append(button) }
    }

    private func reconcileCatalogClip() {
        guard !defersCatalogClipUpdates else { return }
        #if DESKMOTE_TEST
        catalogClipReconciliationCount += 1
        #endif
        renderVisibleCatalogButtons()
        refreshHover()
    }

    func renderVisibleCatalogButtons() {
        guard let document = catalogScroll.documentView else { return }
        let visible = catalogScroll.documentVisibleRect.insetBy(dx: 0, dy: -84)
        let alphabetical = activeAlphabeticalLayout.map { layout in
            allViewport.apply(layout, visibleRect: allViewport.document.convert(visible, from: document),
                              bind: { bindAlphabeticalItem($0, reusing: $1) })
        } ?? []
        for button in catalogButtons + alphabetical where button.pendingContent != nil {
            guard let parent = button.superview, parent === document || parent.isDescendant(of: document),
                  parent.convert(button.frame, to: document).intersects(visible) else { continue }
            button.renderPendingContent()
        }
    }

    func attachHover(to button: AppsMenuButton) {
        button.onPointerChanged = { [weak self] event in
            self?.recordPointer(event)
            self?.refreshHover()
        }
    }

    private func recordPointer(_ event: NSEvent) {
        guard acceptsMenuActions, !isHiddenOrHasHiddenAncestor,
              pointer.receive(event, in: window) else { return }
        pointerFrame = convert(bounds, to: nil)
    }

    internal func clearPointer() {
        pointer.clear()
        pointerFrame = nil
        if hoveredButton != nil { refreshHover() }
    }

    func refreshHover() {
        let target: AppsMenuButton?
        if acceptsMenuActions, pinDrag == nil, let window, window.isKeyWindow,
           let point = pointer.location(in: window), pointerFrame == convert(bounds, to: nil),
           let parent = surface.superview, !isHiddenOrHasHiddenAncestor {
            target = surface.hitTest(parent.convert(point, from: nil)) as? AppsMenuButton
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

    @discardableResult
    func addFileIcon(_ url: URL, at frame: CGRect, to view: NSView) -> NSImageView {
        let icon = addIcon(nil, at: frame, to: view)
        store.requestIcon(at: url) { [weak icon] image in icon?.image = image }
        return icon
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
        if window != nil { updateArtwork() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if window != nil { updateArtwork() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if window != nil { updateArtwork() }
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

private class AppsMenuCanvas: NSView {
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

private final class AppsAllDocument: AppsMenuCanvas {
    var catalogAccessibilityChildren: (() -> [Any]?)?

    override func accessibilityChildren() -> [Any]? {
        catalogAccessibilityChildren?() ?? super.accessibilityChildren()
    }
}

private final class AppsAlphabeticalAccessibilityItem: NSAccessibilityElement {
    enum Action {
        case focus
        case press
        case contextMenu
    }

    let target: AppsAlphabeticalLayout.Item.Target
    private let perform: (Action) -> Bool

    init(item: AppsAlphabeticalLayout.Item, parent: AppsAllDocument, perform: @escaping (Action) -> Bool) {
        target = item.role.target
        self.perform = perform
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.role.label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(item.frame)
    }

    override func accessibilityPerformPress() -> Bool {
        perform(.press)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        perform(.contextMenu)
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if !focused || perform(.focus) { super.setAccessibilityFocused(focused) }
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
    private var duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration
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

private final class AppsMenuRunningExit: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    private var onActivate: (AppsMenuButton) -> Void
    private(set) var catalogBindingRevision: UInt64 = 0
    var contextMenu: (() -> NSMenu?)?
    var onPointerChanged: ((NSEvent) -> Void)?
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
    var hoverTransitionDuration: TimeInterval { style == .pinned ? 0.09 : buttonTransition }
    private let buttonTransition: TimeInterval
    private var tracking: NSTrackingArea?
    private var trackingValidSince: TimeInterval = -.infinity
    private var pressed = false
    private var mouseDownPoint: CGPoint?
    private var dragged = false

    private struct PressIdentity: Equatable {
        let owner: ObjectIdentifier
        let presentation: UInt64
        let binding: UInt64
    }

    private var pressIdentity: PressIdentity?

    private func currentPressIdentity() -> PressIdentity? {
        var view = superview
        while let parent = view {
            if let menu = parent as? AppsMenuView {
                return PressIdentity(owner: ObjectIdentifier(menu), presentation: menu.presentationRevision,
                                     binding: catalogBindingRevision)
            }
            view = parent.superview
        }
        return nil
    }

    func advanceBinding() { catalogBindingRevision &+= 1 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(title: String, buttonTransition: TimeInterval, style: Style = .standard, action: @escaping (AppsMenuButton) -> Void) {
        onActivate = action
        self.buttonTransition = buttonTransition
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

    func bindCatalogItem(_ item: AppsAlphabeticalLayout.Item, action: @escaping (AppsMenuButton) -> Void) {
        catalogBindingRevision &+= 1
        invalidateTracking()
        onActivate = action
        title = item.role.label
        setAccessibilityElement(false)
        setAccessibilityLabel(item.role.label)
        identifier = item.identifier
        frame = item.frame
        contextMenu = nil
        pendingContent = nil
        for child in subviews where child !== selection { child.removeFromSuperview() }
    }

    func renderPendingContent() {
        let render = pendingContent
        pendingContent = nil
        render?(self)
    }

    func retireCatalogBinding() {
        catalogBindingRevision &+= 1
        invalidateTracking()
        pendingContent = nil
        contextMenu = nil
        onPointerChanged = nil
    }

    override func layout() {
        super.layout()
        selection.frame = bounds
    }

    override func updateTrackingAreas() {
        invalidateTracking()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func invalidateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        trackingValidSince = ProcessInfo.processInfo.systemUptime
    }

    private func receivePointer(_ event: NSEvent) {
        guard event.timestamp >= trackingValidSince else { return }
        if event.type != .mouseMoved, let area = event.trackingArea, area !== tracking { return }
        onPointerChanged?(event)
    }

    override func mouseEntered(with event: NSEvent) { receivePointer(event) }
    override func mouseExited(with event: NSEvent) { receivePointer(event) }
    override func mouseMoved(with event: NSEvent) { receivePointer(event) }

    func trackNativePress(_ action: () -> Void) {
        pressIdentity = currentPressIdentity()
        defer { pressIdentity = nil }
        action()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard onDrag != nil else {
            trackNativePress { super.mouseDown(with: event) }
            return
        }
        pressIdentity = currentPressIdentity()
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
        defer { pressIdentity = nil }
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
        pressIdentity = nil
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

    @objc private func invoke() {
        if let pressIdentity, pressIdentity != currentPressIdentity() { return }
        onActivate(self)
    }
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
    var onWheel: ((NSEvent) -> Void)?

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

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
        super.scrollWheel(with: event)
    }

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
        case .list: String(localized: "List", table: "Apps")
        case .grid: String(localized: "Grid", table: "Apps")
        case .category: String(localized: "Category", table: "Apps")
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
        case .utilities: String(localized: "Utilities", table: "Apps")
        case .productivity: String(localized: "Productivity", table: "Apps")
        case .creativity: String(localized: "Creativity", table: "Apps")
        case .reference: String(localized: "Reference", table: "Apps")
        case .developerTools: String(localized: "Developer Tools", table: "Apps")
        case .education: String(localized: "Education", table: "Apps")
        case .entertainment: String(localized: "Entertainment", table: "Apps")
        case .games: String(localized: "Games", table: "Apps")
        case .socialNetworking: String(localized: "Social Networking", table: "Apps")
        case .other: String(localized: "Other", table: "Apps")
        }
    }
}
