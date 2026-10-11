import Darwin
import Foundation

/// Every test run owns its temporary files and exact preferences domains.
/// The journal survives a crashed test process; an unlocked journal is recovered
/// by the next run. No prefix-wide deletion or process-name signalling is used.
enum TestResources {
    private static let scope: TestResourceScope = {
        do {
            let scope = try TestResourceScope()
            try scope.startExitCleanup()
            return scope
        } catch {
            fatalError("Cannot create isolated test resources: \(error)")
        }
    }()

    static var temporaryDirectory: URL { scope.directory }

    static func userDefaults(suiteName: String) -> UserDefaults? {
        registerPreferences(suiteName)
        return UserDefaults(suiteName: suiteName)
    }

    static func registerPreferences(_ suite: String) {
        do { try scope.registerPreferences(suite) }
        catch { fatalError("Cannot track test preferences: \(error)") }
    }
}

final class TestResourceScope: @unchecked Sendable {
    private static let prefix = "quotamonitor-tests-"
    private let mutex = NSLock()
    private let root: URL
    let directory: URL
    private let descriptor: Int32
    private var suites: Set<String> = []
    private var closed = false
    private var cleanupProcess: Process?
    private var cleanupPipe: Pipe?

    private static var defaultParent: URL {
        if let path = ProcessInfo.processInfo.environment["QM_TEST_RESOURCES_PARENT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    init(parent: URL? = nil) throws {
        let parent = parent ?? Self.defaultParent
        try Self.recover(in: parent)
        root = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        directory = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(root.appendingPathComponent("lock").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: root)
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try writeJournal()
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func registerPreferences(_ suite: String) throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed, Self.isTestSuite(suite) else { throw CocoaError(.fileWriteInvalidFileName) }
        if suites.insert(suite).inserted { try writeJournal() }
    }

    private func writeJournal() throws {
        try JSONEncoder().encode(suites.sorted()).write(
            to: root.appendingPathComponent("preferences.json"), options: .atomic)
    }

    // Holding both the pipe and flock until process exit lets the watcher wait
    // through Foundation's final preference flushes, even after SIGKILL.
    func startExitCleanup() throws {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        let process = Self.cleanupCommand(["--root", root.path, "--watch"])
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForReading.closeFile()
        cleanupPipe = pipe
        cleanupProcess = process
    }

    func close() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed else { return }
        flock(descriptor, LOCK_UN)
        let process = Self.cleanupCommand(["--root", root.path])
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        Darwin.close(descriptor)
        closed = true
    }

    static func isTestSuite(_ suite: String) -> Bool {
        guard !suite.contains("/"), !suite.contains("\\"), suite.count > 36 else { return false }
        return UUID(uuidString: String(suite.suffix(36))) != nil
    }

    private static func cleanupCommand(_ arguments: [String]) -> Process {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repo.appendingPathComponent("qa/cleanup-tests.py").path] + arguments
        return process
    }

    static func recover(in parent: URL) throws {
        let process = cleanupCommand(["--parent", parent.path])
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
