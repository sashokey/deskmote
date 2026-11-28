import ApplicationServices
import CoreGraphics
import Foundation

final class AXElementCache: @unchecked Sendable {
    static let shared = AXElementCache()


    struct Key: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    private let lock = NSLock()
    private var elements: [Key: AXUIElement] = [:]

    init() {}

    func store(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement) {
        guard pid > 0, cgWindowID != 0 else { return }
        lock.lock()
        elements[Key(pid: pid, cgWindowID: cgWindowID)] = element
        lock.unlock()
    }

    func element(pid: pid_t, cgWindowID: CGWindowID) -> AXUIElement? {
        guard pid > 0, cgWindowID != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return elements[Key(pid: pid, cgWindowID: cgWindowID)]
    }

    func remove(pid: pid_t, cgWindowID: CGWindowID, matching expected: AXUIElement? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(pid: pid, cgWindowID: cgWindowID)
        if let expected, let current = elements[key], !CFEqual(current, expected) { return }
        elements.removeValue(forKey: key)
    }

    func removeAll(pid: pid_t) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid }
        lock.unlock()
    }

    func retain(pid: pid_t, liveCGWindowIDs: Set<CGWindowID>) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid || liveCGWindowIDs.contains($0.key.cgWindowID) }
        lock.unlock()
    }

    #if DESKMOTE_TEST
    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    func containsForTesting(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        element(pid: pid, cgWindowID: cgWindowID) != nil
    }
    #endif
}
