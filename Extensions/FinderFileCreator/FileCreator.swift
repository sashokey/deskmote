import Darwin
import Foundation

enum FileCreator {
    enum ArchivePublicationError: Error {
        case hardLinkCleanupMayBeDenied
    }

    struct ArchiveFileSystem {
        let temporaryDirectory: URL
        let clone: (Int32, Int32, String) throws -> Void
        let rename: (Int32, Int32, String) throws -> Void

        init(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
             clone: @escaping (Int32, Int32, String) throws -> Void = FileCreator.cloneArchive,
             rename: @escaping (Int32, Int32, String) throws -> Void = FileCreator.renameArchive) {
            self.temporaryDirectory = temporaryDirectory
            self.clone = clone
            self.rename = rename
        }
    }

    private enum ArchiveStagingError: Error {
        case needsParentGroup
        case temporaryParentUnavailable
    }

    private static let stagedArchiveName = "archive"

    static func create(_ type: NewFileType, in directory: URL,
                       expectedDirectory: FinderDirectoryIdentity? = nil,
                       archiveFileSystem: ArchiveFileSystem? = nil,
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

        let fileSystem = archiveFileSystem ?? ArchiveFileSystem()
        if let parent = try? openDirectory(fileSystem.temporaryDirectory) {
            defer { _ = close(parent) }
            if canUseStagingParent(parent, onDevice: destinationInfo.st_dev) {
                do {
                    return try stageArchive(contents, in: directory, expected: expectedDirectory,
                                            destination: destination, destinationGroup: destinationInfo.st_gid,
                                            stagingParent: parent, fileSystem: fileSystem,
                                            allowPreWriteFallback: true, write: write)
                } catch ArchiveStagingError.needsParentGroup, ArchiveStagingError.temporaryParentUnavailable {
                }
            }
        }
        guard canUseStagingParent(destination, onDevice: destinationInfo.st_dev) else { throw POSIXError(.EPERM) }
        try verifyDestination(directory, expected: expectedDirectory)
        return try stageArchive(contents, in: directory, expected: expectedDirectory,
                                destination: destination, destinationGroup: destinationInfo.st_gid,
                                stagingParent: destination, fileSystem: fileSystem, write: write)
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
                                     fileSystem: ArchiveFileSystem, allowPreWriteFallback: Bool = false,
                                     write: (FileHandle, Data) throws -> Void) throws -> URL {
        let name = ".DeskMote-\(UUID().uuidString)"
        guard mkdirat(stagingParent, name, 0o700) == 0 else {
            let error = fileError()
            var entry = stat()
            if allowPreWriteFallback, error.code == .EACCES || error.code == .EPERM,
               fstatat(stagingParent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                throw ArchiveStagingError.temporaryParentUnavailable
            }
            throw error
        }
        var deniedStagingAccess = false
        let result = Result {
            let staging = openat(stagingParent, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            defer { if staging >= 0 { _ = close(staging) } }
            var stagingInfo = stat()
            guard staging >= 0, fstat(staging, &stagingInfo) == 0 else {
                let error = fileError()
                deniedStagingAccess = error.code == .EACCES
                throw error
            }
            guard stagingInfo.st_uid == geteuid(), stagingInfo.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
            return try publishArchive(contents, in: directory, expected: expected, destination: destination, staging: staging,
                                      stagingGroup: stagingInfo.st_gid, destinationGroup: destinationGroup,
                                      fileSystem: fileSystem, write: write)
        }
        let stagingRemoved = unlinkat(stagingParent, name, AT_REMOVEDIR) == 0
        if allowPreWriteFallback, deniedStagingAccess, stagingRemoved {
            throw ArchiveStagingError.temporaryParentUnavailable
        }
        return try result.get()
    }

    private static func canUseStagingParent(_ directory: Int32, onDevice device: dev_t) -> Bool {
        var info = stat()
        var volume = statfs()
        let user = geteuid()
        guard fstat(directory, &info) == 0, info.st_dev == device, fstatfs(directory, &volume) == 0,
              volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0,
              info.st_uid == 0 || info.st_uid == user,
              info.st_flags & UInt32(UF_APPEND | SF_APPEND | UF_IMMUTABLE | SF_IMMUTABLE) == 0,
              info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { return false }
        let writePermission = info.st_uid == user ? S_IWUSR : (belongsToGroup(info.st_gid) ? S_IWGRP : S_IWOTH)
        guard user == 0 || info.st_mode & mode_t(writePermission) != 0 else { return false }
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
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
                  let permissions = try? aclPermissions(for: entry) else { return false }
            let inheritedByDirectories = acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 1
            if tag == ACL_EXTENDED_DENY {
                let appliesToParent = acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 0
                if appliesToParent, permissions & UInt64(ACL_DELETE_CHILD.rawValue) != 0 { return false }
                if inheritedByDirectories, permissions & UInt64(ACL_DELETE.rawValue) != 0 { return false }
                continue
            }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            if permissions & aclMask([ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]) != 0 {
                return false
            }
            if inheritedByDirectories,
               permissions & aclMask([ACL_DELETE, ACL_DELETE_CHILD, ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY,
                                      ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]) != 0 { return false }
        }
        return true
    }

