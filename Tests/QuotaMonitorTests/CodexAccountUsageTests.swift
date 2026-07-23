import Darwin
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex account usage")
struct CodexAccountUsageTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "synthetic_account_usage",
            withExtension: "json",
            subdirectory: "Fixtures/AccountUsage")
        else {
            Issue.record("missing synthetic account usage fixture")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(Self.utcCalendar.date(from: DateComponents(
            year: year, month: month, day: day)))
    }

    @Test("account/usage/read payload decodes nullable summary and daily buckets")
    func payloadDecodes() throws {
        let payload = try JSONDecoder().decode(
            CodexAccountUsagePayload.self,
            from: loadFixture())

        #expect(payload.summary.lifetimeTokens == 9_876_543_210)
        #expect(payload.summary.peakDailyTokens == 456_789_012)
        #expect(payload.summary.longestRunningTurnSec == 9_876)
        #expect(payload.summary.currentStreakDays == 17)
        #expect(payload.summary.longestStreakDays == 42)
        #expect(payload.dailyUsageBuckets?.count == 5)

        let nullSummary = try JSONDecoder().decode(
            CodexAccountUsagePayload.self,
            from: Data("""
                {
                  "summary": {
                    "lifetimeTokens": null,
                    "peakDailyTokens": null,
                    "longestRunningTurnSec": null,
                    "currentStreakDays": null,
                    "longestStreakDays": null
                  },
                  "dailyUsageBuckets": null
                }
                """.utf8))
        #expect(nullSummary.summary.lifetimeTokens == nil)
        #expect(nullSummary.dailyUsageBuckets == nil)
    }

    @Test("day keys are strict calendar dates")
    func dayKeysAreStrict() throws {
        let calendar = Self.utcCalendar
        let expected = try date(2026, 7, 24)
        #expect(CodexAccountUsageDailyBucket(
            startDate: "2026-07-24", tokens: 1).date(in: calendar)
            == expected)
        #expect(CodexAccountUsageDailyBucket(
            startDate: "2026-02-30", tokens: 1).date(in: calendar) == nil)
        #expect(CodexAccountUsageDailyBucket(
            startDate: "2026-7-24", tokens: 1).date(in: calendar) == nil)
        #expect(CodexAccountUsageDailyBucket(
            startDate: "2026/07/24", tokens: 1).date(in: calendar) == nil)
    }

    @Test("day keys stay Gregorian while preserving the caller time zone")
    func dayKeysUseGregorianCalendarAndCallerTimeZone() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var callerCalendar = Calendar(identifier: .buddhist)
        callerCalendar.timeZone = timeZone
        var expectedCalendar = Calendar(identifier: .gregorian)
        expectedCalendar.timeZone = timeZone
        let expected = try #require(expectedCalendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24)))

        let parsed = CodexAccountUsageDailyBucket(
            startDate: "2026-07-24",
            tokens: 1).date(in: callerCalendar)

        #expect(parsed == expected)
        #expect(Self.utcCalendar.dateComponents(
            [.year, .month, .day, .hour],
            from: try #require(parsed)) == DateComponents(
                year: 2026,
                month: 7,
                day: 23,
                hour: 16))
    }

    @Test("null daily buckets stay unavailable instead of becoming zero days")
    func nullDailyBucketsStayUnavailable() throws {
        let payload = CodexAccountUsagePayload(
            summary: CodexAccountUsageSummary(
                lifetimeTokens: 123,
                peakDailyTokens: nil,
                longestRunningTurnSec: nil,
                currentStreakDays: nil,
                longestStreakDays: nil),
            dailyUsageBuckets: nil)
        let snapshot = CodexAccountUsageSnapshot(
            payload: payload,
            trailingDays: 365,
            capturedAt: try date(2026, 7, 24),
            calendar: Self.utcCalendar)

        #expect(snapshot.dailySeries == .unavailable)
        #expect(snapshot.dailySeries.points == nil)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.latestBucketDate == nil)
    }

    @Test("an explicit empty bucket list remains an available zero-filled series")
    func emptyDailyBucketsRemainAvailable() throws {
        let payload = CodexAccountUsagePayload(
            summary: CodexAccountUsageSummary(
                lifetimeTokens: 0,
                peakDailyTokens: 0,
                longestRunningTurnSec: 0,
                currentStreakDays: 0,
                longestStreakDays: 0),
            dailyUsageBuckets: [])
        let snapshot = CodexAccountUsageSnapshot(
            payload: payload,
            trailingDays: 3,
            capturedAt: try date(2026, 7, 24),
            calendar: Self.utcCalendar)

        guard case .available(let points) = snapshot.dailySeries else {
            Issue.record("expected an available daily series")
            return
        }
        #expect(points.count == 3)
        #expect(points.allSatisfy { $0.tokens == 0 })
        #expect(snapshot.daily == points)
        #expect(snapshot.latestBucketDate == nil)
    }

    @Test("snapshot zero-fills exactly 365 trailing days and merges duplicate buckets")
    func snapshotNormalizesDailyBuckets() throws {
        let payload = try JSONDecoder().decode(
            CodexAccountUsagePayload.self,
            from: loadFixture())
        let capturedAt = try #require(Self.utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 24, hour: 18)))
        let snapshot = CodexAccountUsageSnapshot(
            payload: payload,
            capturedAt: capturedAt,
            calendar: Self.utcCalendar)
        let firstDay = try date(2025, 7, 25)
        let duplicateDay = try date(2026, 7, 22)
        let lastDay = try date(2026, 7, 24)

        #expect(snapshot.lifetimeTokens == 9_876_543_210)
        #expect(snapshot.daily.count == 365)
        #expect(snapshot.daily.first?.date == firstDay)
        #expect(snapshot.daily.first?.tokens == 100)
        #expect(snapshot.daily.last?.date == lastDay)
        #expect(snapshot.daily.last?.tokens == 500)
        #expect(snapshot.daily.first(where: {
            $0.date == duplicateDay
        })?.tokens == 700)
        #expect(snapshot.latestBucketDate == lastDay)
        #expect(snapshot.daily.allSatisfy { $0.valueUSD == 0 })
    }

    @Test("snapshot ends at the latest server bucket and ignores invalid values")
    func snapshotRejectsInvalidValues() throws {
        let summary = CodexAccountUsageSummary(
            lifetimeTokens: nil,
            peakDailyTokens: -1,
            longestRunningTurnSec: nil,
            currentStreakDays: -2,
            longestStreakDays: 9)
        let payload = CodexAccountUsagePayload(
            summary: summary,
            dailyUsageBuckets: [
                .init(startDate: "not-a-day", tokens: 10),
                .init(startDate: "2026-07-25", tokens: 20),
                .init(startDate: "2026-07-24", tokens: -30),
                .init(startDate: "2026-07-23", tokens: 40),
            ])
        let snapshot = CodexAccountUsageSnapshot(
            payload: payload,
            trailingDays: 3,
            capturedAt: try date(2026, 7, 24),
            calendar: Self.utcCalendar)
        let latestDay = try date(2026, 7, 23)
        let firstDay = try date(2026, 7, 21)

        #expect(snapshot.lifetimeTokens == nil)
        #expect(snapshot.peakDailyTokens == nil)
        #expect(snapshot.currentStreakDays == nil)
        #expect(snapshot.longestStreakDays == 9)
        #expect(snapshot.daily.map(\.tokens) == [0, 0, 40])
        #expect(snapshot.daily.first?.date == firstDay)
        #expect(snapshot.daily.last?.date == latestDay)
        #expect(snapshot.latestBucketDate == latestDay)
    }

    @Test("AppServerClient sends account/usage/read and decodes its result")
    func clientReadsAccountUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-account-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let requestURL = root.appendingPathComponent("request.json")
        let serverURL = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r initialize_request
        printf '%s\n' '{"jsonrpc":"2.0","id":"init","result":{}}'
        IFS= read -r usage_request
        printf '%s' "$usage_request" > '\(requestURL.path)'
        call_id=$(printf '%s' "$usage_request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"summary":{"lifetimeTokens":1234,"peakDailyTokens":456,"longestRunningTurnSec":78,"currentStreakDays":9,"longestStreakDays":10},"dailyUsageBuckets":[{"startDate":"2026-07-24","tokens":11}]}}\n' "$call_id"
        """
        try Data(script.utf8).write(to: serverURL)
        #expect(chmod(serverURL.path, 0o700) == 0)

        let client = AppServerClient(binaryPath: serverURL.path, timeout: .seconds(3))
        let payload = try await client.readAccountUsage()

        #expect(payload.summary.lifetimeTokens == 1_234)
        #expect(payload.dailyUsageBuckets?.first?.tokens == 11)
        let requestData = try Data(contentsOf: requestURL)
        let request = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(request["method"] as? String == "account/usage/read")
    }

    @Test("RPC failures retain only the status code, not the raw backend body")
    func rpcErrorsAreSanitized() throws {
        let response = JSONRPCResponse(
            id: "call-test",
            result: nil,
            error: JSONRPCError(
                code: -32001,
                message: "request failed body={\"secret\":\"do-not-log\"}",
                data: nil))

        do {
            _ = try AppServerClient.decodeAccountUsageResponse(response)
            Issue.record("expected RPC failure")
        } catch let error as AppServerClient.ClientError {
            guard case .rpcError(let rpcError) = error else {
                Issue.record("unexpected client error: \(error)")
                return
            }
            #expect(rpcError.code == -32001)
            #expect(rpcError.message == "account usage request failed")
            #expect(!error.description.contains("secret"))
            #expect(!error.description.contains("body="))
        }
    }
}
