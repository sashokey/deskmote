import AppKit

public typealias AppsMenuItemFactory = @MainActor (String, @escaping @MainActor () -> Void) -> NSMenuItem

@MainActor
public struct AppsAppearance {
    let buttonCornerRadius: CGFloat
    let buttonTransition: TimeInterval
    let reorderTransition: TimeInterval
    let select: @MainActor (Bool, Bool, Bool, NSBox, NSAppearance) -> CGFloat

    public init(buttonCornerRadius: CGFloat, buttonTransition: TimeInterval, reorderTransition: TimeInterval,
                select: @escaping @MainActor (Bool, Bool, Bool, NSBox, NSAppearance) -> CGFloat) {
        self.buttonCornerRadius = buttonCornerRadius
        self.buttonTransition = buttonTransition
        self.reorderTransition = reorderTransition
        self.select = select
    }
}

@MainActor
public struct AppsWindowAction {
    let title: String
    let isActive: Bool
    let activate: @MainActor () -> Void

    public init(title: String, isActive: Bool, activate: @escaping @MainActor () -> Void) {
        self.title = title
        self.isActive = isActive
        self.activate = activate
    }
}

@MainActor
public final class AppsModule {
    private let store: AppsMenuStore
    private let appearance: AppsAppearance
    private let makePanel: @MainActor (CGRect) -> NSPanel
    private let makeMenuItem: AppsMenuItemFactory
    private let reduceMotion: @MainActor () -> Bool
    private let observeWorkspace: Bool
    private let makePopup: (@MainActor () -> AppsPopupController)?

    public convenience init(appearance: AppsAppearance, makePanel: @escaping @MainActor (CGRect) -> NSPanel,
                            makeMenuItem: @escaping AppsMenuItemFactory,
                            isDeskMote: @escaping @Sendable (String?) -> Bool) {
        self.init(store: AppsMenuStore(isDeskMote: isDeskMote),
                  appearance: appearance, makePanel: makePanel, makeMenuItem: makeMenuItem,
                  observeWorkspace: true,
                  reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
    }

    init(store: AppsMenuStore, appearance: AppsAppearance, makePanel: @escaping @MainActor (CGRect) -> NSPanel,
         makeMenuItem: @escaping AppsMenuItemFactory,
         observeWorkspace: Bool, reduceMotion: @escaping @MainActor () -> Bool,
         makePopup: (@MainActor () -> AppsPopupController)? = nil) {
        self.store = store
        self.appearance = appearance
        self.makePanel = makePanel
        self.makeMenuItem = makeMenuItem
        self.observeWorkspace = observeWorkspace
        self.reduceMotion = reduceMotion
        self.makePopup = makePopup
    }

    public func attach(admitPopup: @escaping @MainActor () -> Bool,
                       windowActions: @escaping @MainActor (pid_t) -> [AppsWindowAction]) -> AppsAttachment {
        let mouseDownSource: AppsMouseDownSource = { [observeWorkspace] _, local, global in
            guard observeWorkspace else { return {} }
            return AppsPopupController.observeMouseDown(local, global)
        }
        let popup = makePopup?() ?? AppsPopupController(makePanel: makePanel, reduceMotion: reduceMotion,
                                                       mouseDownSource: mouseDownSource)
        return AppsAttachment(store: store, popup: popup, appearance: appearance, makeMenuItem: makeMenuItem,
                              observeWorkspace: observeWorkspace, reduceMotion: reduceMotion,
                              admitPopup: admitPopup, windowActions: windowActions)
    }
}

@MainActor
public final class AppsAttachment: NSObject {
    public var view: NSView { button }
    public var leadingInset: CGFloat { AppsMenuGeometry.windowLeadingInset }
    public var isPresented: Bool { popup.isPresented }

    let popup: AppsPopupController
    private let store: AppsMenuStore
    private let appearance: AppsAppearance
    private let makeMenuItem: AppsMenuItemFactory
    private let observeWorkspace: Bool
    private let reduceMotion: @MainActor () -> Bool
    private let admitPopup: @MainActor () -> Bool
    private let windowActions: @MainActor (pid_t) -> [AppsWindowAction]
    private let button: AppsTaskbarButton
    private weak var anchorWindow: NSWindow?
    private var preparedMenu: AppsMenuView?
    private var preparation: Task<Void, Never>?

