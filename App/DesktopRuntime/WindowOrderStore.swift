import Foundation

@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []

    private let orderKey = "deskmote.windowOrder"
    private let bootKey = "deskmote.windowOrderBootTime"
    private let bootSessionKey = "deskmote.windowOrderBootSession"
    private let applicationsKey = "deskmote.windowOrderApplications"
    private let retiredAbsenceKey = "deskmote.windowOrderRetiredAbsence"
    private let retiredElapsedKey = "deskmote.windowOrderRetiredElapsed"
    private let bootSession: UUID?

    private var absentSince: [String: TimeInterval] = [:]
    private static let rankRetentionGrace: TimeInterval = 5.0
    private static let retiredSeatPrefix = "tabgrp-retired-"

    private var stickyAppKeys: [String: String] = [:]
    private var unconfirmedSavedSeats: Set<String> = []

    private let defaults: UserDefaults
    private let elapsed: () -> TimeInterval
    #if DEBUG
    private let inventoryLog: WindowInventoryAnomalyLog
    #endif


    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         bootTimeProvider: () -> Int? = StripOrderStore.bootTimeSeconds,
         bootSessionProvider: () -> UUID? = StripOrderStore.bootSessionUUID,
         elapsed: @escaping () -> TimeInterval = StripOrderStore.elapsedTime,
         inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog()) {
        self.defaults = defaults
        self.elapsed = elapsed
        #if DEBUG
        self.inventoryLog = inventoryLog
        #endif
        bootSession = bootSessionProvider()

        guard let saved = defaults.stringArray(forKey: orderKey) else { return }
        let storedBoot = defaults.object(forKey: bootSessionKey)
        let storedSession = (storedBoot as? String).flatMap(UUID.init(uuidString:))
        let sameSession = bootSession != nil && storedSession == bootSession
        let legacy = storedBoot == nil
            && defaults.object(forKey: bootKey) != nil
            && bootTimeProvider() == defaults.integer(forKey: bootKey)
        guard sameSession || legacy else { return }

        liveOrder = saved
        stickyAppKeys = defaults.dictionary(forKey: applicationsKey) as? [String: String] ?? [:]
        let timestamp = elapsed()
        let retiredAbsences: [String: TimeInterval]
        if legacy {
            let wallNow = now()
            retiredAbsences = (defaults.dictionary(forKey: retiredAbsenceKey) ?? [:]).compactMapValues { value in
                (value as? Date).map { timestamp - wallNow.timeIntervalSince($0) }
            }
        } else {
            retiredAbsences = defaults.dictionary(forKey: retiredElapsedKey) as? [String: TimeInterval] ?? [:]
        }
        for id in saved where id.hasPrefix(Self.retiredSeatPrefix) {
            if let since = retiredAbsences[id], since >= 0, since <= timestamp {
                absentSince[id] = since
            } else {
                absentSince[id] = timestamp - Self.rankRetentionGrace - 1
            }
        }
        if legacy { liveOrder = orderRetainingRanks(at: timestamp) }
        unconfirmedSavedSeats = Set(liveOrder)
        if legacy { persistLiveOrder() }
    }

    func reconciled(current: [String], appKeyOf: [String: String] = [:]) -> [String] {
        let currentSet = Set(current)
        let memory = reconciliationMemory(current: currentSet, appKeyOf: appKeyOf, at: elapsed())
        let merged = memory.appKeys.merging(appKeyOf) { _, new in new }
        let anchors = memory.order.filter { !currentSet.contains($0) }
        let ordered = preservingApplicationOrder(StripOrdering.reconcile(
            remembered: memory.order,
            current: current + anchors,
            appKeyOf: merged
        ), appKeys: merged, rememberedOrder: memory.order, rememberedAppKeys: memory.appKeys)
        return ordered.filter(currentSet.contains)
    }

    private func reconciliationMemory(current: Set<String>, appKeyOf: [String: String], at timestamp: TimeInterval)
        -> (order: [String], appKeys: [String: String], displacedSeats: [String: String]) {
        let rememberedOrder = orderRetainingRanks(at: timestamp)
        guard !unconfirmedSavedSeats.isDisjoint(with: current) else { return (rememberedOrder, stickyAppKeys, [:]) }
        var appKeys = stickyAppKeys
        var displacedSeats: [String: String] = [:]
        let order = rememberedOrder.map { id in
            guard unconfirmedSavedSeats.contains(id), current.contains(id), let savedApp = stickyAppKeys[id],
                  let currentApp = appKeyOf[id], savedApp != currentApp else { return id }
            let anchor = Self.retiredSeatPrefix + UUID().uuidString
            appKeys[anchor] = appKeys.removeValue(forKey: id)
            displacedSeats[id] = anchor
            return anchor
        }
        return (order, appKeys, displacedSeats)
    }

    private func orderRetainingRanks(at now: TimeInterval) -> [String] {
        liveOrder.filter { id in
            absentSince[id].map { now - $0 <= Self.rankRetentionGrace } ?? true
        }
    }

    func sync(
        current: [String],
        appKeyOf: [String: String] = [:]
    ) {
        let now = elapsed()
        let currentSet = Set(current)
        let memory = reconciliationMemory(current: currentSet, appKeyOf: appKeyOf, at: now)
        let previousAppKeys = stickyAppKeys
        stickyAppKeys = memory.appKeys.merging(appKeyOf) { _, new in new }
        #if DEBUG
        let expiredMemory = absentSince.filter { now - $0.value > Self.rankRetentionGrace }
        #endif

        for (seat, anchor) in memory.displacedSeats {
            absentSince[anchor] = absentSince.removeValue(forKey: seat) ?? now
        }
        for id in current { absentSince.removeValue(forKey: id) }
        let anchors = memory.order.filter { !currentSet.contains($0) }
        for id in anchors where absentSince[id] == nil {
            absentSince[id] = now
        }
        let reconcileResult = StripOrdering.reconcileOrder(
            remembered: memory.order,
            current: current + anchors,
            appKeyOf: stickyAppKeys
        )
        let next = preservingApplicationOrder(reconcileResult.order, appKeys: stickyAppKeys,
                                              rememberedOrder: memory.order, rememberedAppKeys: memory.appKeys)
        absentSince = absentSince.filter { now - $0.value <= Self.rankRetentionGrace }
        #if DEBUG
        for (chipID, since) in expiredMemory {
            inventoryLog.record(.orderMemoryDropped(InventoryOrderMemoryDroppedPayload(
                chipID: chipID,
                appKey: stickyAppKeys[chipID],
                previousIndex: liveOrder.firstIndex(of: chipID) ?? -1,
                absentForMs: max(0, Int(((now - since) * 1_000).rounded()))
            )))
        }
        let currentSetForLog = Set(current)
        let visibleNextForLog = next.filter(currentSetForLog.contains)
        for placement in reconcileResult.placements where currentSetForLog.contains(placement.chipID) {
            inventoryLog.record(.orderChipPlaced(InventoryOrderChipPlacedPayload(
                chipID: placement.chipID,
                appKey: stickyAppKeys[placement.chipID],
                index: visibleNextForLog.firstIndex(of: placement.chipID) ?? placement.index,
                reason: placement.reason.rawValue
            )))
        }
        #endif
        if next != liveOrder || previousAppKeys != stickyAppKeys {
            if next != liveOrder { liveOrder = next }
            persistLiveOrder()
        }

        let aliveKeys = currentSet.union(Set(liveOrder))
        stickyAppKeys = stickyAppKeys.filter { aliveKeys.contains($0.key) }
        unconfirmedSavedSeats.subtract(current.filter { appKeyOf[$0] != nil })
        unconfirmedSavedSeats.formIntersection(liveOrder)
    }

    func reorderGroup(_ appKey: String, relativeTo targetAppKey: String, after: Bool, current: [String]) {
        let liveApps = Set(current.map { stickyAppKeys[$0] ?? $0 })
        guard appKey != targetAppKey, liveApps.contains(appKey), liveApps.contains(targetAppKey) else { return }
        let rememberedOrder = orderRetainingRanks(at: elapsed())
        let currentSet = Set(current)
        let anchors = rememberedOrder.filter { !currentSet.contains($0) }
        let base = StripOrdering.reconcile(remembered: rememberedOrder,
                                           current: current + anchors, appKeyOf: stickyAppKeys)
        let next = TaskbarGroupOrdering.moving(appKey, relativeTo: targetAppKey, after: after,
                                              order: base, appKeys: stickyAppKeys)
        if next != liveOrder { liveOrder = next; persistLiveOrder() }
    }

    private func preservingApplicationOrder(_ order: [String], appKeys: [String: String],
                                             rememberedOrder: [String],
                                             rememberedAppKeys: [String: String]) -> [String] {
        let retainedIDs = Set(order)
        var ranks: [String: Int] = [:]
        for id in rememberedOrder where retainedIDs.contains(id) {
            if let app = rememberedAppKeys[id], ranks[app] == nil { ranks[app] = ranks.count }
        }
        guard !ranks.isEmpty else { return order }
        return order.enumerated().sorted { lhs, rhs in
            let left = appKeys[lhs.element].flatMap { ranks[$0] } ?? .max
            let right = appKeys[rhs.element].flatMap { ranks[$0] } ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private func persistLiveOrder() {
        guard let bootSession else { return }
        let liveIDs = Set(liveOrder)
        let retiredAbsences = absentSince.filter { liveIDs.contains($0.key) && $0.key.hasPrefix(Self.retiredSeatPrefix) }
        defaults.set(retiredAbsences, forKey: retiredElapsedKey)
        defaults.set(StripOrdering.persistableLiveOrder(liveOrder), forKey: orderKey)
        defaults.set(stickyAppKeys.filter { liveIDs.contains($0.key) }, forKey: applicationsKey)
        defaults.set(bootSession.uuidString, forKey: bootSessionKey)
    }

    private nonisolated static func bootTimeSeconds() -> Int? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else { return nil }
        return Int(tv.tv_sec)
    }

    private nonisolated static func bootSessionUUID() -> UUID? {
        var buffer = [CChar](repeating: 0, count: 37)
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0) }
        guard status == 0, size == buffer.count else { return nil }
        let string = String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UUID(uuidString: string)
    }

    private nonisolated static func elapsedTime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
