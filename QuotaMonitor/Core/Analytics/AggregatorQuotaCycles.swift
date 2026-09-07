import Foundation
import GRDB

struct QuotaCycleUsage: Equatable, Sendable, Identifiable {
    struct Point: Equatable, Sendable, Identifiable {
        let date: Date
        let tokens: Int64
        let valueUSD: Double
        var id: Date { date }
    }

    let cycle: QuotaCycle
    let through: Date
    let tokens: Int64
    let valueUSD: Double
    let cacheUsage: CacheUsageSummary
    let eventCount: Int
    let points: [Point]
    var id: String { cycle.id }
}

extension Aggregator {
    static func quotaCycleUsage(
        db: Database, cycles: [QuotaCycle], now: Date = Date()
    ) throws -> [QuotaCycleUsage] {
        try cycles.filter { $0.isCurrent(at: now) }.map { cycle in
            guard let start = cycle.start, start <= now else {
                return QuotaCycleUsage(cycle: cycle, through: now, tokens: 0, valueUSD: 0,
                                       cacheUsage: .zero, eventCount: 0, points: [])
            }
            // Offsets and SQLite separators do not sort like fractional UTC.
            // Keep the indexed query bounded, then compare parsed instants.
            let lowerBound = String(ISO8601.fractional.string(
                from: start.addingTimeInterval(-86_400)).prefix(10))
            let upperBound = String(ISO8601.fractional.string(
                from: now.addingTimeInterval(2 * 86_400)).prefix(10))
            let rows = try Row.fetchAll(db, sql: """
                SELECT timestamp, MAX(total_tokens, 0) AS tokens,
                       MAX(value_usd, 0) AS value,
                       \(cacheReadTokensExpression(table: "usage_events")) AS cache_read,
                       \(cacheEligibleInputExpression(table: "usage_events")) AS cache_input
                FROM usage_events WHERE provider = ? AND timestamp >= ? AND timestamp < ?
                ORDER BY timestamp, id
                """, arguments: [cycle.observation.provider, lowerBound, upperBound])
            let step: TimeInterval = cycle.observation.bucket == "primary" ? 300 : 3600
            var buckets: [Int: (tokens: Int64, value: Double)] = [:]
            var tokens: Int64 = 0
            var value = 0.0
            var read: Int64 = 0
            var input: Int64 = 0
            var eventCount = 0
            for row in rows {
                guard let date = parseTimestamp(row["timestamp"] as String),
                      date >= start, date < now else { continue }
                eventCount += 1
                let count: Int64 = row["tokens"]
                let cost: Double = row["value"]
                let bucket = Int(date.timeIntervalSince(start) / step)
                buckets[bucket, default: (0, 0)].tokens += count
                buckets[bucket, default: (0, 0)].value += cost
                tokens += count
                value += cost
                read += row["cache_read"] as Int64
                input += row["cache_input"] as Int64
            }
            var runningTokens: Int64 = 0
            var runningValue = 0.0
            var points = [QuotaCycleUsage.Point(date: start, tokens: 0, valueUSD: 0)]
            for bucket in buckets.keys.sorted() {
                runningTokens += buckets[bucket]!.tokens
                runningValue += buckets[bucket]!.value
                points.append(.init(date: min(now, start.addingTimeInterval(Double(bucket + 1) * step)),
                                    tokens: runningTokens, valueUSD: runningValue))
            }
            if points.last?.date != now {
                points.append(.init(date: now, tokens: tokens, valueUSD: value))
            }
            return QuotaCycleUsage(cycle: cycle, through: now, tokens: tokens, valueUSD: value,
                                   cacheUsage: .init(readTokens: read, eligibleInputTokens: input),
                                   eventCount: eventCount, points: points)
        }
    }
}
