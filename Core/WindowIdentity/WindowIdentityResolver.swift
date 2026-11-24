import Foundation

final class WindowIdentityEngine {
    private var memory = IdentityMemory()
    private let bridgeTTL: TimeInterval = 5.0
    private let inventoryBindingTTL: TimeInterval = 2.0
    private let inventoryCGFrameTolerance: CGFloat = 12
    private let rememberedSignatureTTL: TimeInterval = 6.0
    private let signatureStreakWindow: TimeInterval = 3.0
    private let rules = IdentityRuleEngine()

    func identify(observation: SystemObservation, snapshot: DockSnapshot? = nil) -> IdentityDecision {
        let title = rules.titleForMatching(observation.title, bundleIdentifier: observation.bundleIdentifier)
        guard let resolution = resolvedWindow(for: observation, canonicalWindowTitle: title, snapshot: snapshot) else {
            return IdentityDecision(
                kind: .ambiguous,
                windowID: WindowID(rawValue: "unconfirmed-ax-\(observation.pid)"),
                confidence: .low,
                reason: "insufficient-window-evidence",
                isConfirmed: false
            )
        }
        let id = resolution.windowID
        if observation.kind == .disappeared, let snapshot {
            guard let window = snapshot.windows[id], window.pid == observation.pid,
                  observation.cgWindowID == nil || window.cgWindowID == observation.cgWindowID else {
                return IdentityDecision(kind: .ambiguous, windowID: id, confidence: .low,
                                        reason: "unmatched-disappearance", isConfirmed: false)
            }
        }
        let priorConfirmation = memory.confirmationByWindowID[id]
        let hasNativeNumber = observation.cgWindowID != nil
        if priorConfirmation == false, hasNativeNumber,
           !confirmsProvisionalIdentity(resolution, observation: observation, snapshot: snapshot) {
            return IdentityDecision(kind: .ambiguous, windowID: id, confidence: .low,
                                    reason: "unconfirmed-native-identity", isConfirmed: false)
        }
        let isKnown = priorConfirmation != nil || snapshot?.windows[id] != nil
        let isConfirmed = resolution.isConfirmed && (priorConfirmation != false || hasNativeNumber)
        let kind: DecisionKind = isKnown ? .knownWindow : .newWindow
        memory.confirmationByWindowID[id] = isConfirmed
        memory.record(observation: observation, canonicalWindowTitle: title, resolvedID: id)
        return IdentityDecision(
            kind: kind,
            windowID: id,
            confidence: resolution.confidence,
            reason: resolution.reason,
            isConfirmed: isConfirmed
        )
    }

    func retire(windowID: WindowID) {
        memory.retire(windowID: windowID)
    }

    private func confirmsProvisionalIdentity(_ resolution: IdentityResolution, observation: SystemObservation,
                                            snapshot: DockSnapshot?) -> Bool {
        guard let number = observation.cgWindowID, number != 0, !observation.isMinimized,
              observation.kind != .disappeared, observation.kind != .minimized, observation.kind != .hidden else {
            return false
        }
        if resolution.hasExactBridge { return true }
        let key = CGWindowOwnerKey(pid: observation.pid, cgWindowID: number)
        if memory.windowIDByCGWindow[key] == resolution.windowID { return true }
        guard let window = snapshot?.windows[resolution.windowID] else { return false }
        return window.pid == observation.pid && window.cgWindowID == number && window.status != .closedPending
    }

    func bindConfirmedRestoration(observation: SystemObservation, of record: WindowRecord) -> Bool {
        guard observation.source == .coreGraphics, observation.kind != .disappeared,
              !observation.isMinimized, observation.pid == record.pid,
              let original = record.cgWindowID, let restored = observation.cgWindowID,
              original != restored, restored != 0 else { return false }
        return memory.rebindConfirmedCGWindow(record.id, pid: record.pid, original: original, restored: restored)
    }

