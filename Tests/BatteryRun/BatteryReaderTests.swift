import Foundation

let reportedWattsTests = [
    TestCase(name: "Reported watts interprets encoded signed power and converts units") {
        for value in [NSNumber(value: -7_800), NSNumber(value: UInt64(bitPattern: -7_800))] {
            let result = BatteryReader.reportedWatts(
                from: ["PowerTelemetryData": ["BatteryPower": value, "SystemPowerIn": 15_090]],
                externalPower: true, isCharging: true, readSMC: { nil }
            )
            try expectNear(result.battery, -7.8, "battery milliwatts are signed")
            try expectNear(result.input, 15.09, "input milliwatts converted to watts")
        }
    },
    TestCase(name: "Reported watts selects idle AC sensors and falls back per channel") {
        let properties = ["PowerTelemetryData": ["BatteryPower": -7_800, "SystemPowerIn": 15_090]]
        let partial = BatteryReader.reportedWatts(from: properties, externalPower: true, isCharging: false) {
            PowerWatts(battery: 0, input: -.infinity)
        }
        try expectNear(partial.battery, 0, "a reported zero is valid")
        try expectNear(partial.input, 15.09, "nonfinite input falls back")
        let other = BatteryReader.reportedWatts(from: properties, externalPower: true, isCharging: false) {
            PowerWatts(battery: .nan, input: 10)
        }
        try expectNear(other.battery, -7.8, "battery fallback is independent")
        try expectNear(other.input, 10, "reported SMC input takes precedence when idle")
        let negativeInput = BatteryReader.reportedWatts(from: properties, externalPower: true, isCharging: false) {
            PowerWatts(battery: nil, input: -1)
        }
        try expectNear(negativeInput.input, 15.09, "negative SMC input falls back")
    },
    TestCase(name: "Reported watts ignores input and idle AC sensors on battery") {
        var queriedSMC = false
        let result = BatteryReader.reportedWatts(
            from: ["PowerTelemetryData": ["BatteryPower": -7_800, "SystemPowerIn": 0]],
            externalPower: false, isCharging: false
        ) {
            queriedSMC = true
            return PowerWatts(battery: 15, input: 20)
        }
        try expect(!queriedSMC && result.input == nil, "AC sensor data do not apply on battery")
        try expectNear(result.battery, -7.8, "reported battery power remains available")
    },
    TestCase(name: "Reported watts declines invalid telemetry and never multiplies voltage and current") {
        for input: NSNumber in [NSNumber(value: -1), NSNumber(value: Double.infinity), NSNumber(value: true)] {
            let result = BatteryReader.reportedWatts(
                from: ["PowerTelemetryData": ["BatteryPower": true, "SystemPowerIn": input]],
                externalPower: true, isCharging: true, readSMC: { nil }
            )
            try expect(result.battery == nil && result.input == nil, "wrong values are unavailable")
        }
        let unreported = BatteryReader.reportedWatts(
            from: ["Voltage": 4000, "InstantAmperage": 2500],
            externalPower: true, isCharging: true, readSMC: { nil }
        )
        try expect(unreported.battery == nil && unreported.input == nil, "derived power is not reported by the system")
    },
]

let batteryHardwareTests = [
    TestCase(name: "real IOKit reports finite watt values when available") {
        let watts = BatteryReader.readWatts()
        try expect(watts.battery?.isFinite != false, "battery watts are finite when reported")
        try expect(watts.input.map { $0.isFinite && $0 >= 0 } != false, "input watts are finite and nonnegative when reported")
    },
]
