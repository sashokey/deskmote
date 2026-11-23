import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDDevice {
    let id: UInt64
    let isExternalMouse: Bool

    init(id: UInt64, properties: [String: Any]) {
        self.id = id
        let transport = properties[kIOHIDTransportKey] as? String ?? ""
        let external = [kIOHIDTransportUSBValue, kIOHIDTransportBluetoothValue, kIOHIDTransportBluetoothLowEnergyValue].contains(transport)
        let builtIn = properties[kIOHIDBuiltInKey] as? Bool == true
        let virtual = properties[kIOHIDVirtualHIDevice] as? Bool == true || properties["VirtualHIDDevice"] as? Bool == true
        let usages = properties[kIOHIDDeviceUsagePairsKey] as? [[String: Int]] ?? []
        func conforms(_ page: Int, _ usage: Int) -> Bool {
            (properties[kIOHIDPrimaryUsagePageKey] as? Int == page && properties[kIOHIDPrimaryUsageKey] as? Int == usage)
                || usages.contains { $0[kIOHIDDeviceUsagePageKey] == page && $0[kIOHIDDeviceUsageKey] == usage }
        }
        let pointerType = properties[kIOHIDPointerAccelerationTypeKey] as? String
        let trackpad = pointerType == kIOHIDTrackpadAccelerationType
            || (pointerType != kIOHIDMouseAccelerationType && conforms(Int(kHIDPage_Digitizer), Int(kHIDUsage_Dig_TouchPad)))
        isExternalMouse = external && !builtIn && !virtual && !trackpad
            && conforms(Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_Mouse))
    }
}
