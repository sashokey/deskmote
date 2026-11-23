import AppKit
import Foundation
import IOKit.ps

@MainActor
func visibleText(in view: NSView) -> [String] {
    visibleTextFields(in: view).map(\.stringValue)
}

@MainActor
private func visibleTextFields(in view: NSView) -> [NSTextField] {
    guard !view.isHidden else { return [] }
    return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { visibleTextFields(in: $0) }
}

let appKitTests = [
    TestCase(name: "AppKit uses the same estimate positions for charging and displays its uncertainty") {
        try MainActor.assumeIsolated {
            let date = Date(timeIntervalSince1970: 1704110400)
            func reading(_ percent: Int, date: Date, charging: Bool, minutes: Int = 30) -> BatterySample? {
                BatteryReader.sample(from: [[
                    kIOPSTypeKey: kIOPSInternalBatteryType,
                    kIOPSCurrentCapacityKey: percent,
                    kIOPSMaxCapacityKey: 100,
                    kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                    kIOPSIsChargingKey: charging,
                    kIOPSTimeToFullChargeKey: minutes
                ]], at: date)
            }
            let url = URL(fileURLWithPath: ".build/charging-window-\(UUID().uuidString).json")
            var current = reading(60, date: date, charging: false)
            let monitor = BatteryMonitor(stateURL: url, readSample: { current })
            let controller = BatteryWindowController(monitor: monitor)
            controller.refreshBatteryData(nil)

            current = reading(60, date: date.addingTimeInterval(30), charging: true)
            controller.refreshBatteryData(nil)
            let waiting = visibleText(in: controller.dashboard)
            try expect(waiting.contains("30m"), "the system ETA should appear before enough charge has been measured")
            try expect(!waiting.contains { $0.hasPrefix("≈") }, "no full-charge prediction before a measured rate")

            current = reading(70, date: date.addingTimeInterval(3630), charging: true)
            controller.refreshBatteryData(nil)
            let values = visibleText(in: controller.dashboard)
            let titles = values.filter { ["Time to Full", "0% → 100%"].contains($0) }
            try expect(titles == ["Time to Full", "0% → 100%"], "live ETA and full-range estimate must keep their order")
            for expected in ["Charging", "Charge added", "10%", "30m", "≈ 7h 30m", "Based on the measured rate and macOS estimate."] {
                try expect(values.contains(expected), "charging must display \(expected)")
            }

            current = reading(70, date: date.addingTimeInterval(3630), charging: true, minutes: -1)
            controller.refreshBatteryData(nil)
            let measuredOnly = visibleText(in: controller.dashboard)
            try expect(measuredOnly.contains("≈ 10h 0m"), "measured rate should still give a full-range estimate without a system ETA")
            try expect(measuredOnly.contains("Based on the measured charging rate."), "the note must identify the calculation being used")

            current = reading(70, date: date.addingTimeInterval(3690), charging: false)
            controller.refreshBatteryData(nil)
            current = reading(70, date: date.addingTimeInterval(3750), charging: true)
            controller.refreshBatteryData(nil)
            let resumed = visibleText(in: controller.dashboard)
            try expect(!resumed.contains { $0.hasPrefix("≈") }, "a new charging session must not reuse the old rate")
        }
    },
    TestCase(name: "AppKit compacts to battery and input watts when charging pauses") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/power-window-\(UUID().uuidString).json")
            var current = historyCurrent(63)
            let monitor = BatteryMonitor(stateURL: url, readSample: { current })
            let controller = BatteryWindowController(monitor: monitor)
            controller.refreshBatteryData(nil)
            guard let window = controller.window else { throw TestFailure.failed("missing window") }
            let expandedFrame = window.frame
            guard let idle = BatteryReader.sample(from: [[
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: 63,
                kIOPSMaxCapacityKey: 100,
                kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                kIOPSIsChargingKey: false
            ]], at: current.date, powerProperties: [
                "PowerTelemetryData": ["BatteryPower": -480, "SystemPowerIn": 67630]
            ]) else { throw TestFailure.failed("missing idle reading") }
            current = idle
            controller.refreshBatteryData(nil)
            let compactFrame = window.frame
            let values = visibleText(in: controller.dashboard)
            try expect(values.contains("Battery") && values.contains("DC In"), "compact view must show the two power channels")
            let watts = values.filter { $0.hasSuffix(" W") }.map { $0.replacingOccurrences(of: ",", with: ".") }
            try expect(watts == ["-0.48 W", "67.63 W"], "compact view must show the battery flow and measured DC input")
            controller.dashboard.layoutSubtreeIfNeeded()
            let fields = visibleTextFields(in: controller.dashboard)
            let labels = fields.filter { ["Battery", "DC In"].contains($0.stringValue) }
            let powerValues = fields.filter { $0.stringValue.hasSuffix(" W") }
            let labelFrames = labels.map { $0.convert($0.bounds, to: controller.dashboard) }
            let powerFrames = powerValues.map { $0.convert($0.bounds, to: controller.dashboard) }
            for (label, value) in zip(labelFrames, powerFrames) {
                try expect(abs(label.midY - value.midY) <= 0.5, "each power label and its value must share the center of their row")
            }
            try expectNear(Double(labelFrames[0].minX), Double(labelFrames[1].minX), "power labels must align on the left")
            try expectNear(Double(powerFrames[0].maxX), Double(powerFrames[1].maxX), "power values must align on the right")
            try expect(!values.contains("Current Session") && !values.contains("63%"), "old session and charge fields must be hidden")
            try expect(compactFrame.width < expandedFrame.width && compactFrame.height < expandedFrame.height, "pause must shrink both window dimensions")
            try expectNear(Double(compactFrame.width), 460, "the default idle window should be only modestly narrower")
            try expect(window.contentLayoutRect.height >= 220, "the idle window needs room for the power card and refresh status")
            current = historyCurrent(62)
            controller.refreshBatteryData(nil)
            try expectNear(Double(window.frame.width), Double(expandedFrame.width), "resuming must restore expanded width")
            try expect(visibleText(in: controller.dashboard).contains("Current Session"), "resume must restore the session fields")

            let screenWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 620
            if screenWidth >= 620 {
                window.setContentSize(NSSize(width: 620, height: controller.dashboard.bounds.height))
                current = idle
                controller.refreshBatteryData(nil)
                try expectNear(Double(window.frame.width), 560, "a wider user-sized window should also shrink by only 60 points")
            }
        }
    },
    TestCase(name: "manual power refresh finishes and dismisses its result without a later poll") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/refresh-power-\(UUID().uuidString).json")
            func reading(_ count: Int, input: Int = 15090, live: PowerWatts? = nil) -> BatterySample? {
                BatteryReader.sample(from: [[
                    kIOPSTypeKey: kIOPSInternalBatteryType,
                    kIOPSCurrentCapacityKey: 80,
                    kIOPSMaxCapacityKey: 100,
                    kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                    kIOPSIsChargingKey: false
                ]], at: Date(), powerProperties: [
                    "PowerTelemetryData": ["BatteryPower": 0, "SystemPowerIn": input, "SystemPowerInAccumulatorCount": count]
                ], readLivePower: { live })
            }
            var current = reading(10)
            var reads = 0
            let monitor = BatteryMonitor(stateURL: url, readSample: {
                reads += 1
                return current
            })
            monitor.refresh()
            let controller = BatteryWindowController(monitor: monitor)
            guard let item = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "RefreshBattery" }),
                  let action = item.action else { throw TestFailure.failed("missing toolbar action") }
            try expect(NSApp.sendAction(action, to: item.target, from: item), "the native toolbar must dispatch its action")
            try expect(reads == 2, "the toolbar must request a fresh read immediately")
            let unchanged = "No new power reading."
            try expect(visibleText(in: controller.dashboard).contains(unchanged), "an unchanged system snapshot must finish refresh immediately")

            let dismissalDeadline = ContinuousClock.now + .seconds(5)
            while visibleText(in: controller.dashboard).contains(unchanged), ContinuousClock.now < dismissalDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            try expect(!visibleText(in: controller.dashboard).contains(unchanged), "the result must clear even when no further battery read occurs")
            try expect(reads == 2, "dismissing the result must not require a battery read")

            current = reading(11)
            try expect(NSApp.sendAction(action, to: item.target, from: item), "the toolbar must read again")
            try expect(visibleText(in: controller.dashboard).contains("Power readings updated."), "a new sample may have the same wattage")
            current = reading(12, input: 12010)
            try expect(NSApp.sendAction(action, to: item.target, from: item), "the toolbar must still respond after receiving new telemetry")
            let displayed = visibleText(in: controller.dashboard).map { $0.replacingOccurrences(of: ",", with: ".") }
            try expect(displayed.contains("12.01 W"), "the manual action must display the latest input watts")
            try expect(displayed.contains("Power readings updated."), "immediately available readings must complete the request")

            current = reading(13, live: PowerWatts(battery: 0.47, input: 12.01))
            try expect(NSApp.sendAction(action, to: item.target, from: item), "refresh must read the direct sensors")
            current = reading(13)
            try expect(NSApp.sendAction(action, to: item.target, from: item), "refresh must survive loss of direct readings")
            try expect(visibleText(in: controller.dashboard).contains("Showing cached power readings."), "a return to an older cached sample is not a fresh reading")
            current = reading(13, live: PowerWatts(battery: 0, input: nil))
            try expect(NSApp.sendAction(action, to: item.target, from: item), "refresh must keep a partial direct sample")
            try expect(visibleText(in: controller.dashboard).contains("One live power reading available."), "a partial direct read still observes one live sensor")
        }
    },
    TestCase(name: "AppKit presents all measured session values in native text controls") {
        try MainActor.assumeIsolated {
            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: 650))
            let start = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 80, onBattery: true)
            view.update(model: DashboardModel(sample: historyCurrent(), session: DischargeSession(start: start, origin: .history), forecastStart: start), notice: nil, isReadingHistory: false)
            let values = visibleText(in: view)
            for expected in ["60%", "On Battery", "3h 0m", "5h 0m", "80%", "1h 0m", "20%", "20%/h"] {
                try expect(values.contains(expected), "native window must display \(expected)")
            }
            try expect(values.contains { $0.hasPrefix("≈") }, "historical uncertainty must remain visible")
        }
    },
    TestCase(name: "AppKit groups session values by the timestamp used for each elapsed time") {
        try MainActor.assumeIsolated {
            @MainActor
            func sessionValue(_ label: String, in view: NSView) -> String? {
                if let grid = view as? NSGridView {
                    let row = (0..<grid.numberOfRows).first {
                        (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue == label
                    }
                    return row.flatMap { (grid.cell(atColumnIndex: 1, rowIndex: $0).contentView as? NSTextField)?.stringValue }
                }
                return view.subviews.lazy.compactMap { sessionValue(label, in: $0) }.first
            }

            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 460, height: 590))
            let current = historyCurrent(70)
            let start = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 90, onBattery: true)
            let wake = BatterySample(date: current.date.addingTimeInterval(-1800), percent: 75, onBattery: true)
            let session = DischargeSession(start: start, origin: .observed)
            view.update(model: DashboardModel(sample: current, session: session, forecastStart: wake), notice: nil, isReadingHistory: false)
            try expect(sessionValue("Charge at forecast start", in: view) == "75%", "the forecast row must show the charge at wake")
            let wakeTime = wake.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            let unplugTime = start.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            try expect(sessionValue("Forecast start time", in: view) == wakeTime, "the forecast time must show the wake reading's timestamp")
            try expect(sessionValue("Discharge started", in: view) == unplugTime, "the session start must show the unplug time")
            try expect(sessionValue("Starting charge", in: view) == "90%", "the starting charge row must show the charge at unplugging")
            try expect(sessionValue("Discharge elapsed", in: view) == "2h 0m", "the discharge duration must start at unplugging")
            try expect(sessionValue("Forecast elapsed", in: view) == "30m", "the forecast duration must start at wake")

            @MainActor
            func sectionRowLabels(in parent: NSView) -> [String: [String]] {
                if let stack = parent as? NSStackView,
                   let title = stack.arrangedSubviews.first as? NSTextField,
                   let grid = stack.arrangedSubviews.last as? NSGridView {
                    let labels = (0..<grid.numberOfRows).compactMap {
                        (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue
                    }
                    return [title.stringValue: labels]
                }
                return parent.subviews.reduce(into: [:]) { $0.merge(sectionRowLabels(in: $1)) { existing, _ in existing } }
            }
            let sections = sectionRowLabels(in: view)
            try expect(sections["Discharge"] == ["Discharge started", "Starting charge", "Discharge elapsed", "Charge used"], "the discharge group must contain its own four rows in order")
            try expect(sections["Forecast"] == ["Forecast start time", "Charge at forecast start", "Forecast elapsed", "Average drain"], "the forecast group must contain its own four rows in order")

            view.update(model: DashboardModel(sample: historyCurrent(70, onBattery: false), session: session, forecastStart: wake), notice: nil, isReadingHistory: false)
            let idle = visibleText(in: view)
            try expect(!idle.contains("Forecast"), "external power without charging must hide the forecast section")
            try expect(!idle.contains("Current Session"), "external power without charging must hide the session")

            view.update(model: DashboardModel(sample: current, session: session, forecastStart: nil), notice: nil, isReadingHistory: false)
            try expect(sessionValue("Charge at forecast start", in: view) == "—", "an unknown forecast baseline must display as unavailable")
            try expect(sessionValue("Forecast start time", in: view) == "—", "an unknown forecast time must display as unavailable")
            try expect(sessionValue("Forecast elapsed", in: view) == "—", "an unknown forecast duration must display as unavailable")
        }
    },
    TestCase(name: "AppKit clears stale forecasts when power switches to AC") {
        try MainActor.assumeIsolated {
            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: 650))
            let start = BatterySample(date: Date(timeIntervalSince1970: 1704110400), percent: 80, onBattery: true)
            let session = DischargeSession(start: start, origin: .history)
            view.update(model: DashboardModel(sample: historyCurrent(), session: session, forecastStart: start), notice: nil, isReadingHistory: false)
            view.update(model: DashboardModel(sample: historyCurrent(60, onBattery: false), session: session, forecastStart: start), notice: nil, isReadingHistory: false)
            let values = visibleText(in: view)
            try expect(values.contains("External Power"), "source change must be reflected in the native window")
            try expect(!values.contains("3h 0m"), "previous remaining time must be removed")
            try expect(!values.contains("80%"), "previous session values must be removed")
        }
    },
    TestCase(name: "AppKit unavailable state hides old charge and presents the data error") {
        try MainActor.assumeIsolated {
            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: 650))
            view.update(model: DashboardModel(sample: historyCurrent(), session: nil, forecastStart: nil), notice: nil, isReadingHistory: false)
            view.update(model: DashboardModel(sample: nil, session: nil, forecastStart: nil), notice: nil, isReadingHistory: false)
            let values = visibleText(in: view)
            try expect(values.contains("Battery Unavailable"), "unavailable data must have a clear state")
            try expect(!values.contains("60%"), "stale charge must not remain visible")
        }
    },
    TestCase(name: "AppKit presents persistence errors and history progress") {
        try MainActor.assumeIsolated {
            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: 650))
            view.update(model: DashboardModel(sample: historyCurrent(), session: nil, forecastStart: nil), notice: "Session storage failed", isReadingHistory: true)
            let values = visibleText(in: view)
            try expect(values.contains("Session storage failed"), "the native view must surface storage errors")
            try expect(values.contains("Reading power history…"), "history progress must be visible")
        }
    },
    TestCase(name: "AppKit presents persistence errors in compact and unavailable states") {
        try MainActor.assumeIsolated {
            let view = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: 650))
            for sample in [historyCurrent(70, onBattery: false), nil] as [BatterySample?] {
                view.update(model: DashboardModel(sample: sample, session: nil, forecastStart: nil),
                            notice: "Session storage failed", isReadingHistory: false)
                try expect(visibleText(in: view).contains("Session storage failed"), "the storage error must remain visible")
            }
        }
    },
    TestCase(name: "AppKit window refresh binds live battery data to the dashboard") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/window-\(UUID().uuidString).json")
            let reading = historyCurrent(71)
            let monitor = BatteryMonitor(stateURL: url, readSample: { reading })
            let controller = BatteryWindowController(monitor: monitor)
            controller.refreshBatteryData(nil)
            try expect(controller.window != nil, "the app must provide a native window")
            try expect(monitor.sample == reading, "refresh must read the battery source")
            try expect(visibleText(in: controller.dashboard).contains("71%"), "measured charge must reach the native dashboard")
        }
    },
    TestCase(name: "AppKit observes monitor updates without a manual window refresh") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/automatic-window-\(UUID().uuidString).json")
            let monitor = BatteryMonitor(stateURL: url, readSample: { historyCurrent(63) })
            let controller = BatteryWindowController(monitor: monitor)
            monitor.refresh()
            let expected = "63%"
            let deadline = Date().addingTimeInterval(1)
            while !visibleText(in: controller.dashboard).contains(expected), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            try expect(visibleText(in: controller.dashboard).contains(expected), "published battery changes must update the native window automatically")
        }
    },
    TestCase(name: "AppKit fits the opening window to the historical session and available screen height") {
        try MainActor.assumeIsolated {
            let url = URL(fileURLWithPath: ".build/window-size-\(UUID().uuidString).json")
            let current = historyCurrent(70)
            let start = BatterySample(date: current.date.addingTimeInterval(-7200), percent: 90, onBattery: true)
            let history = DischargeSession(start: start, origin: .history)
            try SessionStore.save(SessionTracker(session: history, lastSample: start), to: url)
            let monitor = BatteryMonitor(stateURL: url, readSample: { current })
            monitor.refresh()
            let controller = BatteryWindowController(monitor: monitor)
            guard let window = controller.window,
                  let scroll = controller.dashboard.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else {
                throw TestFailure.failed("the window must present a scrollable dashboard")
            }
            controller.dashboard.layoutSubtreeIfNeeded()
            try expectNear(Double(window.frame.width), 520, "opening width must match the intended size")
            let visibleHeight = scroll.contentView.bounds.height
            let requiredHeight = document.bounds.height
            let chromeHeight = window.frame.height - visibleHeight
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame
            if let screen {
                try expect(window.frame.minY >= screen.minY && window.frame.maxY <= screen.maxY, "the opening window must stay in the visible area")
                if window.frame.width <= screen.width {
                    try expect(window.frame.minX >= screen.minX && window.frame.maxX <= screen.maxX, "the window must stay within its selected screen")
                }
            }
            let unconstrainedHeight = ceil(requiredHeight) + chromeHeight
            if unconstrainedHeight <= (screen?.height ?? .infinity) {
                try expect(visibleHeight >= requiredHeight, "the historical session must fit without scrolling (viewport \(visibleHeight), content \(requiredHeight))")
            } else {
                try expectNear(Double(window.frame.height), screen.map { Double($0.height) } ?? 0, "the window must fit the available height on a shorter screen")
            }
        }
    }
]
