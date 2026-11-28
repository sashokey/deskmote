import AppKit
import QuartzCore

extension PanelCoordinator {
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedUnitDisplayUUID else { return nil }
        let screens = screenProvider()
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: mainScreenProvider().flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    func applySpaceFullscreen(_ fullscreen: Bool, source: String) {
        setSpaceVisibility(fullscreen ? .fullscreen : .desktop, source: source)
    }

    func applySpaceUnavailable(source: String) {
        setSpaceVisibility(.unknown, source: source)
    }

    func spaceWillChange() {
        guard !isSuspendedForPermissionLoss else { return }
        taskbarView?.taskbarContent.prepareForHiding()
    }

    private func setSpaceVisibility(_ next: PanelVisibilityState, source: String) {
        guard !isSuspendedForPermissionLoss else { return }
        if visibilityState != next {
            visibilityState = next
            if next == .fullscreen { lastHideWasForFullscreen = true }
        }
        applyPanelVisibility(source: source)
    }

    func applyPanelVisibility(source: String = "visibility-reconcile") {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible && hasMatchingPanelScreen
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        taskbarPresenter?.setPanelVisible(shouldShow)
        if shouldShow, let panel = dockPanel {
            let fadeIn = lastHideWasForFullscreen && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            lastHideWasForFullscreen = false
            if fadeIn { panel.alphaValue = 0 }
            orderDockSurfaceFront(source: source)
            if fadeIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            orderDockSurfaceOut(source: source)
            dockPanel?.alphaValue = 1
        }
    }

    private var hasMatchingPanelScreen: Bool {
        guard let currentScreen else { return false }
        guard let fixedUnitDisplayUUID else { return true }
        return DisplayIdentity.uuidString(for: currentScreen) == fixedUnitDisplayUUID
    }
}

