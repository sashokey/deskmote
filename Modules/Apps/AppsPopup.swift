import AppKit

typealias AppsMouseDownSource = @MainActor (
    NSEvent.EventTypeMask, @escaping @MainActor (NSEvent) -> NSEvent?, @escaping @MainActor (NSEvent) -> Void
) -> @MainActor () -> Void

typealias AppsPopupFrameSource = @MainActor (NSView, @escaping @MainActor (TimeInterval) -> Void) -> @MainActor () -> Void

@MainActor
private final class AppsPopupDisplayLink: NSObject {
    private let startedAt = CACurrentMediaTime()
    private let tick: @MainActor (TimeInterval) -> Void
    private var link: CADisplayLink?

    init(view: NSView, tick: @escaping @MainActor (TimeInterval) -> Void) {
        self.tick = tick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        tick(max(0, link.targetTimestamp - startedAt))
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}

@MainActor
private final class AppsPopupViewport: NSView {
    private enum Phase { case resting, opening, closing }

    private static let key = "apps-popup-slide"
    private static let duration: TimeInterval = 0.19
    private static let openingTimes: [CGFloat] = [0, 0.16, 0.34, 0.50, 0.67, 0.84, 1]
    private static let openingFractions: [CGFloat] = [1, 0.53, 0.28, 0.12, 0.04, 0.006, 0]
    private let appsView: AppsMenuView
    private var restingFrame: CGRect
    private var phase: Phase = .resting
    private var openingFraction: CGFloat = 0
    private var firstVisibleFrame = false
    private var stopFrames: (@MainActor () -> Void)?
    private var bottomInset: CGFloat { phase == .resting ? 0 : AppsMenuGeometry.popupGap }
    private var travel: CGFloat { restingFrame.height + AppsMenuGeometry.popupGap }


    init(menu: AppsMenuView, restingFrame: CGRect) {
        appsView = menu
        self.restingFrame = restingFrame
        super.init(frame: menu.frame)
        clipsToBounds = true
        wantsLayer = true
        menu.wantsLayer = true
        menu.clipsToBounds = true
        menu.layer?.cornerRadius = menu.cornerRadius
        menu.layer?.cornerCurve = .continuous
        addSubview(menu)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard phase != .closing else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), appsView.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopFrameUpdates() }
    }

    func updateFrame(_ frame: CGRect) {
        guard frame != restingFrame else { return }
        restingFrame = frame
        applyFrame()
    }

    func prepareOpening() {
        phase = .opening
        openingFraction = 1
        applyFrame()
    }

    func startFrameUpdates(_ source: AppsPopupFrameSource) {
        if phase == .resting { appsView.presentedOpeningFinished() }
        guard phase == .opening || appsView.catalogDeferredUntilFrame else { return }
        stopFrames = source(self) { [weak self] elapsed in self?.advance(elapsed: elapsed) }
    }

    private func advance(elapsed: TimeInterval) {
        if phase == .opening {
            if elapsed < Self.duration {
                let progress = CGFloat(elapsed / Self.duration)
                let times = Self.openingTimes
                let fractions = Self.openingFractions
                if let next = times.firstIndex(where: { $0 > progress }) {
                    let weight = (progress - times[next - 1]) / (times[next] - times[next - 1])
                    openingFraction = fractions[next - 1] + (fractions[next] - fractions[next - 1]) * weight
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                appsView.setFrameOrigin(CGPoint(x: 0, y: bottomInset - openingFraction * travel))
                CATransaction.commit()
            } else {
                phase = .resting
                openingFraction = 0
                applyFrame()
                appsView.presentedOpeningFinished()
            }
        }
        guard phase != .closing else { return }
        if appsView.catalogDeferredUntilFrame, appsView.frame.intersects(bounds) {
            if firstVisibleFrame { appsView.presentedFirstFrame() }
            firstVisibleFrame = true
        }
        if phase == .resting, !appsView.catalogDeferredUntilFrame { stopFrameUpdates() }
    }

    func stopFrameUpdates() {
        stopFrames?()
        stopFrames = nil
    }

    func detachMenu() {
        stopFrameUpdates()
        appsView.layer?.removeAnimation(forKey: Self.key)
        appsView.removeFromSuperview()
    }

    func stopMenuActions() { appsView.stopMenuActions() }

    func slideOut(completion: @escaping @Sendable () -> Void) {
        stopFrameUpdates()
        let initial = openingFraction
        phase = .closing
        setAccessibilityHidden(true)
        window?.makeFirstResponder(nil)
        applyFrame()
        let fractions: [CGFloat] = [0, 0.009, 0.042, 0.112, 0.234, 0.414, 0.70, 1]
        let motion = CAKeyframeAnimation(keyPath: "transform.translation.y")
        motion.values = fractions.map { NSNumber(value: Double(-(initial + (1 - initial) * $0) * travel)) }
        motion.keyTimes = [0, 0.13, 0.27, 0.42, 0.57, 0.71, 0.85, 1]
        motion.duration = Self.duration
        motion.isRemovedOnCompletion = false
        motion.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        appsView.layer?.add(motion, forKey: Self.key)
        CATransaction.commit()
    }

    private func applyFrame() {
        var viewportFrame = restingFrame
        viewportFrame.origin.y -= bottomInset
        viewportFrame.size.height += bottomInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let window, window.frame != viewportFrame {
            appsView.clearPointer()
            window.setFrame(viewportFrame, display: false)
        }
        let offset = phase == .opening ? openingFraction * travel : 0
        appsView.frame = CGRect(origin: CGPoint(x: 0, y: bottomInset - offset), size: restingFrame.size)
        CATransaction.commit()
    }

}

