import AppKit
import Combine

extension PanelCoordinator {
    func subscribeSettings() {
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
            orderDockSurfaceOut()
            return
        }
        let frame = TaskbarMetrics.panelFrame(on: screen.frame)
        if panel.frame != frame {
            taskbarView?.taskbarContent.prepareForHiding()
            panel.setFrame(frame, display: true)
        }
        dockContentHost?.layoutContent()
    }

    func screenParametersChanged(sharedRead: FullscreenAXReadBatch? = nil) {
        fullscreenProbeGeneration &+= 1
        taskbarView?.taskbarContent.prepareForHiding()
        relayout()
        reconcilePanelVisibility()
        triggerAsyncFullscreenCheck(source: "screen-ax", sharedRead: sharedRead)
    }
}
