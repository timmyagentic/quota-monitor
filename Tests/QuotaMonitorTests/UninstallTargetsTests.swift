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
}
