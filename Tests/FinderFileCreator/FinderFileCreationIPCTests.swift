import Darwin
import Foundation
import Synchronization

@main
enum FinderFileCreationIPCTests {
    static func main() {
        do {
            try expect(FinderFileCreationClient.awaitReply(deadline: .now()) { _ in } == .unconfirmed,
                       "A missing XPC reply cannot confirm that creation failed")
            try expect(FinderFileCreationClient.awaitReply(deadline: .now()) { $0(nil) } == .unconfirmed,
                       "An interrupted XPC connection cannot confirm that creation failed")
            try expect(FinderFileCreationClient.awaitReply(deadline: .now()) { $0(false) } == .failed,
                       "A service rejection must still report failure")
            try testDestinationPathValidation()
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let handler = FinderFileCreationHandler()
            try expect(!create(handler, type: 99, path: folder.path), "Reject unsupported file types")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty,
                       "Invalid requests must leave the folder untouched")

            try expect(create(handler, type: 0, path: folder.path), "Create the text document")
            try expect(try Data(contentsOf: folder.appending(path: "New Text Document.txt")).isEmpty,
                       "Text creation must finish before replying")
            try expect(create(handler, type: 1, path: folder.path), "Create the ZIP archive")
            try expect(FileManager.default.fileExists(atPath: folder.appending(path: "New Compressed (zipped) Folder.zip").path),
                       "ZIP creation must use its normal filename")
            let original = folder.appending(path: "selected")
            let moved = folder.appending(path: "moved")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let captured = FinderDirectoryIdentity.capture(at: original)
            try expect(captured != nil, "Capture the selected directory")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try expect(!create(handler, type: 0, path: original.path, identity: captured),
                       "The broker must reject a different object at the captured path")
            try expect(FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty,
                       "The replacement directory must remain empty")
            print("Finder file creation XPC handler tests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func testDestinationPathValidation() throws {
        let atLimit = "/" + String(repeating: "é", count: 2047) + "x"
        try expect(FinderFileCreationIPC.destination(for: atLimit) != nil, "Accept exactly 4096 UTF-8 bytes")
        try expect(FinderFileCreationIPC.destination(for: atLimit + "x") == nil, "Reject 4097 UTF-8 bytes")
        try expect(FinderFileCreationIPC.destination(for: "relative") == nil, "Reject relative destination paths")
        try expect(FinderFileCreationIPC.destination(for: "/selected\0other") == nil, "Reject an embedded NUL")
    }

    private static func create(_ handler: FinderFileCreationHandler, type: Int, path: String,
                               identity: FinderDirectoryIdentity? = nil) -> Bool {
        let result = Mutex(false)
        let expected = identity ?? FinderDirectoryIdentity.capture(at: URL(fileURLWithPath: path))
        let encoded = expected.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        handler.createFile(type, in: path, identity: encoded) { value in result.withLock { $0 = value } }
        return result.withLock { $0 }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
}
