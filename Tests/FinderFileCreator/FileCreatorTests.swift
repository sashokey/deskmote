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
            try testArchiveSkipsAnOccupiedSymbolicLinkName()
            try testRemovesIncompleteArchive()
            try testArchiveIsPublishedAfterTheWriteFinishes()
            try testArchiveRejectsAReplacedDestinationBeforePublication()
            try testArchiveAvoidsStagingParentsThatMayPreventCleanup()
            try testArchiveUsesProtectedTempWhenSelectedFolderDeniesDeletion()
            try testArchiveFallsBackWhenTemporaryParentDeniesMkdir()
            try testArchiveFallsBackWhenInheritedACLBlocksStagingAccess()
            try testArchiveCanBeCreatedWhenOnlyFilesMayBeAdded()
            try testArchiveInheritsTheDestinationACL()
            try testArchiveCanBeCreatedWhenOnlyTheParentAllowsAddingFiles()
            try testArchiveCanInheritARestrictionAgainstDeletion()
            try testArchiveWithoutCloningPreservesInheritedPermissions()
            try testArchiveWithoutCloningCleansUpAfterDeniedRename()
            try testArchiveWithoutCloningReportsUnsafeHardLinkCleanup()
            try testArchiveCleansUpWhenPathStatIsDenied()
            try testACLPermissionMasksCoverGenericAndUnknownRights()
            try testFinderMenuHasDirectCreationCommands()
            try await Task.detached { try testRequestedFileAndFolderFollowFinderAction() }.value
            print("25 tests passed")
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

    private static func testArchiveSkipsAnOccupiedSymbolicLinkName() throws {
        try inTemporaryDirectory { directory in
            let link = directory.appending(path: "New Compressed (zipped) Folder.zip")
            let manager = FileManager.default
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: link.lastPathComponent)

            let archive = try FileCreator.create(.zipArchive, in: directory)
            try expect(archive.lastPathComponent == "New Compressed (zipped) Folder (2).zip",
                       "An existing symbolic link must occupy the first archive name")
            try expect(manager.destinationOfSymbolicLink(atPath: link.path) == link.lastPathComponent,
                       "The existing symbolic link must be left intact")
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "The returned numbered path must contain the complete ZIP")
        }
    }

    private static func testRemovesIncompleteArchive() throws {
        enum InjectedWriteError: Error {
            case interrupted
        }

        try inTemporaryDirectory { root in
            let temporary = try fixtureDirectory("Temporary", in: root)
            let destination = try fixtureDirectory("Selected", in: root)
            let temporaryIdentity = FinderDirectoryIdentity.capture(at: temporary)
            let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary)
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

            var actualParents = [FinderDirectoryIdentity]()
            do {
                _ = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                    actualParents.append(try stagingParentIdentity(of: handle))
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        try expect(lseek(handle.fileDescriptor, 0, SEEK_CUR) == 1,
                                   "The limited write must leave exactly one byte before failing")
                        throw InjectedWriteError.interrupted
                    }
                }
            } catch InjectedWriteError.interrupted {
                try expect(actualParents.count == 1 && actualParents.first == temporaryIdentity,
                           "The failed write must occur once in the controlled temporary directory")
                try expect(FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty,
                           "The incomplete archive and staging directory must be removed")
                try expect(FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                           "A failed write must leave the selected directory empty")
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

    private static func testArchiveAvoidsStagingParentsThatMayPreventCleanup() throws {
        let restrictions: [(String, (URL) throws -> Void)] = [
            ("delete-child ACL", { try changeFixtureACL(["+a", "everyone deny delete_child"], at: $0) }),
            ("directory-inherited delete ACL", {
                try changeFixtureACL(["+a", "everyone deny delete,directory_inherit,only_inherit"], at: $0)
            }),
            ("append-only flag", {
                try expect(chflags($0.path, UInt32(UF_APPEND)) == 0, "Could not set the fixture's append-only flag")
            }),
            ("ACL-only creation", {
                try expect(chmod($0.path, 0o500) == 0, "Could not set the fixture's POSIX mode")
                try changeFixtureACL(["+a", "everyone allow add_subdirectory"], at: $0)
            })
        ]
        var unsafe = [String]()
        for (restriction, configure) in restrictions {
            try inTemporaryDirectory { root in
                let temporary = try fixtureDirectory("Temporary", in: root)
                let destination = try fixtureDirectory("Selected", in: root)
                defer {
                    _ = chflags(temporary.path, 0)
                    _ = chmod(temporary.path, 0o700)
                    try? changeFixtureACL(["-RN"], at: temporary)
                }
                try configure(temporary)
                let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary)
                var actualParent: FinderDirectoryIdentity?
                let archive = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                    actualParent = try stagingParentIdentity(of: handle)
                    try handle.write(contentsOf: data)
                }
                try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                           "The complete ZIP must be published in the selected directory")
                try expect(FileManager.default.contentsOfDirectory(atPath: destination.path) == [archive.lastPathComponent],
                           "The selected directory must have no staging entries after publication")
                let remaining = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
                if actualParent != FinderDirectoryIdentity.capture(at: destination) || !remaining.isEmpty {
                    unsafe.append(restriction)
                }
            }
        }
        try expect(unsafe.isEmpty, "ZIP staging required a removable parent under: \(unsafe.joined(separator: ", "))")
    }

    private static func testArchiveUsesProtectedTempWhenSelectedFolderDeniesDeletion() throws {
        try inTemporaryDirectory { root in
            let temporary = try fixtureDirectory("Temporary", in: root)
            let destination = try fixtureDirectory("Selected", in: root)
            defer { try? changeFixtureACL(["-RN"], at: destination) }
            try changeFixtureACL(["+a", "everyone deny delete_child"], at: destination)

            let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary)
            let temporaryIdentity = FinderDirectoryIdentity.capture(at: temporary)
            let archive = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                try expect(temporaryIdentity != nil && stagingParentIdentity(of: handle) == temporaryIdentity,
                           "The actual archive staging parent must be the protected temporary directory")
                try handle.write(contentsOf: data)
            }
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "The selected directory must receive the complete ZIP")
            try expect(FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty,
                       "The protected temporary directory must be cleaned up")
            try expect(FileManager.default.contentsOfDirectory(atPath: destination.path) == [archive.lastPathComponent],
                       "Only the finished ZIP may be left in the selected directory")
        }
    }

    private static func testArchiveFallsBackWhenTemporaryParentDeniesMkdir() throws {
        try inTemporaryDirectory { root in
            let temporary = try fixtureDirectory("Temporary", in: root)
            let destination = try fixtureDirectory("Selected", in: root)
            try changeFixtureACL(["+a", "everyone deny add_subdirectory"], at: temporary)
            let destinationIdentity = FinderDirectoryIdentity.capture(at: destination)
            let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary)
            var actualParents = [FinderDirectoryIdentity]()
            let archive = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                actualParents.append(try stagingParentIdentity(of: handle))
                try handle.write(contentsOf: data)
            }
            try expect(actualParents.count == 1 && actualParents.first == destinationIdentity,
                       "After mkdir is denied, write once under the verified selected directory")
            try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                       "The fallback must publish the complete archive")
            try expect(FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty,
                       "The denied staging parent must stay empty")
            try expect(FileManager.default.contentsOfDirectory(atPath: destination.path) == [archive.lastPathComponent],
                       "Fallback staging must be removed")
        }
    }

    private static func testArchiveFallsBackWhenInheritedACLBlocksStagingAccess() throws {
        let fixtures = [
            (principal: "everyone", right: "search", deniesSearch: true, fallsBack: true),
            (principal: "everyone", right: "readattr", deniesSearch: false, fallsBack: true),
            (principal: "everyone", right: "readsecurity", deniesSearch: false, fallsBack: true),
            (principal: "user:root", right: "search,readattr,readsecurity", deniesSearch: false, fallsBack: false)
        ]
        var failures = [String]()
        for (principal, right, deniesSearch, fallsBack) in fixtures {
            try inTemporaryDirectory { root in
                let temporary = try fixtureDirectory("Temporary", in: root)
                let destination = try fixtureDirectory("Selected", in: root)
                try changeFixtureACL(["+a", "\(principal) deny \(right),directory_inherit,only_inherit"], at: temporary)
                try verifyStagingAccess(under: temporary, right: right, deniesSearch: deniesSearch,
                                        deniesStat: fallsBack && !deniesSearch)
                let manager = FileManager.default
                let beforeStaging = Date(timeIntervalSince1970: 946_684_800)
                try manager.setAttributes([.modificationDate: beforeStaging], ofItemAtPath: temporary.path)

                let expectedParent = FinderDirectoryIdentity.capture(at: fallsBack ? destination : temporary)
                try expect(expectedParent != nil, "Could not identify the expected staging parent")
                let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary)
                var actualParents = [FinderDirectoryIdentity]()
                let archive: URL
                do {
                    archive = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                        actualParents.append(try stagingParentIdentity(of: handle))
                        let attributes = try manager.attributesOfItem(atPath: temporary.path)
                        try expect((attributes[.modificationDate] as? Date).map { $0 > beforeStaging } == true,
                                   "The temporary parent must host staging before the write for \(right)")
                        try expect(manager.contentsOfDirectory(atPath: temporary.path).isEmpty == fallsBack,
                                   "Temporary staging must be removed before a fallback write")
                        try handle.write(contentsOf: data)
                    }
                } catch let error as POSIXError where error.code == .EACCES && fallsBack {
                    failures.append(right)
                    return
                }
                try expect(actualParents.count == 1 && actualParents.first == expectedParent,
                           "Write once in the expected staging parent for \(principal) deny \(right)")
                try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                           "The selected directory must receive the complete ZIP")
                try expect(manager.contentsOfDirectory(atPath: temporary.path).isEmpty,
                           "No staging directory may remain in the temporary parent")
                try expect(manager.contentsOfDirectory(atPath: destination.path) == [archive.lastPathComponent],
                           "Only the finished ZIP may be left in the selected directory")
            }
        }
        try expect(failures.isEmpty, "Staging must fall back after inherited access is denied: \(failures.joined(separator: ", "))")
    }

    private static func verifyStagingAccess(under directory: URL, right: String, deniesSearch: Bool,
                                            deniesStat: Bool) throws {
        let parent = open(directory.path, O_SEARCH | O_CLOEXEC)
        try expect(parent >= 0, "The inherited ACL must allow opening the parent for \(right)")
        defer { _ = close(parent) }
        var info = stat()
        try expect(fstat(parent, &info) == 0, "The inherited ACL must allow stat of the parent for \(right)")
        let name = "Probe"
        try expect(mkdirat(parent, name, 0o700) == 0, "The inherited ACL must allow mkdir for \(right)")

        let probe = openat(parent, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        let openError = errno
        if deniesSearch {
            if probe >= 0 { _ = close(probe) }
            try expect(probe < 0 && openError == EACCES, "Inherited \(right) must deny the staging open")
        } else {
            try expect(probe >= 0, "Inherited \(right) must allow the staging open")
            defer { _ = close(probe) }
            let result = fstat(probe, &info)
            let statError = errno
            try expect(deniesStat ? result != 0 && statError == EACCES : result == 0,
                       "Unexpected staging stat result with inherited \(right)")
        }
        try expect(unlinkat(parent, name, AT_REMOVEDIR) == 0, "The inherited ACL must allow removing empty staging for \(right)")
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

    private static func testArchiveWithoutCloningPreservesInheritedPermissions() throws {
        let configurations: [(String, Bool)] = [
            ("user:root deny delete,file_inherit,only_inherit", false),
            ("everyone allow read,file_inherit,only_inherit", true)
        ]
        for (rule, renameUnsupported) in configurations {
            try inTemporaryDirectory { root in
                let temporary = try fixtureDirectory("Temporary", in: root)
                let destination = try fixtureDirectory("Selected", in: root)
                try changeFixtureACL(["+a", rule], at: destination)
                let text = try FileCreator.create(.textDocument, in: destination)
                let occupied = destination.appending(path: "New Compressed (zipped) Folder.zip")
                let original = Data("keep this".utf8)
                try original.write(to: occupied)
                let fileSystem = renameUnsupported
                    ? FileCreator.ArchiveFileSystem(temporaryDirectory: temporary,
                                                   clone: cloneUnsupported, rename: renameUnavailable)
                    : FileCreator.ArchiveFileSystem(temporaryDirectory: temporary, clone: cloneUnsupported)

                let archive = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem)
                try expect(archive.lastPathComponent == "New Compressed (zipped) Folder (2).zip",
                           "Fallback publication must preserve numbering")
                try expect(Data(contentsOf: occupied) == original, "Fallback publication must preserve the occupied file")
                try expect(Data(contentsOf: archive) == NewFileType.zipArchive.initialContents,
                           "Fallback publication must preserve the entire ZIP")
                try expect(aclText(archive) == aclText(text), "Fallback publication must preserve the inherited ACL")
                try expect(FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty,
                           "Fallback publication must clean up staging")
            }
        }
    }

    private static func testArchiveWithoutCloningCleansUpAfterDeniedRename() throws {
        try verifyFailedArchivePublication(renameUnsupported: false)
    }

    private static func testArchiveWithoutCloningReportsUnsafeHardLinkCleanup() throws {
        try verifyFailedArchivePublication(renameUnsupported: true)
    }

    private static func testArchiveCleansUpWhenPathStatIsDenied() throws {
        var leftovers = [String]()
        for readRight in ["readattr", "readsecurity"] {
            try inTemporaryDirectory { root in
                let temporary = try fixtureDirectory("Temporary", in: root)
                let destination = try fixtureDirectory("Selected", in: root)
                try changeFixtureACL(["+a", "everyone deny delete,\(readRight),file_inherit,only_inherit"], at: destination)
                var archiveDescriptor: Int32 = -1
                var renameDeniedAfterStat = false
                defer {
                    if archiveDescriptor >= 0 {
                        if let empty = acl_init(0) {
                            _ = acl_set_fd_np(archiveDescriptor, empty, ACL_TYPE_EXTENDED)
                            acl_free(UnsafeMutableRawPointer(empty))
                        }
                        _ = close(archiveDescriptor)
                    }
                }
                let fileSystem = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary, clone: cloneUnsupported) {
                    staging, selected, name in
                    var info = stat()
                    let observed = fstatat(staging, "archive", &info, AT_SYMLINK_NOFOLLOW)
                    try expect(observed != 0 && errno == EACCES, "The inherited ACL must deny pathname stat")
                    try expect(fstat(archiveDescriptor, &info) == 0, "The open descriptor must still identify the archived file")
                    let renamed = renameatx_np(staging, "archive", selected, name, UInt32(RENAME_EXCL))
                    let renameError = POSIXErrorCode(rawValue: errno) ?? .EIO
                    try expect(renamed != 0 && renameError == .EACCES, "The inherited ACL must deny exclusive rename")
                    renameDeniedAfterStat = true
                    throw POSIXError(renameError)
                }
                do {
                    _ = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem) { handle, data in
                        try expect(archiveDescriptor == -1, "Denied publication must attempt the archive write once")
                        archiveDescriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                        try expect(archiveDescriptor >= 0, "Could not retain the fixture archive descriptor")
                        try handle.write(contentsOf: data)
                    }
                    throw Failure("ZIP publication unexpectedly succeeded with an effective delete restriction")
                } catch let error as POSIXError where error.code == .EACCES {
                    try expect(renameDeniedAfterStat, "Creation must reach the real rename after pathname stat is denied for \(readRight)")
                    try expect(FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                               "Denied rename must leave the selected directory empty")
                    if try !FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty {
                        leftovers.append(readRight)
                    }
                }
            }
        }
        try expect(leftovers.isEmpty, "Staging was left behind with denied: \(leftovers.joined(separator: ", "))")
    }

    private static func verifyFailedArchivePublication(renameUnsupported: Bool) throws {
        try inTemporaryDirectory { root in
            let temporary = try fixtureDirectory("Temporary", in: root)
            let destination = try fixtureDirectory("Selected", in: root)
            try changeFixtureACL(["+a", "everyone deny delete,file_inherit,only_inherit"], at: destination)
            let native = FileCreator.ArchiveFileSystem(temporaryDirectory: temporary, clone: cloneUnsupported)
            let fileSystem = renameUnsupported
                ? FileCreator.ArchiveFileSystem(temporaryDirectory: temporary,
                                               clone: cloneUnsupported, rename: renameUnavailable)
                : native

            do {
                _ = try FileCreator.create(.zipArchive, in: destination, archiveFileSystem: fileSystem)
                throw Failure("ZIP publication unexpectedly succeeded with an effective delete restriction")
            } catch FileCreator.ArchivePublicationError.hardLinkCleanupMayBeDenied where renameUnsupported {
            } catch let error as POSIXError where error.code == .EACCES && !renameUnsupported {
            } catch {
                throw Failure("Unexpected ZIP publication error: \(error)")
            }
            try expect(FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                       "Failed publication must leave the selected directory empty")
            try expect(FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty,
                       "Failed publication must remove the staged file and directory")
        }
    }

    private static func cloneUnsupported(_ archive: Int32, _ destination: Int32, _ name: String) throws {
        throw POSIXError(.ENOTSUP)
    }

    private static func testACLPermissionMasksCoverGenericAndUnknownRights() throws {
        var standard: acl_permset_mask_t = 0
        try expect(acl_maximal_permset_mask_np(&standard) == 0, "Could not read the system ACL mask")
        let delete = UInt64(ACL_DELETE.rawValue)
        let deleteChild = UInt64(ACL_DELETE_CHILD.rawValue)
        let writeSecurity = UInt64(ACL_WRITE_SECURITY.rawValue)
        let addSubdirectory = UInt64(ACL_ADD_SUBDIRECTORY.rawValue)
        let readAttributes = UInt64(ACL_READ_ATTRIBUTES.rawValue)
        let readSecurity = UInt64(ACL_READ_SECURITY.rawValue)
        let execute = UInt64(ACL_EXECUTE.rawValue)
        let relevantWrite = delete | deleteChild | writeSecurity | addSubdirectory
        let relevantRead = readAttributes | readSecurity
        let fixtures: [(String, UInt64, UInt64, UInt64)] = [
            ("generic all", UInt64(KAUTH_ACE_GENERIC_ALL), relevantWrite | relevantRead | execute, 0),
            ("generic write", UInt64(KAUTH_ACE_GENERIC_WRITE), relevantWrite, relevantRead),
            ("generic read", UInt64(KAUTH_ACE_GENERIC_READ), relevantRead, relevantWrite),
            ("generic execute", UInt64(KAUTH_ACE_GENERIC_EXECUTE), execute, relevantWrite | relevantRead),
            ("ordinary read", readAttributes, readAttributes, relevantWrite | readSecurity),
            ("unrecognized access bit", UInt64(1) << 31, relevantWrite | relevantRead, 0)
        ]
        var unrecognized = [String]()
        for (name, mask, expected, excluded) in fixtures {
            let expanded = FileCreator.expandedACLPermissions(mask, knownPermissions: standard)
            if expanded & expected != expected || expanded & excluded != 0 {
                unrecognized.append(name)
            }
        }
        try expect(unrecognized.isEmpty, "Incorrect ACL permissions for: \(unrecognized.joined(separator: ", "))")
    }

    private static func renameUnavailable(_ staging: Int32, _ destination: Int32, _ name: String) throws {
        throw POSIXError(.ENOTSUP)
    }

    private static func fixtureDirectory(_ name: String, in parent: URL) throws -> URL {
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func changeFixtureACL(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [directory.path]
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Could not change the fixture ACL")
    }

    private static func stagingParentIdentity(of handle: FileHandle) throws -> FinderDirectoryIdentity {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return try buffer.withUnsafeMutableBufferPointer { path in
            guard let address = path.baseAddress, fcntl(handle.fileDescriptor, F_GETPATH, address) == 0 else {
                throw Failure("Could not look up the staged archive")
            }
            let archive = URL(fileURLWithFileSystemRepresentation: address, isDirectory: false, relativeTo: nil)
            let parent = archive.deletingLastPathComponent().deletingLastPathComponent()
            guard let identity = FinderDirectoryIdentity.capture(at: parent) else {
                throw Failure("Could not identify the staging parent")
            }
            return identity
        }
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
