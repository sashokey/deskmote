import AppKit
import Combine

extension PanelCoordinator {
    func subscribeSettings() {
        guard !isSuspendedForPermissionLoss else { return }
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
    }

    func relayout() {
        guard let panel = dockPanel else { return }
        let primary = fixedUnitDisplayUUID == nil ? screenProvider().first : nil
        guard let screen = resolvedPinnedScreen() ?? primary ?? panelCurrentScreen(panel: panel) else {
            panelsAreVisible = false
            taskbarPresenter?.setPanelVisible(false)
            orderDockSurfaceOut(source: "screen-unavailable")
            return
        }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        guard panel.frame != frame else { return }
        taskbarView?.taskbarContent.prepareForHiding()
        panel.setFrame(frame, display: panel.isVisible)
        dockContentHost?.layoutContent()
    }

    func screenParametersChanged() {
        guard !isSuspendedForPermissionLoss else { return }
        taskbarView?.taskbarContent.prepareForHiding()
        relayout()
        applyPanelVisibility(source: "screen-parameters-changed")
    }
}
