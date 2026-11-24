import AppKit

struct TaskbarMenuEntry {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void
}

@MainActor
private final class TaskbarPopupPanel: NonConstrainingPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class AppsPopupViewport: NSView {
    private enum Phase { case resting, opening, closing }

    private static let key = "apps-popup-slide"
    private let appsView: AppsMenuView
    private var restingFrame: CGRect
    private var phase: Phase = .resting
    private var bottomInset: CGFloat { phase == .resting ? 0 : AppsMenuGeometry.popupGap }
    private var travel: CGFloat { restingFrame.height + AppsMenuGeometry.popupGap }

    init(menu: AppsMenuView, restingFrame: CGRect) {
        appsView = menu
        self.restingFrame = restingFrame
        super.init(frame: menu.frame)
        clipsToBounds = true
        wantsLayer = true
        menu.wantsLayer = true
        addSubview(menu)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard phase == .resting else { return nil }
        return super.hitTest(point)
    }

    func updateFrame(_ frame: CGRect) {
        guard frame != restingFrame else { return }
        restingFrame = frame
        applyFrame()
    }

    func slideIn() {
        phase = .opening
        applyFrame()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .opening, self.window != nil else { return }
                self.phase = .resting
                self.applyFrame()
            }
        }
        slide(fractions: [1, 0.53, 0.28, 0.12, 0.04, 0.006, 0],
              times: [0, 0.16, 0.34, 0.50, 0.67, 0.84, 1], retainEnd: false)
        CATransaction.commit()
    }

    func slideOut(completion: @escaping @Sendable () -> Void) {
        let offset = appsView.layer?.presentation()?.transform.m42 ?? (phase == .opening ? -travel : 0)
        let initial = min(1, max(0, -offset / max(1, travel)))
        phase = .closing
        appsView.stopMenuActions()
        setAccessibilityHidden(true)
        window?.makeFirstResponder(nil)
        applyFrame()
        let fractions: [CGFloat] = [0, 0.009, 0.042, 0.112, 0.234, 0.414, 0.70, 1]
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        slide(fractions: fractions.map { initial + (1 - initial) * $0 },
              times: [0, 0.13, 0.27, 0.42, 0.57, 0.71, 0.85, 1], retainEnd: true)
        CATransaction.commit()
    }

    private func applyFrame() {
        var viewportFrame = restingFrame
        viewportFrame.origin.y -= bottomInset
        viewportFrame.size.height += bottomInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let window, window.frame != viewportFrame { window.setFrame(viewportFrame, display: false) }
        appsView.frame = CGRect(origin: CGPoint(x: 0, y: bottomInset), size: restingFrame.size)
        CATransaction.commit()
    }

    private func slide(fractions: [CGFloat], times: [NSNumber], retainEnd: Bool) {
        let motion = CAKeyframeAnimation(keyPath: "transform.translation.y")
        motion.values = fractions.map { NSNumber(value: Double(-$0 * travel)) }
        motion.keyTimes = times
        motion.duration = 0.19
        motion.isRemovedOnCompletion = !retainEnd
        if retainEnd { motion.fillMode = .forwards }
        appsView.layer?.add(motion, forKey: Self.key)
    }
}

@MainActor
protocol TaskbarPopupPresenting: AnyObject {
    var panel: NSPanel? { get }
    var isPresented: Bool { get }
    var onPresent: ((NSPanel) -> Void)? { get set }
    var onDismiss: (() -> Void)? { get set }
    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?)
    func updateFrame(_ frame: CGRect)
    func makeKey()
    func dismiss()
    func dismissImmediately()
}

extension TaskbarPopupPresenting {
    func dismissImmediately() { dismiss() }

    func updateFrame(_ frame: CGRect) {
        guard let panel, panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }
}

@MainActor
final class TaskbarPopupController: TaskbarPopupPresenting {
    private(set) var panel: NSPanel?
    var isPresented: Bool { panel != nil }
    private var resignKeyObserver: NSObjectProtocol?
    private let makePanel: (CGRect) -> NSPanel
    private let reduceMotion: () -> Bool
    private var closingPanel: NSPanel?
    var onPresent: ((NSPanel) -> Void)?
    var onDismiss: (() -> Void)?

