import AppKit

@MainActor
final class AppKitDashboard: NSView {
    private let charge = NSTextField(labelWithString: "—")
    private let source = NSTextField(labelWithString: "")
    private let journalDate = NSTextField(labelWithString: "")
    private let batteryImage = NSImageView()
    private let chargeBar = NSProgressIndicator()
    private let remainingLabel = NSTextField(labelWithString: "Remaining to 0%")
    private let fullDurationLabel = NSTextField(labelWithString: "100% → 0%")
    private let remaining = NSTextField(labelWithString: "—")
    private let fullDuration = NSTextField(labelWithString: "—")
    private let sessionHeading = NSTextField(labelWithString: "Discharge")
    private let startLabel = NSTextField(labelWithString: "Discharge started")
    private let elapsedLabel = NSTextField(labelWithString: "Discharge elapsed")
    private let usedLabel = NSTextField(labelWithString: "Charge used")
    private let rateLabel = NSTextField(labelWithString: "Average drain")
    private let startValue = NSTextField(labelWithString: "—")
    private let startCharge = NSTextField(labelWithString: "—")
    private let forecastStartCharge = NSTextField(labelWithString: "—")
    private let forecastStartTime = NSTextField(labelWithString: "—")
    private let elapsed = NSTextField(labelWithString: "—")
    private let forecastElapsed = NSTextField(labelWithString: "—")
    private let used = NSTextField(labelWithString: "—")
    private let rate = NSTextField(labelWithString: "—")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let originNote = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let progressRow = NSStackView()
    private let available = NSStackView()
    private let compact = NSStackView()
    private let batteryWatts = NSTextField(labelWithString: "")
    private let inputWatts = NSTextField(labelWithString: "")
    private let compactStatus = NSTextField(labelWithString: "External Power")
    private let compactCharge = NSTextField(labelWithString: "")
    private let powerStatus = NSTextField(labelWithString: "Battery history unavailable.")
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    var requiredContentHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return scroll.documentView?.bounds.height ?? 0
    }

    func update(model: DashboardModel, isReadingHistory: Bool) {
        available.isHidden = model.isCompact
        compact.isHidden = !model.isCompact
        charge.stringValue = model.recordedCharge.map(DashboardModel.percent) ?? "—"
        source.stringValue = model.sourceLabel
        journalDate.stringValue = model.asOf ?? ""
        journalDate.isHidden = model.asOf == nil
        chargeBar.isHidden = model.recordedCharge == nil
        chargeBar.doubleValue = model.recordedCharge ?? 0
        let level = Int(((model.recordedCharge ?? 0) / 25).rounded()) * 25
        let symbol = model.isOnBattery ? "battery.\(level)percent" : "battery.100percent.bolt"
        batteryImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        compactStatus.stringValue = model.powerHeading
        if let date = model.asOf, let percent = model.recordedCharge {
            compactCharge.stringValue = "\(date) · \(DashboardModel.percent(percent))"
            compactCharge.isHidden = false
        } else {
            compactCharge.isHidden = true
        }
        batteryWatts.stringValue = model.batteryPower
        inputWatts.stringValue = model.inputPower
        powerStatus.isHidden = !model.historyUnavailable || isReadingHistory
        remainingLabel.stringValue = model.isCharging ? "Time to Full" : "Remaining to 0%"
        fullDurationLabel.stringValue = model.isCharging ? "0% → 100%" : "100% → 0%"
        remaining.stringValue = model.remaining
        fullDuration.stringValue = model.fullDuration
        sessionHeading.stringValue = model.isCharging ? "Charging" : "Discharge"
        startLabel.stringValue = model.startLabel
        elapsedLabel.stringValue = model.isCharging ? "Charging elapsed" : "Discharge elapsed"
        usedLabel.stringValue = model.isCharging ? "Charge added" : "Charge used"
        rateLabel.stringValue = model.isCharging ? "Average charge rate" : "Average drain"
        startValue.stringValue = model.startValue
        startCharge.stringValue = model.startCharge
        forecastStartCharge.stringValue = model.forecastStartCharge
        forecastStartTime.stringValue = model.forecastStartTime
        elapsed.stringValue = model.elapsed
        forecastElapsed.stringValue = model.forecastElapsed
        used.stringValue = model.chargeUsed
        rate.stringValue = model.rate
        explanation.stringValue = model.explanation
        explanation.isHidden = model.explanation.isEmpty
        originNote.stringValue = model.originNote ?? ""
        originNote.isHidden = model.originNote == nil
        progressRow.isHidden = !isReadingHistory
        if isReadingHistory { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        needsLayout = true
    }

    private func configure() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let root = verticalStack(spacing: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        available.orientation = .vertical
        available.alignment = .leading
        available.spacing = 24
        root.addArrangedSubview(available)
        available.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let descriptor = NSFont.systemFont(ofSize: 40, weight: .semibold).fontDescriptor
        charge.font = NSFont(descriptor: descriptor.withDesign(.rounded) ?? descriptor, size: 40)
        source.textColor = .secondaryLabelColor
        journalDate.textColor = .secondaryLabelColor
        let headerText = verticalStack(spacing: 4, views: [charge, source, journalDate])
        batteryImage.contentTintColor = .controlAccentColor
        batteryImage.imageScaling = .scaleProportionallyUpOrDown
        batteryImage.setAccessibilityElement(false)
        batteryImage.widthAnchor.constraint(equalToConstant: 56).isActive = true
        batteryImage.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let header = NSStackView(views: [batteryImage, headerText])
        header.spacing = 16
        header.alignment = .centerY
        available.addArrangedSubview(header)

        chargeBar.style = .bar
        chargeBar.isIndeterminate = false
        chargeBar.maxValue = 100
        chargeBar.setAccessibilityLabel("Battery charge")
        addFullWidth(chargeBar, to: available)

        let fullColumn = estimateColumn(fullDurationLabel, value: fullDuration)
        let estimates = NSStackView(views: [estimateColumn(remainingLabel, value: remaining), fullColumn])
        estimates.distribution = .fillEqually
        estimates.spacing = 24
        estimates.alignment = .top
        addFullWidth(card(containing: estimates), to: available)

        let sessionTitle = NSTextField(labelWithString: "Current Session")
        sessionTitle.font = .systemFont(ofSize: 12, weight: .medium)
        let details = verticalStack(spacing: 16)
        let sessionReadings = sessionSection(sessionHeading, rows: [
            (startLabel, startValue),
            (NSTextField(labelWithString: "Starting charge"), startCharge),
            (elapsedLabel, elapsed),
            (usedLabel, used)
        ])
        let forecast = sessionSection(NSTextField(labelWithString: "Forecast"), rows: [
            (NSTextField(labelWithString: "Forecast start time"), forecastStartTime),
            (NSTextField(labelWithString: "Charge at forecast start"), forecastStartCharge),
            (NSTextField(labelWithString: "Forecast elapsed"), forecastElapsed),
            (rateLabel, rate)
        ])
        addFullWidth(sessionReadings, to: details)
        addFullWidth(forecast, to: details)
        let session = verticalStack(spacing: 8, views: [sessionTitle])
        addFullWidth(card(containing: details), to: session)
        addFullWidth(session, to: available)

        let footer = verticalStack(spacing: 8)
        for label in [explanation, originNote] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addFullWidth(label, to: footer)
        }
        addFullWidth(footer, to: available)
        progress.style = .spinning
        progress.controlSize = .small
        progressRow.addArrangedSubview(progress)
        let historyLabel = NSTextField(labelWithString: "Reading power history…")
        historyLabel.font = .systemFont(ofSize: 11)
        historyLabel.textColor = .secondaryLabelColor
        progressRow.addArrangedSubview(historyLabel)
        progressRow.spacing = 8

        compact.orientation = .vertical
        compact.alignment = .leading
        compact.spacing = 14
        compactStatus.font = .systemFont(ofSize: 16, weight: .semibold)
        compact.addArrangedSubview(compactStatus)
        compactCharge.textColor = .secondaryLabelColor
        compact.addArrangedSubview(compactCharge)
        let batteryLabel = NSTextField(labelWithString: "Battery")
        batteryLabel.toolTip = "Power flowing into or out of the battery."
        let inputLabel = NSTextField(labelWithString: "DC In")
        inputLabel.toolTip = "Power received from the adapter."
        let powerReadings = readingsGrid([(batteryLabel, batteryWatts), (inputLabel, inputWatts)])
        powerReadings.rowAlignment = .none
        powerReadings.yPlacement = .center
        powerReadings.rowSpacing = 16
        for label in [batteryLabel, inputLabel] {
            label.font = .systemFont(ofSize: 14)
        }
        for value in [batteryWatts, inputWatts] {
            value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        }
        addFullWidth(card(containing: powerReadings), to: compact)
        powerStatus.font = .systemFont(ofSize: 12)
        powerStatus.textColor = .secondaryLabelColor
        addFullWidth(powerStatus, to: compact)
        addFullWidth(compact, to: root)

        root.addArrangedSubview(progressRow)
        update(model: DashboardModel(snapshot: nil), isReadingHistory: false)
    }

    private func sessionSection(_ heading: NSTextField, rows: [(label: NSTextField, value: NSTextField)]) -> NSStackView {
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let section = verticalStack(spacing: 8, views: [heading])
        addFullWidth(readingsGrid(rows), to: section)
        return section
    }

    private func readingsGrid(_ rows: [(label: NSTextField, value: NSTextField)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [$0.label, $0.value] })
        grid.rowSpacing = 14
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        for (label, value) in rows {
            label.textColor = .secondaryLabelColor
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            value.isSelectable = true
        }
        return grid
    }

    private func estimateColumn(_ label: NSTextField, value: NSTextField) -> NSStackView {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        value.isSelectable = true
        return verticalStack(spacing: 8, views: [label, value])
    }

    private func verticalStack(spacing: CGFloat, views: [NSView] = []) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func card(containing content: NSView) -> NSView {
        let wrapper = NSView()
        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 0
        background.cornerRadius = 12
        background.fillColor = .controlColor
        for child in [background, content] {
            child.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(child)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            background.topAnchor.constraint(equalTo: wrapper.topAnchor),
            background.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -16)
        ])
        return wrapper
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
