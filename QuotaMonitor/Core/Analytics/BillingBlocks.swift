import Foundation
import GRDB

// Reconstructs Anthropic's 5-hour billing windows from `usage_events` rows.
// Ported from ccusage's `_session-blocks.ts` — same gap-detection rules, same
// hour-floored block start, same burn-rate / projection math.
//
// Concept is Anthropic-specific. We expose `loadCurrent` against any provider
// filter, but in practice the caller restricts to `.claude` since Codex has
// no equivalent billing window.

enum BillingBlocks {

    /// Anthropic's 5-hour billing block.
    static let sessionDuration: TimeInterval = 5 * 60 * 60

    // MARK: - Public types

    struct TokenCounts: Sendable, Equatable, Hashable {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheCreation: Int64 = 0
        var cacheRead: Int64 = 0
        var total: Int64 { input + output + cacheCreation + cacheRead }
        /// Subset used for the burn-rate "indicator" (excludes cache traffic so
        /// the threshold matches pre-cache-pricing behavior).
        var nonCache: Int64 { input + output }
    }

    struct Block: Sendable, Identifiable, Equatable, Hashable {
        let id: String
        let startTime: Date
        /// Nominal end (`startTime + 5h`) for normal blocks; for gap blocks it's
        /// the wall-clock instant when activity resumed.
        let endTime: Date
        let firstEntryAt: Date?
        let lastEntryAt: Date?
        let isActive: Bool
        let isGap: Bool
        let entryCount: Int
        let tokenCounts: TokenCounts
        let costUSD: Double
        let models: [String]
    }

    struct BurnRate: Sendable, Equatable {
        let tokensPerMinute: Double
        /// Non-cache tokens/min — used for HIGH/MODERATE/NORMAL color band.
        let nonCacheTokensPerMinute: Double
        let costPerHour: Double
    }

    struct Projection: Sendable, Equatable {
        let totalTokens: Int64
        let totalCost: Double
        let remainingMinutes: Int
    }

    /// What the Dashboard / menu bar render. Only the current (or most recent)
    /// block is included for now — recent-block history is a follow-up.
    struct Snapshot: Sendable, Equatable {
        let currentBlock: Block?
        let burnRate: BurnRate?
        let projection: Projection?
        /// All non-gap blocks from the last `recentDays`, newest first.
        let recentBlocks: [Block]
    }

    // MARK: - Public API

    /// Build blocks + burn-rate + projection from Claude `usage_events` rows.
    /// `provider` should be `.claude` in practice; passing `.all` includes
    /// Codex events which don't really fit the 5h model but stays consistent.
    static func loadSnapshot(
        db: Database,
        provider: ProviderFilter = .claude,
        now: Date = Date(),
        recentDays: Int = 3
    ) throws -> Snapshot {
        // Only fetch what `recentBlocks` could possibly need plus a generous
        // safety buffer (one extra day) so an in-progress block whose start
        // is exactly at the cutoff still has all its events to sum. Without
        // this, fetchEntries scans the full usage_events table on every
        // refresh — minutes of work once the table reaches 100k rows.
        let fetchCutoff = now.addingTimeInterval(-Double(recentDays + 1) * 24 * 3600)
        let entries = try fetchEntries(db: db, provider: provider, since: fetchCutoff)
        let blocks = identifyBlocks(entries: entries, now: now)

        let active = blocks.first { $0.isActive && !$0.isGap }
        let current = active ?? blocks.last { !$0.isGap }
        let rate = current.flatMap(burnRate(for:))
        let proj: Projection? = {
            guard let current, current.isActive, let rate else { return nil }
            return projection(for: current, burnRate: rate, now: now)
        }()

        let cutoff = now.addingTimeInterval(-Double(recentDays) * 24 * 3600)
        let recent = blocks
            .filter { !$0.isGap && ($0.startTime >= cutoff || $0.isActive) }
            .reversed()  // newest first

        return Snapshot(
            currentBlock: current,
            burnRate: rate,
            projection: proj,
            recentBlocks: Array(recent))
    }

    // MARK: - DB load

    private struct RawEntry {
        let timestamp: Date
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64
        let costUSD: Double
        let modelId: String
    }

    private static func fetchEntries(
        db: Database, provider: ProviderFilter, since: Date? = nil
    ) throws -> [RawEntry] {
        let providerWhere = provider.whereClause(table: "usage_events")
        let timeFilterSQL: String
        var arguments: StatementArguments = []
        if let since {
            // ISO-8601 string compares lexicographically the same way it sorts
            // chronologically, so `>=` works on the text column without needing
            // a numeric cast. Combine with whatever provider filter is in play.
            let sinceIso = ISO8601.fractional.string(from: since)
            timeFilterSQL = providerWhere.isEmpty
                ? "WHERE timestamp >= ?"
                : "\(providerWhere) AND timestamp >= ?"
            arguments = [sinceIso]
        } else {
            timeFilterSQL = providerWhere
        }

        let rows = try Row.fetchAll(db, sql: """
            SELECT timestamp, model_id,
                   input_tokens, output_tokens,
                   cached_input_tokens, cache_creation_tokens,
                   value_usd
            FROM usage_events
            \(timeFilterSQL)
            ORDER BY timestamp ASC, id ASC
            """, arguments: arguments)

        let sqlite = Self.sqliteFormatter

        return rows.compactMap { row -> RawEntry? in
            let ts: String = row["timestamp"] ?? ""
            let date = ISO8601.fractional.date(from: ts)
                ?? ISO8601.plain.date(from: ts)
                ?? sqlite.date(from: ts)
            guard let date else { return nil }
            return RawEntry(
                timestamp: date,
                inputTokens: row["input_tokens"] ?? 0,
                outputTokens: row["output_tokens"] ?? 0,
                cacheCreationTokens: row["cache_creation_tokens"] ?? 0,
                cacheReadTokens: row["cached_input_tokens"] ?? 0,
                costUSD: row["value_usd"] ?? 0,
                modelId: row["model_id"] ?? "unknown")
        }
    }

