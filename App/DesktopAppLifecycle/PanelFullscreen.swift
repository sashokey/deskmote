import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
#if DEBUG
import os
#endif

struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let displayWindowServerFrame: CGRect?
}

struct FullscreenDisplay: Equatable {
    let frame: CGRect
    let uuid: String?
}

struct FullscreenCGConfirmation {
    let display: FullscreenDisplay
    let overlayWindowID: CGWindowID?
}

extension PanelCoordinator {

    func setupFullscreenMonitor(
        readAX: @escaping @Sendable (pid_t) -> FullscreenAXObservation = { PanelCoordinator.readFullscreenAXObservation(pid: $0) }
    ) {
        guard !isSuspendedForPermissionLoss, fullscreenProbeWorker == nil else { return }
        let readsSpaces = fullscreenSLSVerdictEnabled
        let readSpace = fullscreenSpaceProvider ?? { uuid in
            guard let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
            return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
        }
        fullscreenProbeWorker = FullscreenProbeWorker(
            read: { request in
                let observation = request.sharedRead?.observation(for: request.pid)
                    ?? request.pid.map(readAX) ?? .unknown
                return observation.probe(on: request.screenFrame)
            },
            readSpace: { request in
                guard readsSpaces else { return nil }
                return readSpace(request.displayUUID ?? "Main")
            },
            deliver: { [weak self] request, result in self?.receiveFullscreenProbe(result, request: request) }
        )
    }

    func handleSpaceChange(sharedRead: FullscreenReadBatch? = nil) {
        guard !isSuspendedForPermissionLoss else { return }
        let wasVisible = panelsAreVisible
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        if let screen = currentPanelScreenCGFrame(),
           fixedUnitDisplayUUID.map({ panelMatchesDisplayUUID($0) }) ?? true,
           let evidence = cgScreenEvidence(on: screen, sharedRead: sharedRead, isImmediateSpaceChange: true) {
            let isFullscreen = evidence.state == .fullscreen
            let confirmation = isFullscreen ? FullscreenCGConfirmation(
                display: FullscreenDisplay(frame: screen, uuid: currentPanelDisplayUUID()),
                overlayWindowID: evidence.overlayWindowID
            ) : nil
            applyFullscreenVisibility(isFullscreen, source: "space-cg", expectedSpaceHoldGeneration: spaceHoldGeneration,
                                      cgConfirmation: confirmation)
            if isFullscreen {
                reconcileOverlayWindowWatch(overlayWindowID: evidence.overlayWindowID)
            }
        }
        if !wasVisible || panelsAreVisible { taskbarView?.taskbarContent.prepareForHiding() }
        triggerAsyncFullscreenCheck(source: "space-ax", sharedRead: sharedRead)
        repairAllSpacesMembershipIfNeeded()
    }

    func handleAppActivated(pid: pid_t?, sharedRead: FullscreenReadBatch? = nil) {
        guard !isSuspendedForPermissionLoss else { return }
        lastActiveApplicationPID = pid
        beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        triggerAsyncFullscreenCheck(source: "app-activation-ax", sharedRead: sharedRead)
    }

    nonisolated static func captureFullscreenCGWindows() -> [[String: Any]]? {
        NativeWindowSystem().windowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    }

