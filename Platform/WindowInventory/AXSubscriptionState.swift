import ApplicationServices
import CoreGraphics
import Foundation

enum WindowSubscriptionItem: Int, CaseIterable, Comparable {
    case destroyed
    case miniaturized
    case deminiaturized
    case titleChanged

    var isCritical: Bool { self == .destroyed || self == .miniaturized }

    #if DEBUG
    var logName: String {
        switch self {
        case .destroyed: return "destroyed"
        case .miniaturized: return "miniaturized"
        case .deminiaturized: return "deminiaturized"
        case .titleChanged: return "titleChanged"
        }
    }
    #endif

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum WindowSubscriptionItemState: Equatable {
    case pending
    case done
    case unsupported
    case failed
}

enum WindowSubscriptionAttemptKind: String, Codable, Equatable {
    case initial
    case renewal
    case retry
}

enum WindowSubscriptionStop: String, Codable, Equatable {
    case completed
    case timeoutSkippedRest
    case retryTimeLimit
    case dead
}

struct WindowSubscriptionLedger<Element: Hashable> {
    struct Record {
        var element: Element
        var instanceID: UInt64
        var items: [WindowSubscriptionItem: WindowSubscriptionItemState]
        var step: Int
        var retryAt: TimeInterval
        var isDead: Bool
    }

    static var backoff: [TimeInterval] { [1, 5, 15, 60] }

    private(set) var records: [CGWindowID: Record] = [:]
    private var cgIDByElement: [Element: CGWindowID] = [:]
    private let instanceIDs: WindowSubscriptionInstanceIDs

    init(instanceIDs: WindowSubscriptionInstanceIDs = WindowSubscriptionInstanceIDs()) {
        self.instanceIDs = instanceIDs
    }

    func attemptKind(cgWindowID: CGWindowID, element: Element, now: TimeInterval) -> WindowSubscriptionAttemptKind? {
        guard let record = records[cgWindowID] else { return .initial }
        if record.element != element { return .renewal }
        if record.isDead || Self.isCovered(record) { return nil }
        return now >= record.retryAt ? .retry : nil
    }

    func isCovered(cgWindowID: CGWindowID) -> Bool {
        records[cgWindowID].map(Self.isCovered) ?? false
    }

    func record(for cgWindowID: CGWindowID) -> Record? { records[cgWindowID] }

    func cgWindowID(forElement element: Element) -> CGWindowID? { cgIDByElement[element] }

    mutating func rebind(element: Element, to cgWindowID: CGWindowID) -> Record? {
        guard let previousID = cgIDByElement[element], previousID != cgWindowID,
              let record = records[previousID] else { return nil }
        return replaceRecord(record, for: cgWindowID)
    }

    mutating func beginAttempt(
        cgWindowID: CGWindowID,
        element: Element,
        kind: WindowSubscriptionAttemptKind,
        now: TimeInterval
    ) -> (instanceID: UInt64, previousInstanceID: UInt64?, items: [WindowSubscriptionItem]) {
        var previousInstanceID: UInt64?
        if kind != .retry || records[cgWindowID] == nil {
            let record = Record(
                element: element,
                instanceID: instanceIDs.next(),
                items: Dictionary(uniqueKeysWithValues: WindowSubscriptionItem.allCases.map { ($0, .pending) }),
                step: 0,
                retryAt: now,
                isDead: false
            )
            previousInstanceID = replaceRecord(record, for: cgWindowID)?.instanceID
        }
        let record = records[cgWindowID]!
        let items = WindowSubscriptionItem.allCases.filter {
            let state = record.items[$0] ?? .pending
            return state == .pending || state == .failed
        }
        return (record.instanceID, previousInstanceID, items)
    }

    mutating func record(cgWindowID: CGWindowID, item: WindowSubscriptionItem, result: AXError) {
        guard records[cgWindowID] != nil else { return }
        switch result {
        case .success, .notificationAlreadyRegistered:
            records[cgWindowID]?.items[item] = .done
        case .notificationUnsupported:
            records[cgWindowID]?.items[item] = .unsupported
        case .invalidUIElement:
            records[cgWindowID]?.items[item] = .failed
            records[cgWindowID]?.isDead = true
        default:
            records[cgWindowID]?.items[item] = .failed
        }
    }

