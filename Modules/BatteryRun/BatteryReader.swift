import Foundation
import IOKit.ps

struct PowerWatts: Sendable {
    let battery: Double?
    let input: Double?
}

enum BatteryReader {
    static func readWatts() -> PowerWatts {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let battery = sources.lazy.compactMap({
                  IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
              }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              battery[kIOPSIsPresentKey] as? Bool != false,
              let source = battery[kIOPSPowerSourceStateKey] as? String,
              source == kIOPSBatteryPowerValue || source == kIOPSACPowerValue else {
            return PowerWatts(battery: nil, input: nil)
        }
        return reportedWatts(
            from: readPowerProperties(),
            externalPower: source == kIOPSACPowerValue,
            isCharging: battery[kIOPSIsChargingKey] as? Bool != false,
            readSMC: SMCPowerReader.read
        )
    }

    static func reportedWatts(
        from properties: [String: Any], externalPower: Bool, isCharging: Bool,
        readSMC: () -> PowerWatts?
    ) -> PowerWatts {
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let reportedBattery = number(telemetry["BatteryPower"]).map { Double($0.int64Value) / 1000 }
        let reportedInput = number(telemetry["SystemPowerIn"])?.doubleValue
        let live = externalPower && !isCharging ? readSMC() : nil
        let battery = live?.battery.flatMap { $0.isFinite ? $0 : nil } ?? reportedBattery
        let input = live?.input.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            ?? reportedInput.flatMap { $0 >= 0 ? $0 / 1000 : nil }
        return PowerWatts(battery: battery, input: externalPower ? input : nil)
    }

    private static func readPowerProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(service) }
        let key = "PowerTelemetryData"
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return [:]
        }
        return [key: value]
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value
    }
}
