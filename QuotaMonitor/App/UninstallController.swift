import Foundation
import AppKit

// Self-uninstall path. macOS has no first-party uninstaller framework —
// Apple's official "drag to Trash" only removes the .app bundle and
// leaves `~/Library/{Application Support,Preferences,Caches,…}` orphans
// behind. For a non-sandboxed menu-bar app that writes a SQLite DB and
// a prefs plist, that's noticeably untidy, so we offer an explicit
// "Uninstall" button (Settings → Advanced) that wipes everything we
// own and moves the .app to Trash in one shot.
//
// What we DON'T touch (third-party data, not ours):
//   - ~/.codex/ and ~/.claude/        (CLI homes, read-only consumers)
//   - `Claude Code-credentials` Keychain item (Claude Code owns it)
//   - ~/.claude/.credentials.json     (Claude Code's source-of-truth file;
//                                      mirror toggle only writes a copy
//                                      of Claude's own data — leaving it
//                                      alone keeps Claude Code working)
//
// What we DO touch (current bundle id + legacy `CodexMonitor` rename):
//   - ~/Library/Application Support/QuotaMonitor (SQLite + WAL)
//   - ~/Library/Preferences/dev.tjzhou.QuotaMonitor.plist
//   - ~/Library/Caches/dev.tjzhou.QuotaMonitor
//   - ~/Library/Saved Application State/dev.tjzhou.QuotaMonitor.savedState
//   - ~/Library/HTTPStorages/dev.tjzhou.QuotaMonitor*
//   - Trusted installed .app bundles (via NSWorkspace.recycle → Trash, not unlink)

extension AppEnvironment {

    /// Bundle identifiers whose files we own. Current production id
    /// plus the legacy `CodexMonitor` id from before the rename — if
    /// the user upgraded through that rename their UserDefaults
    /// migration ran but the legacy plist + Application Support
    /// folder can still be sitting around.
    nonisolated static let uninstallBundleIDs: [String] =
        ["dev.tjzhou.QuotaMonitor", "dev.tjzhou.CodexMonitor"]

    nonisolated static func allowsUninstall(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        LocalQAEnvironment.allowsExternalDataSources(
            environment: environment,
            arguments: arguments)
    }

