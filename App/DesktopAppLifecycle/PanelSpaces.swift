import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
#if DEBUG
import os
#endif

extension PanelCoordinator {
    func repairAllSpacesMembershipIfNeeded(attempt: Int = 1) {
        guard Self.spaceMembershipRepairEnabled, !isSuspendedForPermissionLoss else { return }
        if attempt == 1 && spaceMembershipRepairInFlight { return }
        guard let dock = dockPanel else { return }
        let repairCandidates = allSpacesPanels.filter { panel in
            !(overlaySpaceHost?.isPinned(windowNumber: panel.windowNumber) ?? false)
        }
        guard !repairCandidates.isEmpty else {
            spaceMembershipRepairInFlight = false
            return
        }

        guard let screen = panelCurrentScreen(panel: dock),
              let uuid = DisplayIdentity.uuidString(for: screen),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else {
            spaceMembershipRepairInFlight = false
            return
        }
        let desktops = layout.orderedSpaceIDs.filter { !layout.fullscreenSpaceIDs.contains($0) }

        let broken = repairCandidates.filter { panel in
            guard let owned = WindowSpaceMembershipReader.spaceIDs(forWindowNumber: panel.windowNumber)
            else { return false }
            return !AllSpacesMembership.missingSpaceIDs(
                windowSpaceIDs: owned,
                desktopSpaceIDs: desktops
            ).isEmpty
        }
        guard !broken.isEmpty else {
            if attempt > 1 {
                #if DEBUG
                logger.info("[space-membership] repaired attempts=\(attempt - 1, privacy: .public)")
                #endif
            }
            spaceMembershipRepairInFlight = false
            return
        }
        guard AllSpacesMembership.shouldRetry(attempt: attempt - 1) else {
            #if DEBUG
            logger.error("[space-membership] give up after \(attempt - 1, privacy: .public) attempts")
            #endif
            spaceMembershipRepairInFlight = false
            return
        }

        spaceMembershipRepairInFlight = true
        PanelCollectionBehavior.restoreMembership(of: broken) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + AllSpacesMembership.verifyDelay) { [weak self] in
                self?.repairAllSpacesMembershipIfNeeded(attempt: attempt + 1)
            }
        }
    }


    func pinResidentPanelsIfNeeded() {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss else { return }
        let panels = allSpacesPanels
        guard !panels.isEmpty else { return }
        if !host.pin(panels: panels) {
            #if DEBUG
            let windowNumbers = panels.map(\.windowNumber)
            logger.error("[overlay-space] pin failed windows=\(windowNumbers, privacy: .public)")
            #endif
        }
    }

}
