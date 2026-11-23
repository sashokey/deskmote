import Foundation

@main
enum FinderFileCreationServiceMain {
    static func main() {
        let extensionURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let requirement = FinderFileCreationIPC.requirement(for: extensionURL) else {
            FinderFileCreationIPC.logger.error("Invalid enclosing Finder extension signature")
            return
        }

        let listener = NSXPCListener.service()
        let handler = FinderFileCreationListener(peerRequirement: requirement)
        listener.delegate = handler
        withExtendedLifetime(handler) {
            listener.resume()
        }
    }
}