    mutating func finishAttempt(cgWindowID: CGWindowID, now: TimeInterval, sawFailure: Bool) {
        guard var record = records[cgWindowID] else { return }
        if record.isDead || Self.isCovered(record) {
            record.step = 0
            record.retryAt = now
        } else if sawFailure {
            let delays = Self.backoff
            record.retryAt = now + delays[min(record.step, delays.count - 1)]
            record.step += 1
        } else {
            record.retryAt = now
        }
        records[cgWindowID] = record
    }

    mutating func noteDestroyed(element: Element) -> (cgWindowID: CGWindowID, removedInstanceID: UInt64?)? {
        guard let cgWindowID = cgIDByElement.removeValue(forKey: element) else { return nil }
        guard let record = records[cgWindowID], record.element == element else {
            return (cgWindowID, nil)
        }
        records.removeValue(forKey: cgWindowID)
        return (cgWindowID, record.instanceID)
    }

    mutating func retain(keep: Set<CGWindowID>) -> [(cgWindowID: CGWindowID, instanceID: UInt64)] {
        #if DEBUG
        var dropped: [(cgWindowID: CGWindowID, instanceID: UInt64)] = []
        #endif
        for (cgWindowID, record) in records where !keep.contains(cgWindowID) {
            #if DEBUG
            dropped.append((cgWindowID, record.instanceID))
            #endif
            records.removeValue(forKey: cgWindowID)
            cgIDByElement.removeValue(forKey: record.element)
        }
        #if DEBUG
        return dropped.sorted { $0.cgWindowID < $1.cgWindowID }
        #else
        return []
        #endif
    }

    mutating func removeAll() {
        records.removeAll()
        cgIDByElement.removeAll()
    }

    private mutating func replaceRecord(_ record: Record, for cgWindowID: CGWindowID) -> Record? {
        if let previousID = cgIDByElement[record.element], previousID != cgWindowID {
            records.removeValue(forKey: previousID)
        }
        let replaced = records.updateValue(record, forKey: cgWindowID)
        if let replaced { cgIDByElement.removeValue(forKey: replaced.element) }
        cgIDByElement[record.element] = cgWindowID
        return replaced
    }

    private static func isCovered(_ record: Record) -> Bool {
        !record.isDead && record.items.values.allSatisfy { $0 == .done || $0 == .unsupported }
    }
}

enum WindowSubscriptionAttemptPolicy {
    enum Step: Equatable {
        case send
        case skip
        case stop(WindowSubscriptionStop?)
    }

    static func step(
        item: WindowSubscriptionItem,
        index: Int,
        sawTimeout: Bool,
        elapsed: TimeInterval,
        timeLimit: TimeInterval?
    ) -> Step {
        if let timeLimit {
            if sawTimeout { return .stop(nil) }
            if index > 0, elapsed > timeLimit { return .stop(.retryTimeLimit) }
            return .send
        }
        if sawTimeout, !item.isCritical { return .skip }
        return .send
    }
}

final class WindowSubscriptionInstanceIDs {
    private var last: UInt64 = 0

    init() {}

    func next() -> UInt64 {
        last &+= 1
        return last
    }
}

struct WindowSubscriptionRetryCandidate<Element: Hashable>: Equatable {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let element: Element
    let retryAt: TimeInterval
}

enum WindowSubscriptionRetryScheduler {
    static func pick<Element>(
        _ candidates: [WindowSubscriptionRetryCandidate<Element>],
        isValid: (WindowSubscriptionRetryCandidate<Element>) -> Bool
    ) -> (picked: WindowSubscriptionRetryCandidate<Element>?, skippedInvalid: Int) {
        let ordered = candidates.sorted {
            if $0.retryAt != $1.retryAt { return $0.retryAt < $1.retryAt }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.cgWindowID < $1.cgWindowID
        }
        var skipped = 0
        for candidate in ordered {
            if isValid(candidate) { return (candidate, skipped) }
            skipped += 1
        }
        return (nil, skipped)
    }
}
