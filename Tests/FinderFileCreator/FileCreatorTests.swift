import AppKit
import Darwin
import Foundation
import Synchronization

@main
enum FileCreatorTests {
    static func main() async {
        do {
            try testCreatesEmptyTextDocument()
            try testLeavesAnExistingFileUntouched()
            try testSkipsOccupiedNames()
            try testConcurrentCreation()
            try testFailsOutsideAnExistingDirectory()
            try testCreatesZIPThatMacOSCanExtract()
            try testRemovesIncompleteArchive()
            try testArchiveIsPublishedAfterTheWriteFinishes()
            try testArchiveRejectsAReplacedDestinationBeforePublication()
            try testArchiveCanBeCreatedWhenOnlyFilesMayBeAdded()
            try testArchiveInheritsTheDestinationACL()
            try testArchiveCanBeCreatedWhenOnlyTheParentAllowsAddingFiles()
            try testArchiveCanInheritARestrictionAgainstDeletion()
            try testFinderMenuHasDirectCreationCommands()
            try await Task.detached { try testRequestedFileAndFolderFollowFinderAction() }.value
            print("15 tests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func testFinderMenuHasDirectCreationCommands() throws {
        let finder = FinderSync(
            targetedURL: { URL(fileURLWithPath: "/tmp", isDirectory: true) },
            submit: { _, _, _ in .failed }
        )
        guard let menu = finder.menu(for: .contextualMenuForContainer) else {
            throw Failure("Finder must receive the menu")
        }
        let items = menu.items
        try expect(items.map(\.title) == ["New Text Document", "New Compressed (zipped) Folder"],
                   "Finder must have one direct creation command per type")
        try expect(items.allSatisfy { $0.isEnabled && $0.action != nil && $0.submenu == nil },
                   "Both creation commands must be directly actionable")
    }

    private static func testRequestedFileAndFolderFollowFinderAction() throws {
        try expect(!Thread.isMainThread, "Finder action must run on a worker thread")
        try inTemporaryDirectory { menuTarget in
            try inTemporaryDirectory { actionTarget in
                let target = Mutex(menuTarget)
                let request = Mutex<(NewFileType, URL, Bool)?>(nil)
                let actionReturned = DispatchSemaphore(value: 0)
                let requestSubmitted = DispatchSemaphore(value: 0)
                let finder = FinderSync(
                    targetedURL: { target.withLock { $0 } },
                    submit: { type, directory, identity in
                        let asynchronous = actionReturned.wait(timeout: .now() + .seconds(1)) == .success
                        let matchesFolder = FinderDirectoryIdentity.capture(at: directory) == identity
                        request.withLock { $0 = (type, directory, asynchronous && matchesFolder) }
                        requestSubmitted.signal()
                        return .created
                    }
                )
                guard let item = finder.menu(for: .contextualMenuForContainer)?.item(withTitle: "New Text Document"),
                      let action = item.action else {
                    throw Failure("Finder menu did not provide a text document action")
                }

                target.withLock { $0 = actionTarget }
                _ = finder.perform(action, with: item)
                target.withLock { $0 = menuTarget }
                actionReturned.signal()

                try expect(requestSubmitted.wait(timeout: .now() + .seconds(2)) == .success,
                           "Finder must submit the chosen command")
                try expect(request.withLock { $0?.0 == .textDocument && $0?.1 == actionTarget },
                           "Finder must submit the chosen type and current target")
                try expect(request.withLock { $0?.2 == true }, "Finder must return before XPC completes")
                try expect(FileManager.default.contentsOfDirectory(atPath: actionTarget.path).isEmpty,
                           "Finder Sync must leave file creation to the broker")
            }
        }
    }

    private static func testCreatesEmptyTextDocument() throws {
        try inTemporaryDirectory { directory in
            let file = try FileCreator.create(.textDocument, in: directory)
            try expect(file == directory.appending(path: "New Text Document.txt"), "First filename")
            try expect(Data(contentsOf: file).isEmpty, "New document must be empty")
        }
    }

    private static func testLeavesAnExistingFileUntouched() throws {
        try inTemporaryDirectory { directory in
            let existing = directory.appending(path: "New Text Document.txt")
            let original = Data("keep this".utf8)
            try original.write(to: existing)

            let file = try FileCreator.create(.textDocument, in: directory)
            try expect(file.lastPathComponent == "New Text Document (2).txt", "Second filename")
            try expect(Data(contentsOf: existing) == original, "Existing document was changed")
            try expect(Data(contentsOf: file).isEmpty, "Second document must be empty")
        }
    }

    private static func testSkipsOccupiedNames() throws {
        try inTemporaryDirectory { directory in
            let occupied = directory.appending(path: "New Text Document.txt")
            let link = directory.appending(path: "New Text Document (2).txt")
            try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appending(path: "missing"))

            let file = try FileCreator.create(.textDocument, in: directory)
            try expect(file.lastPathComponent == "New Text Document (3).txt", "Directories and dangling links occupy names")
            try expect(!FileManager.default.fileExists(atPath: directory.appending(path: "missing").path), "Symlink target was created")
        }
    }

    private static func testConcurrentCreation() throws {
        try inTemporaryDirectory { directory in
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                _ = try? FileCreator.create(.textDocument, in: directory)
            }

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let expected = ["New Text Document.txt"] + (2...12).map { "New Text Document (\($0)).txt" }
            try expect(Set(names) == Set(expected), "Concurrent requests must each create a unique file")
        }
    }

