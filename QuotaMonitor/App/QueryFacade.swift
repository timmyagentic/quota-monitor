import Foundation

// Pure pass-throughs to Aggregator. Lives here so the AppEnvironment file
// stays focused on shared mutable state + lifecycle, not query plumbing.

extension AppEnvironment {

    // MARK: - Sessions queries (used by Sessions tab)

    func fetchSessionsList(
        sort: SessionSort,
        search: String
    ) async throws -> [SessionRow] {
        let filter = providerFilter
        let op = DeveloperLog.startOperation(
            "query.sessions.list",
            category: "query",
            trigger: "ui",
            fields: [
                "sort": .string(String(describing: sort)),
                "search_length": .int(search.count),
                "filter": .string(filter.rawValue)
            ])
        do {
            let (db, _) = try ensureServices()
            let rows = try await db.pool.read { conn in
                try Aggregator.fetchSessions(
                    db: conn, sort: sort, search: search, provider: filter)
            }
            DeveloperLog.finishOperation(op, fields: [
                "rows": .int(rows.count),
                "filter": .string(filter.rawValue)
            ])
            return rows
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: ["filter": .string(filter.rawValue)])
            throw error
        }
    }

    func fetchSessionDetail(sessionId: String) async throws -> SessionDetail? {
        let op = DeveloperLog.startOperation(
            "query.session.detail",
            category: "query",
            trigger: "ui",
            fields: ["session_id": .string(sessionId)])
        do {
            let (db, _) = try ensureServices()
            let detail = try await db.pool.read { conn in
                try Aggregator.fetchSessionDetail(db: conn, sessionId: sessionId)
            }
            DeveloperLog.finishOperation(op, fields: [
                "session_id": .string(sessionId),
                "found": .bool(detail != nil)
            ])
            return detail
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: ["session_id": .string(sessionId)])
            throw error
        }
    }

    // MARK: - History queries (used by History tab)

    func fetchHistoryPage(
        before cursor: Date? = nil,
        pageSize: Int = 7,
        now: Date = Date(),
        calendar: Calendar,
        trigger: HistoryPageLoadTrigger
    ) async throws -> HistoryPage {
        let filter = providerFilter
        let op = DeveloperLog.startOperation(
            "query.days.page",
            category: "query",
            trigger: trigger.rawValue,
            fields: [
                "page_size": .int(pageSize),
                "filter": .string(filter.rawValue),
                "cursor": .string(cursor.map {
                    ISO8601.fractional.string(from: $0)
                } ?? "")
            ])
        do {
            let (db, _) = try ensureServices()
            // Keep query.days.page as end-to-end data-ready latency. The
            // database child metric captures the reader boundary separately,
            // before SwiftUI/MainActor scheduling can delay publication.
            DeveloperLog.eventRecord(
                "query.days.page.database.start",
                category: "query",
                operation: op,
                fields: ["filter": .string(filter.rawValue)])
            let databaseStartedAt = ContinuousClock.now
            let measured: (
                page: HistoryPage,
                databaseFinishedAt: ContinuousClock.Instant
            )
            do {
                measured = try await db.pool.read { conn in
                    let page = try Aggregator.fetchHistoryPage(
                        db: conn,
                        before: cursor,
                        pageSize: pageSize,
                        provider: filter,
                        now: now,
                        calendar: calendar)
                    return (
                        page: page,
                        databaseFinishedAt: ContinuousClock.now)
                }
            } catch {
                DeveloperLog.eventRecord(
                    "query.days.page.database.fail",
                    level: .error,
                    category: "query",
                    operation: op,
                    result: "failure",
                    message: String(describing: error),
                    fields: [
                        "filter": .string(filter.rawValue),
                        "error_type": .string(String(describing: type(of: error))),
                        "error_message": .string(error.localizedDescription)
                    ])
                throw error
            }
            let page = measured.page
            let upper = calendar.date(
                byAdding: .day, value: pageSize, to: page.nextCursor)!
            let resultFields: [String: DeveloperLogValue] = [
                "rows": .int(page.days.count),
                "has_more": .bool(page.hasMore),
                "lower_bound": .string(
                    ISO8601.fractional.string(from: page.nextCursor)),
                "upper_bound": .string(ISO8601.fractional.string(from: upper)),
                "filter": .string(filter.rawValue)
            ]
            DeveloperLog.eventRecord(
                "query.days.page.database.finish",
                category: "query",
                operation: op,
                durationMilliseconds: historyDurationMilliseconds(
                    databaseStartedAt.duration(to: measured.databaseFinishedAt)),
                result: "success",
                fields: resultFields)
            DeveloperLog.finishOperation(op, fields: resultFields)
            return page
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: ["filter": .string(filter.rawValue)])
            throw error
        }
    }

    func fetchDayDetail(
        day: String,
        calendar: Calendar
    ) async throws -> DayDetail? {
        let filter = providerFilter
        let op = DeveloperLog.startOperation(
            "query.day.detail",
            category: "query",
            trigger: "ui",
            fields: [
                "day": .string(day),
                "filter": .string(filter.rawValue)
            ])
        do {
            let (db, _) = try ensureServices()
            let detail = try await db.pool.read { conn in
                try Aggregator.fetchDayDetail(
                    db: conn,
                    day: day,
                    provider: filter,
                    calendar: calendar)
            }
            DeveloperLog.finishOperation(op, fields: [
                "day": .string(day),
                "found": .bool(detail != nil),
                "filter": .string(filter.rawValue)
            ])
            return detail
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: [
                "day": .string(day),
                "filter": .string(filter.rawValue)
            ])
            throw error
        }
    }

    func fetchSessionEventsOnDay(
        sessionId: String,
        day: String,
        calendar: Calendar
    ) async throws -> [SessionDetail.Event] {
        let op = DeveloperLog.startOperation(
            "query.session_events_on_day",
            category: "query",
            trigger: "ui",
            fields: [
                "session_id": .string(sessionId),
                "day": .string(day)
            ])
        do {
            let (db, _) = try ensureServices()
            let rows = try await db.pool.read { conn in
                try Aggregator.fetchEventsForSessionOnDay(
                    db: conn,
                    sessionId: sessionId,
                    day: day,
                    calendar: calendar)
            }
            DeveloperLog.finishOperation(op, fields: [
                "rows": .int(rows.count),
                "session_id": .string(sessionId),
                "day": .string(day)
            ])
            return rows
        } catch {
            DeveloperLog.failOperation(op, error: error, fields: [
                "session_id": .string(sessionId),
                "day": .string(day)
            ])
            throw error
        }
    }
}

private func historyDurationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return max(0, Int(
        components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000))
}
