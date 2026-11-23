import Foundation
import IOKit.ps

let batteryReaderTests = [
    TestCase(name: "internal battery is selected over a peripheral and capacity is normalized") {
        let descriptions: [[String: Any]] = [
            [kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 10, kIOPSMaxCapacityKey: 100],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
             kIOPSCurrentCapacityKey: 3000, kIOPSMaxCapacityKey: 5000,
             kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        ]
        let sample = BatteryReader.sample(from: descriptions, at: Date(timeIntervalSince1970: 1000))
        try expectNear(sample?.percent, 60, "must scale internal battery capacity to percent")
        try expect(sample?.onBattery == true, "must use the battery power-source state")
    },
    TestCase(name: "external power is distinguished from a paused charge") {
        let descriptions: [[String: Any]] = [
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80,
             kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: false,
             kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        ]
        try expect(BatteryReader.sample(from: descriptions, at: Date())?.onBattery == false, "not charging does not mean running on battery")
    },
    TestCase(name: "power channels preserve measured zero and reject invalid readings") {
        let battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80,
            kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: false, kIOPSTimeToFullChargeKey: 20
        ]
        let date = Date(timeIntervalSince1970: 1000)
        let zero = BatteryReader.sample(from: [battery], at: date, powerProperties: [
            "PowerTelemetryData": ["BatteryPower": 0, "SystemPowerIn": 0]
        ])
        try expectNear(zero?.batteryWatts, 0, "zero battery flow is a reading")
        try expectNear(zero?.inputWatts, 0, "zero input is a reading")
        try expect(zero?.timeToFull == nil, "paused charging must discard a stale ETA")

        let invalid = BatteryReader.sample(from: [battery], at: date, powerProperties: [
            "PowerTelemetryData": ["BatteryPower": Double.nan, "SystemPowerIn": -1]
        ])
        try expect(invalid?.batteryWatts == nil && invalid?.inputWatts == nil, "invalid channels must be unavailable")
    },
    TestCase(name: "battery power falls back to signed instantaneous current and voltage") {
        let battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80,
            kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSACPowerValue
        ]
        let sample = BatteryReader.sample(from: [battery], at: Date(), powerProperties: [
            "Voltage": 12000, "InstantAmperage": UInt64(bitPattern: -40), "Amperage": 30
        ])
        try expectNear(sample?.batteryWatts, -0.48, "signed current and millivolts must convert to watts")
        try expect(sample?.inputWatts == nil, "missing measured input must be unavailable")
    },
    TestCase(name: "idle power prefers the direct channels and falls back independently") {
        let battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80,
            kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: false
        ]
        let properties = ["PowerTelemetryData": ["BatteryPower": 100, "SystemPowerIn": 15250]]
        let live = BatteryReader.sample(from: [battery], at: Date(), powerProperties: properties, readLivePower: {
            PowerWatts(battery: 0.47, input: 12.01)
        })
        try expectNear(live?.batteryWatts, 0.47, "fresh Battery watts must take precedence over the cached value")
        try expectNear(live?.inputWatts, 12.01, "fresh DC In watts must take precedence over the cached value")
        try expect(live?.powerReadingSource == .direct, "success requires both channels to be read directly")

        let partial = BatteryReader.sample(from: [battery], at: Date(), powerProperties: properties, readLivePower: {
            PowerWatts(battery: 0, input: .nan)
        })
        try expectNear(partial?.batteryWatts, 0, "a fresh measured zero must be kept")
        try expectNear(partial?.inputWatts, 15.25, "an invalid direct reading must fall back for that channel only")
        try expect(partial?.powerReadingSource == .partial, "a cached channel must not be marked as a direct reading")
    },
    TestCase(name: "one measured percentage point is enough to estimate the charge rate") {
        let date = Date(timeIntervalSince1970: 1000)
        func reading(_ capacity: Int, at date: Date) -> BatterySample? {
            BatteryReader.sample(from: [[
                kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: capacity,
                kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                kIOPSIsChargingKey: true
            ]], at: date)
        }
        guard let start = reading(56, at: date), let current = reading(57, at: date.addingTimeInterval(60)) else {
            throw TestFailure.failed("valid charging samples expected")
        }
        let session = ChargingSession(start: start, observedStart: true)
        try expectNear(session.secondsPerPoint(at: current), 60, "roundoff must not delay the estimate")
    },
    TestCase(name: "missing absent or invalid battery data is unavailable rather than fabricated") {
        for descriptions: [[String: Any]] in [
            [],
            [[kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]],
            [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 0]],
            [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: false, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]],
            [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: -1, kIOPSMaxCapacityKey: 100]],
            [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]]
        ] {
            try expect(BatteryReader.sample(from: descriptions, at: Date()) == nil, "invalid battery dictionary must yield no sample")
        }
    }
]

let batteryHardwareTests = [
    TestCase(name: "real IOKit battery read returns a valid internal battery sample") {
        let sample = BatteryReader.read()
        try expect(sample?.isValid == true, "this Mac has a readable battery")
    }
]