    private static func testFailsOutsideAnExistingDirectory() throws {
        try inTemporaryDirectory { directory in
            do {
                _ = try FileCreator.create(.textDocument, in: directory.appending(path: "missing"))
            } catch let error as NSError where
                (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                try expect(FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Unexpected files after failed creation")
                return
            }
            throw Failure("Creation unexpectedly succeeded without a destination")
        }
    }

    private static func testCreatesZIPThatMacOSCanExtract() throws {
        try inTemporaryDirectory { directory in
            let first = try FileCreator.create(.zipArchive, in: directory)
            let second = try FileCreator.create(.zipArchive, in: directory)
            try expect(first.lastPathComponent == "New Compressed (zipped) Folder.zip", "First archive filename")
            try expect(second.lastPathComponent == "New Compressed (zipped) Folder (2).zip", "Second archive filename")
            try expect(Data(contentsOf: first) == Data(contentsOf: second), "Both archives must have the same contents")

            let extracted = directory.appending(path: "Extracted", directoryHint: .isDirectory)
            let extractor = Process()
            extractor.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extractor.arguments = ["-x", "-k", first.path, extracted.path]
            try extractor.run()
            extractor.waitUntilExit()
            try expect(extractor.terminationStatus == 0, "macOS could not extract the archive")

            let manager = FileManager.default
            try expect(manager.contentsOfDirectory(atPath: extracted.path) == ["Folder"], "Archive must contain one folder")
            let folder = extracted.appending(path: "Folder", directoryHint: .isDirectory)
            try expect(manager.contentsOfDirectory(atPath: folder.path).isEmpty, "The folder must be empty")
        }
    }

    private static func testRemovesIncompleteArchive() throws {
        try inTemporaryDirectory { directory in
            var originalLimit = rlimit()
            try expect(getrlimit(RLIMIT_FSIZE, &originalLimit) == 0, "Could not read file-size limit")
            var limited = originalLimit
            limited.rlim_cur = 1

            let previousHandler = signal(SIGXFSZ, SIG_IGN)
            defer {
                _ = setrlimit(RLIMIT_FSIZE, &originalLimit)
                _ = signal(SIGXFSZ, previousHandler)
            }
            try expect(setrlimit(RLIMIT_FSIZE, &limited) == 0, "Could not set file-size limit")

            do {
                _ = try FileCreator.create(.zipArchive, in: directory)
            } catch {
                try expect(FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Incomplete archive remained on disk")
                return
            }
            throw Failure("Creation unexpectedly succeeded with a one-byte file-size limit")
        }
    }

    private static func testArchiveIsPublishedAfterTheWriteFinishes() throws {
        try inTemporaryDirectory { directory in
            let archive = directory.appending(path: "New Compressed (zipped) Folder.zip")
            let file = try FileCreator.create(.zipArchive, in: directory) { handle, data in
                try handle.write(contentsOf: data.prefix(1))
                try expect(!FileManager.default.fileExists(atPath: archive.path),
                           "The public filename must not expose a partially written archive")
                try handle.write(contentsOf: data.dropFirst())
            }
            try expect(file == archive, "The finished archive must have its usual name")
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "Publication must preserve the entire archive")
            try expect(FileManager.default.contentsOfDirectory(atPath: directory.path) == [archive.lastPathComponent],
                       "Staging must be removed after publication")
        }
    }

    private static func testArchiveRejectsAReplacedDestinationBeforePublication() throws {
        try inTemporaryDirectory { parent in
            let destination = parent.appending(path: "Selected", directoryHint: .isDirectory)
            let original = parent.appending(path: "Original", directoryHint: .isDirectory)
            let manager = FileManager.default
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            guard let identity = FinderDirectoryIdentity.capture(at: destination) else {
                throw Failure("Could not capture the original directory")
            }
            do {
                _ = try FileCreator.create(.zipArchive, in: destination, expectedDirectory: identity) { handle, data in
                    try handle.write(contentsOf: data)
                    try manager.moveItem(at: destination, to: original)
                    try manager.createDirectory(at: destination, withIntermediateDirectories: false)
                }
                throw Failure("An archive was published after the selected directory changed")
            } catch let error as POSIXError where error.code == .ESTALE {
                try expect(manager.contentsOfDirectory(atPath: destination.path).isEmpty,
                           "The replacement must stay empty")
                try expect(manager.contentsOfDirectory(atPath: original.path).isEmpty,
                           "The original directory must stay empty too")
            }
        }
    }

    private static func testArchiveCanBeCreatedWhenOnlyFilesMayBeAdded() throws {
        try inTemporaryDirectory { directory in
            let permissions = Process()
            permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
            permissions.arguments = ["+a", "everyone deny add_subdirectory", directory.path]
            try permissions.run()
            permissions.waitUntilExit()
            try expect(permissions.terminationStatus == 0, "Could not set the fixture ACL")
            let text = try FileCreator.create(.textDocument, in: directory)
            let archive = try FileCreator.create(.zipArchive, in: directory)
            try expect(Data(contentsOf: text).isEmpty, "Creating ordinary files must be allowed")
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "The ZIP must also be created as a regular file")
        }
    }

