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
        } catch let failure as POSIXError {
            FinderFileCreationIPC.logger.error("Finder file creation failed with errno \(failure.code.rawValue, privacy: .public)")
            reply(false)
        } catch {
            FinderFileCreationIPC.logger.error("Finder file creation failed")
            reply(false)
        }
    }
}

final class FinderFileCreationListener: NSObject, NSXPCListenerDelegate {
    private let peerRequirement: String

    init(peerRequirement: String) {
        self.peerRequirement = peerRequirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(peerRequirement)
        connection.exportedInterface = NSXPCInterface(with: FinderFileCreationProtocol.self)
        connection.exportedObject = FinderFileCreationHandler()
        connection.activate()
        return true
    }
}