    /// Pure helper: enumerate every Library path we should wipe given
    /// a `home` (the user's home directory) and the bundle-id list.
    /// Kept pure (no FileManager call, no I/O) so a test can assert
    /// the exact list without touching the real filesystem.
    nonisolated static func uninstallTargets(
        home: URL, bundleIDs: [String]
    ) -> [URL] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        var out: [URL] = []
        // Pairs of (app-support folder name, bundle-id). The folder
        // name is the human-readable app name we used for SQLite
        // storage (`QuotaMonitor`, legacy `CodexMonitor`); the bundle
        // id drives the dotted plist / caches / state paths.
        let folders = ["QuotaMonitor", "CodexMonitor"]
        for folder in folders {
            out.append(lib.appendingPathComponent(
                "Application Support/\(folder)", isDirectory: true))
        }
        for bid in bundleIDs {
            out.append(lib.appendingPathComponent(
                "Preferences/\(bid).plist", isDirectory: false))
            out.append(lib.appendingPathComponent(
                "Caches/\(bid)", isDirectory: true))
            out.append(lib.appendingPathComponent(
                "Saved Application State/\(bid).savedState", isDirectory: true))
            out.append(lib.appendingPathComponent(
                "HTTPStorages/\(bid)", isDirectory: true))
            out.append(lib.appendingPathComponent(
                "HTTPStorages/\(bid).binarycookies", isDirectory: false))
        }
        return out
    }

    /// App bundles safe for the uninstaller to move to Trash.
    ///
    /// The running bundle is included first so dev builds / DMG-run
    /// copies still uninstall themselves. We then scan trusted install
    /// locations for current and legacy names so uninstalling from a
    /// dev build also removes the stale `/Applications/QuotaMonitor.app`
    /// copy that Finder would otherwise ask to replace on reinstall.
    ///
    /// Every candidate, including same-name apps in `/Applications`,
    /// must prove ownership via `Contents/Info.plist` bundle id. This
    /// avoids deleting an unrelated app that happens to have the same
    /// filename.
    nonisolated static func trustedAppBundleTargets(
        home: URL,
        runningBundleURL: URL,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ],
        allowedBundleIDs: [String]
    ) -> [URL] {
        var candidates: [URL] = [runningBundleURL]
        let appNames = ["QuotaMonitor.app", "CodexMonitor.app"]
        let dirs = applicationsDirectories + [
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        for dir in dirs {
            for name in appNames {
                candidates.append(dir.appendingPathComponent(name, isDirectory: true))
            }
        }

        var seen: Set<String> = []
        var out: [URL] = []
        for candidate in candidates {
            let key = candidate.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            guard trustedBundleID(at: candidate, allowedBundleIDs: allowedBundleIDs) != nil else {
                continue
            }
            out.append(candidate)
        }
        return out
    }

    private nonisolated static func trustedBundleID(
        at bundleURL: URL,
        allowedBundleIDs: [String]
    ) -> String? {
        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String,
              allowedBundleIDs.contains(bundleID)
        else { return nil }
        return bundleID
    }

    /// Wipe all app-owned data, move the running .app bundle to
    /// Trash, then terminate. Best-effort: per-file delete failures
    /// are swallowed (a missing file is the expected case on a fresh
    /// install; permission errors on someone else's data we don't
    /// want to surface as a scary error). If `NSWorkspace.recycle`
    /// can't move the bundle (e.g. user is running from a read-only
    /// DMG), data is still wiped and we still terminate — the user
    /// can drag the .app manually.
    ///
    /// We deliberately do **not** explicitly stop the pollers first:
    /// the process is about to terminate, GRDB releases its file
    /// handles in deinit, and any in-flight write to a now-unlinked
    /// SQLite file lands on a phantom inode the kernel reaps on
    /// last-close. Adding plumbing to drain them cleanly would just
    /// be ceremony.
    func performUninstall() {
        guard Self.allowsUninstall() else {
            DeveloperLog.eventRecord(
                "uninstall.perform.skip",
                level: .warning,
                category: "uninstall",
                trigger: "user",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }

        let op = DeveloperLog.startOperation(
            "uninstall.perform",
            category: "uninstall",
            trigger: "user")
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let targets = Self.uninstallTargets(
            home: home, bundleIDs: Self.uninstallBundleIDs)
        DeveloperLog.eventRecord(
            "uninstall.targets",
            level: .warning,
            category: "uninstall",
            operation: op,
            trigger: "user",
            fields: ["targets": .int(targets.count)])

        // 1. UserDefaults — flush the in-memory domain so even if
        //    `cfprefsd` had buffered writes pending, they won't
        //    repopulate the plist between our unlink and terminate().
        for bid in Self.uninstallBundleIDs {
            UserDefaults.standard.removePersistentDomain(forName: bid)
        }
        UserDefaults.standard.synchronize()

        // 2. Files. `removeItem` throws on missing — swallow per call.
        for url in targets {
            try? fm.removeItem(at: url)
            DeveloperLog.eventRecord(
                "uninstall.target.remove",
                category: "uninstall",
                operation: op,
                trigger: "user",
                fields: ["path": .string(url.path)])
        }

        // 3. Move trusted .app bundles to Trash via NSWorkspace.recycle.
        //    macOS keeps the running binary's memory mapping valid
        //    until our process exits, so the trash move is safe to
        //    do before terminate(). Completion fires on the main
        //    thread; we terminate from there regardless of success
        //    so the data wipe sticks even if the bundle move fails.
        let appBundles = Self.trustedAppBundleTargets(
            home: home,
            runningBundleURL: Bundle.main.bundleURL,
            allowedBundleIDs: Self.uninstallBundleIDs)
        DeveloperLog.eventRecord(
            "uninstall.app_bundles.recycle",
            level: .warning,
            category: "uninstall",
            operation: op,
            trigger: "user",
            fields: ["app_bundles": .string(appBundles.map(\.path).joined(separator: ","))])
        DeveloperLog.finishOperation(op, fields: [
            "targets": .int(targets.count),
            "app_bundles": .int(appBundles.count)
        ])
        NSWorkspace.shared.recycle(appBundles) { _, _ in
            // Hop back to MainActor — recycle's completion handler
            // is documented as main-thread, but the closure isn't
            // typed as @MainActor so Swift 6 won't let us call
            // NSApp.terminate directly without the hop.
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