    private func cgScreenEvidence(
        on screen: CGRect, sharedRead: FullscreenReadBatch?, isImmediateSpaceChange: Bool = false
    ) -> FullscreenCGEvidence? {
        guard !screen.isEmpty, !screen.isInfinite else { return nil }
        let capture = fullscreenCGWindowsProvider ?? Self.captureFullscreenCGWindows
        let windows = if let sharedRead {
            sharedRead.cgWindows(isImmediateSpaceChange: isImmediateSpaceChange, fallback: capture)
        } else {
            capture()
        }
        guard let windows else { return nil }
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let systemSurfaceBundleIDs = DockWindowEligibilityPolicy.systemSurfaceBundleIdentifiers.union(["com.apple.screencaptureui"])
        let systemSurfacePIDs = Set(systemSurfaceBundleIDs
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier))
        return FullscreenCGEvidence.classify(
            windows, on: screen, excludingPID: ProcessInfo.processInfo.processIdentifier, dockPID: dockPID,
            systemSurfacePIDs: systemSurfacePIDs)
    }

    func triggerAsyncFullscreenCheck(
        source: String = "ax",
        sharedRead: FullscreenReadBatch? = nil
    ) {
        guard !isSuspendedForPermissionLoss, let displayWindowServerFrame = currentPanelScreenCGFrame() else { return }
        let frontPID = lastActiveApplicationPID
        if let hold = fullscreenSpaceHold, fullscreenSpaceHoldTimer == nil,
           (hold.pid != frontPID || hold.displayWindowServerFrame != displayWindowServerFrame) {
            finishFullscreenSpaceHold(generation: hold.generation)
        }
        fullscreenProbeGeneration &+= 1
        let holdGeneration = fullscreenSpaceHold?.generation
        fullscreenProbeWorker?.request(FullscreenProbeRequest(
            pid: frontPID, screenFrame: displayWindowServerFrame, generation: fullscreenProbeGeneration,
            spaceGeneration: holdGeneration, finalConfirmation: holdGeneration != nil && fullscreenSpaceHoldTimer == nil,
            source: source, displayUUID: currentPanelDisplayUUID(), sharedRead: sharedRead
        ))
    }

    func receiveFullscreenProbe(_ probe: FullscreenAXProbe, request: FullscreenProbeRequest) {
        guard !isSuspendedForPermissionLoss, request.generation == fullscreenProbeGeneration,
              request.spaceGeneration == fullscreenSpaceHold?.generation,
              request.screenFrame == currentPanelScreenCGFrame(),
              panelMatchesDisplayUUID(request.displayUUID) else { return }
        let display = FullscreenDisplay(frame: request.screenFrame, uuid: request.displayUUID)
        let space = fullscreenSLSVerdictEnabled ? probe.spaceVerdict : nil
        let wasFullscreen = visibilityState.hideReasons.contains(.fullscreen)
        let mayConfirmWindowed = request.spaceGeneration == nil || request.finalConfirmation
        let verdict: Bool
        let suffix: String
        var cgConfirmation: FullscreenCGConfirmation?
        var overlayWindowID = probe.overlayWindowID
        if probe.verdict == .fullscreen || space == true {
            verdict = true
            suffix = probe.verdict == .fullscreen ? "" : "-sls"
            if probe.verdict == .fullscreen, let overlayWindowID,
               let previous = fullscreenCGConfirmation, previous.display == display,
               previous.overlayWindowID == overlayWindowID {
                cgConfirmation = previous
            }
        } else {
            let canResolveUnknown = space == false || (!fullscreenSLSVerdictEnabled && fullscreenCGConfirmation?.display == display)
            let needsCGEvidence = probe.verdict == .notOnThisScreen
                || (wasFullscreen && mayConfirmWindowed && (probe.verdict == .windowed || canResolveUnknown))
            let evidence = needsCGEvidence ? cgScreenEvidence(on: request.screenFrame, sharedRead: request.sharedRead) : nil
            if let evidence, evidence.state == .fullscreen {
                verdict = true
                suffix = "-cg"
                cgConfirmation = FullscreenCGConfirmation(display: display, overlayWindowID: evidence.overlayWindowID)
                overlayWindowID = evidence.overlayWindowID
            } else {
                switch probe.verdict {
                case .unknown:
                    guard canResolveUnknown, wasFullscreen, mayConfirmWindowed,
                          evidence?.state == .windowed || (space == false && evidence?.state == .splitOrTiled) else { return }
                case .notOnThisScreen:
                    guard space == false || evidence?.state == .windowed else { return }
                case .windowed:
                    if fullscreenSLSVerdictEnabled, space == nil, wasFullscreen, !request.screenFrame.isEmpty,
                       evidence?.state != .windowed { return }
                case .fullscreen:
                    return
                }
                verdict = false
                suffix = space == false ? "-sls" : evidence == nil ? "" : "-cg"
            }
        }
        applyFullscreenVisibility(verdict, source: request.source + suffix, expectedSpaceHoldGeneration: request.spaceGeneration,
                                  isFinalSpaceHoldWindowedConfirmation: request.finalConfirmation,
                                  cgConfirmation: cgConfirmation, overlayCandidate: overlayWindowID)
        if overlayWindowID != nil || !visibilityState.hideReasons.contains(.fullscreen) {
            reconcileOverlayWindowWatch(overlayWindowID: overlayWindowID)
        }
    }

    func windowGeometryChanged(sharedRead: FullscreenReadBatch? = nil) {
        guard !isSuspendedForPermissionLoss else { return }
        triggerAsyncFullscreenCheck(source: "window-geometry-ax", sharedRead: sharedRead)
    }

    private func reconcileOverlayWindowWatch(overlayWindowID: CGWindowID?) {
        guard let overlayWindowID, visibilityState.hideReasons.contains(.fullscreen) else {
            endOverlayWindowWatch()
            return
        }
        beginOverlayWindowWatch(windowID: overlayWindowID)
    }

    private func beginOverlayWindowWatch(windowID: CGWindowID) {
        guard Self.overlayWindowWatchEnabled else { return }
        if overlayWindowWatchID == windowID, overlayWindowWatchTimer != nil { return }
        endOverlayWindowWatch()
        overlayWindowWatchID = windowID
        let timer = Timer(timeInterval: OverlayWindowWatch.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlayWindowWatchTick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        overlayWindowWatchTimer = timer
    }

    func endOverlayWindowWatch() {
        overlayWindowWatchTimer?.invalidate()
        overlayWindowWatchTimer = nil
        overlayWindowWatchID = nil
    }

    private func overlayWindowWatchTick() {
        guard let windowID = overlayWindowWatchID,
              visibilityState.hideReasons.contains(.fullscreen),
              let displayWindowServerFrame = currentPanelScreenCGFrame() else {
            endOverlayWindowWatch()
            return
        }
        let read = fullscreenCGWindowObservationProvider ?? Self.cgWindowObservation(of:)
        let observation = read(windowID)
        guard OverlayWindowWatch.shouldRecheck(
            isOnscreen: observation?.isOnscreen,
            bounds: observation?.bounds,
            displayWindowServerFrame: displayWindowServerFrame
        ) else { return }
        endOverlayWindowWatch()
        triggerAsyncFullscreenCheck(source: "overlay-gone-ax")
    }

    nonisolated private static func cgWindowObservation(of windowID: CGWindowID) -> (isOnscreen: Bool, bounds: CGRect?)? {
        guard let info = NativeWindowSystem().windowDescriptions(for: [windowID])?.first else { return nil }
        let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return (isOnscreen, bounds)
    }

    func reconcileFullscreenState(sharedRead: FullscreenReadBatch? = nil) {
        triggerAsyncFullscreenCheck(source: "periodic-ax", sharedRead: sharedRead)
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        cgConfirmation: FullscreenCGConfirmation? = nil,
        overlayCandidate: CGWindowID? = nil
    ) {
        guard !isSuspendedForPermissionLoss else { return }
        switch FullscreenSpaceHoldDecision.disposition(
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale, .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        fullscreenCGConfirmation = cgConfirmation
        visibilityState.setFullscreen(isFullscreen)
        #if DEBUG
        diagnosticFullscreenCandidate = isFullscreen ? overlayCandidate ?? cgConfirmation?.overlayWindowID : nil
        #endif
        reconcilePanelVisibility(source: source)
        #if DEBUG
        logFullscreenVerdict(isFullscreen, source: source)
        #endif
    }

    #if DEBUG
    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }
    #endif

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard visibilityState.hideReasons.contains(.fullscreen) else {
            return nil
        }

        let displayWindowServerFrame = currentPanelScreenCGFrame()
        let hold: FullscreenSpaceHold
        if let current = fullscreenSpaceHold,
           current.pid == pid,
           current.displayWindowServerFrame == displayWindowServerFrame {
            hold = current
        } else {
            fullscreenSpaceHoldGeneration &+= 1
            fullscreenProbeGeneration &+= 1
            hold = FullscreenSpaceHold(
                generation: fullscreenSpaceHoldGeneration,
                pid: pid,
                displayWindowServerFrame: displayWindowServerFrame
            )
            fullscreenSpaceHold = hold
        }
        scheduleFullscreenSpaceHoldConfirmation(
            generation: hold.generation,
            after: confirmationDelay
        )
        return hold.generation
    }

    private func scheduleFullscreenSpaceHoldConfirmation(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        fullscreenSpaceHoldTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.confirmFullscreenSpaceHoldWindowed(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceHoldTimer = timer
    }

    private func confirmFullscreenSpaceHoldWindowed(generation: UInt64) {
        guard let hold = fullscreenSpaceHold,
              hold.generation == generation else {
            return
        }
        guard hold.pid == lastActiveApplicationPID,
              hold.displayWindowServerFrame == currentPanelScreenCGFrame() else {
            finishFullscreenSpaceHold(generation: generation)
            triggerAsyncFullscreenCheck()
            return
        }
        fullscreenSpaceHoldTimer = nil
        triggerAsyncFullscreenCheck(source: "space-hold-final-ax")
    }

    private func finishFullscreenSpaceHold(generation: UInt64) {
        guard fullscreenSpaceHold?.generation == generation else { return }
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        if let fullscreenFrameProvider { return fullscreenFrameProvider() }
        guard let panel = dockPanel else { return nil }
        return panelCurrentScreen(panel: panel).map(Self.toCGRect)
    }

    nonisolated static func readFullscreenAXObservation(
        pid: pid_t,
        reader: AXWindowReader = AXWindowReader(),
        system: any WindowSystemAccess = NativeWindowSystem()
    ) -> FullscreenAXObservation {
        let accessibility = reader.accessibility
        let appElement = accessibility.application(pid)
        _ = accessibility.setTimeout(appElement, 0.1)
        let (focusedError, rawFocused) = accessibility.copy(appElement, kAXFocusedWindowAttribute as CFString)
        guard focusedError == .success, let rawFocused, CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focused = rawFocused as! AXUIElement
        guard accessibility.pid(focused) == pid else { return .unknown }
        _ = accessibility.setTimeout(focused, 0.1)
        guard let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1),
              role == kAXWindowRole else {
            return .unknown
        }
        let (fullscreenError, rawFullscreen) = accessibility.copy(focused, "AXFullScreen" as CFString)
        guard fullscreenError == .success || fullscreenError == .attributeUnsupported || fullscreenError == .noValue else {
            return .unknown
        }
        guard fullscreenError != .success || rawFullscreen is NSNumber else {
            return .unknown
        }
        let isAXFullscreen = (rawFullscreen as? NSNumber)?.boolValue ?? false
        guard let windowFrame = reader.frame(of: focused, maxAttempts: 1) else {
            return .unknown
        }
        let cgWindowID = isAXFullscreen ? nil : reader.cgWindowID(for: focused, maxAttempts: 1)
        let windowLayer = cgWindowID.flatMap { Self.cgWindowLayer(of: $0, system: system) }

        return .window(role: role, isFullscreen: isAXFullscreen, frame: windowFrame, id: cgWindowID, layer: windowLayer)
    }

    nonisolated private static func cgWindowLayer(of windowID: CGWindowID, system: any WindowSystemAccess) -> Int? {
        guard let info = system.windowDescriptions(for: [windowID])?.first else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private func currentPanelDisplayUUID() -> String? {
        fixedUnitDisplayUUID ?? physicalPanelDisplayUUID()
    }

    private func panelMatchesDisplayUUID(_ expectedUUID: String?) -> Bool {
        if let fixedUnitDisplayUUID {
            guard fixedUnitDisplayUUID == expectedUUID else { return false }
            if dockPanel == nil, fullscreenDisplayUUIDProvider == nil { return true }
        }
        return physicalPanelDisplayUUID() == expectedUUID
    }

    private func physicalPanelDisplayUUID() -> String? {
        if let fullscreenDisplayUUIDProvider { return fullscreenDisplayUUIDProvider() }
        return currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) }
    }
}