    private static func aclPermissions(for entry: acl_entry_t) throws -> acl_permset_mask_t {
        var mask: acl_permset_mask_t = 0
        var knownPermissions: acl_permset_mask_t = 0
        guard acl_get_permset_mask_np(entry, &mask) == 0,
              acl_maximal_permset_mask_np(&knownPermissions) == 0 else { throw fileError() }
        return expandedACLPermissions(mask, knownPermissions: knownPermissions)
    }

    static func expandedACLPermissions(_ mask: acl_permset_mask_t,
                                       knownPermissions: acl_permset_mask_t) -> acl_permset_mask_t {
        let all = UInt64(KAUTH_ACE_GENERIC_ALL)
        let read = UInt64(KAUTH_ACE_GENERIC_READ)
        let write = UInt64(KAUTH_ACE_GENERIC_WRITE)
        let execute = UInt64(KAUTH_ACE_GENERIC_EXECUTE)
        guard mask & ~(knownPermissions | all | read | write | execute) == 0 else { return .max }
        var permissions = mask
        if mask & (all | read) != 0 {
            permissions |= aclMask([ACL_READ_DATA, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY])
        }
        if mask & (all | write) != 0 {
            permissions |= aclMask([ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                    ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY])
        }
        if mask & (all | execute) != 0 {
            permissions |= UInt64(ACL_EXECUTE.rawValue)
        }
        return permissions
    }

    private static func aclMask(_ permissions: [acl_perm_t]) -> acl_permset_mask_t {
        permissions.reduce(0) { mask, permission in mask | UInt64(permission.rawValue) }
    }

    private static func publishArchive(_ contents: Data, in directory: URL, expected: FinderDirectoryIdentity?,
                                       destination: Int32, staging: Int32, stagingGroup: gid_t, destinationGroup: gid_t,
                                       fileSystem: ArchiveFileSystem, write: (FileHandle, Data) throws -> Void) throws -> URL {
        guard let empty = acl_init(0) else { throw fileError() }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(staging, empty, ACL_TYPE_EXTENDED) != 0 {
            let error = fileError()
            guard error.code == .ENOENT || error.code == .ENOTSUP else { throw error }
        }
        let handle = FileHandle(fileDescriptor: try openNewFile(stagedArchiveName, in: staging, access: O_RDWR), closeOnDealloc: true)
        var archiveRemains = true
        defer {
            if archiveRemains { _ = unlinkat(staging, stagedArchiveName, 0) }
            try? handle.close()
        }
        try write(handle, contents)

        var fallbackDeniesDeletion: Bool?
        do {
            return try publish(.zipArchive, in: directory) { name in
                if fallbackDeniesDeletion == nil {
                    try verifyDestination(directory, expected: expected)
                    do {
                        try fileSystem.clone(handle.fileDescriptor, destination, name)
                        return
                    } catch let error as POSIXError where error.code == .ENOTSUP || error.code == .EXDEV {
                    }
                    guard stagingGroup == destinationGroup || belongsToGroup(destinationGroup) else {
                        throw ArchiveStagingError.needsParentGroup
                    }
                    fallbackDeniesDeletion = try inheritFilePermissions(from: destination, to: handle.fileDescriptor)
                }
                try verifyDestination(directory, expected: expected)
                do {
                    try fileSystem.rename(staging, destination, name)
                    archiveRemains = false
                    return
                } catch let error as POSIXError where error.code == .ENOTSUP {
                    guard fallbackDeniesDeletion == false else { throw ArchivePublicationError.hardLinkCleanupMayBeDenied }
                    try verifyDestination(directory, expected: expected)
                    guard linkat(staging, stagedArchiveName, destination, name, 0) == 0 else { throw fileError() }
                }
            }
        } catch {
            if fallbackDeniesDeletion == true {
                archiveRemains = false
                try removeRestrictedStagingArchive(staging, archive: handle.fileDescriptor, emptyACL: empty)
            }
            throw error
        }
    }

