import Foundation

// MARK: - account/usage/read

/// Wire payload returned by Codex app-server's `account/usage/read` method.
///
/// The summary fields are nullable upstream. Keep that distinction all the
/// way to the UI instead of turning "not reported" into a misleading zero.
struct CodexAccountUsagePayload: Decodable, Sendable, Equatable {
    let summary: CodexAccountUsageSummary
    let dailyUsageBuckets: [CodexAccountUsageDailyBucket]?
}

struct CodexAccountUsageSummary: Decodable, Sendable, Equatable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct CodexAccountUsageDailyBucket: Decodable, Sendable, Equatable {
    let startDate: String
    let tokens: Int64

    /// Parses the protocol's strict Gregorian `yyyy-MM-dd` day key while
    /// preserving the supplied calendar's time zone. Comparing the
    /// round-tripped components prevents Calendar's lenient normalization
    /// from accepting values such as 2026-02-30.
    func date(in calendar: Calendar) -> Date? {
        let bytes = Array(startDate.utf8)
        guard bytes.count == 10,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (0x30...0x39).contains(byte)
              }),
              let year = Int(startDate.prefix(4)),
              let month = Int(startDate.dropFirst(5).prefix(2)),
              let day = Int(startDate.suffix(2))
        else { return nil }

        var gregorianCalendar = Calendar(identifier: .gregorian)
        gregorianCalendar.locale = Locale(identifier: "en_US_POSIX")
        gregorianCalendar.timeZone = calendar.timeZone
        let components = DateComponents(
            calendar: gregorianCalendar,
            timeZone: gregorianCalendar.timeZone,
            year: year,
            month: month,
            day: day)
        guard let parsed = gregorianCalendar.date(from: components) else { return nil }
        let roundTrip = gregorianCalendar.dateComponents(
            [.year, .month, .day],
            from: parsed)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day
        else { return nil }
        return gregorianCalendar.startOfDay(for: parsed)
    }
}

/// Availability-aware daily series returned by the account usage endpoint.
///
/// A missing upstream field means the service did not report daily usage. It
/// must remain distinct from an explicitly reported (possibly empty) bucket
/// list, which is safe to normalize into zero-valued days.
enum CodexAccountUsageDailySeries: Sendable, Equatable {
    case unavailable
    case available([DailyPoint])

    var points: [DailyPoint]? {
        switch self {
        case .unavailable:
            nil
        case .available(let points):
            points
        }
    }
}

/// UI-ready account profile data. Daily buckets are normalized to a fixed,
/// zero-filled trailing window so the existing Activity heatmap can consume
/// them without knowing about the app-server wire format.
struct CodexAccountUsageSnapshot: Sendable, Equatable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSeconds: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let dailySeries: CodexAccountUsageDailySeries
    let latestBucketDate: Date?
    let capturedAt: Date

    /// Compatibility view for existing heatmap consumers. New callers that
    /// need to distinguish unavailable data from a reported empty series
    /// should switch on `dailySeries` instead.
    var daily: [DailyPoint] {
        dailySeries.points ?? []
    }

    init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?,
        daily: [DailyPoint],
        latestBucketDate: Date?,
        capturedAt: Date
    ) {
        self.init(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            longestRunningTurnSeconds: longestRunningTurnSeconds,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            dailySeries: .available(daily),
            latestBucketDate: latestBucketDate,
            capturedAt: capturedAt)
    }

    init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?,
        dailySeries: CodexAccountUsageDailySeries,
        latestBucketDate: Date?,
        capturedAt: Date
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.dailySeries = dailySeries
        self.latestBucketDate = latestBucketDate
        self.capturedAt = capturedAt
    }

    init(
        payload: CodexAccountUsagePayload,
        trailingDays: Int = 365,
        capturedAt: Date = Date(),
        calendar: Calendar = .current
    ) {
        var gregorianCalendar = Calendar(identifier: .gregorian)
        gregorianCalendar.locale = Locale(identifier: "en_US_POSIX")
        gregorianCalendar.timeZone = calendar.timeZone
        let today = gregorianCalendar.startOfDay(for: capturedAt)
        var tokensByDay: [Date: Int64] = [:]

        for bucket in payload.dailyUsageBuckets ?? [] {
            guard bucket.tokens >= 0,
                  let day = bucket.date(in: gregorianCalendar),
                  day <= today
            else { continue }

            let existing = tokensByDay[day, default: 0]
            let (sum, overflow) = existing.addingReportingOverflow(bucket.tokens)
            tokensByDay[day] = overflow ? Int64.max : sum
        }

        let latestBucketDate = tokensByDay.keys.max()
        let dailySeries: CodexAccountUsageDailySeries
        if payload.dailyUsageBuckets == nil {
            dailySeries = .unavailable
        } else {
            // Account usage buckets often trail the wall clock by one day.
            // End the chart on the newest server-reported day so an
            // unreported today is not presented as a real zero-usage day.
            let seriesEnd = latestBucketDate ?? capturedAt
            dailySeries = .available(Aggregator.dailySeries(
                dayTokens: tokensByDay,
                dayValue: [:],
                days: trailingDays,
                now: seriesEnd,
                calendar: gregorianCalendar))
        }

        self.init(
            lifetimeTokens: Self.nonnegative(payload.summary.lifetimeTokens),
            peakDailyTokens: Self.nonnegative(payload.summary.peakDailyTokens),
            longestRunningTurnSeconds: Self.nonnegative(
                payload.summary.longestRunningTurnSec),
            currentStreakDays: Self.nonnegative(payload.summary.currentStreakDays),
            longestStreakDays: Self.nonnegative(payload.summary.longestStreakDays),
            dailySeries: dailySeries,
            latestBucketDate: latestBucketDate,
            capturedAt: capturedAt)
    }

    private static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

protocol CodexAccountUsageFetching: Sendable {
    func fetchAccountUsage() async throws -> CodexAccountUsageSnapshot
}

extension AppServerClient: CodexAccountUsageFetching {
    /// Fetches the wire payload without logging or embedding the raw response
    /// body in errors. In particular, RPC messages can contain a backend body,
    /// so only the stable error code is retained here.
    func readAccountUsage() async throws -> CodexAccountUsagePayload {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            throw ClientError.disabledInLocalQA
        }

        let response = try await call(
            method: "account/usage/read",
            params: EmptyParams())
        return try Self.decodeAccountUsageResponse(response)
    }

    func fetchAccountUsage() async throws -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(payload: try await readAccountUsage())
    }

    static func decodeAccountUsageResponse(
        _ response: JSONRPCResponse
    ) throws -> CodexAccountUsagePayload {
        if let result = response.result {
            do {
                return try result.decode(as: CodexAccountUsagePayload.self)
            } catch {
                throw ClientError.decodingFailed("account usage payload")
            }
        }

        if let error = response.error {
            let sanitized = JSONRPCError(
                code: error.code,
                message: "account usage request failed",
                data: nil)
            throw ClientError.rpcError(sanitized)
        }
        throw ClientError.malformedResponse(
            "account usage response is missing result and error")
    }
}
