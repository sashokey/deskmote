import AppKit
import QuartzCore
#if DEBUG
import os
#endif

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
        #if DEBUG
        recordPanelVisibility(event: "space-pending", source: "space-notification")
        #endif
    }

    private func setSpaceVisibility(_ next: PanelVisibilityState, source: String) {
        guard !isSuspendedForPermissionLoss else { return }
        if visibilityState != next {
            visibilityState = next
            if next == .fullscreen { lastHideWasForFullscreen = true }
            #if DEBUG
            recordPanelVisibility(event: "visibility-decision", source: source)
            #endif
        }
        applyPanelVisibility(source: source)
    }

    func applyPanelVisibility(source: String = "visibility-reconcile") {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible && hasMatchingPanelScreen
        guard shouldShow != panelsAreVisible else { return }
        #if DEBUG
        let span = ActionResourceLog.begin(shouldShow ? "taskbar.panel.show" : "taskbar.panel.hide")
        defer { span?.finish() }
        #endif
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

#if DEBUG
struct TaskbarVisibilitySample: Encodable, Equatable, Sendable {
    let windowNumber: Int
    let primaryDisplay: Bool?
    let requestedVisible: Bool
    let spaceState: String
    let appKitVisible: Bool
    let onActiveSpace: Bool
    let occlusionVisible: Bool
    let alpha: String
}

@MainActor
final class TaskbarVisibilityJournal {
    private struct Line: Encodable, Sendable {
        let timestamp: String
        let revision: String?
        let event: String
        let source: String?
        let state: TaskbarVisibilitySample
    }

    private static let queue = BoundedDiagnosticQueue(label: "io.github.sashokey.deskmote.taskbar-visibility")
    private let write: @Sendable (Data) -> Void
    private let revision = Bundle.main.object(forInfoDictionaryKey: "DeskMoteSourceRevision") as? String
    private var previous: TaskbarVisibilitySample?

    init(write: @escaping @Sendable (Data) -> Void) { self.write = write }

    static func live() -> TaskbarVisibilityJournal? {
        guard DebugSwitch.inventoryLog.value() == "1" else { return nil }
        let file = PrivateJSONLinesFile(directory: PrivateJSONLinesFile.liveDirectory, name: "taskbar-visibility.jsonl")
        return TaskbarVisibilityJournal { try? file.append($0) }
    }

    func capture(_ state: TaskbarVisibilitySample, event: String = "observed", source: String? = nil) {
        guard event != "observed" || state != previous else { return }
        previous = state
        let date = Date()
        let revision = self.revision
        let write = self.write
        Self.queue.submit {
            let clock = ISO8601DateFormatter()
            clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record = Line(timestamp: clock.string(from: date), revision: revision, event: event,
                              source: source, state: state)
            guard var data = try? JSONEncoder().encode(record) else { return }
            data.append(0x0A)
            write(data)
        }
    }

    func flush() { Self.queue.flush() }
}

extension PanelCoordinator {
    private static let visibilityLogger = Logger(subsystem: "io.github.sashokey.deskmote", category: "dock-panel")

    func startPanelVisibilityObservation() {
        guard let panel = dockPanel else { return }
        panelVisibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSuspendedForPermissionLoss else { return }
                self.recordPanelVisibility(event: "observed", source: "appkit-occlusion")
            }
        }
    }

    func stopPanelVisibilityObservation() {
        if let panelVisibilityObserver { NotificationCenter.default.removeObserver(panelVisibilityObserver) }
        panelVisibilityObserver = nil
    }

    func recordPanelVisibility(event: String, source: String) {
        guard let panel = dockPanel else { return }
        let appKitVisible = panel.isVisible
        let onActiveSpace = appKitVisible && panel.isOnActiveSpace
        let occlusionVisible = panel.occlusionState.contains(.visible)
        Self.visibilityLogger.log(level: event == "observed" ? .debug : .default,
                                  "event=\(event, privacy: .public) source=\(source, privacy: .public) panel=\(panel.windowNumber, privacy: .public) space=\(self.visibilityState.rawValue, privacy: .public) requested=\(self.panelsAreVisible, privacy: .public) visible=\(appKitVisible, privacy: .public) activeSpace=\(onActiveSpace, privacy: .public) occlusionVisible=\(occlusionVisible, privacy: .public)")
        guard let taskbarVisibilityJournal else { return }
        let state = TaskbarVisibilitySample(
            windowNumber: panel.windowNumber,
            primaryDisplay: currentScreen.flatMap { screen in screenProvider().first.map { $0.frame == screen.frame } },
            requestedVisible: panelsAreVisible,
            spaceState: visibilityState.rawValue, appKitVisible: appKitVisible,
            onActiveSpace: onActiveSpace, occlusionVisible: occlusionVisible,
            alpha: panel.alphaValue < 0.01 ? "transparent" : panel.alphaValue > 0.99 ? "opaque" : "fading"
        )
        taskbarVisibilityJournal.capture(state, event: event, source: source)
    }
}
#endif
