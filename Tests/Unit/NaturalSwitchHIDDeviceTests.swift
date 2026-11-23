import Testing
@testable import NaturalSwitch

@Test(arguments: ["USB", "Bluetooth", "BluetoothLowEnergy"])
func externalMouseUsesSupportedTransports(_ transport: String) {
    let device = HIDDevice(id: 1, properties: ["Transport": transport, "PrimaryUsagePage": 1, "PrimaryUsage": 2])
    #expect(device.isExternalMouse)
}

@Test func compoundDeviceUsesUsagePairs() {
    let device = HIDDevice(id: 1, properties: [
        "Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 6,
        "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 6], ["DeviceUsagePage": 1, "DeviceUsage": 2]]
    ])
    #expect(device.isExternalMouse)
}

@Test(arguments: ["SPI", "I2C", "Virtual", ""])
func internalAndVirtualTransportsAreExcluded(_ transport: String) {
    #expect(!HIDDevice(id: 1, properties: ["Transport": transport, "PrimaryUsagePage": 1, "PrimaryUsage": 2]).isExternalMouse)
}

@Test func builtInAndVirtualFlagsAreExcluded() {
    for flag in ["Built-In", "HIDVirtualDevice", "VirtualHIDDevice"] {
        #expect(!HIDDevice(id: 1, properties: ["Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 2, flag: true]).isExternalMouse)
    }
}

@Test func keyboardAndMalformedDevicesAreExcluded() {
    #expect(!HIDDevice(id: 1, properties: ["Transport": "USB", "PrimaryUsagePage": 1, "PrimaryUsage": 6]).isExternalMouse)
    #expect(!HIDDevice(id: 2, properties: [:]).isExternalMouse)
}

@Test func touchpadUsageIsExcluded() {
    let device = HIDDevice(id: 1, properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 2], ["DeviceUsagePage": 13, "DeviceUsage": 5]]
    ])
    #expect(!device.isExternalMouse)
}

@Test func systemPointerClassificationOverridesAmbiguousUsages() {
    let mouse = HIDDevice(id: 1, properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "HIDPointerAccelerationType": "HIDMouseAcceleration",
        "DeviceUsagePairs": [["DeviceUsagePage": 13, "DeviceUsage": 5]]
    ])
    let trackpad = HIDDevice(id: 2, properties: [
        "Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 2,
        "HIDPointerAccelerationType": "HIDTrackpadAcceleration"
    ])
    #expect(mouse.isExternalMouse)
    #expect(!trackpad.isExternalMouse)
}
