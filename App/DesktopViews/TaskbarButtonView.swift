import AppKit

@MainActor
struct TaskbarButtonSelection {
    let opacity: CGFloat
    private let borderEmphasis: CGFloat

    init(active: Bool, hovered: Bool, pressed: Bool) {
        switch (pressed, active, hovered) {
        case (true, _, _): (opacity, borderEmphasis) = (0.45, 0)
        case (false, true, true): (opacity, borderEmphasis) = (0.95, 0.2)
        case (false, true, false): (opacity, borderEmphasis) = (0.65, 1)
        case (false, false, true): (opacity, borderEmphasis) = (0.65, 0.5)
        default: (opacity, borderEmphasis) = (0, 0)
        }
    }

    func applyColors(to box: NSBox, appearance: NSAppearance) {
        box.fillColor = .unemphasizedSelectedContentBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let separator = NSColor.separatorColor
            box.borderColor = separator.withAlphaComponent(separator.alphaComponent * borderEmphasis)
        }
    }
}

@MainActor
struct TaskbarPointerPosition {
    private var point: NSPoint?
    private var timestamp: TimeInterval = -.infinity
    private var validSince: TimeInterval = -.infinity
    private var windowFrame: NSRect?

    mutating func receive(_ event: NSEvent, in view: NSView, tracking: NSTrackingArea?) -> Bool {
        guard event.windowNumber == (view.window?.windowNumber ?? 0),
              event.timestamp >= timestamp, event.timestamp >= validSince else { return false }
        if event.type != .mouseMoved, let area = event.trackingArea, area !== tracking { return false }
        timestamp = event.timestamp
        point = event.type == .mouseExited ? nil : event.locationInWindow
        windowFrame = view.window?.frame
        return true
    }

    func isInside(_ view: NSView) -> Bool {
        guard let point, !view.isHiddenOrHasHiddenAncestor, view.window?.frame == windowFrame else { return false }
        return view.isMousePoint(view.convert(point, from: nil), in: view.visibleRect)
    }

    mutating func clear() {
        point = nil
        validSince = ProcessInfo.processInfo.systemUptime
    }

    mutating func rebase(in view: NSView, to newFrame: NSRect) -> Bool {
        guard let point, let windowFrame, view.window?.frame == windowFrame, newFrame.size == windowFrame.size else {
            clear()
            return false
        }
        let rebased = CGPoint(x: point.x + windowFrame.minX - newFrame.minX,
                              y: point.y + windowFrame.minY - newFrame.minY)
        clear()
        guard view.isMousePoint(view.convert(rebased, from: nil), in: view.visibleRect) else { return false }
        self.point = rebased
        self.windowFrame = newFrame
        return true
    }
}

@MainActor
final class TaskbarButtonView: NSButton {
    enum ActionTargets: Equatable {
        case window(WindowActionIdentity)
        case list(Set<WindowActionIdentity>)
    }

