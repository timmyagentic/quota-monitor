import Foundation
import GRDB

// Pricing-catalog actions extracted from AppEnvironment.
// Lives as an extension so the @Observable storage is unaffected.

extension AppEnvironment {

    nonisolated static func allowsPricingRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        LocalQAEnvironment.allowsExternalDataSources(
            environment: environment,
            arguments: arguments)
    }

    /// Fire a LiteLLM refresh if we've never fetched, or the latest fetched_at
    /// is older than 24h. Errors are swallowed (set on `lastError`).
    func refreshPricingIfStale(maxAge: TimeInterval = 24 * 3600) async {
        guard Self.allowsPricingRefresh() else {
            DeveloperLog.eventRecord(
                "pricing.refresh_if_stale.skip",
                category: "pricing",
                trigger: "background",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }

        let op = DeveloperLog.startOperation(
            "pricing.refresh_if_stale",
            category: "pricing",
            trigger: "background",
            fields: ["max_age_seconds": .double(maxAge)])
        do {
            let (db, _) = try ensureServices()
            let latest = try await db.pool.read { conn -> Date? in
                let iso = try String.fetchOne(conn, sql: """
                    SELECT fetched_at FROM pricing_catalog
                    WHERE fetched_at IS NOT NULL
                    ORDER BY fetched_at DESC LIMIT 1
                    """)
                return iso.flatMap(ISO8601.parse)
            }
            if let latest, Date().timeIntervalSince(latest) < maxAge {
                DeveloperLog.finishOperation(
                    op,
                    result: "skipped",
                    fields: [
                        "reason": "fresh",
                        "latest": .string(ISO8601.fractional.string(from: latest))
                    ])
                return
            }
            DeveloperLog.eventRecord(
                "pricing.refresh_if_stale.refresh",
                category: "pricing",
                operation: op,
                trigger: "background",
                fields: ["latest": .string(latest.map { ISO8601.fractional.string(from: $0) } ?? "")])
            _ = try await refreshPricingFromLiteLLM()
            DeveloperLog.finishOperation(op)
        } catch {
            self.lastError = "LiteLLM refresh failed: \(error.localizedDescription)"
            DeveloperLog.failOperation(op, error: error)
        }
    }

    /// Pull latest prices from LiteLLM and apply them to the catalog. Throws on
    /// network/decode failure so the caller can surface it.
    @discardableResult
    func refreshPricingFromLiteLLM() async throws -> Int {
        guard Self.allowsPricingRefresh() else {
            DeveloperLog.eventRecord(
                "pricing.litellm_refresh.skip",
                category: "pricing",
                trigger: "settings",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return 0
        }
        guard !isRefreshingPricing else {
            DeveloperLog.eventRecord(
                "pricing.litellm_refresh.skip",
                category: "pricing",
                trigger: "settings",
                result: "skipped",
                fields: ["reason": "already-refreshing"])
            return 0
        }
        isRefreshingPricing = true
        defer { isRefreshingPricing = false }
        let op = DeveloperLog.startOperation(
            "pricing.litellm_refresh",
            category: "pricing",
            trigger: "settings")

        do {
            let (db, _) = try ensureServices()
            let entries = try await pricingSource.fetch()
            let fastMode = SettingsStore.snapshot().codexFastModeBilling
            let updated = try await db.pool.write { conn in
                try PricingService.applyLiteLLMUpdate(
                    entries: entries, in: conn,
                    codexFastModeBilling: fastMode)
            }
            // Stamp the most-recent fetched_at we can see (any non-local row).
            let latest = try await db.pool.read { conn -> Date? in
                let iso = try String.fetchOne(conn, sql: """
                    SELECT fetched_at FROM pricing_catalog
                    WHERE fetched_at IS NOT NULL
                    ORDER BY fetched_at DESC LIMIT 1
                    """)
                return iso.flatMap(ISO8601.parse)
            }
            refreshDashboard(trigger: "pricing", parentOperation: op)
            DeveloperLog.finishOperation(
                op,
                fields: [
                    "updated": .int(updated),
                    "latest": .string(latest.map { ISO8601.fractional.string(from: $0) } ?? ""),
                    "codex_fast_mode_billing": .bool(fastMode)
                ])
            return updated
        } catch {
            DeveloperLog.failOperation(op, error: error)
            throw error
        }
    }

    func restorePricingDefaults() async throws {
        let op = DeveloperLog.startOperation(
            "pricing.restore_defaults",
            category: "pricing",
            trigger: "settings")
        do {
            let (db, _) = try ensureServices()
            let fastMode = SettingsStore.snapshot().codexFastModeBilling
            try await db.pool.write { conn in
                try PricingService.seedCatalog(in: conn)
                try PricingService.backfillAllValues(
                    in: conn, codexFastModeBilling: fastMode)
            }
            refreshDashboard(trigger: "pricing", parentOperation: op)
            DeveloperLog.finishOperation(op, fields: ["codex_fast_mode_billing": .bool(fastMode)])
        } catch {
            DeveloperLog.failOperation(op, error: error)
            throw error
        }
    }

    /// Re-price every event under the new Codex Fast-Mode setting and
    /// refresh menu-bar + dashboard so the user sees the new dollar
    /// totals immediately. Called from the Advanced tab toggle's
    /// `onChange`. Swallows errors into `lastError` rather than throwing
    /// so a transient DB hiccup doesn't crash the settings sheet.
    func applyCodexFastModeBilling() {
        let op = DeveloperLog.startOperation(
            "pricing.codex_fast_mode.apply",
            category: "pricing",
            trigger: "settings",
            fields: ["enabled": .bool(SettingsStore.shared.codexFastModeBilling)])
        Task { [op] in
            do {
                let (db, _) = try ensureServices()
                let fastMode = SettingsStore.shared.codexFastModeBilling
                try await db.pool.write { conn in
                    try PricingService.backfillAllValues(
                        in: conn, codexFastModeBilling: fastMode)
                }
                refreshDashboard(trigger: "pricing", parentOperation: op)
                refreshMenuBar(trigger: "pricing", parentOperation: op)
                DeveloperLog.finishOperation(op, fields: ["enabled": .bool(fastMode)])
            } catch {
                self.lastError = "Codex Fast-Mode billing apply failed: \(error.localizedDescription)"
                DeveloperLog.failOperation(op, error: error)
            }
        }
    }

    func loadPricingCatalog() async throws -> [PricingCatalogRow] {
        let op = DeveloperLog.startOperation(
            "pricing.catalog.load",
            category: "pricing",
            trigger: "settings")
        do {
            let (db, _) = try ensureServices()
            let rows = try await db.pool.read { conn in
                try Row.fetchAll(conn, sql: """
                    SELECT model_id, display_name,
                           input_price_per_million, cached_input_price_per_million,
                           output_price_per_million, cache_creation_price_per_million,
                           is_official, note, source_url, updated_at,
                           price_source, fetched_at
                    FROM pricing_catalog
                    ORDER BY model_id
                    """).map { row in
                    PricingCatalogRow(
                        modelId: row["model_id"] ?? "",
                        displayName: row["display_name"] ?? "",
                        inputPrice: row["input_price_per_million"] ?? 0,
                        cachedInputPrice: row["cached_input_price_per_million"] ?? 0,
                        outputPrice: row["output_price_per_million"] ?? 0,
                        cacheCreationPrice: row["cache_creation_price_per_million"] ?? 0,
                        isOfficial: row["is_official"] ?? false,
                        note: row["note"],
                        sourceUrl: row["source_url"] ?? "",
                        updatedAt: row["updated_at"] ?? "",
                        priceSource: row["price_source"] ?? "seed",
                        fetchedAt: row["fetched_at"])
                }
            }
            DeveloperLog.finishOperation(op, fields: ["rows": .int(rows.count)])
            return rows
        } catch {
            DeveloperLog.failOperation(op, error: error)
            throw error
        }
    }
}
