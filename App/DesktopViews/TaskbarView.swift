import AppKit
import QuartzCore

@MainActor
struct TaskbarViewActions {
    var toggle: (WindowActionIdentity) -> Void = { _ in }
    var activate: (WindowActionIdentity) -> Void = { _ in }
    var close: (WindowActionIdentity) -> Void = { _ in }
    var quit: (TaskbarGroupPresentation) -> Void = { _ in }
    var reorder: (String, String, Bool) -> Void = { _, _, _ in }
    var backgroundMenu: (NSEvent, NSView) -> Void = { _, _ in }
    var contextMenuVisibilityChanged: (Bool) -> Void = { _ in }
}

@MainActor
final class TaskbarView: NSGlassEffectView {
    let taskbarContent: TaskbarContentView

    override convenience init(frame: CGRect) {
        self.init(frame: frame, popup: TaskbarPopupController(), contextMenu: TaskbarNativeContextMenu())
    }

    init(frame: CGRect, popup: any TaskbarPopupPresenting, contextMenu: any TaskbarContextMenuPresenting,
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) }) {
        taskbarContent = TaskbarContentView(frame: CGRect(origin: .zero, size: frame.size), popup: popup, contextMenu: contextMenu, delay: delay)
        super.init(frame: frame)
        style = .regular
        cornerRadius = 0
        tintColor = nil
        contentView = taskbarContent
        taskbarContent.autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class TaskbarAppsButton: NSButton {
    private let selection = NSBox()
    private let icon = TaskbarAppsIconView(frame: .zero)
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let visualBounds = AppsMenuGeometry.buttonFrame.offsetBy(dx: -frameRect.minX, dy: -frameRect.minY)
        clipsToBounds = true
        setButtonType(.toggle)
        isBordered = false
        isTransparent = true
        selection.boxType = .custom
        selection.titlePosition = .noTitle
        selection.borderWidth = 1
        selection.cornerRadius = TaskbarMetrics.buttonCornerRadius
        selection.contentViewMargins = .zero
        selection.fillColor = .unemphasizedSelectedContentBackgroundColor
        selection.frame = visualBounds
        selection.autoresizingMask = [.width]
        selection.setAccessibilityElement(false)
        addSubview(selection)
        icon.frame = visualBounds
        icon.autoresizingMask = [.width]
        icon.setAccessibilityElement(false)
        addSubview(icon)
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet {
            hovered = containsCurrentMouse ?? hovered
            updateSelection(animated: true)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hovered = containsCurrentMouse ?? false
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
        updateSelection()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(whenDetached: true)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(whenDetached: false)
    }

    private func updateHover(whenDetached: Bool) {
        let isInside = containsCurrentMouse ?? whenDetached
        guard hovered != isInside else { return }
        hovered = isInside
        updateSelection(animated: true)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        updateSelection(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
    }

    private func updateSelection(animated: Bool = false) {
        let appearance = TaskbarButtonSelection(active: state == .on, hovered: hovered, pressed: pressed)
        appearance.applyColors(to: selection, appearance: effectiveAppearance)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? TaskbarMotion.buttonTransition : 0
            selection.animator().alphaValue = appearance.opacity
            icon.showColor(hovered || state == .on)
        }
    }
}

@MainActor
private final class TaskbarAppsIconView: NSView {
    private static let icons: (color: NSImage, monochrome: NSImage) = {
        let bundle = "/System/Applications/Apps.app"
        let color = NSImage(contentsOfFile: bundle + "/Contents/Resources/AppIcon.icns")
            ?? NSWorkspace.shared.icon(forFile: bundle)
        let pixels = 128
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let original = color.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let gray = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                   bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let buffer = gray.data?.assumingMemoryBound(to: UInt8.self) else { return (color, color) }
        gray.interpolationQuality = .high
        gray.draw(original, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        for offset in stride(from: 0, to: gray.bytesPerRow * gray.height, by: 4) {
            let luminance = UInt8((54 * Int(buffer[offset]) + 183 * Int(buffer[offset + 1]) + 19 * Int(buffer[offset + 2]) + 128) / 256)
            buffer[offset] = luminance
            buffer[offset + 1] = luminance
            buffer[offset + 2] = luminance
        }
        guard let monochrome = gray.makeImage() else { return (color, color) }
        return (color, NSImage(cgImage: monochrome, size: color.size))
    }()

    private let monochrome = NSImageView()
    private let color = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        monochrome.image = Self.icons.monochrome
        color.image = Self.icons.color
        for view in [monochrome, color] {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        color.alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let side: CGFloat = 20
        let imageFrame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        monochrome.frame = imageFrame
        color.frame = imageFrame
    }

    func showColor(_ shown: Bool) {
        color.animator().alphaValue = shown ? 1 : 0
    }
}

@MainActor
final class TaskbarContentView: NSView {
    private enum PointerAnchor: Equatable {
        case mouse(String)
        case fileDrag(String)

        var buttonID: String {
            switch self {
            case let .mouse(id), let .fileDrag(id): id
            }
        }
    }

    var actions = TaskbarViewActions()
    var iconProvider: (TaskbarWindowPresentation) -> NSImage? = { _ in nil }
    var canUseWindowActions: () -> Bool = { true }
    var admitWindowList: (_ openedByClick: Bool) -> Bool = { _ in true }
    var onBackgroundClick: () -> Void = {}
    private(set) var groups: [TaskbarGroupPresentation] = []
    private(set) var layoutResult = TaskbarLayoutResult(buttons: [], overflowGroups: [], overflowFrame: nil, combinedGroups: [])
    private(set) var buttonViews: [String: TaskbarButtonView] = [:]
    private(set) var overflowButton: TaskbarButtonView?
    private let popup: any TaskbarPopupPresenting
    private let contextMenu: any TaskbarContextMenuPresenting
    private var listGroupID: String?
    private var listSignature: [StripItem] = []
    private weak var windowList: TaskbarWindowListView?
    private var listOpenedByClick = false
    var hasClickedWindowList: Bool { listOpenedByClick && popup.isPresented }
    var hasExplicitPopup: Bool { popup.isPresented && (listOpenedByClick || appsMenu != nil) }
    private var appsStore: AppsMenuStore?
    private var appsButton: NSButton?
    private weak var appsMenu: AppsMenuView?
    private var preparedAppsMenu: AppsMenuView?
    private var appsPreparation: Task<Void, Never>?
    private var pointerAnchor: PointerAnchor?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private let delay: TaskbarDelayedAction.Delay
    private let fileHover: TaskbarDelayedAction
    private var fileDragLocation: CGPoint?
    private var draggedGroupID: String?
    private var dragMembers: [String] = []
    private var dragButtonIDs = Set<String>()
    private var dragGeometry: TaskbarDragGeometry?
    private var dragPointer = CGPoint.zero
    private var animateNextLayout = false
    private var groupDrag = TaskbarGroupDrag()
    #if DEBUG
    private var groupDragResources: ActionResourceLog.Span?
    #endif
    private var suppressClick = false
    private var measuredLayoutGroups: [String: TaskbarLayoutGroup]?
    private var lastLayoutBounds: CGRect?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TaskbarMetrics.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, popup: any TaskbarPopupPresenting = TaskbarPopupController(),
         contextMenu: any TaskbarContextMenuPresenting = TaskbarNativeContextMenu(),
         delay: @escaping TaskbarDelayedAction.Delay = { try? await Task.sleep(for: $0) }) {
        self.popup = popup
        self.contextMenu = contextMenu
        self.delay = delay
        fileHover = TaskbarDelayedAction(delay: delay)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("DeskMote")
        contextMenu.visibilityChanged = { [weak self] visible in self?.actions.contextMenuVisibilityChanged(visible) }
        popup.onDismiss = { [weak self] in
            self?.cancelDismiss()
            self?.listGroupID = nil
            self?.listSignature = []
            self?.windowList = nil
            self?.listOpenedByClick = false
            self?.appsMenu = nil
            self?.appsButton?.state = .off
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        #if DEBUG
        groupDragResources?.finish()
        #endif
        hoverTask?.cancel()
        dismissTask?.cancel()
        fileHover.cancel()
        appsPreparation?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            prepareAppsMenu()
        } else {
            appsPreparation?.cancel()
            appsPreparation = nil
            preparedAppsMenu = nil
        }
    }

    func enableAppsMenu(store: AppsMenuStore = .shared) {
        guard appsButton == nil else { return }
        appsStore = store
        store.preloadCatalog()
        let title = String(localized: "Apps")
        let button = TaskbarAppsButton(frame: interactionFrame(for: AppsMenuGeometry.buttonHitFrame))
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("DeskMote.Apps")
        button.target = self
        button.action = #selector(toggleAppsMenu)
        addSubview(button)
        appsButton = button
        needsLayout = true
        prepareAppsMenu()
    }

    private func prepareAppsMenu() {
        guard window != nil, let store = appsStore, preparedAppsMenu == nil, appsPreparation == nil else { return }
        appsPreparation = Task { [weak self] in
            _ = await store.loadCatalog()
            guard !Task.isCancelled, let self else { return }
            self.appsPreparation = nil
            guard self.preparedAppsMenu == nil,
                  let window = self.window, let screen = window.screen ?? NSScreen.main else { return }
            let frame = self.appsFrame(window: window, screen: screen)
            guard !frame.isEmpty else { return }
            self.preparedAppsMenu = self.makeAppsMenu(frame: frame, store: store, deferCatalog: false)
        }
    }

    private func makeAppsMenu(frame: CGRect, store: AppsMenuStore, deferCatalog: Bool) -> AppsMenuView {
        AppsMenuView(frame: CGRect(origin: .zero, size: frame.size), store: store,
                     runningWindows: { [weak self] pid in
                         self?.groups.flatMap(\.windows).filter { $0.item.resourcePID == pid } ?? []
                     },
                     activateWindow: { [weak self] target in self?.actions.activate(target) },
                     deferCatalog: deferCatalog,
                     dismiss: { [weak self] in self?.dismissPopups() })
    }

    @objc private func toggleAppsMenu() {
        guard let appsButton, let appsStore else { return }
        if appsMenu != nil {
            dismissPopups()
            return
        }
        appsButton.state = .off
        guard let window, let screen = window.screen ?? NSScreen.main, admitWindowList(true) else { return }
        let frame = appsFrame(window: window, screen: screen)
        guard !frame.isEmpty else { return }
        #if DEBUG
        let span = ActionResourceLog.begin("apps.menu.open")
        defer { span?.finish() }
        #endif
        dismissPopups(animate: false)
        cancelFileHover()
        appsPreparation?.cancel()
        appsPreparation = nil
        let menu = preparedAppsMenu ?? makeAppsMenu(frame: frame, store: appsStore, deferCatalog: true)
        preparedAppsMenu = menu
        menu.prepareForPresentation(size: frame.size)
        popup.present(content: menu, frame: frame, anchorWindow: window)
        appsMenu = menu
        appsButton.state = .on
        popup.makeKey()
        menu.focusSearch()
    }

    private func appsFrame(window: NSWindow, screen: NSScreen) -> CGRect {
        AppsMenuGeometry.popupFrame(taskbar: window.frame, screen: screen.frame,
                                    visibleTop: screen.visibleFrame.maxY)
    }

    func update(groups: [TaskbarGroupPresentation], refreshIcons: Bool = false) {
        let groupsChanged = self.groups != groups
        guard groupsChanged || lastLayoutBounds != bounds else {
            if refreshIcons { refreshImages() }
            return
        }
        self.groups = groups
        if groupsChanged { measuredLayoutGroups = nil }
        groupDrag.reconcile(liveGroups: groups.map(\.id))
        if let draggedGroupID, groups.first(where: { $0.id == draggedGroupID })?.windows.map(\.id) != dragMembers {
            endGroupDrag(event: nil, cancelled: true)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if refreshIcons { windowList?.refreshIcons() }
    }

    private func refreshImages() {
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.render.icons")
        defer { span?.finish() }
        #endif
        let lookup = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for button in layoutResult.buttons {
            guard let group = lookup[button.groupID],
                  let item = group.windows.first(where: { button.windowIDs.contains($0.id) }) else { continue }
            buttonViews[button.id]?.image = iconProvider(item)
        }
        windowList?.refreshIcons()
    }

    override func layout() {
        #if DEBUG
        let span = draggedGroupID == nil ? ActionResourceLog.begin("taskbar.render") : nil
        defer { span?.finish() }
        #endif
        super.layout()
        lastLayoutBounds = bounds
        appsButton?.frame = interactionFrame(for: AppsMenuGeometry.buttonHitFrame)
        let groupLookup = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if measuredLayoutGroups == nil {
            let font = NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
            measuredLayoutGroups = Dictionary(groups.map { group in
                (group.id, TaskbarLayoutGroup(id: group.id,
                    desiredWidth: TaskbarMetrics.buttonWidth(textWidth: (WindowDisplayTitle.singleLine(group.name) as NSString).size(withAttributes: [.font: font]).width),
                    windows: group.windows.map {
                        TaskbarLayoutWindow(id: $0.id, desiredWidth: TaskbarMetrics.buttonWidth(textWidth: (WindowDisplayTitle.singleLine($0.title) as NSString).size(withAttributes: [.font: font]).width))
                    }))
            }, uniquingKeysWith: { first, _ in first })
        }
        let inputs = groups.compactMap { measuredLayoutGroups?[$0.id] }
        let previewOrder = groupDrag.target.map { _ in groupDrag.order(groups.map(\.id)) }
        let leadingInset = appsButton == nil ? TaskbarMetrics.leadingInset : AppsMenuGeometry.windowLeadingInset
        var result = TaskbarLayout.resolve(groups: inputs, width: bounds.width, previewOrder: previewOrder,
                                           leadingInset: leadingInset)
        if let draggedGroupID,
           Set(result.buttons.filter { $0.groupID == draggedGroupID }.map(\.id)) != dragButtonIDs {
            endGroupDrag(event: nil, cancelled: true)
            result = TaskbarLayout.resolve(groups: inputs, width: bounds.width, leadingInset: leadingInset)
        }
        let changed = result != layoutResult
        layoutResult = result
        let animateLayout = animateNextLayout || (changed && draggedGroupID != nil)
        animateNextLayout = false
        let dragFrames = dragFrames(in: result)
        let liveIDs = Set(result.buttons.map(\.id))
        for id in Array(buttonViews.keys) where !liveIDs.contains(id) { buttonViews.removeValue(forKey: id)?.removeFromSuperview() }
        for layout in result.buttons {
            guard let group = groupLookup[layout.groupID],
                  let item = group.windows.first(where: { layout.windowIDs.contains($0.id) }) else { continue }
            let frame = interactionFrame(for: layout.frame)
            let view: TaskbarButtonView
            if let existing = buttonViews[layout.id] { view = existing }
            else {
                view = TaskbarButtonView(frame: frame)
                view.canInteract = { [weak self] in self?.canUseWindowActions() ?? false }
                buttonViews[layout.id] = view
                addSubview(view)
            }
            let targets: TaskbarButtonView.ActionTargets = layout.isCombined
                ? .list(Set(group.windows.map(\.item.actionIdentity)))
                : .window(item.item.actionIdentity)
            updateActionTargets(targets, for: view, buttonID: layout.id)
            view.title = layout.isCombined ? group.name : item.title
            view.image = iconProvider(item)
            view.isCombined = layout.isCombined
            view.isActiveWindow = layout.isCombined ? group.isActive : item.isActive
            view.onClick = { [weak self] in self?.click(layout.id) }
            view.onContextMenu = { [weak self] event in self?.showContextMenu(buttonID: layout.id, event: event) }
            view.onHover = { [weak self] entered in self?.hover(buttonID: layout.id, entered: entered) }
            view.onBeginDrag = { [weak self] event, start in self?.beginGroupDrag(layout.groupID, event: event, start: start) }
            view.onDragMoved = { [weak self] event in self?.moveGroupDrag(event: event) }
            view.onEndDrag = { [weak self] event, cancelled in self?.endGroupDrag(event: event, cancelled: cancelled) }
            view.alphaValue = 1
            view.layer?.zPosition = draggedGroupID == layout.groupID ? 1 : 0
            if draggedGroupID == layout.groupID, let dragFrames {
                view.layer?.removeAllAnimations()
                view.frame = frame.offsetBy(dx: dragFrames.displayed.minX - dragFrames.slot.minX, dy: 0)
            } else if animateLayout && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = TaskbarMotion.reorderTransition
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().setFrameSize(frame.size)
                    view.animator().setFrameOrigin(frame.origin)
                }
            } else { view.frame = frame }
        }
        if let overflowFrame = result.overflowFrame {
            let frame = interactionFrame(for: overflowFrame)
            let view = overflowButton ?? TaskbarButtonView(frame: frame)
            if overflowButton == nil {
                view.canInteract = { [weak self] in self?.canUseWindowActions() ?? false }
                addSubview(view)
                overflowButton = view
            }
            let overflowIDs = Set(result.overflowGroups)
            let targets = groups.filter { overflowIDs.contains($0.id) }.flatMap(\.windows).map(\.item.actionIdentity)
            updateActionTargets(.list(Set(targets)), for: view, buttonID: "overflow")
            view.frame = frame
            view.isOverflow = true
            view.title = String(localized: "More windows")
            view.onClick = { [weak self] in self?.showOverflow(openedByClick: true) }
            view.onContextMenu = { [weak self] event in self?.rightMouseDown(with: event) }
            view.onHover = { [weak self] entered in self?.hover(buttonID: "overflow", entered: entered) }
        } else { overflowButton?.removeFromSuperview(); overflowButton = nil }
        updateOpenList(using: groupLookup)
        if appsMenu != nil, let window, let screen = window.screen ?? NSScreen.main {
            popup.updateFrame(appsFrame(window: window, screen: screen))
        }
    }

    private func updateOpenList(using groupLookup: [String: TaskbarGroupPresentation]) {
        guard let listGroupID, let windowList else { return }
        let anchor: CGRect?
        let liveWindows: [TaskbarWindowPresentation]?
        if listGroupID == "overflow" {
            anchor = layoutResult.overflowFrame
            liveWindows = groups.filter { layoutResult.overflowGroups.contains($0.id) }.flatMap(\.windows)
        } else {
            anchor = layoutResult.buttons.first { $0.groupID == listGroupID && $0.isCombined }?.frame
            liveWindows = groupLookup[listGroupID]?.windows
        }
        guard let anchor, let liveWindows, listMatches(liveWindows) else {
            popup.dismiss()
            return
        }
        windowList.updateTitles(windows: liveWindows)
        if let screen = window?.screen ?? NSScreen.main {
            popup.updateFrame(listFrame(anchor: anchor, contentSize: windowList.frame.size, screen: screen))
        }
    }

    private func updateActionTargets(_ targets: TaskbarButtonView.ActionTargets, for view: TaskbarButtonView,
                                     buttonID: String) {
        if view.updateActionTargets(targets), fileHover.target == buttonID { cancelFileHover() }
    }

    private func interactionFrame(for visualFrame: CGRect) -> CGRect {
        CGRect(x: visualFrame.minX, y: visualFrame.minY, width: visualFrame.width,
               height: max(0, bounds.maxY - visualFrame.minY))
    }

    private func click(_ id: String) {
        guard !suppressClick,
              let button = layoutResult.buttons.first(where: { $0.id == id }),
              let group = groups.first(where: { $0.id == button.groupID }) else { return }
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.button.click")
        defer { span?.finish() }
        #endif
        if button.isCombined { showWindowList(group: group, anchor: button.frame, openedByClick: true) }
        else if let item = group.windows.first(where: { button.windowIDs.contains($0.id) }) {
            dismissPopups()
            actions.toggle(item.item.actionIdentity)
        }
    }

    private func hover(buttonID: String, entered: Bool) {
        guard canUseWindowActions(), draggedGroupID == nil, !hasExplicitPopup else { return }
        let anchor = PointerAnchor.mouse(buttonID)
        if entered { pointerAnchor = anchor }
        else {
            guard pointerAnchor == anchor else { return }
            pointerAnchor = nil
        }
        hoverTask?.cancel()
        updateListDismissal()
        guard entered, let button = buttonViews[buttonID], button.isCombined else { return }
        let delay = delay
        hoverTask = Task { @MainActor [weak self, weak button] in
            await delay(.milliseconds(400))
            guard !Task.isCancelled, let self, self.pointerAnchor == anchor,
                  let button, self.buttonViews[buttonID] === button, button.containsCurrentMouse != false,
                  let layout = self.layoutResult.buttons.first(where: { $0.id == buttonID }), layout.isCombined,
                  let group = self.groups.first(where: { $0.id == layout.groupID }) else { return }
            self.showWindowList(group: group, anchor: layout.frame)
        }
    }

    private func keepsListOpen(_ list: TaskbarWindowListView) -> Bool {
        if listOpenedByClick || list.isPointerInside { return true }
        guard let listGroupID else { return false }
        let anchorID = listGroupID == "overflow" ? "overflow" : "group:" + listGroupID
        return pointerAnchor?.buttonID == anchorID
    }

    private func updateListDismissal() {
        guard let list = windowList else { return }
        if keepsListOpen(list) {
            cancelDismiss()
            return
        }
        guard dismissTask == nil else { return }
        let delay = delay
        dismissTask = Task { @MainActor [weak self, weak list] in
            await delay(.milliseconds(250))
            guard !Task.isCancelled, let self, let list, self.windowList === list else { return }
            self.dismissTask = nil
            if !self.keepsListOpen(list) { self.popup.dismiss() }
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func dismissPopups(animate: Bool = true) {
        pointerAnchor = nil
        hoverTask?.cancel()
        cancelDismiss()
        if animate { popup.dismiss() } else { popup.dismissImmediately() }
        contextMenu.dismiss()
    }

    func dismissAppsMenu() {
        if appsMenu != nil { dismissPopups() }
    }

    func prepareForHiding() {
        dismissPopups(animate: false)
        cancelFileHover()
        buttonViews.values.forEach { $0.cancelPendingPress() }
        overflowButton?.cancelPendingPress()
        endGroupDrag(event: nil, cancelled: true)
    }

    private func listFrame(anchor: CGRect, contentSize: CGSize, screen: NSScreen) -> CGRect {
        let screenAnchor = window.map { $0.convertToScreen(convert(anchor, to: nil)) } ?? anchor
        return TaskbarPopupGeometry.frame(anchor: screenAnchor, contentSize: contentSize, screen: screen.frame)
    }

    private func listMatches(_ windows: [TaskbarWindowPresentation]) -> Bool {
        listSignature.elementsEqual(windows.map(\.item)) { $0.representsSameWindow(as: $1) }
    }

    private func showWindowList(group: TaskbarGroupPresentation, anchor: CGRect, openedByClick: Bool = false) {
        guard canUseWindowActions(), openedByClick || !hasExplicitPopup,
              let screen = window?.screen ?? NSScreen.main,
              admitWindowList(openedByClick) else { return }
        cancelDismiss()
        if openedByClick {
            hoverTask?.cancel()
            cancelFileHover()
        }
        if listGroupID == group.id && listMatches(group.windows) && popup.isPresented {
            if openedByClick {
                listOpenedByClick = true
                popup.makeKey()
            }
            return
        }
        #if DEBUG
        let span = ActionResourceLog.begin(group.id == "overflow" ? "taskbar.menu.overflow" : "taskbar.menu.windows")
        defer { span?.finish() }
        #endif
        let view = TaskbarWindowListView(windows: group.windows,
                                      availableHeight: screen.visibleFrame.height - TaskbarMetrics.height - 24,
                                      delay: delay,
                                      icon: iconProvider,
                                      activate: { [weak self] item in self?.activateIfLive(item, dismiss: true) },
                                      close: { [weak self] item in self?.closeIfLive(item) },
                                      fileHover: { [weak self] item in self?.activateIfLive(item, dismiss: false) })
        view.canPerformActions = { [weak self, weak view] in
            guard let self, let view else { return false }
            return self.windowList === view && self.popup.isPresented
        }
        let frame = listFrame(anchor: anchor, contentSize: view.frame.size, screen: screen)
        popup.present(content: view, frame: frame, anchorWindow: window)
        listOpenedByClick = openedByClick
        if openedByClick { popup.makeKey() }
        windowList = view
        listGroupID = group.id
        listSignature = group.windows.map(\.item)
        view.onHover = { [weak self, weak view] _ in
            guard let self, let view, self.windowList === view else { return }
            self.updateListDismissal()
        }
    }

    private func showOverflow(openedByClick: Bool = false) {
        guard let anchor = layoutResult.overflowFrame else { return }
        let ids = Set(layoutResult.overflowGroups)
        let windows = groups.filter { ids.contains($0.id) }.flatMap(\.windows)
        showWindowList(group: TaskbarGroupPresentation(id: "overflow", name: String(localized: "More windows"), windows: windows),
                    anchor: anchor, openedByClick: openedByClick)
    }

    private func showContextMenu(buttonID: String, event: NSEvent) {
        guard canUseWindowActions(), buttonViews[buttonID] != nil,
              let button = layoutResult.buttons.first(where: { $0.id == buttonID }),
              let group = groups.first(where: { $0.id == button.groupID }) else { return }
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.menu.context")
        defer { span?.finish() }
        #endif
        dismissPopups()
        let entries = TaskbarContextMenuModel.actions(button: button, group: group).map { action in
            switch action {
            case let .closeWindow(id):
                return TaskbarMenuEntry(title: String(localized: "Close window"), symbol: "xmark", action: { [weak self] in self?.closeIfLive(id, expectedWindows: group.windows) })
            case let .closeWindows(ids):
                return TaskbarMenuEntry(title: String(localized: "Close all windows"), symbol: "xmark", action: { [weak self] in
                    for id in ids { self?.closeIfLive(id, expectedWindows: group.windows) }
                })
            case .quitApplication:
                let representedWindows = group.windows.filter { button.windowIDs.contains($0.id) }
                return TaskbarMenuEntry(title: String(localized: "Quit"), symbol: "power", action: { [weak self] in
                    guard let self, self.canUseWindowActions(),
                          let current = self.groups.first(where: { $0.id == group.id }) else { return }
                    let survivors = current.windows.filter { live in
                        representedWindows.contains { $0.item.representsSameProcess(as: live.item) }
                    }
                    guard !survivors.isEmpty else { return }
                    #if DEBUG
                    let span = ActionResourceLog.begin("taskbar.application.quit")
                    defer { span?.finish() }
                    #endif
                    self.actions.quit(TaskbarGroupPresentation(id: current.id, name: current.name, windows: survivors))
                })
            }
        }
        contextMenu.present(entries: entries, event: event, view: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        #if DEBUG
        let span = ActionResourceLog.begin("taskbar.menu.background")
        defer { span?.finish() }
        #endif
        onBackgroundClick()
        dismissPopups()
        actions.backgroundMenu(event, self)
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick()
        dismissPopups()
    }

    private func dragFrames(in result: TaskbarLayoutResult) -> (slot: CGRect, displayed: CGRect)? {
        guard let id = draggedGroupID, let dragGeometry else { return nil }
        let slot = result.buttons.filter { $0.groupID == id }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !slot.isNull else { return nil }
        let occupied = result.buttons.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return (slot, dragGeometry.frame(pointer: dragPointer, groupWidth: slot.width, occupiedBounds: occupied))
    }

    private func beginGroupDrag(_ id: String, event: NSEvent, start: CGPoint) {
        guard let group = groups.first(where: { $0.id == id }), !group.windows.isEmpty else { return }
        dismissPopups()
        cancelFileHover()
        let rectangles = layoutResult.buttons.filter { $0.groupID == id }.map(\.frame)
        guard let first = rectangles.first else { return }
        #if DEBUG
        groupDragResources?.finish()
        groupDragResources = ActionResourceLog.begin("taskbar.group.drag")
        #endif
        let frame = rectangles.dropFirst().reduce(first) { $0.union($1) }
        draggedGroupID = id
        dragMembers = group.windows.map(\.id)
        dragButtonIDs = Set(layoutResult.buttons.filter { $0.groupID == id }.map(\.id))
        dragPointer = convert(event.locationInWindow, from: nil)
        dragGeometry = .make(pointer: convert(start, from: nil), groupFrame: frame)
        suppressClick = true
        needsLayout = true
    }

    private func moveGroupDrag(event: NSEvent) {
        guard let id = draggedGroupID else { return }
        layoutSubtreeIfNeeded()
        dragPointer = convert(event.locationInWindow, from: nil)
        let previousTarget = groupDrag.target
        if bounds.contains(dragPointer), let frames = dragFrames(in: layoutResult) {
            groupDrag.update(groupID: id, draggedFrame: frames.displayed,
                             buttons: layoutResult.buttons, liveGroups: groups.map(\.id))
        }
        if groupDrag.target != previousTarget {
            needsLayout = true
            layoutSubtreeIfNeeded()
        } else if let frames = dragFrames(in: layoutResult) {
            for layout in layoutResult.buttons where layout.groupID == id {
                guard let view = buttonViews[layout.id] else { continue }
                view.layer?.removeAllAnimations()
                view.frame = interactionFrame(for: layout.frame).offsetBy(dx: frames.displayed.minX - frames.slot.minX, dy: 0)
            }
        }
    }

    private func endGroupDrag(event: NSEvent?, cancelled: Bool) {
        guard let id = draggedGroupID else { return }
        #if DEBUG
        let span = groupDragResources
        groupDragResources = nil
        defer { span?.finish() }
        #endif
        let inside = event.map { bounds.contains(convert($0.locationInWindow, from: nil)) } ?? false
        let target = !cancelled && inside ? groupDrag.target : nil
        if let target {
            let lookup = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            groups = groupDrag.order(groups.map(\.id)).compactMap { lookup[$0] }
            actions.reorder(id, target.groupID, target.after)
        }
        draggedGroupID = nil
        dragGeometry = nil
        dragMembers = []
        dragButtonIDs = []
        groupDrag.cancel()
        suppressClick = false
        animateNextLayout = true
        needsLayout = true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canUseWindowActions(), sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
              let buttonID = fileHoverButtonID(at: sender.draggingLocation) else {
            pointerAnchor = nil
            finishFileHover()
            return []
        }
        pointerAnchor = .fileDrag(buttonID)
        updateListDismissal()
        scheduleFileHover(buttonID: buttonID, at: sender.draggingLocation)
        return .generic
    }

    private func fileHoverButtonID(at location: CGPoint) -> String? {
        let point = convert(location, from: nil)
        if overflowButton?.frame.contains(point) == true { return "overflow" }
        return layoutResult.buttons.first(where: { buttonViews[$0.id]?.frame.contains(point) == true })?.id
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        finishFileHover()
        groupDrag.cancel()
        needsLayout = true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) { finishFileHover() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        finishFileHover()
        return false
    }

    private func finishFileHover() {
        cancelFileHover()
        if case .fileDrag = pointerAnchor { pointerAnchor = nil }
        updateListDismissal()
    }

    func scheduleFileHover(buttonID: String, at location: CGPoint? = nil) {
        let button = layoutResult.buttons.first(where: { $0.id == buttonID })
        let group = button.flatMap { button in groups.first(where: { $0.id == button.groupID }) }
        guard canUseWindowActions(), appsMenu == nil, buttonID == "overflow" || group != nil else {
            cancelFileHover()
            return
        }
        fileDragLocation = location
        let expectedWindow = button.flatMap { button in group?.windows.first(where: { button.windowIDs.contains($0.id) }) }
        fileHover.schedule(target: buttonID, after: .milliseconds(600)) { [weak self] in
            guard let self else { return }
            if let location = self.fileDragLocation {
                self.layoutSubtreeIfNeeded()
                guard self.fileHover.target == buttonID, self.fileHoverButtonID(at: location) == buttonID else {
                    self.finishFileHover()
                    return
                }
            }
            if buttonID == "overflow" {
                self.showOverflow()
                return
            }
            guard let button = self.layoutResult.buttons.first(where: { $0.id == buttonID }),
                  let group = self.groups.first(where: { $0.id == button.groupID }) else {
                self.cancelFileHover()
                return
            }
            if button.isCombined { self.showWindowList(group: group, anchor: button.frame) }
            else if let expectedWindow,
                    group.windows.contains(where: { $0.item.representsSameWindow(as: expectedWindow.item) }) {
                self.activateIfLive(expectedWindow, dismiss: true)
            } else { self.cancelFileHover() }
        }
    }

    private func activateIfLive(_ item: TaskbarWindowPresentation, dismiss: Bool) {
        guard canUseWindowActions(),
              groups.flatMap(\.windows).contains(where: { $0.item.representsSameWindow(as: item.item) }) else { return }
        if dismiss { dismissPopups() }
        actions.activate(item.item.actionIdentity)
    }

    private func closeIfLive(_ id: String, expectedWindows: [TaskbarWindowPresentation]) {
        guard let item = expectedWindows.first(where: { $0.item.actionWindowID == id }) else { return }
        closeIfLive(item)
    }

    private func closeIfLive(_ expected: TaskbarWindowPresentation) {
        guard canUseWindowActions(),
              groups.flatMap(\.windows).contains(where: { $0.item.representsSameWindow(as: expected.item) }) else { return }
        actions.close(expected.item.actionIdentity)
    }

    private func cancelFileHover() {
        fileHover.cancel()
        fileDragLocation = nil
    }
}
