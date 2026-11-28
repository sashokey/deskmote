import AppKit
import Foundation
import Synchronization

@MainActor
func visibleText(in view: NSView) -> [String] {
    visibleTextFields(in: view).map(\.stringValue)
}

@MainActor
private func visibleTextFields(in view: NSView) -> [NSTextField] {
    guard !view.isHidden else { return [] }
    return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { visibleTextFields(in: $0) }
}

let journalAppKitTests = [
    TestCase(name: "Journal dashboard renders a dated time to full and preserves the title") {
        try MainActor.assumeIsolated {
            let count = Mutex(0)
            let lines = [journalReading(0, "AC", 70), journalReading(1200, "AC", 80)]
            let monitor = BatteryMonitor(readJournal: {
                count.withLock { $0 += 1 }
                return lines.joined(separator: "\n")
            }, readWatts: { PowerWatts(battery: 25, input: 30) })
            let controller = BatteryWindowController(monitor: monitor)
            try expect(controller.window?.title == "Show Battery Runtime Estimates", "matches the existing menu")
            try expect(count.withLock { $0 == 0 }, "offscreen construction does not load history")
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains("Recorded charging") }), "toolbar result becomes visible")
            let first = visibleText(in: controller.dashboard)
            for text in ["Time to Full", "0% → 100%", "Recorded charging", "80%", "40m", "3h 20m", "20m", "Current Session"] {
                try expect(first.contains(text), "charging window includes \(text), got \(first)")
            }
            try expect(first.contains { $0.hasPrefix("As of ") }, "estimate is dated")
            try expect(!first.contains { $0.contains("monitoring resumed") || $0.contains("charging measurements") }, "no app-owned samples are requested")
            try expect(count.withLock { $0 == 1 }, "one toolbar action loads once")
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { !monitor.isReadingHistory }), "repeat load completes")
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard) == first }), "repeat load preserves displayed data and time")
            try expect(count.withLock { $0 == 2 }, "repeat action only adds one read")
        }
    },
    TestCase(name: "Journal dashboard distinguishes known external power and unavailable history") {
        try MainActor.assumeIsolated {
            let monitor = BatteryMonitor(readJournal: { nil }, readWatts: { PowerWatts(battery: -7.8, input: nil) })
            let controller = BatteryWindowController(monitor: monitor)
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains { $0.hasSuffix(" W") } }), "power readings become visible")
            let fields = visibleText(in: controller.dashboard)
            try expect(fields.contains("Battery history unavailable.") && fields.contains("Power Readings"), "unknown history has a neutral heading")
            try expect(!fields.contains("External Power") && !fields.contains { $0.hasPrefix("As of ") }, "unavailable journal does not date or classify watts")
            try expect(fields.contains { $0.replacingOccurrences(of: ",", with: ".") == "-7.80 W" }, "battery watts keep two displayed decimals: \(fields)")
        }
    },
    TestCase(name: "Journal dashboard keeps the compact layout and restores the expanded window") {
        try MainActor.assumeIsolated {
            let request = Mutex(0)
            let logs = [journalReading(0, "Batt", 63), journalReading(0, "AC", 63), journalReading(0, "Batt", 62)]
            let monitor = BatteryMonitor(readJournal: {
                request.withLock { count in
                    defer { count += 1 }
                    return logs[count]
                }
            }, readWatts: { PowerWatts(battery: -0.48, input: 67.63) })
            let controller = BatteryWindowController(monitor: monitor)
            guard let window = controller.window else { throw TestFailure.failed("missing window") }
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains("63%") }), "battery window appears")
            let expandedFrame = window.frame
            try expect(visibleText(in: controller.dashboard).contains("—"), "one journal point is insufficient for an estimate")
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains("External Power") }), "external power compacts")
            let compactFrame = window.frame
            try expect(compactFrame.height < expandedFrame.height, "compact window shrinks vertically")
            let values = visibleText(in: controller.dashboard)
            let watts = values.filter { $0.hasSuffix(" W") }.map { $0.replacingOccurrences(of: ",", with: ".") }
            try expect(watts == ["-0.48 W", "67.63 W"] && !values.contains("Current Session"), "compact view displays measured channels")
            try expect(values.contains { $0.hasPrefix("As of ") && $0.contains("63%") }, "the compact timestamp dates the recorded charge")
            controller.dashboard.layoutSubtreeIfNeeded()
            let fields = visibleTextFields(in: controller.dashboard)
            let labels = fields.filter { ["Battery", "DC In"].contains($0.stringValue) }.map { $0.convert($0.bounds, to: controller.dashboard) }
            let amounts = fields.filter { $0.stringValue.hasSuffix(" W") }.map { $0.convert($0.bounds, to: controller.dashboard) }
            for (label, amount) in zip(labels, amounts) {
                try expect(abs(label.midY - amount.midY) <= 0.5, "a power row shares its vertical center")
            }
            try expectNear(Double(labels[0].minX), Double(labels[1].minX), "labels align on the left")
            try expectNear(Double(amounts[0].maxX), Double(amounts[1].maxX), "readings align on the right")
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains("62%") }), "discharge restores expanded view")
            try expectNear(Double(window.frame.width), Double(expandedFrame.width), "expanded width is restored")
            try expect(controller.window === window, "the exact window remains registered")
        }
    },
    TestCase(name: "Journal dashboard shows zero for a logged full charge") {
        try MainActor.assumeIsolated {
            let monitor = BatteryMonitor(readJournal: { journalReading(0, "AC", 100) }, readWatts: { PowerWatts(battery: nil, input: nil) })
            let controller = BatteryWindowController(monitor: monitor)
            controller.refreshBatteryData(nil)
            try expect(drainBatteryHistory(until: { visibleText(in: controller.dashboard).contains("Recorded full charge") }), "completion is displayed")
            let fields = visibleText(in: controller.dashboard)
            try expect(fields.contains("Time to Full") && fields.contains("0m"), "100% has a zero estimate")
        }
    },
]
