import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

private func registryChanged(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
    guard let context else { return }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.scheduleRefresh()
    }
}

@MainActor
final class DeviceMonitor: DeviceMonitoring {
    var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    isolated deinit { stop() }

    func start() throws {
        guard port == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw NaturalSwitchError.registry(kIOReturnNoResources)
        }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        do {
            for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, kind, IOServiceMatching(kIOHIDDeviceKey), registryChanged,
                    Unmanaged.passUnretained(self).toOpaque(), &iterator
                )
                guard status == KERN_SUCCESS else { throw NaturalSwitchError.registry(status) }
                iterators.append(iterator)
                registryChanged(Unmanaged.passUnretained(self).toOpaque(), iterator)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    func snapshot() throws -> [HIDDevice] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator)
        guard status == KERN_SUCCESS else { throw NaturalSwitchError.registry(status) }
        defer { IOObjectRelease(iterator) }
        var devices: [HIDDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            var raw: Unmanaged<CFMutableDictionary>?
            let propertyStatus = IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0)
            if propertyStatus == kIOReturnNoDevice || propertyStatus == kIOReturnNotFound { continue }
            guard propertyStatus == KERN_SUCCESS, var properties = raw?.takeRetainedValue() as? [String: Any] else {
                throw NaturalSwitchError.registry(propertyStatus)
            }
            let idStatus = IORegistryEntryGetRegistryEntryID(service, &id)
            if idStatus == kIOReturnNoDevice || idStatus == kIOReturnNotFound { continue }
            guard idStatus == KERN_SUCCESS else { throw NaturalSwitchError.registry(idStatus) }
            for key in [kIOHIDTransportKey, kIOHIDBuiltInKey, kIOHIDVirtualHIDevice] where properties[key] == nil {
                properties[key] = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    UInt32(kIORegistryIterateParents | kIORegistryIterateRecursively)
                )
            }
            if properties[kIOHIDPointerAccelerationTypeKey] == nil {
                properties[kIOHIDPointerAccelerationTypeKey] = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, kIOHIDPointerAccelerationTypeKey as CFString,
                    kCFAllocatorDefault, UInt32(kIORegistryIterateRecursively)
                )
            }
            devices.append(HIDDevice(id: id, properties: properties))
        }
        return devices
    }

    fileprivate func scheduleRefresh() {
        guard port != nil, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.port != nil else { return }
                self.pending = nil
                self.onChange?()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }
}
