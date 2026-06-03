import Foundation
import Testing
@testable import QuotaMonitor

/// Locks down the exact list of filesystem paths the in-app
/// uninstaller wipes. Important to test because:
///   1. Each path is a `~/Library/...` location a human almost
///      certainly can't reconstruct by reading source — if we drop
///      one (e.g. a future macOS adds a new storage location), the
///      uninstaller silently leaves orphan data.
///   2. We MUST NOT accidentally start touching paths outside our
///      own footprint (e.g. ~/.codex, ~/.claude, ~/Library at the
///      root). A test that enumerates the full set makes a slip
///      visible in the diff.
///
/// Test runs against synthetic inputs — never touches the real
/// filesystem — so it's safe to keep in the default suite.
@Suite("Uninstall targets")
struct UninstallTargetsTests {

    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let bundleIDs = ["dev.tjzhou.QuotaMonitor", "dev.tjzhou.CodexMonitor"]

    @Test("Enumerates Application Support folders for both names")
    func appSupportFolders() {
        let urls = AppEnvironment.uninstallTargets(
            home: home, bundleIDs: bundleIDs)
        let paths = urls.map(\.path)
        #expect(paths.contains(
            "/Users/example/Library/Application Support/QuotaMonitor"))
        #expect(paths.contains(
            "/Users/example/Library/Application Support/CodexMonitor"))
    }

    @Test("Enumerates Preferences plist for every bundle id")
    func prefsPlists() {
        let urls = AppEnvironment.uninstallTargets(
            home: home, bundleIDs: bundleIDs)
        let paths = urls.map(\.path)
        #expect(paths.contains(
            "/Users/example/Library/Preferences/dev.tjzhou.QuotaMonitor.plist"))
        #expect(paths.contains(
            "/Users/example/Library/Preferences/dev.tjzhou.CodexMonitor.plist"))
    }

    @Test("Enumerates Caches + Saved Application State + HTTPStorages")
    func bundleIdSubdirs() {
        let urls = AppEnvironment.uninstallTargets(
            home: home, bundleIDs: ["dev.tjzhou.QuotaMonitor"])
        let paths = urls.map(\.path)
        #expect(paths.contains(
            "/Users/example/Library/Caches/dev.tjzhou.QuotaMonitor"))
        #expect(paths.contains(
            "/Users/example/Library/Saved Application State/dev.tjzhou.QuotaMonitor.savedState"))
        #expect(paths.contains(
            "/Users/example/Library/HTTPStorages/dev.tjzhou.QuotaMonitor"))
        #expect(paths.contains(
            "/Users/example/Library/HTTPStorages/dev.tjzhou.QuotaMonitor.binarycookies"))
    }

    /// Belt-and-suspenders: nothing under the user's home dir other
    /// than `~/Library/…` should ever appear. If a future tweak
    /// accidentally adds `~/.codex` or `~/.claude` to the list, this
    /// test fails loudly.
    @Test("All targets live strictly under ~/Library")
    func allTargetsAreUnderLibrary() {
        let urls = AppEnvironment.uninstallTargets(
            home: home, bundleIDs: bundleIDs)
        for url in urls {
            #expect(
                url.path.hasPrefix("/Users/example/Library/"),
                "Unexpected uninstall target outside ~/Library: \(url.path)")
        }
    }

    @Test("Production bundle-id list covers current + legacy rename")
    func productionBundleIDsCoverLegacy() {
        // If the rename ever expands (e.g. another bundle-id swap), the
        // uninstaller MUST learn about the new id — otherwise users
        // upgrading through the rename get partial cleanup. Keep this
        // assertion strict so adding a new id without thinking is hard.
        #expect(AppEnvironment.uninstallBundleIDs ==
                ["dev.tjzhou.QuotaMonitor", "dev.tjzhou.CodexMonitor"])
    }

    @Test("Local QA disables self uninstall")
    func localQADisablesSelfUninstall() {
        let arguments = [
            "QuotaMonitor",
            "--quotamonitor-qa-config-base64",
            Data(#"{"mode":true,"home":"/tmp/qm-qa-home"}"#.utf8).base64EncodedString()
        ]

        #expect(AppEnvironment.allowsUninstall(
            environment: ["HOME": "/Users/example"],
            arguments: arguments) == false)
        #expect(AppEnvironment.allowsUninstall(
            environment: ["HOME": "/Users/example"],
            arguments: ["QuotaMonitor"]) == true)
    }

    @Test("Trusted app bundles include running copy plus installed current and legacy copies")
    func trustedAppBundlesIncludeKnownInstallLocations() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Users/example", isDirectory: true)
        let systemApplications = root.appendingPathComponent("Applications", isDirectory: true)
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
        let running = root.appendingPathComponent("Build/QuotaMonitor.app", isDirectory: true)

        try writeBundle(at: running, bundleID: "dev.tjzhou.QuotaMonitor")
        try writeBundle(
            at: systemApplications.appendingPathComponent("QuotaMonitor.app", isDirectory: true),
            bundleID: "dev.tjzhou.QuotaMonitor")
        try writeBundle(
            at: systemApplications.appendingPathComponent("CodexMonitor.app", isDirectory: true),
            bundleID: "dev.tjzhou.CodexMonitor")
        try writeBundle(
            at: userApplications.appendingPathComponent("QuotaMonitor.app", isDirectory: true),
            bundleID: "dev.tjzhou.QuotaMonitor")

        let paths = AppEnvironment.trustedAppBundleTargets(
            home: home,
            runningBundleURL: running,
            applicationsDirectories: [systemApplications, userApplications],
            allowedBundleIDs: bundleIDs
        ).map(\.path)

        #expect(paths == [
            running.path,
            systemApplications.appendingPathComponent("QuotaMonitor.app").path,
            systemApplications.appendingPathComponent("CodexMonitor.app").path,
            userApplications.appendingPathComponent("QuotaMonitor.app").path,
        ])
    }

    @Test("Trusted app bundles reject same-name apps with unexpected bundle id")
    func trustedAppBundlesRejectUnexpectedBundleID() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Users/example", isDirectory: true)
        let systemApplications = root.appendingPathComponent("Applications", isDirectory: true)
        let running = root.appendingPathComponent("Build/QuotaMonitor.app", isDirectory: true)
        let impostor = systemApplications.appendingPathComponent("QuotaMonitor.app", isDirectory: true)

        try writeBundle(at: running, bundleID: "dev.tjzhou.QuotaMonitor")
        try writeBundle(at: impostor, bundleID: "com.example.NotQuotaMonitor")

        let paths = AppEnvironment.trustedAppBundleTargets(
            home: home,
            runningBundleURL: running,
            applicationsDirectories: [systemApplications],
            allowedBundleIDs: bundleIDs
        ).map(\.path)

        #expect(paths == [running.path])
    }

    @Test("Trusted app bundles de-duplicate when running from Applications")
    func trustedAppBundlesDeduplicateRunningApplicationsCopy() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Users/example", isDirectory: true)
        let systemApplications = root.appendingPathComponent("Applications", isDirectory: true)
        let running = systemApplications.appendingPathComponent("QuotaMonitor.app", isDirectory: true)

        try writeBundle(at: running, bundleID: "dev.tjzhou.QuotaMonitor")

        let paths = AppEnvironment.trustedAppBundleTargets(
            home: home,
            runningBundleURL: running,
            applicationsDirectories: [systemApplications],
            allowedBundleIDs: bundleIDs
        ).map(\.path)

        #expect(paths == [running.path])
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeBundle(at url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist", isDirectory: false)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID],
            format: .xml,
            options: 0)
        try data.write(to: plist)
    }
}
