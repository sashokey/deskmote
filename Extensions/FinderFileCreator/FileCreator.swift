import Darwin
import Foundation

enum FileCreator {
    private enum ArchiveStagingError: Error {
        case needsParentGroup
    }

    static func create(_ type: NewFileType, in directory: URL,
                       expectedDirectory: FinderDirectoryIdentity? = nil,
                       write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws -> URL {
        let contents = type.initialContents
        let destination = try openDirectory(directory)
        defer { _ = close(destination) }
        var destinationInfo = stat()
        guard fstat(destination, &destinationInfo) == 0 else { throw fileError() }
        if let expectedDirectory {
            guard FinderDirectoryIdentity(destinationInfo) == expectedDirectory else { throw POSIXError(.ESTALE) }
        }

        if contents.isEmpty {
            return try publish(type, in: directory) { name in
                try verifyDestination(directory, expected: expectedDirectory)
                let descriptor = try openNewFile(name, in: destination)
                guard close(descriptor) == 0 else { throw fileError() }
            }
        }

        if let parent = try? openDirectory(FileManager.default.temporaryDirectory) {
            defer { _ = close(parent) }
            if protectsStagingNames(parent, onDevice: destinationInfo.st_dev) {
                do {
                    return try stageArchive(contents, in: directory, expected: expectedDirectory,
                                            destination: destination, destinationGroup: destinationInfo.st_gid,
                                            stagingParent: parent, write: write)
                } catch ArchiveStagingError.needsParentGroup {
                }
            }
        }
        guard protectsStagingNames(destination, onDevice: destinationInfo.st_dev) else { throw POSIXError(.EPERM) }
        try verifyDestination(directory, expected: expectedDirectory)
        return try stageArchive(contents, in: directory, expected: expectedDirectory,
                                destination: destination, destinationGroup: destinationInfo.st_gid,
                                stagingParent: destination, write: write)
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        try directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            let descriptor = open(path, O_SEARCH | O_CLOEXEC)
            guard descriptor >= 0 else { throw fileError() }
            return descriptor
        }
    }

    private static func verifyDestination(_ directory: URL, expected: FinderDirectoryIdentity?) throws {
        if let expected, FinderDirectoryIdentity.capture(at: directory) != expected { throw POSIXError(.ESTALE) }
    }

    private static func stageArchive(_ contents: Data, in directory: URL, expected: FinderDirectoryIdentity?,
                                     destination: Int32, destinationGroup: gid_t, stagingParent: Int32,
                                     write: (FileHandle, Data) throws -> Void) throws -> URL {
        let name = ".DeskMote-\(UUID().uuidString)"
        guard mkdirat(stagingParent, name, 0o700) == 0 else { throw fileError() }
        defer { _ = unlinkat(stagingParent, name, AT_REMOVEDIR) }
        let staging = openat(stagingParent, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw fileError() }
        defer { _ = close(staging) }
        var stagingInfo = stat()
        guard fstat(staging, &stagingInfo) == 0 else { throw fileError() }
        guard stagingInfo.st_uid == geteuid(), stagingInfo.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        return try publishArchive(contents, in: directory, expected: expected, destination: destination, staging: staging,
                                  stagingGroup: stagingInfo.st_gid, destinationGroup: destinationGroup, write: write)
    }

    private static func protectsStagingNames(_ directory: Int32, onDevice device: dev_t) -> Bool {
        var info = stat()
        var volume = statfs()
        guard fstat(directory, &info) == 0, info.st_dev == device, fstatfs(directory, &volume) == 0,
              volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0,
              info.st_uid == 0 || info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { return false }
        guard let acl = acl_get_fd_np(directory, ACL_TYPE_EXTENDED) else {
            let error = fileError()
            return error.code == .ENOENT || error.code == .ENOTSUP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = ACL_FIRST_ENTRY
        while acl_get_entry(acl, Int32(index.rawValue), &entry) == 0, let entry {
            index = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return false }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var flags: acl_flagset_t?
            var permissions: acl_permset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
                  acl_get_permset(entry, &permissions) == 0, let permissions else { return false }
            if [ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER].contains(where: { acl_get_perm_np(permissions, $0) == 1 }) {
                return false
            }
            if acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 1,
               [ACL_DELETE, ACL_DELETE_CHILD, ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
                   .contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return false }
        }
        return true
    }

