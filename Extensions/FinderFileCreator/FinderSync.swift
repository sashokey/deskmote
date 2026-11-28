import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    private let targetedURL: @Sendable () -> URL?
    private let submit: @Sendable (NewFileType, URL, FinderDirectoryIdentity) -> FinderFileCreationClient.Outcome
    private static let requests = DispatchQueue(label: "io.github.sashokey.deskmote.finder-sync.requests", qos: .userInitiated)

    override convenience init() {
        let extensionBundle = Bundle(for: FinderSync.self)
        self.init(
            targetedURL: { FIFinderSyncController.default().targetedURL() },
            submit: { FinderFileCreationClient.send($0, to: $1, identity: $2, in: extensionBundle) }
        )
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    init(targetedURL: @escaping @Sendable () -> URL?,
         submit: @escaping @Sendable (NewFileType, URL, FinderDirectoryIdentity) -> FinderFileCreationClient.Outcome) {
        self.targetedURL = targetedURL
        self.submit = submit
        super.init()
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForContainer, targetedURL()?.isFileURL == true else {
            return nil
        }

        let menu = NSMenu()

        for type in NewFileType.allCases {
            let item = NSMenuItem(title: type.menuTitle, action: #selector(createFile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = type.rawValue
            menu.addItem(item)
        }

        return menu
    }

    @objc nonisolated private func createFile(_ sender: NSMenuItem) {
        guard let type = NewFileType(rawValue: sender.tag),
              let directory = targetedURL(),
              directory.isFileURL,
              let identity = FinderDirectoryIdentity.capture(at: directory) else {
            NSSound.beep()
            return
        }

        Self.requests.async { [submit] in
            switch submit(type, directory, identity) {
            case .created:
                break
            case .failed:
                NSSound.beep()
            case .unconfirmed:
                break
            }
        }
    }
}
