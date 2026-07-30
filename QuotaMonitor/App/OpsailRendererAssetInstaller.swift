import CryptoKit
import Darwin
import Foundation

enum OpsailRendererAssetLocator {
    static func bundledAssetsURL(in bundle: Bundle = .main) -> URL {
        bundledAssetsURL(bundleURL: bundle.bundleURL)
    }

    static func bundledAssetsURL(bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("OpsailRenderer", isDirectory: true)
    }

    static func defaultStateRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("opsail", isDirectory: true)
            .appendingPathComponent("refit", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }
}

enum OpsailRendererAssetInstallOutcome: Equatable {
    case installed
    case unchanged
    case preservedNewer(version: String)
    case preservedSameVersion
}

enum OpsailRendererAssetInstallError: Error, LocalizedError {
    case invalidBundle(String)
    case unsafeStorage(String)
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason):
            "Invalid bundled Opsail renderer assets: \(reason)"
        case .unsafeStorage(let reason):
            "Unsafe Opsail renderer asset storage: \(reason)"
        case .storageFailure(let reason):
            "Could not install Opsail renderer assets: \(reason)"
        }
    }
}

struct OpsailRendererAssetInstaller {
    private static let expectedFiles = [
        "opsail-refit-codex-dom-adapter.js",
        "opsail-refit-codex-renderer-control.js",
        "opsail-refit-codex-usage-model.js",
        "opsail-refit-codex-usage-runtime.js",
    ]
    private static let forbiddenJavaScript = [
        "fetch(",
        "XMLHttpRequest",
        "WebSocket(",
        "eval(",
        "new Function",
        "/v1/",
        "responses.create",
        "chat.completions",
    ]

    private let sourceURL: URL
    private let stateRoot: URL?
    private let fileManager: FileManager

    init(
        sourceURL: URL = OpsailRendererAssetLocator.bundledAssetsURL(),
        stateRoot: URL? = OpsailRendererAssetLocator.defaultStateRoot(),
        fileManager: FileManager = .default
    ) {
        self.sourceURL = sourceURL
        self.stateRoot = stateRoot
        self.fileManager = fileManager
    }

    func installIfNeeded() throws -> OpsailRendererAssetInstallOutcome {
        guard let stateRoot else {
            throw OpsailRendererAssetInstallError.storageFailure(
                "the user Application Support directory is unavailable")
        }
        let bundle = try loadBundle(at: sourceURL)
        let assetRoot = stateRoot
            .appendingPathComponent("renderer-assets", isDirectory: true)
        let versionsRoot = assetRoot
            .appendingPathComponent("versions", isDirectory: true)
        let pointerURL = assetRoot
            .appendingPathComponent("current.json", isDirectory: false)

        try preparePrivateDirectory(stateRoot)
        try preparePrivateDirectory(assetRoot)
        try preparePrivateDirectory(versionsRoot)

        if let pointer = try loadPointer(at: pointerURL) {
            let selected = versionsRoot
                .appendingPathComponent(pointer.directory, isDirectory: true)
            if let selectedVersion = try? loadSelectedVersion(
                at: selected,
                expectedVersion: pointer.version
            ), selectedVersion > bundle.version {
                return .preservedNewer(version: pointer.version)
            }
            let installed = try? loadBundle(at: selected)
            if installed?.manifest.assetVersion == pointer.version,
               let ordering = installed?.version.compare(to: bundle.version)
            {
                if ordering == 0 {
                    if try bundleMatches(bundle, at: selected) {
                        return .unchanged
                    }
                    return .preservedSameVersion
                }
            }
        }

        let identity = sha256(
            Data(bundle.manifest.files.map(\.sha256).joined().utf8)
        )
        let directoryName =
            "quota-monitor-\(bundle.manifest.assetVersion)-\(identity.prefix(16))"
        let finalDirectory = versionsRoot
            .appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: finalDirectory.path) {
            guard try bundleMatches(bundle, at: finalDirectory) else {
                throw OpsailRendererAssetInstallError.unsafeStorage(
                    "the QuotaMonitor asset directory has unexpected contents")
            }
        } else {
            try stage(bundle, in: versionsRoot, finalURL: finalDirectory)
        }

