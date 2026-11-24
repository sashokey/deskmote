import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

private func naturalSwitchRegistryChanged(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.registryChanged(iterator)
    }
}

@MainActor
final class DeviceMonitor: DeviceMonitoring {
    @MainActor
    struct Notifications {
        let create: () -> IONotificationPortRef?
        let getSource: (IONotificationPortRef) -> CFRunLoopSource?
        let destroy: (IONotificationPortRef) -> Void
        let register: (IONotificationPortRef, String, IOServiceMatchingCallback, UnsafeMutableRawPointer) throws -> io_iterator_t
        let next: (io_iterator_t) -> io_object_t
        let release: (io_object_t) -> Void

        static let system = Self(
            create: { IONotificationPortCreate(kIOMainPortDefault) },
            getSource: { IONotificationPortGetRunLoopSource($0)?.takeUnretainedValue() },
            destroy: IONotificationPortDestroy,
            register: { port, kind, callback, context in
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, kind, IOServiceMatching(kIOHIDDeviceKey), callback, context, &iterator
                )
                guard status == KERN_SUCCESS else { throw NaturalSwitchError.registry(status) }
                return iterator
            },
            next: IOIteratorNext,
            release: { IOObjectRelease($0) }
        )
    }

    var onChange: (() -> Void)?
    private let notifications: Notifications
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    init(notifications: Notifications = .system) {
        self.notifications = notifications
    }

    isolated deinit { stop() }

    func start() throws {
        guard port == nil else { return }
        guard let port = notifications.create() else {
            throw NaturalSwitchError.registry(kIOReturnNoResources)
        }
        guard let source = notifications.getSource(port) else {
            notifications.destroy(port)
            throw NaturalSwitchError.registry(kIOReturnNoResources)
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
                let iterator = try notifications.register(port, kind, naturalSwitchRegistryChanged, context)
                iterators.append(iterator)
                drain(iterator)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        iterators.forEach(notifications.release)
        iterators.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { notifications.destroy(port) }
        source = nil
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
            var raw: Unmanaged<CFMutableDictionary>?
            let propertyStatus = IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0)
            if propertyStatus == kIOReturnNoDevice || propertyStatus == kIOReturnNotFound { continue }
            guard propertyStatus == KERN_SUCCESS, var properties = raw?.takeRetainedValue() as? [String: Any] else {
                throw NaturalSwitchError.registry(propertyStatus)
            }
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
            devices.append(HIDDevice(properties: properties))
        }
        return devices
    }

    fileprivate func registryChanged(_ iterator: io_iterator_t) {
        drain(iterator)
        scheduleRefresh()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let object = notifications.next(iterator), object != 0 { notifications.release(object) }
    }

    private func scheduleRefresh() {
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
