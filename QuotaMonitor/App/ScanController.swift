import Foundation
import GRDB

// File-scan + CSV-export actions extracted from AppEnvironment.

extension AppEnvironment {

    /// `minInterval` is honoured **only** by the auto-refresh-on-popover-open
    /// caller. Refresh button presses pass nil → always run, because the
    /// user expressing explicit intent should never be silently throttled.
    func runScan(minInterval: TimeInterval? = nil) {
        guard !isScanning else { return }
        // Hard gate: don't touch ~/.codex or ~/.claude until the user
        // has finished onboarding. Same rationale as the network
        // refreshes in AppEnvironment — first-launch should see the
        // setup wizard before anything starts probing user folders.
        guard SettingsStore.snapshot().hasCompletedProviderOnboarding else { return }
        if let interval = minInterval, let last = lastScanAt,
           Date().timeIntervalSince(last) < interval {
            return
        }
        isScanning = true
        lastError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isScanning = false } }
            do {
                let (db, engine) = try self.ensureServices()
                let claude = self.claudeEngine
                let enabled = SettingsStore.snapshot().enabledProviders
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
                        ? engine.performScan()
                        : ImportEngine.ScanReport.empty
                    // Run the Claude scan as its own task so the optional-
                    // chained `claude?.performScan()` doesn't interact
                    // awkwardly with `async let` (we hit a case where the
                    // call appeared to be skipped silently).
                    let claudeTask = Task { () async throws -> ImportEngine.ScanReport in
                        guard enabled.contains("claude"), let claude else {
                            return .empty
                        }
                        return try await claude.performScan()
                    }
                    let merged = Self.mergeScanReports(
                        try await codexReport, try await claudeTask.value)
                    // Single backfill at the tail values any Codex/Claude rows
                    // imported in this pass and propagates price-table edits.
                    // Skip when nothing changed — backfill is sub-second, but
                    // it still pulls a write lock and walks every event row.
                    if merged.changedFiles > 0 {
                        try await db.pool.write { try PricingService.backfillAllValues(in: $0) }
                    }
                    return merged
                }
                await MainActor.run {
                    self.lastScanReport = merged
                    self.lastScanAt = Date()
                }
                // runScan() only fires from the popover (open + Refresh
                // button), so we refresh only the menu bar here.
                // Dashboard refreshes itself via `.task { refreshDashboard() }`
                // when its window opens, and the Dashboard's own Refresh
                // button is a separate path that doesn't go through runScan.
                // Skipping the Dashboard's heavy aggregator query keeps the
                // popover-triggered refresh cheap.
                let blocks = try? await db.pool.read { conn in
                    try BillingBlocks.loadSnapshot(db: conn, provider: .claude)
                }
                await MainActor.run {
                    self.refreshMenuBar(precomputedBlocks: blocks)
                }
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
            }
        }
    }

    /// Stream all usage_events to a CSV file at `url`.
    func exportUsageEventsCSV(to url: URL) async throws -> Int {
        let (db, _) = try ensureServices()
        return try await db.pool.read { conn in
            let rows = try Row.fetchCursor(conn, sql: """
                SELECT ue.id, ue.session_id, ue.timestamp, ue.model_id,
                       ue.input_tokens, ue.cached_input_tokens, ue.output_tokens,
                       ue.reasoning_output_tokens, ue.total_tokens, ue.value_usd,
                       s.title, s.agent_nickname
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
                    row["title"] as String? ?? "",
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

    nonisolated static func csvRow(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }
}