    override var title: String {
        didSet {
            titleLabel.stringValue = WindowDisplayTitle.singleLine(title)
            setAccessibilityLabel(title)
        }
    }
    override var image: NSImage? { didSet { iconView.image = image } }
    var isActiveWindow = false { didSet { if oldValue != isActiveWindow { updateAppearance(animated: true) } } }
    var isCombined = false { didSet { groupIndicator.isHidden = !isCombined } }
    var isOverflow = false {
        didSet {
            if isOverflow { image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil) }
            titleLabel.isHidden = isOverflow
            indicator.isHidden = isOverflow
            needsLayout = true
        }
    }
    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var acceptPointerEntry: (TimeInterval) -> Bool = { _ in true }
    var onBeginDrag: ((NSEvent, CGPoint) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onEndDrag: ((NSEvent?, Bool) -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @objc dynamic var indicatorProgress: CGFloat = 0 { didSet { updateIndicator() } }
    let selectionView = NSBox()
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let indicator = NSBox()
    private let groupIndicator = NSBox()
    private var tracking: NSTrackingArea?
    private var pointer = TaskbarPointerPosition()
    private var downPointInWindow: CGPoint?
    private var beganDrag = false
    private var hovered = false
    private var pressed = false
    private var actionTargets: ActionTargets?

    override var isFlipped: Bool { true }
    override var frame: NSRect {
        didSet { if frame != oldValue { clearPointer() } }
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        isBordered = false
        isTransparent = true
        tintProminence = .none
        clipsToBounds = true
        wantsLayer = true
        selectionView.wantsLayer = true
        selectionView.boxType = .custom
        selectionView.titlePosition = .noTitle
        selectionView.borderWidth = 1
        selectionView.cornerRadius = TaskbarMetrics.buttonCornerRadius
        selectionView.contentViewMargins = .zero
        selectionView.fillColor = .unemphasizedSelectedContentBackgroundColor
        selectionView.alphaValue = 0
        selectionView.setAccessibilityElement(false)
        addSubview(selectionView)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        titleLabel.font = NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        indicator.wantsLayer = true
        indicator.boxType = .custom
        indicator.titlePosition = .noTitle
        indicator.borderWidth = 0
        indicator.cornerRadius = 1
        indicator.contentViewMargins = .zero
        indicator.setAccessibilityElement(false)
        addSubview(indicator)
        groupIndicator.boxType = .separator
        groupIndicator.isHidden = true
        groupIndicator.setAccessibilityElement(false)
        addSubview(groupIndicator)
        title = ""
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let contentBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                   height: min(bounds.height, TaskbarMetrics.buttonHeight))
        selectionView.frame = contentBounds
        let iconX = isOverflow ? floor((bounds.width - TaskbarMetrics.iconSize) / 2) : TaskbarMetrics.iconInset
        iconView.frame = CGRect(x: iconX, y: 6, width: TaskbarMetrics.iconSize, height: TaskbarMetrics.iconSize)
        let font = titleLabel.font ?? NSFont.systemFont(ofSize: TaskbarMetrics.fontSize)
        let height = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: font]).height)
        var titleRect = CGRect(x: TaskbarMetrics.labelInset, y: iconView.frame.midY - height / 2,
                               width: max(0, bounds.width - TaskbarMetrics.labelInset - TaskbarMetrics.labelTrailingInset), height: height)
        titleRect.origin.y = backingAlignedRect(titleRect, options: [.alignAllEdgesNearest, .alignRectFlipped]).minY
        titleLabel.frame = titleLabel.frame(forAlignmentRect: titleRect)
        updateIndicator()
        groupIndicator.frame = CGRect(x: bounds.maxX - 3, y: 3, width: 2, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        receivePointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        receivePointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        receivePointer(event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPointer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        clearPointer()
    }

    var acceptsDelayedHover: Bool { window == nil || pointer.isInside(self) }

    private func receivePointer(_ event: NSEvent) {
        guard pointer.receive(event, in: self, tracking: tracking) else { return }
        let inside = window == nil ? event.type != .mouseExited : pointer.isInside(self)
        guard !inside || acceptPointerEntry(event.timestamp) else { return }
        let wasHovered = hovered
        setHovered(inside)
        if inside, wasHovered, event.type == .mouseEntered { onHover?(true) }
    }

    func clearPointer() {
        pointer.clear()
        setHovered(false)
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        updateAppearance(animated: true)
        onHover?(value)
    }

    var canInteract: () -> Bool = { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, canInteract() else { return }
        downPointInWindow = event.locationInWindow
        beganDrag = false
        pressed = true
        highlight(true)
        updateAppearance(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPointInWindow else { return }
        guard canInteract() else { cancelPendingPress(); return }
        if !beganDrag {
            let point = event.locationInWindow
            guard hypot(point.x - downPointInWindow.x, point.y - downPointInWindow.y) >= 4 else { return }
            beganDrag = true
            pressed = false
            highlight(false)
            updateAppearance(animated: true)
            onBeginDrag?(event, downPointInWindow)
        }
        onDragMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard canInteract() else { cancelPendingPress(); return }
        let shouldClick = downPointInWindow != nil && !beganDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        if beganDrag { onEndDrag?(event, false) }
        downPointInWindow = nil
        beganDrag = false
        pressed = false
        highlight(false)
        updateAppearance(animated: true)
        if shouldClick { activateButton() }
    }

    func cancelPendingPress() {
        guard downPointInWindow != nil else { return }
        if beganDrag { onEndDrag?(nil, true) }
        downPointInWindow = nil
        beganDrag = false
        pressed = false
        highlight(false)
        updateAppearance(animated: true)
    }

    func updateActionTargets(_ targets: ActionTargets) -> Bool {
        guard targets != actionTargets else { return false }
        actionTargets = targets
        cancelPendingPress()
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        if canInteract() { onContextMenu?(event) }
    }

    override func accessibilityPerformPress() -> Bool { false }

    private func activateButton() {
        guard isEnabled, canInteract() else { return }
        onClick?()
        state = isActiveWindow ? .on : .off
    }

    private var indicatorFrame: CGRect {
        let width: CGFloat = 4 + 7 * indicatorProgress
        return CGRect(x: TaskbarMetrics.iconInset + (TaskbarMetrics.iconSize - width) / 2,
                      y: 25, width: width, height: 2)
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "indicatorProgress" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    private func updateIndicator() {
        if indicator.frame != indicatorFrame { indicator.frame = indicatorFrame }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if indicatorProgress <= 0 { indicator.fillColor = .secondaryLabelColor }
            else if indicatorProgress >= 1 { indicator.fillColor = .controlAccentColor }
            else {
                indicator.fillColor = NSColor.secondaryLabelColor.blended(withFraction: indicatorProgress,
                                                                         of: .controlAccentColor) ?? .controlAccentColor
            }
        }
    }

    private func updateAppearance(animated: Bool) {
        state = isActiveWindow ? .on : .off
        let selection = TaskbarButtonSelection(active: isActiveWindow, hovered: hovered, pressed: pressed)
        selection.applyColors(to: selectionView, appearance: effectiveAppearance)
        let duration = animated && !reduceMotion() ? TaskbarMotion.buttonTransition : 0
        let progress: CGFloat = isActiveWindow ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            selectionView.animator().alphaValue = selection.opacity
            animator().indicatorProgress = progress
            if duration == 0 { indicatorProgress = progress }
        }
    }
}