    private static func testArchiveInheritsTheDestinationACL() throws {
        try inTemporaryDirectory { directory in
            let permissions = Process()
            permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
            permissions.arguments = ["+a", "everyone allow read,file_inherit,only_inherit,limit_inherit", directory.path]
            try permissions.run()
            permissions.waitUntilExit()
            try expect(permissions.terminationStatus == 0, "Could not set inherited file permissions")
            let text = try FileCreator.create(.textDocument, in: directory)
            let zip = try FileCreator.create(.zipArchive, in: directory)
            let expected = try aclText(text)
            try expect(expected.contains("inherited"), "The native file must inherit the fixture ACL")
            try expect(aclText(zip) == expected, "The published archive must have the destination's file ACL")
        }
    }

    private static func testArchiveCanBeCreatedWhenOnlyTheParentAllowsAddingFiles() throws {
        try inTemporaryDirectory { directory in
            let permissions = Process()
            permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
            permissions.arguments = ["+a", "everyone deny add_file,directory_inherit,only_inherit", directory.path]
            try permissions.run()
            permissions.waitUntilExit()
            try expect(permissions.terminationStatus == 0, "Could not set the directory inheritance fixture")
            let archive = try FileCreator.create(.zipArchive, in: directory)
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "An inherited restriction on subdirectories must not block creating a file here")
        }
    }

    private static func testArchiveCanInheritARestrictionAgainstDeletion() throws {
        try inTemporaryDirectory { directory in
            defer {
                let cleanup = Process()
                cleanup.executableURL = URL(fileURLWithPath: "/bin/chmod")
                cleanup.arguments = ["-RN", directory.path]
                if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
            }
            let permissions = Process()
            permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
            permissions.arguments = ["+a", "everyone deny delete,file_inherit,only_inherit", directory.path]
            try permissions.run()
            permissions.waitUntilExit()
            try expect(permissions.terminationStatus == 0, "Could not set the inherited deletion restriction")
            let text = try FileCreator.create(.textDocument, in: directory)
            let archive = try FileCreator.create(.zipArchive, in: directory)
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "The archive must be published even when published files cannot be deleted")
            try expect(aclText(archive) == aclText(text), "The archive must inherit the same restrictions as the text file")
        }
    }

    private static func aclText(_ file: URL) throws -> String {
        guard let acl = acl_get_file(file.path, ACL_TYPE_EXTENDED) else { throw Failure("Could not read file ACL") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw Failure("Could not format file ACL") }
        defer { acl_free(text) }
        return String(cString: text)
    }

    private static func inTemporaryDirectory(_ test: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        try test(directory)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
