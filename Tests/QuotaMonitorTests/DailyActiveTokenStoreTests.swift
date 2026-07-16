import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Daily active token store")
struct DailyActiveTokenStoreTests {
    @Test("Concurrent same-day requests share one canonical token and one random draw")
    func concurrentSameDayRequestsShareOneToken() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let now = try utcDate(year: 2026, month: 7, day: 16, hour: 12)

        let records = await withTaskGroup(
            of: DailyActiveTokenRecord?.self,
            returning: [DailyActiveTokenRecord?].self
        ) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    await store.record(for: now)
                }
            }

            var records: [DailyActiveTokenRecord?] = []
            for await record in group {
                records.append(record)
            }
            return records
        }

        let expected = DailyActiveTokenRecord(
            day: "2026-07-16",
            token: "AAECAwQFBgcICQoLDA0ODw")
        #expect(records.count == 64)
        #expect(records.allSatisfy { $0 == expected })
        #expect(expected.token.count == 22)
        #expect(expected.token.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        })
        #expect(source.callCount == 1)

        let storedData = try #require(
            defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) as? Data)
        #expect(try JSONDecoder().decode(DailyActiveTokenRecord.self, from: storedData) == expected)
    }

    @Test("UTC midnight rotates the token while retaining only exact prior success")
    func utcMidnightRotatesToken() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = RandomSourceProbe(values: [
            Array(0 ... 15),
            Array(16 ... 31),
        ])
        let store = makeStore(defaults: defaults, source: source)
        let beforeMidnight = try utcDate(
            year: 2026, month: 7, day: 16, hour: 23, minute: 59)
        let atMidnight = try utcDate(year: 2026, month: 7, day: 17)

        let first = try #require(await store.record(for: beforeMidnight))
        await store.markSucceeded(
            day: first.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct")
        let second = try #require(await store.record(for: atMidnight))

        #expect(first.day == "2026-07-16")
        #expect(first.token == "AAECAwQFBgcICQoLDA0ODw")
        #expect(second.day == "2026-07-17")
        #expect(second.token == "EBESExQVFhcYGRobHB0eHw")
        #expect(second.token != first.token)
        #expect(source.callCount == 2)
        #expect(await store.hasSucceeded(
            day: first.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct"))
        #expect(await store.hasSucceeded(
            day: second.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct") == false)

        await store.markSucceeded(
            day: second.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct")
        #expect(await store.hasSucceeded(
            day: first.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct") == false)
    }

    @Test("Random-source failure returns nil without persistence")
    func randomFailureDoesNotPersist() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = RandomSourceProbe(values: [nil])
        let store = makeStore(defaults: defaults, source: source)

        let record = await store.record(
            for: try utcDate(year: 2026, month: 7, day: 16))

        #expect(record == nil)
        #expect(source.callCount == 1)
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
    }

    @Test("A random source must return exactly sixteen bytes")
    func wrongRandomByteCountDoesNotPersist() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = RandomSourceProbe(values: [[0, 1, 2]])
        let store = makeStore(defaults: defaults, source: source)

        let record = await store.record(
            for: try utcDate(year: 2026, month: 7, day: 16))

        #expect(record == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
    }

    @Test("Corrupt Data and wrong defaults types self-heal")
    func corruptAndWrongTypeStateSelfHeals() async throws {
        let badValues: [Any] = [
            Data("not-json".utf8),
            "not-data",
        ]

        for (index, badValue) in badValues.enumerated() {
            let (defaults, suiteName) = makeDefaults(named: "\(#function).\(index)")
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(badValue, forKey: DailyActiveTokenStore.tokenStorageKey)
            let source = RandomSourceProbe(values: [Array(0 ... 15)])
            let store = makeStore(defaults: defaults, source: source)

            let repaired = try #require(await store.record(
                for: try utcDate(year: 2026, month: 7, day: 16)))

            #expect(repaired == DailyActiveTokenRecord(
                day: "2026-07-16",
                token: "AAECAwQFBgcICQoLDA0ODw"))
            #expect(source.callCount == 1)
        }
    }

    @Test("Invalid persisted days and tokens self-heal")
    func invalidRecordFieldsSelfHeal() async throws {
        let invalidRecords = [
            DailyActiveTokenRecord(
                day: "2026-02-30",
                token: "AAECAwQFBgcICQoLDA0ODw"),
            DailyActiveTokenRecord(
                day: "2026-07-16",
                token: "not-a-canonical-token"),
        ]

        for (index, invalidRecord) in invalidRecords.enumerated() {
            let (defaults, suiteName) = makeDefaults(named: "\(#function).\(index)")
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(
                try JSONEncoder().encode(invalidRecord),
                forKey: DailyActiveTokenStore.tokenStorageKey)
            let source = RandomSourceProbe(values: [Array(16 ... 31)])
            let store = makeStore(defaults: defaults, source: source)

            let repaired = try #require(await store.record(
                for: try utcDate(year: 2026, month: 7, day: 16)))

            #expect(repaired == DailyActiveTokenRecord(
                day: "2026-07-16",
                token: "EBESExQVFhcYGRobHB0eHw"))
            #expect(source.callCount == 1)
        }
    }

    @Test("Success requires exact day, version, brand, and channel without delimiter collisions")
    func successFingerprintUsesAllFourDimensions() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let original = try #require(await store.record(for: date))

        await store.markSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable")

        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable"))
        #expect(await store.hasSucceeded(
            day: "2026-07-17",
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable") == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2",
            brand: "40|Quota|Monitor",
            channel: "direct|stable") == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "CodexMonitor",
            channel: "direct|stable") == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "app-store") == false)
        #expect(await store.record(for: date) == original)
        #expect(source.callCount == 1)
    }

    @Test("Corrupt Data and wrong success types fail closed and self-heal")
    func corruptAndWrongTypeSuccessStateSelfHeals() async throws {
        let badValues: [Any] = [
            Data("not-json".utf8),
            "not-data",
        ]

        for (index, badValue) in badValues.enumerated() {
            let (defaults, suiteName) = makeDefaults(named: "\(#function).\(index)")
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let source = RandomSourceProbe(values: [Array(0 ... 15)])
            let store = makeStore(defaults: defaults, source: source)
            let date = try utcDate(year: 2026, month: 7, day: 16)
            let original = try #require(await store.record(for: date))
            defaults.set(badValue, forKey: DailyActiveTokenStore.successStorageKey)

            #expect(await store.hasSucceeded(
                day: original.day,
                version: "0.2.40",
                brand: "QuotaMonitor",
                channel: "direct") == false)
            #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
            #expect(await store.record(for: date) == original)
            #expect(source.callCount == 1)
        }
    }

    @Test("A fresh actor restores the token and success record")
    func freshActorRestoresPersistedState() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let firstSource = RandomSourceProbe(values: [Array(0 ... 15)])
        let firstStore = makeStore(defaults: defaults, source: firstSource)
        let original = try #require(await firstStore.record(for: date))
        await firstStore.markSucceeded(
            day: original.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct")

        let restoredSource = RandomSourceProbe(values: [])
        let restoredStore = makeStore(defaults: defaults, source: restoredSource)

        #expect(await restoredStore.record(for: date) == original)
        #expect(restoredSource.callCount == 0)
        #expect(await restoredStore.hasSucceeded(
            day: original.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct"))
    }

    @Test("Clear removes both records and the next request starts fresh")
    func clearRemovesTokenAndSuccess() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let firstSource = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: firstSource)
        let original = try #require(await store.record(for: date))
        await store.markSucceeded(
            day: original.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct")

        await store.clear()

        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        let nextSource = RandomSourceProbe(values: [Array(16 ... 31)])
        let freshStore = makeStore(defaults: defaults, source: nextSource)
        let replacement = try #require(await freshStore.record(for: date))
        #expect(replacement.token == "EBESExQVFhcYGRobHB0eHw")
        #expect(replacement != original)
        #expect(await freshStore.hasSucceeded(
            day: original.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct") == false)
    }

    private func makeStore(
        defaults: UserDefaults,
        source: RandomSourceProbe
    ) -> DailyActiveTokenStore {
        DailyActiveTokenStore(
            defaults: DailyActiveUserDefaults(defaults),
            calendar: Self.utcCalendar,
            randomBytes: { source.next() })
    }

    private func makeDefaults(named testName: String) -> (UserDefaults, String) {
        let suiteName = "DailyActiveTokenStoreTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) throws -> Date {
        try #require(Self.utcCalendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute)))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private final class RandomSourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]?]
    private var calls = 0

    init(values: [[UInt8]?]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func next() -> [UInt8]? {
        lock.withLock {
            calls += 1
            guard values.isEmpty == false else { return nil }
            return values.removeFirst()
        }
    }
}