    init(makePanel: ((CGRect) -> NSPanel)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        self.makePanel = makePanel ?? {
            TaskbarPopupPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
    }

    func present(content: NSView, frame: CGRect, anchorWindow: NSWindow?) {
        dismissImmediately()
        let panel = makePanel(frame)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.appearance = anchorWindow?.effectiveAppearance
        content.frame = CGRect(origin: .zero, size: frame.size)
        let viewport = (content as? AppsMenuView).map { AppsPopupViewport(menu: $0, restingFrame: frame) }
        panel.contentView = (viewport as NSView?) ?? content
        self.panel = panel
        if let viewport, !reduceMotion() {
            panel.animationBehavior = .none
            viewport.slideIn()
        }
        panel.orderFrontRegardless()
        onPresent?(panel)
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, self.panel === panel else { return }
                self.dismiss()
            }
        }
    }

    func makeKey() { panel?.makeKey() }

    func updateFrame(_ frame: CGRect) {
        guard let panel else { return }
        if let viewport = panel.contentView as? AppsPopupViewport {
            viewport.updateFrame(frame)
        } else if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    func dismiss() { dismiss(animated: true) }

    func dismissImmediately() {
        if let closingPanel {
            Self.close(closingPanel)
            self.closingPanel = nil
        }
        dismiss(animated: false)
    }

    private func dismiss(animated: Bool) {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        let panel = self.panel
        self.panel = nil
        if let panel {
            (panel.contentView as? TaskbarWindowListView)?.cancelPendingActions()
            if animated, let viewport = panel.contentView as? AppsPopupViewport, !reduceMotion() {
                closingPanel = panel
                panel.ignoresMouseEvents = true
                viewport.slideOut { [weak self, weak panel] in
                    Task { @MainActor in
                        guard let self, let panel, self.closingPanel === panel else { return }
                        self.closingPanel = nil
                        Self.close(panel)
                    }
                }
            } else {
                Self.close(panel)
            }
        }
        onDismiss?()
    }

    private static func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    isolated deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        panel?.orderOut(nil)
        closingPanel?.orderOut(nil)
    }
}

@MainActor
private final class TaskbarMenuAction: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    @objc func invokeMenuItem(_ sender: NSMenuItem) { action() }
}

@MainActor
enum TaskbarNativeMenuFactory {
    static func menu(entries: [TaskbarMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries { menu.addItem(item(entry)) }
        return menu
    }

    static func statusMenu(launchAtLogin: NSMenuItem, hideStatusBarIcon: NSMenuItem,
                           input: [NSMenuItem] = [], utilities: [NSMenuItem] = [],
                           quit: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(launchAtLogin)
        menu.addItem(hideStatusBarIcon)
        addSection(String(localized: "Input"), items: input, to: menu)
        addSection(String(localized: "Utilities"), items: utilities, to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItem(title: String(localized: "Quit"), action: quit))
        return menu
    }

    private static func addSection(_ title: String, items: [NSMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: title))
        items.forEach(menu.addItem)
    }

    static func actionItem(title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        item(TaskbarMenuEntry(title: title, symbol: "", action: action))
    }

    private static func item(_ entry: TaskbarMenuEntry) -> NSMenuItem {
        let target = TaskbarMenuAction(action: entry.action)
        let item = NSMenuItem(title: entry.title, action: #selector(TaskbarMenuAction.invokeMenuItem(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        if !entry.symbol.isEmpty {
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        }
        return item
    }
}

@MainActor
protocol TaskbarContextMenuPresenting: AnyObject {
    var visibilityChanged: ((Bool) -> Void)? { get set }
    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView)
    func dismiss()
}

@MainActor
final class TaskbarNativeContextMenu: TaskbarContextMenuPresenting {
    var visibilityChanged: ((Bool) -> Void)?
    private var menu: NSMenu?

