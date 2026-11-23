import CoreGraphics
import Foundation

enum MinimizeHandoffTarget {
    struct ZOrderedWindow: Equatable {
        let pid: Int32
        let cgWindowID: CGWindowID
    }

    enum Verdict: Equatable {
        case switchTo(pid: Int32, cgWindowID: CGWindowID, windowID: WindowID)
        case siblingTakesOver(windowID: WindowID)
        case none
    }

    static func select(zOrder: [ZOrderedWindow], target: WindowRecord, snapshot: DockSnapshot) -> Verdict {
        var start = 0
        if let targetWID = target.cgWindowID,
           let index = zOrder.firstIndex(where: { $0.cgWindowID == targetWID && $0.pid == target.pid }) {
            start = index + 1
        }
        var recordsByWID: [CGWindowID: WindowRecord] = [:]
        for record in snapshot.windows.values {
            guard let wid = record.cgWindowID, record.id != target.id else { continue }
            recordsByWID[wid] = record
        }
        for entry in zOrder[start...] {
            guard let record = recordsByWID[entry.cgWindowID], record.pid == entry.pid else { continue }
            guard record.status != .minimized, record.status != .hidden else { continue }
            if record.pid == target.pid {
                return .siblingTakesOver(windowID: record.id)
            }
            return .switchTo(pid: entry.pid, cgWindowID: entry.cgWindowID, windowID: record.id)
        }
        return .none
    }
}
