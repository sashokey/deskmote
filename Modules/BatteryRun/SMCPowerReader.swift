import Darwin
import IOKit

enum SMCPowerReader {
    private enum Sensor: UInt32 {
        case battery = 0x50504252
        case dcInput = 0x50445452
    }

    private enum Command: UInt8 {
        case readValue = 5
        case readInfo = 9
    }

    private enum Packet {
        static let size = 80
        static let key = 0
        static let valueSize = 28
        static let valueType = 32
        static let result = 40
        static let command = 42
        static let value = 48
        static let floatType: UInt32 = 0x666c7420
    }

    static func read() -> PowerWatts? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        defer { IOServiceClose(connection) }

        return PowerWatts(battery: watts(for: .battery, using: connection), input: watts(for: .dcInput, using: connection))
    }

    private static func watts(for sensor: Sensor, using connection: io_connect_t) -> Double? {
        guard let info = send(.readInfo, for: sensor, using: connection) else { return nil }
        let (size, type) = info.withUnsafeBytes { bytes in
            (
                bytes.loadUnaligned(fromByteOffset: Packet.valueSize, as: UInt32.self),
                bytes.loadUnaligned(fromByteOffset: Packet.valueType, as: UInt32.self)
            )
        }
        guard size == UInt32(MemoryLayout<Float>.size), type == Packet.floatType,
              let response = send(.readValue, for: sensor, using: connection, valueSize: size) else { return nil }
        let value = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Packet.value, as: Float.self) }
        return value.isFinite ? Double(value) : nil
    }

    private static func send(
        _ command: Command, for sensor: Sensor, using connection: io_connect_t, valueSize: UInt32 = 0
    ) -> [UInt8]? {
        var request = [UInt8](repeating: 0, count: Packet.size)
        putUInt32(sensor.rawValue, into: &request, at: Packet.key)
        putUInt32(valueSize, into: &request, at: Packet.valueSize)
        request[Packet.command] = command.rawValue

        var response = [UInt8](repeating: 0, count: Packet.size)
        var responseSize = Packet.size
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &responseSize)
            }
        }
        guard result == kIOReturnSuccess, responseSize == Packet.size, response[Packet.result] == 0 else { return nil }
        return response
    }

    private static func putUInt32(_ value: UInt32, into packet: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { bytes in
            packet.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}