    init(store: AppsMenuStore, popup: AppsPopupController, appearance: AppsAppearance,
         makeMenuItem: @escaping AppsMenuItemFactory,
         observeWorkspace: Bool, reduceMotion: @escaping @MainActor () -> Bool,
         admitPopup: @escaping @MainActor () -> Bool, windowActions: @escaping @MainActor (pid_t) -> [AppsWindowAction]) {
        self.store = store
        self.popup = popup
        self.appearance = appearance
        self.makeMenuItem = makeMenuItem
        self.observeWorkspace = observeWorkspace
        self.reduceMotion = reduceMotion
        self.admitPopup = admitPopup
        self.windowActions = windowActions
        button = AppsTaskbarButton(frame: AppsMenuGeometry.buttonHitFrame, appearanceSettings: appearance,
                                   reduceMotion: reduceMotion)
        super.init()
        let title = String(localized: "Apps", table: "Apps")
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("DeskMote.Apps")
        button.target = self
        button.action = #selector(toggle)
        popup.onDismiss = { [weak self] in self?.button.state = .off }
        store.preloadCatalog()
    }

    public func update(in bounds: CGRect, anchorWindow: NSWindow?) {
        self.anchorWindow = anchorWindow
        let hitFrame = AppsMenuGeometry.buttonHitFrame
        button.frame = CGRect(x: hitFrame.minX, y: hitFrame.minY, width: hitFrame.width,
                              height: max(0, bounds.maxY - hitFrame.minY))
        guard let anchorWindow else {
            preparation?.cancel()
            preparation = nil
            preparedMenu = nil
            popup.dismissImmediately()
            return
        }
        if let frame = popupFrame(anchorWindow) {
            popup.updateFrame(frame)
            prepareMenu()
        }
    }

    public func dismiss(animated: Bool) {
        if animated {
            if popup.isPresented { popup.dismiss() }
        } else {
            popup.dismissImmediately()
        }
    }

    private func prepareMenu() {
        guard preparedMenu == nil, preparation == nil else { return }
        preparation = Task { [weak self, store] in
            _ = await store.loadCatalog()
            guard !Task.isCancelled, let self else { return }
            preparation = nil
            guard preparedMenu == nil, let anchorWindow, let frame = popupFrame(anchorWindow) else { return }
            preparedMenu = makeMenu(frame: frame, deferCatalog: false)
        }
    }

    @objc private func toggle() {
        if popup.isPresented {
            popup.dismiss()
            return
        }
        button.state = .off
        guard let anchorWindow, let frame = popupFrame(anchorWindow), admitPopup() else { return }
        preparation?.cancel()
        preparation = nil
        let menu = preparedMenu ?? makeMenu(frame: frame, deferCatalog: true)
        preparedMenu = menu
        menu.prepareForPresentation(size: frame.size)
        popup.present(content: menu, frame: frame, anchorWindow: anchorWindow, toggle: button)
        button.state = .on
        popup.makeKey()
        menu.focusSearch()
    }

    private func makeMenu(frame: CGRect, deferCatalog: Bool) -> AppsMenuView {
        AppsMenuView(observeWorkspace: observeWorkspace, makeMenuItem: makeMenuItem, frame: CGRect(origin: .zero, size: frame.size),
                     store: store, reduceMotion: reduceMotion, runningWindows: windowActions,
                     buttonTransition: appearance.buttonTransition, reorderTransition: appearance.reorderTransition,
                     deferCatalog: deferCatalog) { [weak self] in self?.popup.dismiss() }
    }

    private func popupFrame(_ window: NSWindow) -> CGRect? {
        guard let screen = window.screen ?? NSScreen.main else { return nil }
        let frame = AppsMenuGeometry.popupFrame(taskbar: window.frame, screen: screen.frame, visibleTop: screen.visibleFrame.maxY)
        return frame.isEmpty ? nil : frame
    }

    isolated deinit { preparation?.cancel() }
}
