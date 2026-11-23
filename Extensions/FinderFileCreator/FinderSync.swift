import AppKit
import FinderSync
import os

final class FinderSync: FIFinderSync {
    private let targetedURL: @Sendable () -> URL?
    private let submit: @Sendable (NewFileType, URL, FinderDirectoryIdentity) -> FinderFileCreationClient.Outcome
    private static let requests = DispatchQueue(label: "io.github.sashokey.deskmote.finder-sync.requests", qos: .userInitiated)
    #if DESKMOTE_QA_JOURNAL
    private static let qaLogger = Logger(subsystem: "io.github.sashokey.deskmote.finder-sync", category: "QA")
    #endif

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
        #if DESKMOTE_QA_JOURNAL
        Self.qaLogger.notice("finder.action.received")
        #endif
        guard let type = NewFileType(rawValue: sender.tag),
              let directory = targetedURL(),
              directory.isFileURL,
              let identity = FinderDirectoryIdentity.capture(at: directory) else {
            #if DESKMOTE_QA_JOURNAL
            Self.qaLogger.notice("finder.action.invalid-selection")
            #endif
            NSSound.beep()
            return
        }

        #if DESKMOTE_QA_JOURNAL
        Self.qaLogger.notice("finder.action.target-captured")
        #endif
        Self.requests.async { [submit] in
            switch submit(type, directory, identity) {
            case .created:
                #if DESKMOTE_QA_JOURNAL
                Self.qaLogger.notice("finder.create.succeeded")
                #endif
                break
            case .failed:
                #if DESKMOTE_QA_JOURNAL
                Self.qaLogger.notice("finder.create.failed")
                #endif
                NSSound.beep()
            case .unconfirmed:
                #if DESKMOTE_QA_JOURNAL
                Self.qaLogger.notice("finder.create.unconfirmed")
                #endif
                break
            }
        }
    }
}