        let pointer = CurrentPointer(
            schemaVersion: 1,
            version: bundle.manifest.assetVersion,
            directory: directoryName)
        try writeAtomically(
            try JSONEncoder.pretty.encode(pointer),
            to: pointerURL)
        return .installed
    }

    private func loadBundle(at root: URL) throws -> AssetBundle {
        let manifestURL = root.appendingPathComponent(
            "manifest.json",
            isDirectory: false)
        let manifestData = try readRegularFile(
            manifestURL,
            maximumBytes: 64 * 1024,
            context: "manifest")
        let manifest: AssetManifest
        do {
            manifest = try JSONDecoder().decode(
                AssetManifest.self,
                from: manifestData)
        } catch {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "manifest JSON is invalid")
        }
        guard manifest.schemaVersion == 1,
              manifest.apiVersion == 1,
              manifest.files.map(\.name) == Self.expectedFiles,
              manifest.files.count == Self.expectedFiles.count,
              let version = SemanticVersion(manifest.assetVersion)
        else {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "manifest schema, API, file list, or version is unsupported")
        }
        var files: [String: Data] = [:]
        var totalBytes = 0
        for record in manifest.files {
            guard record.bytes > 0, record.bytes <= 512 * 1024 else {
                throw OpsailRendererAssetInstallError.invalidBundle(
                    "\(record.name) has an invalid size")
            }
            let data = try readRegularFile(
                root.appendingPathComponent(record.name),
                maximumBytes: 512 * 1024,
                context: record.name)
            guard data.count == record.bytes,
                  sha256(data) == record.sha256
            else {
                throw OpsailRendererAssetInstallError.invalidBundle(
                    "\(record.name) failed size or SHA-256 verification")
            }
            guard let source = String(data: data, encoding: .utf8),
                  !source.contains("\0"),
                  !Self.forbiddenJavaScript.contains(where: source.contains)
            else {
                throw OpsailRendererAssetInstallError.invalidBundle(
                    "\(record.name) violates the local-only JavaScript policy")
            }
            totalBytes += data.count
            files[record.name] = data
        }
        guard totalBytes <= 2 * 1024 * 1024 else {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "asset bundle exceeds the size limit")
        }
        return AssetBundle(
            manifest: manifest,
            manifestData: manifestData,
            files: files,
            version: version)
    }

    private func loadPointer(at url: URL) throws -> CurrentPointer? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try readRegularFile(
            url,
            maximumBytes: 16 * 1024,
            context: "current pointer")
        guard let pointer = try? JSONDecoder().decode(
            CurrentPointer.self,
            from: data),
              pointer.schemaVersion == 1,
              SemanticVersion(pointer.version) != nil,
              isValidDirectoryName(pointer.directory)
        else {
            return nil
        }
        return pointer
    }

    private func loadSelectedVersion(
        at root: URL,
        expectedVersion: String
    ) throws -> SemanticVersion {
        guard isRegularDirectory(root) else {
            throw OpsailRendererAssetInstallError.unsafeStorage(
                "the selected renderer bundle is not a regular directory")
        }
        let manifestData = try readRegularFile(
            root.appendingPathComponent("manifest.json"),
            maximumBytes: 64 * 1024,
            context: "selected renderer manifest")
        let manifest: AssetVersionManifest
        do {
            manifest = try JSONDecoder().decode(
                AssetVersionManifest.self,
                from: manifestData)
        } catch {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "selected renderer manifest JSON is invalid")
        }
        guard manifest.assetVersion == expectedVersion,
              let version = SemanticVersion(manifest.assetVersion)
        else {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "selected renderer version does not match current.json")
        }
        return version
    }

    private func bundleMatches(
        _ bundle: AssetBundle,
        at directory: URL
    ) throws -> Bool {
        guard isRegularDirectory(directory) else { return false }
        let installedManifestURL = directory.appendingPathComponent(
            "manifest.json")
        guard let installedManifest = try? readRegularFile(
            installedManifestURL,
            maximumBytes: 64 * 1024,
            context: "installed manifest"),
              let decoded = try? JSONDecoder().decode(
                AssetManifest.self,
                from: installedManifest),
              decoded == bundle.manifest
        else {
            return false
        }
        for record in bundle.manifest.files {
            guard let data = try? readRegularFile(
                directory.appendingPathComponent(record.name),
                maximumBytes: 512 * 1024,
                context: record.name),
                  data.count == record.bytes,
                  sha256(data) == record.sha256
            else {
                return false
            }
        }
        return true
    }

    private func stage(
        _ bundle: AssetBundle,
        in versionsRoot: URL,
        finalURL: URL
    ) throws {
        let staging = versionsRoot.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            for record in bundle.manifest.files {
                guard let data = bundle.files[record.name] else {
                    throw OpsailRendererAssetInstallError.invalidBundle(
                        "\(record.name) is missing")
                }
                try writeNewPrivateFile(
                    data,
                    to: staging.appendingPathComponent(record.name))
            }
            try writeNewPrivateFile(
                bundle.manifestData,
                to: staging.appendingPathComponent("manifest.json"))
            try fileManager.moveItem(at: staging, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: staging)
            if let installError = error as? OpsailRendererAssetInstallError {
                throw installError
            }
            throw OpsailRendererAssetInstallError.storageFailure(
                error.localizedDescription)
        }
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard isRegularDirectory(url) else {
                throw OpsailRendererAssetInstallError.unsafeStorage(
                    "\(url.lastPathComponent) is not a regular directory")
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw OpsailRendererAssetInstallError.storageFailure(
                    error.localizedDescription)
            }
            guard isRegularDirectory(url) else {
                throw OpsailRendererAssetInstallError.unsafeStorage(
                    "\(url.lastPathComponent) is not a regular directory")
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path)
        } catch {
            throw OpsailRendererAssetInstallError.storageFailure(
                error.localizedDescription)
        }
    }

    private func readRegularFile(
        _ url: URL,
        maximumBytes: Int,
        context: String
    ) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw OpsailRendererAssetInstallError.invalidBundle(
                "\(context) is missing")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes
        else {
            throw OpsailRendererAssetInstallError.unsafeStorage(
                "\(context) is not a bounded regular file")
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw OpsailRendererAssetInstallError.storageFailure(
                "could not read \(context)")
        }
    }

    private func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw OpsailRendererAssetInstallError.storageFailure(
                "could not create \(url.lastPathComponent)")
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".current-\(UUID().uuidString).tmp")
        try writeNewPrivateFile(data, to: temporary)
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard result == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw OpsailRendererAssetInstallError.storageFailure(
                "could not commit current.json")
        }
    }

    private func isRegularDirectory(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path)
        else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private func isValidDirectoryName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 192,
              !value.hasPrefix(".")
        else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 46
                || $0 == 95
                || $0 == 45
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct AssetManifest: Codable, Equatable {
    let schemaVersion: Int
    let assetVersion: String
    let apiVersion: Int
    let files: [AssetRecord]
}

private struct AssetVersionManifest: Decodable {
    let assetVersion: String
}

private struct AssetRecord: Codable, Equatable {
    let name: String
    let sha256: String
    let bytes: Int
}

private struct CurrentPointer: Codable {
    let schemaVersion: Int
    let version: String
    let directory: String
}

private struct AssetBundle {
    let manifest: AssetManifest
    let manifestData: Data
    let files: [String: Data]
    let version: SemanticVersion
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch)
            < (rhs.major, rhs.minor, rhs.patch)
    }

    func compare(to other: Self) -> Int {
        if self < other { return -1 }
        if self > other { return 1 }
        return 0
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
