import Foundation
import GRDB

// Pricing-catalog actions extracted from AppEnvironment.
// Lives as an extension so the @Observable storage is unaffected.

extension AppEnvironment {

    /// Fire a LiteLLM refresh if we've never fetched, or the latest fetched_at
    /// is older than 24h. Errors are swallowed (set on `lastError`).
    func refreshPricingIfStale(maxAge: TimeInterval = 24 * 3600) async {
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
            lastPricingFetchedAt = latest
            if let latest, Date().timeIntervalSince(latest) < maxAge { return }
            _ = try await refreshPricingFromLiteLLM()
        } catch {
            self.lastError = "LiteLLM refresh failed: \(error.localizedDescription)"
        }
    }

    /// Pull latest prices from LiteLLM and apply them to the catalog. Throws on
    /// network/decode failure so the caller can surface it.
    @discardableResult
    func refreshPricingFromLiteLLM() async throws -> Int {
        guard !isRefreshingPricing else { return 0 }
        isRefreshingPricing = true
        defer { isRefreshingPricing = false }

        let (db, _) = try ensureServices()
        let entries = try await pricingSource.fetch()
        let updated = try await db.pool.write { conn in
            try PricingService.applyLiteLLMUpdate(entries: entries, in: conn)
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
        lastPricingFetchedAt = latest
        lastPricingUpdateCount = updated
        refreshDashboard()
        return updated
    }

    func restorePricingDefaults() async throws {
        let (db, _) = try ensureServices()
        try await db.pool.write { conn in
            try PricingService.seedCatalog(in: conn)
            try PricingService.backfillAllValues(in: conn)
        }
        refreshDashboard()
    }

    func loadPricingCatalog() async throws -> [PricingCatalogRow] {
        let (db, _) = try ensureServices()
        return try await db.pool.read { conn in
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
    }
}
