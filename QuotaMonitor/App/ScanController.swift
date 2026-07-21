import AppKit
import Foundation
import GRDB

// File-scan + CSV-export actions extracted from AppEnvironment.

struct ScanRefreshDecision: Equatable, Sendable {
    let refreshMenuBar: Bool
    let refreshDashboard: Bool
}

extension AppEnvironment {

    /// `minInterval` is honoured **only** by the auto-refresh-on-popover-open
    /// caller. Refresh button presses pass nil → always run, because the
    /// user expressing explicit intent should never be silently throttled.
    func runScan(
        minInterval: TimeInterval? = nil,
        providers: Set<String>? = nil,
        trigger: String = "manual",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard !isScanning else {
            DeveloperLog.eventRecord(
                "scan.run.skip",
                category: "scan",
                operation: parentOperation,
                trigger: trigger,
                result: "skipped",
                fields: ["reason": "already-scanning"])
            return
        }
        // Hard gate: don't touch ~/.codex or ~/.claude until the user
        // has finished onboarding. Same rationale as the network
        // refreshes in AppEnvironment — first-launch should see the
        // setup wizard before anything starts probing user folders.
        let initialSnap = SettingsStore.snapshot()
        guard initialSnap.hasCompletedProviderOnboarding else {
            DeveloperLog.eventRecord(
                "scan.run.skip",
                category: "scan",
                operation: parentOperation,
                trigger: trigger,
                result: "skipped",
                fields: ["reason": "onboarding"])
            return
        }
        // App Store sandbox builds can only read history folders the user has
        // explicitly authorized (security-scoped bookmarks). Abort the scan
        // ONLY when *no* enabled provider is authorized — otherwise we scope
        // the scan to the authorized subset below, so an authorized Codex
        // keeps importing while Claude still awaits a folder grant (and vice
        // versa). Developer ID builds skip this branch entirely.
        if DistributionChannel.current == .appStore {
            let authorized = HistoryRootAuthorizationStore.shared
                .authorizedProviders(from: initialSnap.enabledProviders)
            if Self.appStoreScanShouldAbort(isAppStore: true, authorized: authorized) {
                let missing = HistoryRootAuthorizationStore.shared
                    .missingRequiredKinds(for: initialSnap.enabledProviders)
                let labels = missing.map(\.rawValue).joined(separator: ",")
                lastError = L10n.historyFoldersNotAuthorized
                DeveloperLog.eventRecord(
                    "scan.run.skip",
                    category: "scan",
                    operation: parentOperation,
                    trigger: trigger,
                    result: "skipped",
                    fields: [
                        "reason": "history-roots-missing",
                        "missing_roots": .string(labels)
                    ])
                return
            }
        }
        // Throttle against the last scan *of the same scope* — a Claude-only
        // watcher scan must not throttle the full popover scan (which imports
        // Codex too), and vice-versa.
        let throttleKey = Self.scanThrottleKey(forRequested: providers)
        if let interval = minInterval, let last = lastScanAtByScope[throttleKey],
           Date().timeIntervalSince(last) < interval {
            DeveloperLog.eventRecord(
                "scan.run.skip",
                category: "scan",
                operation: parentOperation,
                trigger: trigger,
                result: "skipped",
                fields: [
                    "reason": "throttled",
                    "scan_scope": .string(throttleKey),
                    "min_interval_seconds": .double(interval),
                    "elapsed_seconds": .double(Date().timeIntervalSince(last))
                ])
            return
        }
        isScanning = true
        lastError = nil
        let scanRunID = beginScanProgress()
        let op = DeveloperLog.startOperation(
            "scan.run",
            category: "scan",
            trigger: trigger,
            parent: parentOperation,
            fields: [
                "scan_run_id": .string(scanRunID.uuidString),
                "min_interval_seconds": minInterval.map(DeveloperLogValue.double) ?? .string("none")
            ])

        Task { [weak self, op] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isScanning = false
                    self.clearScanProgress(runID: scanRunID)
                    // Fire any Claude file-watch write that was coalesced while
                    // this scan held `isScanning`, so a post-read append isn't
                    // stranded until the next write / manual refresh.
                    self.runPendingClaudeFileWatchScanIfNeeded()
                }
            }
            do {
                let (db, engine) = try self.ensureServices()
                let claude = self.claudeEngine
                let snap = SettingsStore.snapshot()
                let enabled = snap.enabledProviders
                // A requested scope (e.g. the Claude file-watcher's
                // ["claude"]) is intersected with the enabled set so a
                // ~/.claude write never triggers a separate Codex scan.
                let requestedScope = Self.resolveScanProviders(
                    requested: providers, enabled: enabled)
                // In App Store builds, further restrict to providers whose
                // history folder is authorized — the unauthorized ones are
                // simply skipped this run (not aborted), matching the gate above.
                let isAppStore = DistributionChannel.current == .appStore
                let scanProviders = Self.appStoreScanProviders(
                    requested: requestedScope,
                    authorized: isAppStore
                        ? HistoryRootAuthorizationStore.shared.authorizedProviders(from: enabled)
                        : [],
                    isAppStore: isAppStore)
                DeveloperLog.eventRecord(
                    "scan.providers",
                    category: "scan",
                    operation: op,
                    trigger: trigger,
                    fields: [
                        "enabled_providers": .string(enabled.sorted().joined(separator: ",")),
                        "scan_providers": .string(scanProviders.sorted().joined(separator: ","))
                    ])
                let progressHandler: ScanProgressHandler = { [weak self] update in
                    await MainActor.run {
                        self?.handleScanProgressUpdate(update, runID: scanRunID)
                    }
                }
                // Hard 5-minute cap so a runaway parser (e.g. a hundreds-of-MB
                // rollout from a still-active Codex session) can't strand
                // `isScanning = true` and freeze the Refresh button forever.
                // On timeout the underlying work task is cancelled (best-
                // effort) and we surface the timeout via `lastError`.
                let merged = try await Self.withTimeout(
                    seconds: 300, context: "runScan"
                ) {
                    // Skip per-provider engines when the user has disabled
                    // them in Settings. Returning `.empty` keeps report
                    // merging identical regardless of which providers are
                    // active. Each importer prices its affected session in
                    // the same transaction that advances its import state.
                    async let codexReport = scanProviders.contains("codex")
                        ? engine.performScan(progress: progressHandler)
                        : ImportEngine.ScanReport.empty
                    // Run the Claude scan as its own task so the optional-
                    // chained `claude?.performScan()` doesn't interact
                    // awkwardly with `async let` (we hit a case where the
                    // call appeared to be skipped silently).
                    let claudeTask = Task { () async throws -> ImportEngine.ScanReport in
                        guard scanProviders.contains("claude"), let claude else {
                            return .empty
                        }
                        return try await claude.performScan(progress: progressHandler)
                    }
                    return Self.mergeScanReports(
                        try await codexReport, try await claudeTask.value)
                }
                await MainActor.run {
                    self.lastScanReport = merged
                    self.lastScanAtByScope[throttleKey] = Date()
                    // A resolved-but-unopenable App Store bookmark imported
                    // nothing silently; tell the user to re-select the folder.
                    if merged.scopeUnavailable {
                        self.lastError = L10n.historyFolderScopeUnavailable
                    }
                }
                DeveloperLog.finishOperation(
                    op,
                    fields: [
                        "scan_run_id": .string(scanRunID.uuidString),
                        "scanned_files": .int(merged.scannedFiles),
                        "changed_files": .int(merged.changedFiles),
                        "imported_sessions": .int(merged.importedSessions),
                        "imported_events": .int(merged.importedEvents),
                        "imported_rate_limit_samples": .int(merged.importedRateLimitSamples),
                        "updated_session_metadata": .int(merged.updatedSessionMetadata),
                        "errors": .int(merged.errors.count)
                    ])
                // A no-op file scan leaves every summary query's input
                // unchanged, so avoid re-running those queries. The one
                // exception is an environment that has never obtained its
                // first menu snapshot and has no request in flight.
                let decision = await MainActor.run {
                    Self.scanRefreshDecision(
                        didChangeReadModel: merged.didChangeReadModel,
                        hasMenuBarSnapshot: self.menuBarSnapshot != nil,
                        isMenuBarRefreshInFlight: self.isLoadingMenuBar,
                        isDashboardVisible: NSApp.windows.contains { window in
                            window.identifier?.rawValue == "dashboard" && window.isVisible
                        })
                }
                let blocks = decision.refreshMenuBar
                    ? try? await db.pool.read { conn in
                        try BillingBlocks.loadSnapshot(db: conn, provider: .claude)
                    }
                    : nil
                await MainActor.run {
                    if decision.refreshMenuBar {
                        self.refreshMenuBar(
                            precomputedBlocks: blocks,
                            trigger: "scan",
                            parentOperation: op)
                    }
                    if decision.refreshDashboard {
                        self.refreshDashboard(trigger: "scan", parentOperation: op)
                    }
                }
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
                DeveloperLog.failOperation(
                    op,
                    error: error,
                    fields: ["scan_run_id": .string(scanRunID.uuidString)])
            }
        }
    }

    /// Stream all usage_events to a CSV file at `url`.
    func exportUsageEventsCSV(to url: URL) async throws -> Int {
        let op = DeveloperLog.startOperation(
            "export.usage_events_csv",
            category: "export",
            trigger: "user",
            fields: ["path": .string(url.path)])
        do {
            let (db, _) = try ensureServices()
            let count = try await Self.writeUsageEventsCSV(database: db, to: url)
            DeveloperLog.finishOperation(op, fields: [
                "path": .string(url.path),
                "rows": .int(count)
            ])
            return count
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: ["path": .string(url.path)])
            throw error
        }
    }

    nonisolated static func writeUsageEventsCSV(database db: DatabaseManager, to url: URL) async throws -> Int {
        try await db.pool.read { conn in
            let rows = try Row.fetchCursor(conn, sql: """
                SELECT ue.id, ue.session_id, ue.timestamp, ue.model_id,
                       ue.input_tokens, ue.cached_input_tokens, ue.output_tokens,
                       ue.reasoning_output_tokens, ue.total_tokens, ue.value_usd,
                       COALESCE(NULLIF(TRIM(s.title), ''), NULLIF(TRIM(s.project_name), ''), '') AS export_title,
                       s.agent_nickname
                FROM usage_events ue
                LEFT JOIN sessions s ON s.session_id = ue.session_id
                ORDER BY ue.timestamp ASC
                """)
            let header = "id,session_id,timestamp,model_id,input,cached,output,reasoning,total,value_usd,title,agent\n"
            guard FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8)) else {
                throw NSError(domain: "QuotaMonitor", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create file at \(url.path)"])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var count = 0
            while let row = try rows.next() {
                let line = Self.csvRow([
                    "\(row["id"] as Int64? ?? 0)",
                    row["session_id"] as String? ?? "",
                    row["timestamp"] as String? ?? "",
                    row["model_id"] as String? ?? "",
                    "\(row["input_tokens"] as Int64? ?? 0)",
                    "\(row["cached_input_tokens"] as Int64? ?? 0)",
                    "\(row["output_tokens"] as Int64? ?? 0)",
                    "\(row["reasoning_output_tokens"] as Int64? ?? 0)",
                    "\(row["total_tokens"] as Int64? ?? 0)",
                    String(format: "%.6f", row["value_usd"] as Double? ?? 0),
                    row["export_title"] as String? ?? "",
                    row["agent_nickname"] as String? ?? ""
                ])
                if let data = (line + "\n").data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                count += 1
            }
            return count
        }
    }

    /// Intersect a requested provider scope with the user's enabled
    /// providers. `nil` means "scan everything enabled" (the default
    /// for refresh/popover/manual). The Claude file-watcher passes
    /// `["claude"]` so reacting to a `~/.claude` write only runs the
    /// cheap incremental Claude import, without starting a Codex scan.
    nonisolated static func resolveScanProviders(
        requested: Set<String>?, enabled: Set<String>
    ) -> Set<String> {
        guard let requested else { return enabled }
        return enabled.intersection(requested)
    }

    nonisolated static func mergeScanReports(
        _ a: ImportEngine.ScanReport, _ b: ImportEngine.ScanReport
    ) -> ImportEngine.ScanReport {
        ImportEngine.ScanReport(
            scannedFiles: a.scannedFiles + b.scannedFiles,
            changedFiles: a.changedFiles + b.changedFiles,
            importedSessions: a.importedSessions + b.importedSessions,
            importedEvents: a.importedEvents + b.importedEvents,
            importedRateLimitSamples: a.importedRateLimitSamples + b.importedRateLimitSamples,
            updatedSessionMetadata: a.updatedSessionMetadata + b.updatedSessionMetadata,
            incrementalFiles: a.incrementalFiles + b.incrementalFiles,
            sourceBytesRead: a.sourceBytesRead + b.sourceBytesRead,
            errors: a.errors + b.errors,
            scopeUnavailable: a.scopeUnavailable || b.scopeUnavailable)
    }

    /// Pure post-scan refresh policy. A persisted read-model change always
    /// refreshes the menu snapshot and refreshes the Dashboard only while it
    /// is visible. A no-op scan does neither, unless it is the only remaining
    /// opportunity to populate the first menu snapshot.
    nonisolated static func scanRefreshDecision(
        didChangeReadModel: Bool,
        hasMenuBarSnapshot: Bool,
        isMenuBarRefreshInFlight: Bool,
        isDashboardVisible: Bool
    ) -> ScanRefreshDecision {
        ScanRefreshDecision(
            refreshMenuBar: didChangeReadModel
                || (!hasMenuBarSnapshot && !isMenuBarRefreshInFlight),
            refreshDashboard: didChangeReadModel && isDashboardVisible)
    }

    /// Pure App Store scan-scope decisions, extracted so they can be unit-tested
    /// without the full `runScan` machinery. Developer ID builds are never
    /// scoped or aborted.
    nonisolated static func appStoreScanShouldAbort(
        isAppStore: Bool, authorized: Set<String>
    ) -> Bool {
        isAppStore && authorized.isEmpty
    }

    nonisolated static func appStoreScanProviders(
        requested: Set<String>, authorized: Set<String>, isAppStore: Bool
    ) -> Set<String> {
        isAppStore ? requested.intersection(authorized) : requested
    }

    func beginScanProgress() -> UUID {
        let runID = UUID()
        DeveloperLog.eventRecord(
            "scan.progress.begin",
            level: .debug,
            category: "scan",
            fields: ["scan_run_id": .string(runID.uuidString)])
        scanProgressRunID = runID
        scanProgressStates = [:]
        scanProgress = ScanProgress(
            phase: .discovering,
            completedFiles: 0,
            totalFiles: 0,
            currentFile: nil)
        return runID
    }

    func handleScanProgressUpdate(_ update: ScanProgressUpdate, runID: UUID) {
        guard scanProgressRunID == runID, isScanning else { return }
        DeveloperLog.eventRecord(
            "scan.progress.update",
            level: .debug,
            category: "scan",
            provider: update.provider,
            fields: [
                "scan_run_id": .string(runID.uuidString),
                "completed_files": .int(update.completedFiles),
                "total_files": .int(update.totalFiles),
                "current_file": .string(update.currentFile ?? "")
            ])
        scanProgressStates[update.provider] = ScanProviderProgress(
            completedFiles: update.completedFiles,
            totalFiles: update.totalFiles,
            currentFile: update.currentFile)
        scanProgress = Self.aggregateScanProgress(scanProgressStates, phase: .indexing)
    }

    func clearScanProgress(runID: UUID) {
        guard scanProgressRunID == runID else { return }
        DeveloperLog.eventRecord(
            "scan.progress.clear",
            level: .debug,
            category: "scan",
            fields: ["scan_run_id": .string(runID.uuidString)])
        scanProgressStates = [:]
        scanProgressRunID = nil
        scanProgress = nil
    }

    nonisolated static func aggregateScanProgress(
        _ states: [String: ScanProviderProgress],
        phase: ScanProgress.Phase
    ) -> ScanProgress {
        let completed = states.values.reduce(0) { $0 + max(0, $1.completedFiles) }
        let total = states.values.reduce(0) { $0 + max(0, $1.totalFiles) }
        let current = states.keys.sorted()
            .compactMap { key -> String? in
                guard let file = states[key]?.currentFile,
                      !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return file
            }
            .first
        return ScanProgress(
            phase: phase,
            completedFiles: completed,
            totalFiles: total,
            currentFile: current)
    }

    nonisolated static func csvRow(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }
}