@MainActor
final class AppsPopupController {
    private static let outsideClickMask: NSEvent.EventTypeMask = .leftMouseDown
    private(set) var panel: NSPanel?
    var isPresented: Bool { panel != nil }
    private let mouseDownSource: AppsMouseDownSource
    private var stopMouseDown: (@MainActor () -> Void)?
    private let makePanel: (CGRect) -> NSPanel
    private let reduceMotion: () -> Bool
    private let appsFrameSource: AppsPopupFrameSource
    private var closingPanel: NSPanel?
    var onDismiss: (() -> Void)?

    init(makePanel: ((CGRect) -> NSPanel)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         appsFrameSource: @escaping AppsPopupFrameSource = { view, tick in
             let clock = AppsPopupDisplayLink(view: view, tick: tick)
             return { clock.invalidate() }
         }, mouseDownSource: @escaping AppsMouseDownSource = { _, _, _ in {} }) {
        self.reduceMotion = reduceMotion
        self.mouseDownSource = mouseDownSource
        self.appsFrameSource = appsFrameSource
        self.makePanel = makePanel ?? {
            NSPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
    }

    func present(content: AppsMenuView, frame: CGRect, anchorWindow: NSWindow?, toggle: NSControl? = nil) {
        dismissImmediately()
        let panel = makePanel(frame)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = anchorWindow?.effectiveAppearance
        content.frame = CGRect(origin: .zero, size: frame.size)
        let viewport = AppsPopupViewport(menu: content, restingFrame: frame)
        panel.hasShadow = false
        panel.contentView = viewport
        self.panel = panel
        if !reduceMotion() {
            panel.animationBehavior = .none
            viewport.prepareOpening()
        }
        panel.orderFrontRegardless()
        viewport.startFrameUpdates(appsFrameSource)
        stopMouseDown = mouseDownSource(Self.outsideClickMask, { [weak self, weak panel, weak anchorWindow, weak toggle] event in
            if let self, let panel, self.panel === panel,
               !Self.isInside(event.window, panel: panel),
               !Self.isToggleEvent(event, anchorWindow: anchorWindow, toggle: toggle) {
                self.dismiss()
            }
            return event
        }, { [weak self, weak panel] _ in
            guard let self, let panel, self.panel === panel else { return }
            self.dismiss()
        })
    }

    private static func isInside(_ window: NSWindow?, panel: NSPanel) -> Bool {
        var current = window
        while let window = current {
            if window === panel { return true }
            current = window.parent
        }
        return false
    }

    private static func isToggleEvent(_ event: NSEvent, anchorWindow: NSWindow?, toggle: NSControl?) -> Bool {
        guard let anchorWindow, event.window === anchorWindow,
              let toggle, let parent = toggle.superview, toggle.window === anchorWindow else { return false }
        return toggle.hitTest(parent.convert(event.locationInWindow, from: nil)) != nil
    }

    static func observeMouseDown(_ local: @escaping @MainActor (NSEvent) -> NSEvent?,
                                 _ global: @escaping @MainActor (NSEvent) -> Void) -> @MainActor () -> Void {
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.outsideClickMask) { event in
            local(event)
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.outsideClickMask) { event in
            MainActor.assumeIsolated { global(event) }
        }
        return {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
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
        guard let panel else { return }
        self.panel = nil
        let stop = stopMouseDown
        stopMouseDown = nil
        stop?()
        let viewport = panel.contentView as? AppsPopupViewport
        viewport?.stopMenuActions()
        if animated, let viewport, !reduceMotion() {
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
        onDismiss?()
    }

    private static func close(_ panel: NSPanel) {
        (panel.contentView as? AppsPopupViewport)?.detachMenu()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    isolated deinit {
        stopMouseDown?()
        if let panel { Self.close(panel) }
        if let closingPanel { Self.close(closingPanel) }
    }
}
