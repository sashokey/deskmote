import AppKit

extension PanelCoordinator {
    func setupDockPanel(
        makeTaskbarView: (CGRect) -> TaskbarView = { TaskbarView(frame: $0) },
        makeDockPanel: (CGRect) -> NSPanel = {
            NonConstrainingPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        }
    ) -> Bool {
        let fallback = fixedUnitDisplayUUID == nil ? screenProvider().first ?? mainScreenProvider()
            : mainScreenProvider() ?? screenProvider().first
        guard let screen = resolvedPinnedScreen() ?? fallback else { return false }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        let panel = makeDockPanel(frame)
        configurePanel(panel, backgroundColor: .clear)
        panel.isReleasedWhenClosed = false
        let view = makeTaskbarView(CGRect(origin: .zero, size: frame.size))
        view.taskbarContent.admitWindowList = { [weak self] openedByClick in
            guard let self else { return false }
            return self.onAccessoryInteraction?(self, openedByClick ? .explicit : .implicit) ?? true
        }
        view.taskbarContent.onBackgroundClick = { [weak self] in
            guard let self else { return }
            _ = self.onAccessoryInteraction?(self, .backgroundClick)
        }
        view.taskbarContent.installLeadingSlot(leadingSlotFactory)
        view.autoresizingMask = [.width, .height]
        dockContentHost = ManualPanelHost(contentView: view, in: panel)
        taskbarView = view
        dockPanel = panel
        taskbarPresenter = TaskbarPresenter(
            view: view, runtime: runtime, ordering: stripOrderStore,
            topology: displayTopologyStore, spaces: spaceStore, displayUUID: fixedUnitDisplayUUID,
            backgroundMenu: { [weak self] event, source in self?.onRequestTaskbarMenu?(event, source) },
            contextMenuVisibilityChanged: { [weak self] visible in
                guard let self, visible else { return }
                _ = self.onAccessoryInteraction?(self, .explicit)
            }
        )
        taskbarPresenter?.setPanelVisible(false)
        return true
    }

    func orderDockSurfaceFront(source: String) {
        dockPanel?.orderFrontRegardless()
    }

    func orderDockSurfaceOut(source: String) {
        taskbarView?.taskbarContent.prepareForHiding()
        dockPanel?.orderOut(nil)
    }

    func presentInitialPanels() {
        guard let dock = dockPanel else { return }
        dock.layoutIfNeeded()
        relayout()
        dockContentHost?.layoutContent()
        applyPanelVisibility(source: "initial")
    }

    func configurePanel(_ panel: NSPanel, backgroundColor: NSColor) {
        panel.level = .floating
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }

}