    private static func publishArchive(_ contents: Data, in directory: URL, expected: FinderDirectoryIdentity?,
                                       destination: Int32, staging: Int32, stagingGroup: gid_t, destinationGroup: gid_t,
                                       write: (FileHandle, Data) throws -> Void) throws -> URL {
        guard let empty = acl_init(0) else { throw fileError() }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(staging, empty, ACL_TYPE_EXTENDED) != 0 {
            let error = fileError()
            guard error.code == .ENOENT || error.code == .ENOTSUP else { throw error }
        }
        let handle = FileHandle(fileDescriptor: try openNewFile("archive", in: staging, access: O_RDWR), closeOnDealloc: true)
        var archiveRemains = true
        defer {
            if archiveRemains { _ = unlinkat(staging, "archive", 0) }
            try? handle.close()
        }
        try write(handle, contents)

        var fallbackDeniesDeletion: Bool?
        do {
            return try publish(.zipArchive, in: directory) { name in
                if fallbackDeniesDeletion == nil {
                    try verifyDestination(directory, expected: expected)
                    if fclonefileat(handle.fileDescriptor, destination, name, UInt32(CLONE_NOOWNERCOPY)) == 0 { return }
                    let cloneError = fileError()
                    guard cloneError.code == .ENOTSUP || cloneError.code == .EXDEV else { throw cloneError }
                    guard stagingGroup == destinationGroup || belongsToGroup(destinationGroup) else {
                        throw ArchiveStagingError.needsParentGroup
                    }
                    fallbackDeniesDeletion = try inheritFilePermissions(from: destination, to: handle.fileDescriptor)
                }
                try verifyDestination(directory, expected: expected)
                if renameatx_np(staging, "archive", destination, name, UInt32(RENAME_EXCL)) == 0 {
                    archiveRemains = false
                    return
                }
                if errno == ENOTSUP, fallbackDeniesDeletion == false {
                    try verifyDestination(directory, expected: expected)
                    if linkat(staging, "archive", destination, name, 0) == 0 { return }
                }
                throw fileError()
            }
        } catch {
            if fallbackDeniesDeletion == true { _ = acl_set_fd_np(handle.fileDescriptor, empty, ACL_TYPE_EXTENDED) }
            throw error
        }
    }

    private static func belongsToGroup(_ group: gid_t) -> Bool {
        if getegid() == group { return true }
        let count = getgroups(0, nil)
        guard count > 0 else { return false }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let result = getgroups(count, &groups)
        return result > 0 && groups.prefix(Int(result)).contains(group)
    }

    private static func inheritFilePermissions(from directory: Int32, to file: Int32) throws -> Bool {
        var destinationInfo = stat()
        var fileInfo = stat()
        guard fstat(directory, &destinationInfo) == 0, fstat(file, &fileInfo) == 0 else { throw fileError() }
        if fileInfo.st_gid != destinationInfo.st_gid,
           fchown(file, uid_t.max, destinationInfo.st_gid) != 0 { throw fileError() }

        guard let inheritedSource = acl_get_fd_np(directory, ACL_TYPE_EXTENDED) else {
            let error = fileError()
            if error.code == .ENOENT || error.code == .ENOTSUP { return false }
            throw error
        }
        defer { acl_free(UnsafeMutableRawPointer(inheritedSource)) }
        var inherited: acl_t? = acl_init(0)
        guard inherited != nil else { throw fileError() }
        defer { if let inherited { acl_free(UnsafeMutableRawPointer(inherited)) } }

        var source: acl_entry_t?
        var id = ACL_FIRST_ENTRY
        var deniesDeletion = false
        while acl_get_entry(inheritedSource, Int32(id.rawValue), &source) == 0, let source {
            id = ACL_NEXT_ENTRY
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(source), &flags) == 0, let flags else { throw fileError() }
            guard acl_get_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 1 else { continue }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(source, &tag) == 0,
                  acl_get_permset(source, &permissions) == 0, let permissions else { throw fileError() }
            if tag == ACL_EXTENDED_DENY, acl_get_perm_np(permissions, ACL_DELETE) == 1 { deniesDeletion = true }
            var entry: acl_entry_t?
            guard acl_create_entry(&inherited, &entry) == 0, let entry,
                  acl_copy_entry(entry, source) == 0 else { throw fileError() }
            var inheritedFlags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &inheritedFlags) == 0,
                  let inheritedFlags else { throw fileError() }
            for flag in [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT] {
                guard acl_delete_flag_np(inheritedFlags, flag) == 0 else { throw fileError() }
            }
            guard acl_add_flag_np(inheritedFlags, ACL_ENTRY_INHERITED) == 0 else { throw fileError() }
        }
        guard acl_set_fd_np(file, inherited, ACL_TYPE_EXTENDED) == 0 else { throw fileError() }
        return deniesDeletion
    }

    private static func publish(_ type: NewFileType, in directory: URL, commit: (String) throws -> Void) throws -> URL {
        var number = 1

        while true {
            let suffix = number == 1 ? "" : " (\(number))"
            let name = "\(type.menuTitle)\(suffix).\(type.fileExtension)"
            do {
                try commit(name)
                return directory.appending(path: name, directoryHint: .notDirectory)
            } catch let error as POSIXError where error.code == .EEXIST {
                number += 1
            }
        }
    }

    private static func openNewFile(_ name: String, in directory: Int32, access: Int32 = O_WRONLY) throws -> Int32 {
        let descriptor = openat(directory, name, access | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw fileError() }
        return descriptor
    }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
