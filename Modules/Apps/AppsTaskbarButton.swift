import AppKit

@MainActor
struct AppsPointerPosition {
    private var point: NSPoint?
    private var timestamp: TimeInterval = -.infinity
    private var validSince: TimeInterval = -.infinity
    private var windowFrame: NSRect?

    mutating func receive(_ event: NSEvent, in window: NSWindow?, clearsPosition: Bool = false) -> Bool {
        guard let window, event.windowNumber == window.windowNumber,
              event.timestamp >= timestamp, event.timestamp >= validSince else { return false }
        timestamp = event.timestamp
        point = clearsPosition ? nil : event.locationInWindow
        windowFrame = window.frame
        return true
    }

    func location(in window: NSWindow) -> NSPoint? {
        window.frame == windowFrame ? point : nil
    }

    mutating func clear() {
        point = nil
        validSince = ProcessInfo.processInfo.systemUptime
    }
}

@MainActor
final class AppsTaskbarButton: NSButton {
    private let selection = NSBox()
    private let icon = AppsTaskbarIconView(frame: .zero)
    private var hoverTracking: NSTrackingArea?
    private var geometryObservers: [NSObjectProtocol] = []
    private var pointer = AppsPointerPosition()
    private var pressed = false

    override var isFlipped: Bool { true }

    private let appearanceSettings: AppsAppearance
    private let reduceMotion: @MainActor () -> Bool

    init(frame frameRect: NSRect, appearanceSettings: AppsAppearance,
         reduceMotion: @escaping @MainActor () -> Bool) {
        self.appearanceSettings = appearanceSettings
        self.reduceMotion = reduceMotion
        super.init(frame: frameRect)
        let visualBounds = AppsMenuGeometry.buttonFrame.offsetBy(dx: -frameRect.minX, dy: -frameRect.minY)
        clipsToBounds = true
        setButtonType(.toggle)
        isBordered = false
        isTransparent = true
        selection.boxType = .custom
        selection.titlePosition = .noTitle
        selection.borderWidth = 1
        selection.cornerRadius = appearanceSettings.buttonCornerRadius
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
        didSet { updateSelection(animated: true) }
    }

    override var frame: NSRect {
        didSet { if frame != oldValue { clearPointer() } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
        updateSelection()
    }

    override func mouseEntered(with event: NSEvent) { receivePointer(event) }
    override func mouseExited(with event: NSEvent) { receivePointer(event) }
    override func mouseMoved(with event: NSEvent) { receivePointer(event) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPointer()
        let center = NotificationCenter.default
        geometryObservers.forEach(center.removeObserver)
        geometryObservers.removeAll()
        guard let window else { return }
        geometryObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearPointer() }
            }
        }
    }

    isolated deinit { geometryObservers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidHide() {
        super.viewDidHide()
        clearPointer()
    }

    private var hovered: Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, let point = pointer.location(in: window) else { return false }
        return isMousePoint(convert(point, from: nil), in: visibleRect)
    }

    private func receivePointer(_ event: NSEvent) {
        if event.type != .mouseMoved, let area = event.trackingArea, area !== hoverTracking { return }
        let wasHovered = hovered
        guard pointer.receive(event, in: window, clearsPosition: event.type == .mouseExited) else { return }
        if hovered != wasHovered { updateSelection(animated: true) }
    }

    private func clearPointer() {
        pointer.clear()
        updateSelection()
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
        let opacity = appearanceSettings.select(state == .on, hovered, pressed, selection, effectiveAppearance)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && window?.isVisible == true && !reduceMotion()
                ? appearanceSettings.buttonTransition : 0
            selection.animator().alphaValue = opacity
            icon.showColor(hovered || state == .on)
        }
    }
}

@MainActor
private final class AppsTaskbarIconView: NSView {
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
