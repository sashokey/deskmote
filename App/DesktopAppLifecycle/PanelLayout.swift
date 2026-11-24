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
            orderDockSurfaceOut(source: "screen-unavailable")
            return
        }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        if panel.frame != frame {
            taskbarView?.taskbarContent.prepareForHiding()
            panel.setFrame(frame, display: true)
        }
        dockContentHost?.layoutContent()
    }

    func screenParametersChanged(sharedRead: FullscreenReadBatch? = nil) {
        guard !isSuspendedForPermissionLoss else { return }
        fullscreenProbeGeneration &+= 1
        taskbarView?.taskbarContent.prepareForHiding()
        relayout()
        reconcilePanelVisibility(source: "screen-parameters-changed")
        triggerAsyncFullscreenCheck(source: "screen-ax", sharedRead: sharedRead)
    }
}