    func present(entries: [TaskbarMenuEntry], event: NSEvent, view: NSView) {
        dismiss()
        let menu = TaskbarNativeMenuFactory.menu(entries: entries)
        self.menu = menu
        visibilityChanged?(true)
        defer {
            self.menu = nil
            visibilityChanged?(false)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func dismiss() { menu?.cancelTrackingWithoutAnimation() }
}

@MainActor
private final class TaskbarWindowTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class TaskbarWindowListView: NSGlassEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private var windows: [TaskbarWindowPresentation]
    private let delay: TaskbarDelayedAction.Delay
    private let iconProvider: (TaskbarWindowPresentation) -> NSImage?
    private let activateWindow: (TaskbarWindowPresentation) -> Void
    private let closeWindow: (TaskbarWindowPresentation) -> Void
    private let fileHoverWindow: (TaskbarWindowPresentation) -> Void
    private let cellIdentifier = NSUserInterfaceItemIdentifier("window-cell")
    let tableView: NSTableView = TaskbarWindowTable()
    let scrollView = NSScrollView()
    var canPerformActions: () -> Bool = { true }
    var onHover: ((Bool) -> Void)?
    var isPointerInside: Bool { isMouseInside || fileDragRow != nil }
    private var isMouseInside = false
    private weak var fileDragRow: TaskbarWindowListRow?
    private var tracking: NSTrackingArea?

    init(windows: [TaskbarWindowPresentation], availableHeight: CGFloat,
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) },
         icon: @escaping (TaskbarWindowPresentation) -> NSImage?,
         activate: @escaping (TaskbarWindowPresentation) -> Void,
         close: @escaping (TaskbarWindowPresentation) -> Void,
         fileHover: @escaping (TaskbarWindowPresentation) -> Void) {
        self.windows = windows
        self.delay = delay
        iconProvider = icon
        activateWindow = activate
        closeWindow = close
        fileHoverWindow = fileHover
        let cellHeight = TaskbarMetrics.windowListRowHeight
        let size = CGSize(width: TaskbarMetrics.windowListWidth,
                          height: min(max(cellHeight, availableHeight), cellHeight * CGFloat(windows.count)))
        super.init(frame: CGRect(origin: .zero, size: size))
        style = .regular
        cornerRadius = 4
        tintColor = nil
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        tableView.frame = CGRect(x: 0, y: 0, width: size.width, height: cellHeight * CGFloat(windows.count))
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = .zero
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = cellHeight
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.width = size.width
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateClickedWindow)
        scrollView.documentView = tableView
        contentView = scrollView
        tableView.reloadData()
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard windows.indices.contains(row) else { return nil }
        let item = windows[row]
        let image = iconProvider(item)
        let close: () -> Void = { [weak self] in
            guard let self, self.canPerformActions() else { return }
            self.closeWindow(item)
        }
        let fileHover: () -> Void = { [weak self] in
            guard let self, self.canPerformActions() else { return }
            self.fileHoverWindow(item)
        }
        let cell: TaskbarWindowListRow
        if let reusable = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? TaskbarWindowListRow {
            cell = reusable
            cell.configure(window: item, icon: image, close: close, fileHover: fileHover)
        } else {
            cell = TaskbarWindowListRow(window: item, icon: image, delay: delay,
                                       close: close, fileHover: fileHover)
            cell.identifier = cellIdentifier
        }
        cell.onDragPresence = { [weak self] row, inside in self?.setDragPresence(for: row, inside: inside) }
        cell.onHighlightChanged = { [weak self] selected in
            self?.tableView.rowView(atRow: row, makeIfNecessary: false)?.isSelected = selected
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView.view(atColumn: 0) as? TaskbarWindowListRow)?.cancelFileHover()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = .clear
        view.isEmphasized = false
        return view
    }

    @objc private func activateClickedWindow() {
        let index = tableView.clickedRow
        if canPerformActions(), windows.indices.contains(index) { activateWindow(windows[index]) }
    }

    func cancelPendingActions() {
        fileDragRow = nil
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? TaskbarWindowListRow)?.cancelFileHover()
        }
    }

    func updateTitles(windows: [TaskbarWindowPresentation]) {
        let titles = Dictionary(windows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        self.windows = self.windows.map { item in
            TaskbarWindowPresentation(item: item.item, title: titles[item.id] ?? item.title, isActive: item.isActive)
        }
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? TaskbarWindowListRow,
                  let title = titles[cell.item.id] else { return }
            cell.title = title
        }
    }

    func refreshIcons() {
        tableView.enumerateAvailableRowViews { rowView, index in
            guard self.windows.indices.contains(index),
                  let cell = rowView.view(atColumn: 0) as? TaskbarWindowListRow else { return }
            cell.updateIcon(self.iconProvider(self.windows[index]))
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func updatePointerPresence(_ update: () -> Void) {
        guard canPerformActions() else { return }
        let wasInside = isPointerInside
        update()
        if isPointerInside != wasInside { onHover?(isPointerInside) }
    }

    private func setDragPresence(for row: TaskbarWindowListRow, inside: Bool) {
        updatePointerPresence {
            if inside {
                let previous = fileDragRow
                fileDragRow = row
                if previous !== row { previous?.cancelFileHover() }
            } else if fileDragRow === row {
                fileDragRow = nil
            }
        }
    }

    private func setMousePresence(inside: Bool) {
        if let containsCurrentMouse, containsCurrentMouse != inside { return }
        updatePointerPresence { isMouseInside = inside }
    }

    override func mouseEntered(with event: NSEvent) { setMousePresence(inside: true) }
    override func mouseExited(with event: NSEvent) { setMousePresence(inside: false) }
}

@MainActor
final class TaskbarWindowListRow: NSTableCellView {
    private enum FileDragLocation {
        case screen(CGPoint)
        case detached(CGPoint)

        @MainActor
        func point(in window: NSWindow?) -> CGPoint? {
            switch self {
            case let .screen(point): return window?.convertPoint(fromScreen: point)
            case let .detached(point): return window == nil ? point : nil
            }
        }
    }

    private(set) var item: TaskbarWindowPresentation
    var title: String {
        didSet {
            textField?.stringValue = WindowDisplayTitle.singleLine(title)
            setAccessibilityLabel(title)
        }
    }
    private(set) var icon: NSImage?
    private(set) var close: () -> Void
    private(set) var fileHover: () -> Void
    let closeButton = NSButton()
    var onDragPresence: ((TaskbarWindowListRow, Bool) -> Void)?
    var onHighlightChanged: ((Bool) -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let delayedActivation: TaskbarDelayedAction
    private var fileDrag: (sequence: Int, location: FileDragLocation)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(window: TaskbarWindowPresentation, icon: NSImage?,
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) },
         close: @escaping () -> Void, fileHover: @escaping () -> Void) {
        delayedActivation = TaskbarDelayedAction(delay: delay)
        self.item = window
        self.title = window.title
        self.icon = icon
        self.close = close
        self.fileHover = fileHover
        super.init(frame: CGRect(x: 0, y: 0, width: TaskbarMetrics.windowListWidth, height: TaskbarMetrics.windowListRowHeight))
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        imageView = iconView
        addSubview(iconView)
        let label = NSTextField(labelWithString: WindowDisplayTitle.singleLine(window.title))
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        textField = label
        addSubview(label)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.controlSize = .small
        closeButton.showsBorderOnlyWhileMouseInside = true
        closeButton.tintProminence = .none
        closeButton.isHidden = true
        closeButton.refusesFirstResponder = true
        closeButton.setAccessibilityElement(false)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(window.title)
        registerForDraggedTypes([.fileURL])
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { delayedActivation.cancel() }

    func updateIcon(_ image: NSImage?) {
        icon = image
        imageView?.image = image
    }

    func configure(window: TaskbarWindowPresentation, icon: NSImage?,
                   close: @escaping () -> Void, fileHover: @escaping () -> Void) {
        cancelFileHover()
        onHighlightChanged = nil
        hovered = false
        updateHighlight()
        item = window
        title = window.title
        self.icon = icon
        imageView?.image = icon
        self.close = close
        self.fileHover = fileHover
    }


    override func layout() {
        super.layout()
        imageView?.frame = CGRect(x: 8, y: 12, width: 16, height: 16)
        if let textField {
            textField.frame = textField.frame(forAlignmentRect: CGRect(x: 32, y: 12, width: max(0, bounds.width - 68), height: 20))
        }
        closeButton.frame = CGRect(x: bounds.width - 36, y: 4, width: 32, height: 32)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateHighlight() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHighlight() }
    private func updateHighlight() {
        closeButton.isHidden = !hovered
        onHighlightChanged?(hovered)
    }

    @objc private func closeWindow() { close() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
            endFileDrag(sender)
            return []
        }
        let sequence = sender.draggingSequenceNumber
        let isNewDrag = fileDrag?.sequence != sequence
        if isNewDrag { delayedActivation.cancel() }
        let location = sender.draggingLocation
        let destination = sender.draggingDestinationWindow ?? window
        fileDrag = (sequence, destination.map { .screen($0.convertPoint(toScreen: location)) } ?? .detached(location))
        if isNewDrag { onDragPresence?(self, true) }
        scheduleFileHover()
        return .generic
    }

    func scheduleFileHover() {
        let target = item.id
        delayedActivation.schedule(target: target, after: .milliseconds(600)) { [weak self] in
            guard let self else { return }
            if let drag = self.fileDrag {
                self.enclosingScrollView?.layoutSubtreeIfNeeded()
                guard !Task.isCancelled else { return }
                guard let location = drag.location.point(in: self.window),
                      self.visibleRect.contains(self.convert(location, from: nil)) else {
                    self.cancelFileHover()
                    return
                }
            }
            self.fileHover()
        }
    }

    func cancelFileHover() {
        delayedActivation.cancel()
        guard fileDrag != nil else { return }
        fileDrag = nil
        onDragPresence?(self, false)
    }

    private func endFileDrag(_ sender: (any NSDraggingInfo)?) {
        if let sender, let fileDrag, sender.draggingSequenceNumber != fileDrag.sequence { return }
        cancelFileHover()
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { endFileDrag(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { endFileDrag(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        endFileDrag(sender)
        return false
    }
}