    // MARK: - Algorithm (mirrors ccusage `_session-blocks.ts`)

    /// Floor a date to the start of its UTC hour.
    static func floorToHour(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps) ?? date
    }

    private static func identifyBlocks(
        entries: [RawEntry], now: Date
    ) -> [Block] {
        guard !entries.isEmpty else { return [] }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

        var blocks: [Block] = []
        var blockStart: Date? = nil
        var bucket: [RawEntry] = []

        for entry in sorted {
            guard let start = blockStart else {
                blockStart = floorToHour(entry.timestamp)
                bucket = [entry]
                continue
            }
            let lastEntry = bucket.last!
            let sinceStart = entry.timestamp.timeIntervalSince(start)
            let sinceLast  = entry.timestamp.timeIntervalSince(lastEntry.timestamp)

            if sinceStart > sessionDuration || sinceLast > sessionDuration {
                blocks.append(makeBlock(start: start, entries: bucket, now: now))
                if sinceLast > sessionDuration,
                   let gap = makeGap(lastActivity: lastEntry.timestamp,
                                     nextActivity: entry.timestamp) {
                    blocks.append(gap)
                }
                blockStart = floorToHour(entry.timestamp)
                bucket = [entry]
            } else {
                bucket.append(entry)
            }
        }
        if let start = blockStart, !bucket.isEmpty {
            blocks.append(makeBlock(start: start, entries: bucket, now: now))
        }
        return blocks
    }

    private static func makeBlock(
        start: Date, entries: [RawEntry], now: Date
    ) -> Block {
        let end = start.addingTimeInterval(sessionDuration)
        let firstAt = entries.first?.timestamp
        let lastAt  = entries.last?.timestamp
        // Active = recent activity AND we're still inside the 5h window.
        let isActive: Bool = {
            guard let lastAt else { return false }
            return now.timeIntervalSince(lastAt) < sessionDuration && now < end
        }()

        var counts = TokenCounts()
        var cost = 0.0
        var seen = Set<String>()
        var models: [String] = []
        for e in entries {
            counts.input         += e.inputTokens
            counts.output        += e.outputTokens
            counts.cacheCreation += e.cacheCreationTokens
            counts.cacheRead     += e.cacheReadTokens
            cost += e.costUSD
            if seen.insert(e.modelId).inserted { models.append(e.modelId) }
        }

        return Block(
            id: ISO8601.fractional.string(from: start),
            startTime: start,
            endTime: end,
            firstEntryAt: firstAt,
            lastEntryAt: lastAt,
            isActive: isActive,
            isGap: false,
            entryCount: entries.count,
            tokenCounts: counts,
            costUSD: cost,
            models: models)
    }

    private static func makeGap(lastActivity: Date, nextActivity: Date) -> Block? {
        let gap = nextActivity.timeIntervalSince(lastActivity)
        guard gap > sessionDuration else { return nil }
        let gapStart = lastActivity.addingTimeInterval(sessionDuration)
        let iso = ISO8601.fractional.string(from: gapStart)
        return Block(
            id: "gap-\(iso)",
            startTime: gapStart,
            endTime: nextActivity,
            firstEntryAt: nil,
            lastEntryAt: nil,
            isActive: false,
            isGap: true,
            entryCount: 0,
            tokenCounts: TokenCounts(),
            costUSD: 0,
            models: [])
    }

    static func burnRate(for block: Block) -> BurnRate? {
        guard !block.isGap, block.entryCount > 0,
              let first = block.firstEntryAt, let last = block.lastEntryAt
        else { return nil }
        let durationMinutes = last.timeIntervalSince(first) / 60
        guard durationMinutes > 0 else { return nil }
        let total = Double(block.tokenCounts.total)
        let nonCache = Double(block.tokenCounts.nonCache)
        return BurnRate(
            tokensPerMinute: total / durationMinutes,
            nonCacheTokensPerMinute: nonCache / durationMinutes,
            costPerHour: (block.costUSD / durationMinutes) * 60)
    }

    static func projection(
        for block: Block, burnRate: BurnRate, now: Date = Date()
    ) -> Projection? {
        guard block.isActive, !block.isGap else { return nil }
        let remainingSeconds = max(0, block.endTime.timeIntervalSince(now))
        let remainingMinutes = remainingSeconds / 60
        let projectedTokens = Int64(
            (Double(block.tokenCounts.total) + burnRate.tokensPerMinute * remainingMinutes)
                .rounded())
        let projectedCost = block.costUSD + (burnRate.costPerHour / 60) * remainingMinutes
        return Projection(
            totalTokens: projectedTokens,
            totalCost: projectedCost,
            remainingMinutes: Int(remainingMinutes.rounded()))
    }

    /// Cached SQLite-text fallback formatter; constant locale/timezone so the
    /// shared instance is safe across calls.
    private static let sqliteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
