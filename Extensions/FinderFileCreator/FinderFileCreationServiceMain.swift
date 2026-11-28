import Foundation

@main
enum FinderFileCreationServiceMain {
    static func main() {
        let extensionURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let handler = FinderFileCreationListener(extensionURL: extensionURL) else { return }

        let listener = NSXPCListener.service()
        listener.delegate = handler
        withExtendedLifetime(handler) {
            listener.resume()
        }
    }
}
