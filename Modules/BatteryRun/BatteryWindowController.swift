import AppKit
import Combine

@MainActor
final class BatteryWindowController: NSWindowController, NSToolbarDelegate {
    let dashboard: AppKitDashboard
    let monitor: BatteryMonitor
    private var observation: AnyCancellable?
    private let refreshIdentifier = NSToolbarItem.Identifier("RefreshBattery")
    private var compact = false
    private var expandedWidth: CGFloat = 520
    private var refreshResult: String?
    private var dismissRefreshResult: Task<Void, Never>?

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
        let minimumSize = NSSize(width: 460, height: 590)
        dashboard = AppKitDashboard(frame: NSRect(x: 0, y: 0, width: 520, height: minimumSize.height))
        let window = NSWindow(contentRect: dashboard.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Battery Run"
        window.contentView = dashboard
        window.contentMinSize = minimumSize
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "BatteryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        observation = monitor.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
        render(opening: true)
    }

    required init?(coder: NSCoder) { nil }

    private func fitWindow(_ window: NSWindow, opening: Bool) {
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let maximum = visibleFrame.map { window.contentRect(forFrameRect: $0).size } ?? NSSize(width: CGFloat.infinity, height: CGFloat.infinity)
        let minimum = compact ? NSSize(width: 420, height: 220) : NSSize(width: 460, height: 590)
        let previousFrame = window.frame
        window.contentMinSize = NSSize(width: min(minimum.width, maximum.width), height: min(minimum.height, maximum.height))
        let compactWidth = max(minimum.width, expandedWidth - 60)
        let width = min(compact ? compactWidth : expandedWidth, maximum.width)
        window.setContentSize(NSSize(width: width, height: window.contentMinSize.height))
        let height = max(ceil(dashboard.requiredContentHeight), window.contentMinSize.height)
        let limitedHeight = min(height, maximum.height)
        if compact { window.contentMinSize.height = limitedHeight }
        window.setContentSize(NSSize(width: width, height: limitedHeight))
        if let visibleFrame {
            let size = window.frame.size
            let x = opening ? visibleFrame.midX - size.width / 2 : previousFrame.minX
            let y = opening ? visibleFrame.midY - size.height / 2 : previousFrame.maxY - size.height
            window.setFrameOrigin(NSPoint(
                x: max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width)),
                y: max(visibleFrame.minY, min(y, visibleFrame.maxY - size.height))
            ))
        } else if opening {
            window.center()
        } else {
            window.setFrameTopLeftPoint(NSPoint(x: previousFrame.minX, y: previousFrame.maxY))
        }
    }

    @objc func refreshBatteryData(_ sender: Any?) {
        let previous = monitor.sample
        monitor.refresh()
        setRefreshResult(powerRefreshMessage(after: previous))
        render()
        monitor.recoverHistory()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, refreshIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, refreshIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == refreshIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Refresh Battery Data"
        item.toolTip = "Refresh battery data"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Battery Data")
        item.target = self
        item.action = #selector(refreshBatteryData(_:))
        return item
    }

    private func render(opening: Bool = false) {
        let model = DashboardModel(
            sample: monitor.sample, session: monitor.tracker.session,
            forecastStart: monitor.forecastStart, chargingSession: monitor.chargingSession
        )
        if !model.isCompact && refreshResult != nil { setRefreshResult(nil) }
        dashboard.update(
            model: model, notice: monitor.notice, isReadingHistory: monitor.isReadingHistory,
            powerRefreshMessage: refreshResult
        )
        guard let window, opening || model.isCompact != compact else { return }
        if !compact && model.isCompact { expandedWidth = dashboard.bounds.width }
        compact = model.isCompact
        fitWindow(window, opening: opening)
    }

    private func powerRefreshMessage(after previous: BatterySample?) -> String? {
        guard let sample = monitor.sample, sample.mode == .idle else { return nil }
        guard sample.batteryWatts != nil || sample.inputWatts != nil else { return "Power readings unavailable." }
        if sample.powerReadingSource == .direct { return "Power readings updated." }
        if sample.powerReadingSource == .partial { return "One live power reading available." }
        if previous?.powerReadingSource != nil { return "Showing cached power readings." }
        let counterChanged = sample.powerSampleCount.map { $0 != previous?.powerSampleCount } == true
        if counterChanged || sample.batteryWatts != previous?.batteryWatts || sample.inputWatts != previous?.inputWatts {
            return "Power readings updated."
        }
        return "No new power reading."
    }

    private func setRefreshResult(_ message: String?) {
        dismissRefreshResult?.cancel()
        dismissRefreshResult = nil
        refreshResult = message
        guard message != nil else { return }
        dismissRefreshResult = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshResult = nil
            self?.dismissRefreshResult = nil
            self?.render()
        }
    }
}
