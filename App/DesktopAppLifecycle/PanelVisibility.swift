import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
#if DEBUG
import os
#endif

extension PanelCoordinator {
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
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

    func reconcilePanelVisibility(source: String = "visibility-reconcile") {
        applyPanelVisibility(source: source)
    }

    func applyPanelVisibility(source: String = "visibility-reconcile") {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible && currentScreen != nil
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        taskbarPresenter?.setPanelVisible(shouldShow)
        if shouldShow {
            let fadeIn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            let fadingPanels = [dockPanel].compactMap { $0 }
            if fadeIn { for panel in fadingPanels { panel.alphaValue = 0 } }
            orderDockSurfaceFront(source: source)
            pinResidentPanelsIfNeeded()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for panel in fadingPanels { panel.animator().alphaValue = 1 }
                }
            }
            repairAllSpacesMembershipIfNeeded()
        } else {
            lastHideWasForFullscreen = visibilityState.hideReasons.contains(.fullscreen)
            orderDockSurfaceOut(source: source)
            for panel in [dockPanel] { panel?.alphaValue = 1 }
        }
    }

}

#if DEBUG
struct TaskbarVisibilitySample: Encodable, Equatable, Sendable {
    let windowNumber: Int
    let primaryDisplay: Bool?
    let requestedVisible: Bool
    let fullscreen: Bool
    let appKitVisible: Bool
    let onActiveSpace: Bool
    var windowServerOnScreen: Bool?
    let occlusionVisible: Bool
    let alpha: String
    let repairingMembership: Bool
}

@MainActor
final class TaskbarVisibilityJournal {
    private struct Line: Encodable, Sendable {
        let timestamp: String
        let revision: String?
        let event: String
        let source: String?
        let state: TaskbarVisibilitySample
        let foregroundPID: pid_t?
        let candidateWindowID: CGWindowID?
        let candidateOwnerPID: pid_t?
        let candidateLayer: Int?
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

    func capture(_ state: TaskbarVisibilitySample, event: String = "observed", source: String? = nil,
                 foregroundPID: pid_t? = nil, candidateWindowID: CGWindowID? = nil,
                 candidateOwnerPID: pid_t? = nil, candidateLayer: Int? = nil) {
        guard event != "observed" || state != previous else { return }
        previous = state
        let date = Date()
        let revision = self.revision
        let write = self.write
        Self.queue.submit {
            let clock = ISO8601DateFormatter()
            clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record = Line(timestamp: clock.string(from: date), revision: revision, event: event,
                              source: source, state: state, foregroundPID: foregroundPID,
                              candidateWindowID: candidateWindowID, candidateOwnerPID: candidateOwnerPID,
                              candidateLayer: candidateLayer)
            guard var data = try? JSONEncoder().encode(record) else { return }
            data.append(0x0A)
            write(data)
        }
    }

    func flush() { Self.queue.flush() }
}

extension PanelCoordinator {
    func startPanelVisibilitySampling() {
        guard taskbarVisibilityJournal != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPanelVisibility() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        panelVisibilitySampler = timer
    }

    func recordPanelVisibility(event: String = "observed", source: String? = nil) {
        guard let journal = taskbarVisibilityJournal, let panel = dockPanel else { return }
        let number = CGWindowID(exactly: panel.windowNumber).flatMap { $0 > 0 ? $0 : nil }
        let candidate = event == "order-out" ? diagnosticFullscreenCandidate : nil
        let windowIDs = [number, candidate].compactMap { $0 }
        let descriptions = windowIDs.isEmpty ? nil : NativeWindowSystem().windowDescriptions(for: windowIDs)
        let panelDescription = number.flatMap { id in
            descriptions?.first { nativeWindowNumber(in: $0) == id }
        }
        let candidateDescription = candidate.flatMap { id in
            descriptions?.first { nativeWindowNumber(in: $0) == id }
        }
        let primary = currentScreen.flatMap { screen in screenProvider().first.map { $0.frame == screen.frame } }
        let onScreen = (panelDescription?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
            ?? number.flatMap { id in
                NativeWindowSystem().windowInfo([.optionOnScreenOnly], kCGNullWindowID)?
                    .contains { nativeWindowNumber(in: $0) == id }
            }
        let state = TaskbarVisibilitySample(
            windowNumber: panel.windowNumber, primaryDisplay: primary,
            requestedVisible: panelsAreVisible && !isSuspendedForPermissionLoss,
            fullscreen: visibilityState.hideReasons.contains(.fullscreen), appKitVisible: panel.isVisible,
            onActiveSpace: panel.isOnActiveSpace,
            windowServerOnScreen: onScreen,
            occlusionVisible: panel.occlusionState.contains(.visible),
            alpha: panel.alphaValue < 0.01 ? "transparent" : panel.alphaValue > 0.99 ? "opaque" : "fading",
            repairingMembership: spaceMembershipRepairInFlight
        )
        journal.capture(state, event: event, source: source, foregroundPID: lastActiveApplicationPID,
                        candidateWindowID: candidate,
                        candidateOwnerPID: (candidateDescription?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                        candidateLayer: (candidateDescription?[kCGWindowLayer as String] as? NSNumber)?.intValue)
    }
}
#endif
