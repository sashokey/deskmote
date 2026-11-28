import Darwin
import Foundation
import Security
import Synchronization

@objc protocol FinderFileCreationProtocol {
    func ready(withReply reply: @escaping @Sendable (Bool) -> Void)
    func createFile(_ type: Int, in path: String, identity: Data, withReply reply: @escaping @Sendable (Bool) -> Void)
}

struct FinderDirectoryIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init?(_ info: stat) {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_ino != 0, info.st_birthtimespec.tv_sec > 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }

    static func capture(at directory: URL) -> Self? {
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Self(info)
        }
    }
}

enum FinderFileCreationIPC {
    static let serviceName = "io.github.sashokey.deskmote.finder-sync.service"
    static let servicePath = "Contents/XPCServices/DeskMoteFinderService.xpc"

    static func destination(for path: String) -> URL? {
        let bytes = path.utf8
        guard bytes.first == 47, bytes.count <= 4096, !bytes.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func requirement(for bundleURL: URL) -> String? {
        let flags = SecCSFlags(rawValue: 0)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, flags, &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let signature = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !signature.isEmpty else { return nil }

        let fingerprint = signature.map { String(format: "%02x", $0) }.joined()
        return "cdhash H\"\(fingerprint)\""
    }
}

enum FinderFileCreationClient {
    enum Outcome {
        case created
        case failed
        case unconfirmed
    }

    static func send(_ type: NewFileType, to directory: URL, identity: FinderDirectoryIdentity,
                     in extensionBundle: Bundle,
                     makeConnection: (String) -> NSXPCConnection = { NSXPCConnection(serviceName: $0) }) -> Outcome {
        let path = directory.path
        let host = directory.host()
        guard directory.isFileURL, host == nil || host == "" || host == "localhost",
              FinderFileCreationIPC.destination(for: path) != nil,
              let identityData = try? JSONEncoder().encode(identity) else { return .failed }
        let serviceURL = extensionBundle.bundleURL.appending(path: FinderFileCreationIPC.servicePath)
        guard let requirement = FinderFileCreationIPC.requirement(for: serviceURL) else {
            return .failed
        }

        let connection = makeConnection(FinderFileCreationIPC.serviceName)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FinderFileCreationProtocol.self)
        connection.activate()
        defer { connection.invalidate() }

        guard request(on: connection, deadline: .now() + .seconds(4), { $0.ready(withReply: $1) }) == .created else {
            return .failed
        }
        return request(on: connection, deadline: .now() + .seconds(4)) { service, reply in
            service.createFile(type.rawValue, in: path, identity: identityData, withReply: reply)
        }
    }

    private static func request(
        on connection: NSXPCConnection,
        deadline: DispatchTime,
        _ invoke: (FinderFileCreationProtocol, @escaping @Sendable (Bool) -> Void) -> Void
    ) -> Outcome {
        awaitReply(deadline: deadline) { complete in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                complete(nil)
            }
            guard let service = proxy as? FinderFileCreationProtocol else {
                complete(false)
                return
            }
            invoke(service) { complete($0) }
        }
    }

    static func awaitReply(deadline: DispatchTime,
                           send: (@escaping @Sendable (Bool?) -> Void) -> Void) -> Outcome {
        let signal = DispatchSemaphore(value: 0)
        let result = Mutex<Outcome?>(nil)
        let complete: @Sendable (Bool?) -> Void = { value in
            let outcome: Outcome = value.map { $0 ? .created : .failed } ?? .unconfirmed
            result.withLock { if $0 == nil { $0 = outcome } }
            signal.signal()
        }
        send(complete)
        _ = signal.wait(timeout: deadline)
        return result.withLock { $0 ?? .unconfirmed }
    }
}
