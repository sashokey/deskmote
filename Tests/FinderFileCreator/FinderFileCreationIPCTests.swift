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
            try testExactPeerRequirementsPrecedeActivation()
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let handler = FinderFileCreationHandler()
            try testInvalidPeerNeverPerformsFileCreation(in: folder)
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

    private static func testExactPeerRequirementsPrecedeActivation() throws {
        try expect(FinderFileCreationIPC.serviceName == "io.github.sashokey.deskmote.finder-sync.service",
                   "The connection must address the signed production service")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let extensionURL = directory.appending(path: "Fixture.appex")
        let serviceURL = extensionURL.appending(path: FinderFileCreationIPC.servicePath)
        defer { try? FileManager.default.removeItem(at: directory) }
        try createSignedFixture(at: serviceURL, identifier: FinderFileCreationIPC.serviceName)
        try createSignedFixture(at: extensionURL, identifier: "io.github.sashokey.deskmote.finder-sync")
        let serviceRequirement = try signingRequirement(at: serviceURL)
        let extensionRequirement = try signingRequirement(at: extensionURL)
        try expect(serviceRequirement != extensionRequirement, "The two peers must pin different code")

        let listener = NSXPCListener.anonymous()
        let connection = RecordingConnection(listenerEndpoint: listener.endpoint)
        guard let delegate = FinderFileCreationListener(extensionURL: extensionURL) else {
            throw Failure(description: "A signed extension must admit its exact peer")
        }
        try expect(delegate.listener(listener, shouldAcceptNewConnection: connection), "Configure the admitted peer")
        try expect(connection.events == [extensionRequirement, "activate"], "Pin the enclosing extension before activation")
        try expect(connection.exportedObject is FinderFileCreationHandler, "Export only the Finder file-creation handler")
        try expect(FinderFileCreationListener(extensionURL: directory) == nil, "An invalid enclosing signature cannot admit a peer")

        let client = RecordingConnection(listenerEndpoint: listener.endpoint)
        guard let extensionBundle = Bundle(url: extensionURL), let identity = FinderDirectoryIdentity.capture(at: directory) else {
            throw Failure(description: "The signed fixture must be usable as a bundle")
        }
        let outcome = FinderFileCreationClient.send(.textDocument, to: directory, identity: identity, in: extensionBundle) { name in
            if name == FinderFileCreationIPC.serviceName { client.events.append("service") }
            return client
        }
        try expect(outcome == .failed, "A peer that rejects readiness must stop the request")
        try expect(client.events == ["service", serviceRequirement, "activate", "request", "invalidate"],
                   "Pin the embedded service before activation and send no create request after rejection")
        try expect(client.refusingPeer.attemptedCreations.withLock { $0 } == 0, "A rejected peer received a create request")
    }

    private static func testInvalidPeerNeverPerformsFileCreation(in directory: URL) throws {
        guard let identity = FinderDirectoryIdentity.capture(at: directory) else {
            throw Failure(description: "Capture the test folder")
        }
        try expect(FinderFileCreationIPC.requirement(for: directory) == nil, "An unsigned peer must fail validation")
        try expect(FinderFileCreationClient.send(.textDocument, to: directory, identity: identity, in: .main) == .failed,
                   "A missing embedded service must fail closed")
        try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                   "A refused client must leave the directory empty")
    }

    private final class RecordingConnection: NSXPCConnection, @unchecked Sendable {
        var events: [String] = []
        let refusingPeer = RefusingPeer()

        override func setCodeSigningRequirement(_ requirement: String) {
            events.append(requirement)
        }

        override func activate() {
            events.append("activate")
        }

        override func invalidate() {
            events.append("invalidate")
        }

        override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any {
            events.append("request")
            return refusingPeer
        }
    }

    private final class RefusingPeer: NSObject, FinderFileCreationProtocol, @unchecked Sendable {
        let attemptedCreations = Mutex(0)

        func ready(withReply reply: @escaping @Sendable (Bool) -> Void) { reply(false) }

        func createFile(_ type: Int, in path: String, identity: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
            attemptedCreations.withLock { $0 += 1 }
            reply(false)
        }
    }

    private static func createSignedFixture(at path: URL, identifier: String) throws {
        let contents = path.appending(path: "Contents")
        let executables = contents.appending(path: "MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executables.appending(path: "Fixture"))
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "XPC!"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        _ = try codesign(["--force", "--sign", "-", "--timestamp=none", path.path])
    }

    private static func signingRequirement(at path: URL) throws -> String {
        let details = try codesign(["--display", "--verbose=4", path.path])
        guard let record = details.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("CDHash=") }) else {
            throw Failure(description: "The signed test fixture must have a cdhash")
        }
        return "cdhash H\"\(record.dropFirst(7))\""
    }

    private static func codesign(_ arguments: [String]) throws -> String {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        let result = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, result)
        return result
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