    private static func removeRestrictedStagingArchive(_ staging: Int32, archive: Int32, emptyACL: acl_t) throws {
        var stagedInfo = stat()
        let couldStatName = fstatat(staging, stagedArchiveName, &stagedInfo, AT_SYMLINK_NOFOLLOW) == 0
        if !couldStatName {
            let error = fileError()
            if error.code == .ENOENT { return }
            guard error.code == .EACCES || error.code == .EPERM else { throw error }
        }
        var archiveInfo = stat()
        guard fstat(archive, &archiveInfo) == 0 else { throw fileError() }
        guard archiveInfo.st_ino != 0, archiveInfo.st_nlink == 1 else { throw POSIXError(.ESTALE) }
        if couldStatName {
            guard archiveInfo.st_dev == stagedInfo.st_dev,
                  archiveInfo.st_ino == stagedInfo.st_ino else { throw POSIXError(.ESTALE) }
        } else {
            guard try stagingEntryMatches(staging, archive: archiveInfo) else { throw POSIXError(.ESTALE) }
        }
        guard acl_set_fd_np(archive, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw fileError() }
        guard unlinkat(staging, stagedArchiveName, 0) == 0 else { throw fileError() }
    }

    private static func stagingEntryMatches(_ staging: Int32, archive: stat) throws -> Bool {
        let readable = openat(staging, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard readable >= 0 else { throw fileError() }
        guard let directory = fdopendir(readable) else {
            let error = fileError()
            _ = close(readable)
            throw error
        }
        defer { _ = closedir(directory) }
        var parent = stat()
        guard fstat(dirfd(directory), &parent) == 0 else { throw fileError() }
        guard parent.st_dev == archive.st_dev else { return false }
        let nameLength = stagedArchiveName.utf8.count
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw fileError() }
                return false
            }
            guard entry.pointee.d_namlen == nameLength else { continue }
            let matchesName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) {
                    strcmp($0, stagedArchiveName) == 0
                }
            }
            if matchesName { return entry.pointee.d_ino == archive.st_ino }
        }
    }

    private static func cloneArchive(_ archive: Int32, _ destination: Int32, _ name: String) throws {
        let flags = UInt32(CLONE_NOOWNERCOPY | CLONE_NOFOLLOW)
        guard fclonefileat(archive, destination, name, flags) == 0 else { throw fileError() }
    }

    private static func renameArchive(_ staging: Int32, _ destination: Int32, _ name: String) throws {
        guard renameatx_np(staging, stagedArchiveName, destination, name, UInt32(RENAME_EXCL)) == 0 else { throw fileError() }
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
            guard acl_get_tag_type(source, &tag) == 0 else { throw fileError() }
            if tag == ACL_EXTENDED_DENY {
                let permissions = try aclPermissions(for: source)
                if permissions & UInt64(ACL_DELETE.rawValue) != 0 { deniesDeletion = true }
            }
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