    private func resolvedWindow(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution? {
        if let cgWindowID = observation.cgWindowID {
            let cgWindow = CGWindowOwnerKey(pid: observation.pid, cgWindowID: cgWindowID)
            if let bound = memory.windowIDByCGWindow[cgWindow] {
                return IdentityResolution(
                    windowID: bound,
                    confidence: .high,
                    reason: "cg-window-id-bound"
                )
            }

            if let snapshot, let bound = snapshot.windows.values.first(where: {
                $0.pid == observation.pid && $0.cgWindowID == cgWindowID && $0.status != .closedPending
                    && memory.permitsCGBinding($0.id, to: observation, snapshot: snapshot)
            }) {
                return IdentityResolution(windowID: bound.id, confidence: .high, reason: "cg-window-id-bound")
            }

            if let bridged = memory.lookupPendingBridge(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                now: observation.timestamp,
                ttl: bridgeTTL,
                snapshot: snapshot
            ) {
                return IdentityResolution(
                    windowID: bridged.windowID,
                    confidence: .medium,
                    reason: "restored-via-bridge",
                    hasExactBridge: bridged.hasExactFrame
                )
            }

            if let inventoryBound = memory.lookupInventoryBinding(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                now: observation.timestamp,
                ttl: inventoryBindingTTL,
                frameTolerance: inventoryCGFrameTolerance,
                snapshot: snapshot
            ) {
                return IdentityResolution(
                    windowID: inventoryBound,
                    confidence: .high,
                    reason: "cg-bound-to-inventory"
                )
            }

            if let retained = retainedWindowResolution(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                snapshot: snapshot
            ) {
                return retained
            }

            if let existing = existingLiveWindowResolution(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                snapshot: snapshot
            ) {
                return existing
            }

            let legacyID = WindowID(rawValue: "cg-\(cgWindowID)")
            let priorOwner = snapshot?.windows[legacyID]?.pid ?? memory.firstOwnerByCGWindowID[cgWindowID]
            let preferredID = priorOwner == nil || priorOwner == observation.pid
                ? legacyID
                : WindowID(rawValue: "cg-\(cgWindowID)-pid-\(observation.pid)")
            return IdentityResolution(
                windowID: memory.availableCGWindowID(preferredID, snapshot: snapshot),
                confidence: .high,
                reason: "cg-window-id"
            )
        }

        switch memory.lookupRememberedIdentity(
            for: observation,
            canonicalWindowTitle: canonicalWindowTitle,
            now: observation.timestamp,
            ttl: rememberedSignatureTTL
        ) {
        case let .matched(matched, matchKind):
            let signatureStreak = memory.recentObservationCount(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                now: observation.timestamp,
                window: signatureStreakWindow
            )
            let confidence: Confidence
            let reason: String
            if observation.isMinimized {
                confidence = .medium
                reason = "minimized-side-evidence"
            } else if matchKind == .frameOnly, observation.source == .accessibility {
                confidence = .medium
                reason = "frame-replay-accessibility"
            } else if observation.source == .accessibility, observation.bounds != nil {
                if signatureStreak >= 2 {
                    confidence = .high
                    reason = "signature-streak-accessibility"
                } else {
                    confidence = .medium
                    reason = "signature-replay-accessibility"
                }
            } else {
                confidence = .high
                reason = signatureStreak >= 2 ? "signature-streak" : "signature-replay"
            }
            return IdentityResolution(
                windowID: matched,
                confidence: confidence,
                reason: reason
            )
        case .conflict:
            return IdentityResolution(
                windowID: memory.makeTransientAXWindowID(pid: observation.pid),
                confidence: .low,
                reason: "conflicting-coarse-signature",
                isConfirmed: false
            )
        case .none:
            if let retained = retainedWindowResolution(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                snapshot: snapshot
            ) {
                return retained
            }

            if let existing = existingLiveWindowResolution(
                for: observation,
                canonicalWindowTitle: canonicalWindowTitle,
                snapshot: snapshot
            ) {
                return existing
            }

            let appTitle = normalizedWindowTitle(observation.appName)
            if observation.source == .accessibility,
               observation.bounds.map(WindowFrameMatchPolicy.isValid) != true,
               !FinderWindowRules.isFinder(bundleIdentifier: observation.bundleIdentifier),
               canonicalWindowTitle == nil || appTitle == nil || canonicalWindowTitle == appTitle {
                return nil
            }
            return IdentityResolution(
                windowID: memory.makeTransientAXWindowID(pid: observation.pid),
                confidence: .low,
                reason: observation.title ?? observation.appName ?? "unlabeled-window"
            )
        }
    }

    private func retainedWindowResolution(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution? {
        snapshotSeatResolution(
            for: observation,
            canonicalWindowTitle: canonicalWindowTitle,
            snapshot: snapshot,
            acceptsStatus: isRetainedSeatStatus,
            reasonPrefix: "retained-seat",
            allowsTitleOnly: true
        )
    }

    private func existingLiveWindowResolution(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution? {
        snapshotSeatResolution(
            for: observation,
            canonicalWindowTitle: canonicalWindowTitle,
            snapshot: snapshot,
            acceptsStatus: isLiveSeatStatus,
            reasonPrefix: "snapshot-seat",
            allowsTitleOnly: true
        )
    }

    private func snapshotSeatResolution(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        snapshot: DockSnapshot?,
        acceptsStatus: (WindowStatus) -> Bool,
        reasonPrefix: String,
        allowsTitleOnly: Bool
    ) -> IdentityResolution? {
        guard let snapshot else {
            return nil
        }

        let baseCandidates = snapshot.windows.values.filter { record in
            guard acceptsStatus(record.status) else { return false }
            guard record.id.rawValue.hasPrefix("app-") == false else { return false }
            guard record.pid == observation.pid else { return false }
            guard matchesApplication(observation: observation, record: record) else { return false }
            return memory.permitsCGBinding(record.id, to: observation, snapshot: snapshot)
        }
        let frameCandidates: [WindowRecord]
        if let observationBounds = observation.bounds {
            frameCandidates = baseCandidates.filter { record in
                guard let recordBounds = record.bounds else { return false }
                return WindowFrameMatchPolicy.areClose(observationBounds, recordBounds)
            }
        } else {
            frameCandidates = []
        }

        if let observationNormalizedTitle = canonicalWindowTitle {
            let titleAndFrameCandidates = frameCandidates.filter { record in
                normalizedRecordTitle(for: record) == observationNormalizedTitle
            }

            if titleAndFrameCandidates.count == 1, let match = titleAndFrameCandidates.first {
                return IdentityResolution(
                    windowID: match.id,
                    confidence: .high,
                    reason: "\(reasonPrefix)-title-frame"
                )
            }

            if titleAndFrameCandidates.count > 1 {
                return nil
            }
        }

        guard frameCandidates.count == 1, let match = frameCandidates.first else {
            if allowsTitleOnly, let observationNormalizedTitle = canonicalWindowTitle {
                let titleCandidates = baseCandidates.filter { record in
                    normalizedRecordTitle(for: record) == observationNormalizedTitle
                }

                if titleCandidates.count == 1, let titleMatch = titleCandidates.first {
                    return IdentityResolution(
                        windowID: titleMatch.id,
                        confidence: .medium,
                        reason: "\(reasonPrefix)-title"
                    )
                }
            }

            return nil
        }

        return IdentityResolution(
            windowID: match.id,
            confidence: .medium,
            reason: "\(reasonPrefix)-frame"
        )
    }

    private func isRetainedSeatStatus(_ status: WindowStatus) -> Bool {
        switch status {
        case .minimized, .hidden, .disappeared:
            return true
        case .active, .inactive, .closedPending:
            return false
        }
    }

    private func isLiveSeatStatus(_ status: WindowStatus) -> Bool {
        switch status {
        case .active, .inactive:
            return true
        case .minimized, .hidden, .disappeared, .closedPending:
            return false
        }
    }

    private func matchesApplication(observation: SystemObservation, record: WindowRecord) -> Bool {
        if let observationBundle = nonEmpty(observation.bundleIdentifier) {
            if let recordBundle = nonEmpty(record.bundleIdentifier) {
                return observationBundle == recordBundle
            }

            return record.appID.rawValue == observationBundle
        }

        if nonEmpty(record.bundleIdentifier) != nil {
            return false
        }

        if let appName = nonEmpty(observation.appName) {
            return record.appID.rawValue == appName || record.appID.rawValue == "pid-\(observation.pid)"
        }

        return record.appID.rawValue == "pid-\(observation.pid)"
    }

    private func normalizedRecordTitle(for record: WindowRecord) -> String? {
        rules.titleForMatching(record.title, bundleIdentifier: record.bundleIdentifier)
            ?? record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}

private struct CGWindowOwnerKey: Hashable {
    let pid: pid_t
    let cgWindowID: UInt32
}

private struct CoarseWindowSignature: Hashable {
    let pid: pid_t
    let title: String?
}

private enum WindowSignature: Hashable {
    case exact(CoarseWindowSignature, [Int]?)
    case coarse(CoarseWindowSignature)
    case frame(pid: pid_t, components: [Int]?)
}

private struct IdentityMemory {
    var confirmationByWindowID: [WindowID: Bool] = [:]
    var rememberedExactIDBySignature: [WindowSignature: TimedWindowID] = [:]
    var rememberedExactCandidatesBySignature: [WindowSignature: [WindowID: Date]] = [:]
    var rememberedExactIDsByCoarseSignature: [CoarseWindowSignature: [WindowSignature: TimedWindowID]] = [:]
    var rememberedCoarseCandidatesBySignature: [CoarseWindowSignature: [WindowID: Date]] = [:]
    var rememberedFrameCandidatesBySignature: [WindowSignature: [WindowID: Date]] = [:]
    var rememberedFramesByCoarseSignature: [CoarseWindowSignature: [WindowID: TimedFrame]] = [:]
    var recentInventoryCandidatesByCoarseSignature: [CoarseWindowSignature: [WindowID: TimedOptionalFrame]] = [:]
    var windowIDByCGWindow: [CGWindowOwnerKey: WindowID] = [:]
    var firstOwnerByCGWindowID: [UInt32: pid_t] = [:]
    private var cgWindowByWindowID: [WindowID: CGWindowOwnerKey] = [:]
    private var pendingBridges: [WindowID: PendingBridge] = [:]
    var recentObservationEvidenceBySignature: [WindowSignature: TimedObservationEvidence] = [:]
    var nextTransientAXSequence: UInt64 = 1
    private var nextCGSequence: UInt64 = 1

    private struct PendingBridge {
        let coarseSignature: CoarseWindowSignature
        let bounds: CGRect?
        let timestamp: Date
        let canConfirmIdentity: Bool
    }

    private let observationStreakDefaultWindow: TimeInterval = 3.0

    mutating func rebindConfirmedCGWindow(_ windowID: WindowID, pid: pid_t, original: UInt32, restored: UInt32) -> Bool {
        let originalKey = CGWindowOwnerKey(pid: pid, cgWindowID: original)
        let restoredKey = CGWindowOwnerKey(pid: pid, cgWindowID: restored)
        guard cgWindowByWindowID[windowID] == originalKey, windowIDByCGWindow[originalKey] == windowID,
              windowIDByCGWindow[restoredKey] == nil else { return false }
        windowIDByCGWindow.removeValue(forKey: originalKey)
        windowIDByCGWindow[restoredKey] = windowID
        cgWindowByWindowID[windowID] = restoredKey
        pendingBridges.removeValue(forKey: windowID)
        return true
    }

    mutating func record(observation: SystemObservation, canonicalWindowTitle: String?, resolvedID: WindowID) {
        let exactSignature = observation.exactSignature(canonicalWindowTitle: canonicalWindowTitle)
        let coarseSignature = observation.coarseSignature(canonicalWindowTitle: canonicalWindowTitle)

        let timed = TimedWindowID(id: resolvedID, timestamp: observation.timestamp)
        rememberedExactIDBySignature[exactSignature] = timed
        var exactCandidates = rememberedExactCandidatesBySignature[exactSignature] ?? [:]
        exactCandidates[resolvedID] = observation.timestamp
        rememberedExactCandidatesBySignature[exactSignature] = exactCandidates

        var exactEntries = rememberedExactIDsByCoarseSignature[coarseSignature] ?? [:]
        exactEntries[exactSignature] = timed
        rememberedExactIDsByCoarseSignature[coarseSignature] = exactEntries

        var coarseCandidates = rememberedCoarseCandidatesBySignature[coarseSignature] ?? [:]
        coarseCandidates[resolvedID] = observation.timestamp
        rememberedCoarseCandidatesBySignature[coarseSignature] = coarseCandidates

        if let frameSignature = observation.frameSignature() {
            var frameCandidates = rememberedFrameCandidatesBySignature[frameSignature] ?? [:]
            frameCandidates[resolvedID] = observation.timestamp
            rememberedFrameCandidatesBySignature[frameSignature] = frameCandidates
        }
        if let bounds = observation.bounds {
            var frameEntries = rememberedFramesByCoarseSignature[coarseSignature] ?? [:]
            frameEntries[resolvedID] = TimedFrame(bounds: bounds, timestamp: observation.timestamp)
            rememberedFramesByCoarseSignature[coarseSignature] = frameEntries
        }
        if observation.source == .appWindowInventory {
            var inventoryEntries = recentInventoryCandidatesByCoarseSignature[coarseSignature] ?? [:]
            inventoryEntries[resolvedID] = TimedOptionalFrame(
                bounds: observation.bounds,
                timestamp: observation.timestamp
            )
            recentInventoryCandidatesByCoarseSignature[coarseSignature] = inventoryEntries
        }
        if let cgWindowID = observation.cgWindowID {
            let cgWindow = CGWindowOwnerKey(pid: observation.pid, cgWindowID: cgWindowID)
            if let previous = cgWindowByWindowID.updateValue(cgWindow, forKey: resolvedID), previous != cgWindow {
                windowIDByCGWindow.removeValue(forKey: previous)
            }
            windowIDByCGWindow[cgWindow] = resolvedID
            if firstOwnerByCGWindowID[cgWindowID] == nil {
                firstOwnerByCGWindowID[cgWindowID] = observation.pid
            }
        }

        for signature in [exactSignature, .coarse(coarseSignature)] {
            recentObservationEvidenceBySignature[signature] = nextObservationEvidence(
                previous: recentObservationEvidenceBySignature[signature],
                timestamp: observation.timestamp
            )
        }

        switch observation.kind {
        case .disappeared, .minimized, .hidden:
            pendingBridges[resolvedID] = PendingBridge(coarseSignature: coarseSignature, bounds: observation.bounds,
                                                       timestamp: observation.timestamp,
                                                       canConfirmIdentity: observation.kind != .disappeared)
        case .restored, .appeared, .unchanged, .titleChanged, .unhidden:
            let isEarlyAXVisibility = observation.source == .accessibility && observation.kind == .unchanged
            if !observation.isMinimized, !isEarlyAXVisibility {
                pendingBridges.removeValue(forKey: resolvedID)
            }
        }
    }

    func lookupRememberedIdentity(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        now: Date,
        ttl: TimeInterval
    ) -> RememberedIdentityLookup {
        let exactSignature = observation.exactSignature(canonicalWindowTitle: canonicalWindowTitle)
        let exactMatches = freshExactCandidates(for: exactSignature, now: now, ttl: ttl)
        if exactMatches.count == 1 {
            return .matched(exactMatches[0], .coarse)
        }
        if exactMatches.count > 1 {
            return .conflict
        }

        let coarseSignature = observation.coarseSignature(canonicalWindowTitle: canonicalWindowTitle)
        if let tolerantMatches = freshTolerantFrameCandidates(
            for: observation,
            coarseSignature: coarseSignature,
            now: now,
            ttl: ttl
        ) {
            if tolerantMatches.count == 1 {
                return .matched(tolerantMatches[0], .frameOnly)
            }
            if tolerantMatches.count > 1 {
                return .conflict
            }
        }

        if observation.bounds != nil,
           hasConflictingFreshExactSignature(
            for: coarseSignature,
            excluding: exactSignature,
            now: now,
            ttl: ttl
           ) {
            return .conflict
        }

        let coarseMatches = freshCoarseCandidates(for: coarseSignature, now: now, ttl: ttl)
        if coarseMatches.count == 1 {
            return .matched(coarseMatches[0], .coarse)
        }
        if coarseMatches.count > 1 {
            return .conflict
        }

        if let frameSignature = observation.frameSignature() {
            let frameMatches = freshFrameCandidates(for: frameSignature, now: now, ttl: ttl)
            if frameMatches.count == 1 {
                return .matched(frameMatches[0], .frameOnly)
            }
            if frameMatches.count > 1 {
                return .conflict
            }
        }

        return .none
    }

    func lookupInventoryBinding(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        now: Date,
        ttl: TimeInterval,
        frameTolerance: CGFloat,
        snapshot: DockSnapshot?
    ) -> WindowID? {
        let coarseSignature = observation.coarseSignature(canonicalWindowTitle: canonicalWindowTitle)
        guard let candidates = recentInventoryCandidatesByCoarseSignature[coarseSignature] else {
            return nil
        }

        let freshCandidates = candidates.filter { windowID, candidate in
            now.timeIntervalSince(candidate.timestamp) <= ttl
                && permitsCGBinding(windowID, to: observation, snapshot: snapshot)
        }
        guard freshCandidates.isEmpty == false else { return nil }

        if let bounds = observation.bounds {
            let tightFrameMatches = freshCandidates.compactMap { windowID, candidate -> WindowID? in
                guard let candidateBounds = candidate.bounds else { return nil }
                return WindowFrameMatchPolicy.areClose(
                    bounds,
                    candidateBounds,
                    tolerance: frameTolerance
                ) ? windowID : nil
            }
            if tightFrameMatches.count == 1 {
                return tightFrameMatches[0]
            }
            if tightFrameMatches.count > 1 {
                return nil
            }
        }

        if freshCandidates.count == 1 {
            return freshCandidates.keys.first
        }

        return nil
    }

    func permitsCGBinding(_ windowID: WindowID, to observation: SystemObservation, snapshot: DockSnapshot?) -> Bool {
        guard let incomingNumber = observation.cgWindowID else { return true }
        if let lastNumber = cgWindowByWindowID[windowID]?.cgWindowID, lastNumber != incomingNumber { return false }
        if let currentNumber = snapshot?.windows[windowID]?.cgWindowID, currentNumber != incomingNumber { return false }
        return true
    }

    func lookupPendingBridge(for observation: SystemObservation, canonicalWindowTitle: String?, now: Date,
                             ttl: TimeInterval, snapshot: DockSnapshot?)
        -> (windowID: WindowID, hasExactFrame: Bool)? {
        guard !observation.isMinimized, observation.kind != .disappeared,
              observation.kind != .hidden, observation.kind != .minimized else { return nil }
        let explicitlyReturned = observation.kind == .restored || observation.kind == .unhidden
        let signature = observation.coarseSignature(canonicalWindowTitle: canonicalWindowTitle)
        let candidates = pendingBridges.filter { id, bridge in
            guard bridge.coarseSignature == signature, now.timeIntervalSince(bridge.timestamp) <= ttl,
                  snapshot?.windows[id]?.status != .closedPending else { return false }
            let compatibleNumber = permitsCGBinding(id, to: observation, snapshot: snapshot)
            guard compatibleNumber || explicitlyReturned else { return false }
            if let bounds = observation.bounds, let previous = bridge.bounds {
                return WindowFrameMatchPolicy.areClose(bounds, previous)
            }
            return compatibleNumber
        }
        guard candidates.count == 1, let (id, bridge) = candidates.first else { return nil }
        let hasExactFrame = observation.bounds.map {
            WindowFrameMatchPolicy.isValid($0) && $0 == bridge.bounds
        } ?? false
        return (id, bridge.canConfirmIdentity && hasExactFrame)
    }

    func recentObservationCount(
        for observation: SystemObservation,
        canonicalWindowTitle: String?,
        now: Date,
        window: TimeInterval
    ) -> Int {
        let exactSignature = observation.exactSignature(canonicalWindowTitle: canonicalWindowTitle)
        if observation.bounds != nil {
            let exactCount = freshObservationEvidenceCount(
                for: exactSignature,
                now: now,
                window: window
            )
            if exactCount > 0 {
                return exactCount
            }
        }

        return freshObservationEvidenceCount(
            for: .coarse(observation.coarseSignature(canonicalWindowTitle: canonicalWindowTitle)),
            now: now,
            window: window
        )
    }

    mutating func makeTransientAXWindowID(pid: Int32) -> WindowID {
        let id = WindowID(rawValue: "ax-\(pid)-transient-\(nextTransientAXSequence)")
        nextTransientAXSequence += 1
        return id
    }

    mutating func availableCGWindowID(_ preferred: WindowID, snapshot: DockSnapshot?) -> WindowID {
        var candidate = preferred
        while confirmationByWindowID[candidate] != nil || snapshot?.windows[candidate] != nil {
            candidate = WindowID(rawValue: "\(preferred.rawValue)-instance-\(nextCGSequence)")
            nextCGSequence += 1
        }
        return candidate
    }

    mutating func retire(windowID: WindowID) {
        let exactSignatures = rememberedExactIDBySignature.compactMap { signature, timed in
            timed.id == windowID ? signature : nil
        }
        let coarseSignatures = rememberedCoarseCandidatesBySignature.compactMap { signature, entries in
            entries.keys.contains(windowID) ? signature : nil
        }
        let frameSignatures = rememberedFrameCandidatesBySignature.compactMap { signature, entries in
            entries.keys.contains(windowID) ? signature : nil
        }

        confirmationByWindowID.removeValue(forKey: windowID)
        rememberedExactIDBySignature = rememberedExactIDBySignature.filter { $0.value.id != windowID }
        rememberedExactCandidatesBySignature = rememberedExactCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedExactIDsByCoarseSignature = rememberedExactIDsByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.value.id != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedCoarseCandidatesBySignature = rememberedCoarseCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedFramesByCoarseSignature = rememberedFramesByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        recentInventoryCandidatesByCoarseSignature = recentInventoryCandidatesByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        windowIDByCGWindow = windowIDByCGWindow.filter { $0.value != windowID }
        cgWindowByWindowID.removeValue(forKey: windowID)
        rememberedFrameCandidatesBySignature = rememberedFrameCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        pendingBridges.removeValue(forKey: windowID)
        for signature in Set(exactSignatures + coarseSignatures.map(WindowSignature.coarse) + frameSignatures) {
            recentObservationEvidenceBySignature.removeValue(forKey: signature)
        }
    }

    private func nextObservationEvidence(
        previous: TimedObservationEvidence?,
        timestamp: Date
    ) -> TimedObservationEvidence {
        guard let previous,
              timestamp.timeIntervalSince(previous.timestamp) <= observationStreakDefaultWindow else {
            return TimedObservationEvidence(count: 1, timestamp: timestamp)
        }

        return TimedObservationEvidence(count: previous.count + 1, timestamp: timestamp)
    }

    private func freshExactMatch(
        for signature: WindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> WindowID? {
        guard let match = rememberedExactIDBySignature[signature],
              now.timeIntervalSince(match.timestamp) <= ttl else {
            return nil
        }
        return match.id
    }

    private func freshExactCandidates(
        for signature: WindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedExactCandidatesBySignature[signature] else {
            if let single = freshExactMatch(for: signature, now: now, ttl: ttl) {
                return [single]
            }
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func hasConflictingFreshExactSignature(
        for coarseSignature: CoarseWindowSignature,
        excluding exactSignature: WindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard let exactEntries = rememberedExactIDsByCoarseSignature[coarseSignature] else {
            return false
        }

        for (candidateSignature, timed) in exactEntries {
            guard candidateSignature != exactSignature else { continue }
            if now.timeIntervalSince(timed.timestamp) <= ttl {
                return true
            }
        }

        return false
    }

    private func freshCoarseCandidates(
        for coarseSignature: CoarseWindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedCoarseCandidatesBySignature[coarseSignature] else {
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func freshFrameCandidates(
        for frameSignature: WindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedFrameCandidatesBySignature[frameSignature] else {
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func freshTolerantFrameCandidates(
        for observation: SystemObservation,
        coarseSignature: CoarseWindowSignature,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID]? {
        guard let bounds = observation.bounds,
              let entries = rememberedFramesByCoarseSignature[coarseSignature] else {
            return nil
        }

        return entries.compactMap { windowID, frame in
            guard now.timeIntervalSince(frame.timestamp) <= ttl else { return nil }
            return WindowFrameMatchPolicy.areClose(bounds, frame.bounds) ? windowID : nil
        }
    }

    private func freshObservationEvidenceCount(
        for signature: WindowSignature,
        now: Date,
        window: TimeInterval
    ) -> Int {
        guard let evidence = recentObservationEvidenceBySignature[signature],
              now.timeIntervalSince(evidence.timestamp) <= window else {
            return 0
        }
        return evidence.count
    }
}

private struct IdentityResolution {
    let windowID: WindowID
    let confidence: Confidence
    let reason: String
    var isConfirmed = true
    var hasExactBridge = false
}

private enum RememberedIdentityLookup {
    case matched(WindowID, RememberedMatchKind)
    case conflict
    case none
}

private enum RememberedMatchKind {
    case coarse
    case frameOnly
}

private struct TimedWindowID {
    let id: WindowID
    let timestamp: Date
}

private struct TimedFrame {
    let bounds: CGRect
    let timestamp: Date
}

private struct TimedOptionalFrame {
    let bounds: CGRect?
    let timestamp: Date
}

private struct TimedObservationEvidence {
    let count: Int
    let timestamp: Date
}

private extension SystemObservation {
    func exactSignature(canonicalWindowTitle: String?) -> WindowSignature {
        .exact(coarseSignature(canonicalWindowTitle: canonicalWindowTitle),
               bounds.flatMap(WindowFrameMatchPolicy.integralComponents(for:)))
    }

    func coarseSignature(canonicalWindowTitle: String?) -> CoarseWindowSignature {
        CoarseWindowSignature(pid: pid,
            title: canonicalWindowTitle ?? title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func frameSignature() -> WindowSignature? {
        guard let bounds else { return nil }
        return .frame(pid: pid, components: WindowFrameMatchPolicy.integralComponents(for: bounds))
    }
}
