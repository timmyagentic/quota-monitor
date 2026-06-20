import AppKit
import Foundation
import GRDB

// File-scan + CSV-export actions extracted from AppEnvironment.

extension AppEnvironment {

    /// `minInterval` is honoured **only** by the auto-refresh-on-popover-open
    /// caller. Refresh button presses pass nil → always run, because the
    /// user expressing explicit intent should never be silently throttled.
    func runScan(
        minInterval: TimeInterval? = nil,
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
        if let interval = minInterval, let last = lastScanAt,
           Date().timeIntervalSince(last) < interval {
            DeveloperLog.eventRecord(
                "scan.run.skip",
                category: "scan",
                operation: parentOperation,
                trigger: trigger,
                result: "skipped",
                fields: [
                    "reason": "throttled",
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
                }
            }
            do {
                let (db, engine) = try self.ensureServices()
                let claude = self.claudeEngine
                let snap = SettingsStore.snapshot()
                let enabled = snap.enabledProviders
                let fastMode = snap.codexFastModeBilling
                DeveloperLog.eventRecord(
                    "scan.providers",
                    category: "scan",
                    operation: op,
                    trigger: trigger,
                    fields: [
                        "enabled_providers": .string(enabled.sorted().joined(separator: ",")),
                        "codex_fast_mode_billing": .bool(fastMode)
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
                    // them in Settings. Returning `.empty` keeps the merge +
                    // backfill logic below identical regardless of which
                    // providers are active.
                    async let codexReport = enabled.contains("codex")
                        ? engine.performScan(progress: progressHandler)
                        : ImportEngine.ScanReport.empty
                    // Run the Claude scan as its own task so the optional-
                    // chained `claude?.performScan()` doesn't interact
                    // awkwardly with `async let` (we hit a case where the
                    // call appeared to be skipped silently).
                    let claudeTask = Task { () async throws -> ImportEngine.ScanReport in
                        guard enabled.contains("claude"), let claude else {
                            return .empty
                        }
                        return try await claude.performScan(progress: progressHandler)
                    }
                    let merged = Self.mergeScanReports(
                        try await codexReport, try await claudeTask.value)
                    // Single backfill at the tail values any Codex/Claude rows
                    // imported in this pass and propagates price-table edits.
                    // Skip when nothing changed — backfill is sub-second, but
                    // it still pulls a write lock and walks every event row.
                    if merged.changedFiles > 0 {
                        await MainActor.run { self.markScanPricing(runID: scanRunID) }
                        try await db.pool.write {
                            try PricingService.backfillAllValues(
                                in: $0, codexFastModeBilling: fastMode)
                        }
                    }
                    return merged
                }
                await MainActor.run {
                    self.lastScanReport = merged
                    self.lastScanAt = Date()
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
                        "errors": .int(merged.errors.count)
                    ])
                // runScan() typically fires from the popover (open +
                // Refresh button). Always refresh the menu bar; only
                // refresh the Dashboard when its window is actually
                // visible, since `loadDashboard` is a much heavier
                // aggregator query and would be wasted work if no one
                // is looking. When the Dashboard *is* open, skipping
                // the refresh used to leave it lagging behind the
                // menu-bar card until the user re-focused the window.
                let blocks = try? await db.pool.read { conn in
                    try BillingBlocks.loadSnapshot(db: conn, provider: .claude)
                }
                let dashboardVisible = await MainActor.run {
                    NSApp.windows.contains { w in
                        w.identifier?.rawValue == "dashboard" && w.isVisible
                    }
                }
                await MainActor.run {
                    self.refreshMenuBar(
                        precomputedBlocks: blocks,
                        trigger: "scan",
                        parentOperation: op)
                    if dashboardVisible {
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

    nonisolated static func mergeScanReports(
        _ a: ImportEngine.ScanReport, _ b: ImportEngine.ScanReport
    ) -> ImportEngine.ScanReport {
        ImportEngine.ScanReport(
            scannedFiles: a.scannedFiles + b.scannedFiles,
            changedFiles: a.changedFiles + b.changedFiles,
            importedSessions: a.importedSessions + b.importedSessions,
            importedEvents: a.importedEvents + b.importedEvents,
            importedRateLimitSamples: a.importedRateLimitSamples + b.importedRateLimitSamples,
            errors: a.errors + b.errors)
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

    func markScanPricing(runID: UUID) {
        guard scanProgressRunID == runID, isScanning else { return }
        DeveloperLog.eventRecord(
            "scan.progress.pricing",
            level: .debug,
            category: "scan",
            fields: ["scan_run_id": .string(runID.uuidString)])
        scanProgress = Self.aggregateScanProgress(scanProgressStates, phase: .pricing)
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
