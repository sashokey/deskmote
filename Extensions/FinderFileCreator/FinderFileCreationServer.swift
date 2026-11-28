import Foundation

final class FinderFileCreationHandler: NSObject, FinderFileCreationProtocol {
    func ready(withReply reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }

    func createFile(_ type: Int, in path: String, identity: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
        guard let fileType = NewFileType(rawValue: type),
              let directory = FinderFileCreationIPC.destination(for: path),
              identity.count <= 256, let captured = try? JSONDecoder().decode(FinderDirectoryIdentity.self, from: identity) else {
            reply(false)
            return
        }

        do {
            _ = try FileCreator.create(fileType, in: directory, expectedDirectory: captured)
            reply(true)
        } catch {
            reply(false)
        }
    }
}

final class FinderFileCreationListener: NSObject, NSXPCListenerDelegate {
    private let peerRequirement: String

    init?(extensionURL: URL) {
        guard let requirement = FinderFileCreationIPC.requirement(for: extensionURL) else { return nil }
        peerRequirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(peerRequirement)
        connection.exportedInterface = NSXPCInterface(with: FinderFileCreationProtocol.self)
        connection.exportedObject = FinderFileCreationHandler()
        connection.activate()
        return true
    }
}
