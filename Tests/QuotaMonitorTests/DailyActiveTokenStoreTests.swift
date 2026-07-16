import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Daily active token store")
struct DailyActiveTokenStoreTests {
    @Test("Suppression writes the UTC day first and clears token and success")
    func suppressionClearsRecordsAndPersistsDay() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16, hour: 23, minute: 59)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let record = try #require(await store.record(for: date))
        await store.markSucceeded(
            day: record.day,
            token: record.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: date)

        await store.suppressUntilNextUTCDay(from: date)

        #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            == "2026-07-16")
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
    }

    @Test("Same-day re-enable stays suppressed and next UTC day resumes")
    func sameDayReenableWaitsUntilNextUTCDay() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let beforeMidnight = try utcDate(
            year: 2026, month: 7, day: 16, hour: 23, minute: 59)
        let afterMidnight = try utcDate(
            year: 2026, month: 7, day: 17, hour: 0, minute: 0)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)

        await store.suppressUntilNextUTCDay(from: beforeMidnight)

        #expect(await store.record(for: beforeMidnight) == nil)
        #expect(source.callCount == 0)
        #expect(await store.record(for: afterMidnight)?.day == "2026-07-17")
        #expect(source.callCount == 1)
        #expect(defaults.object(forKey: DailyActiveTokenStore.suppressedDayStorageKey) == nil)
    }

    @Test("Invalid, wrong-type, future, and rolled-back markers fail closed")
    func malformedAndFutureSuppressionFailsClosed() async throws {
        let markers: [Any] = [
            "not-a-day",
            Data("2026-07-16".utf8),
            "2026-07-18",
        ]

        for (index, marker) in markers.enumerated() {
            let (defaults, suiteName) = makeDefaults(named: "\(#function).\(index)")
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let date = try utcDate(year: 2026, month: 7, day: 16)
            defaults.set(marker, forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            defaults.set(Data("residual".utf8), forKey: DailyActiveTokenStore.tokenStorageKey)
            defaults.set(Data("residual".utf8), forKey: DailyActiveTokenStore.successStorageKey)
            let source = RandomSourceProbe(values: [Array(0 ... 15)])
            let store = makeStore(defaults: defaults, source: source)

            #expect(await store.record(for: date) == nil)
            #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
                == (marker as? String == "2026-07-18" ? "2026-07-18" : "2026-07-16"))
            #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
            #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
            #expect(source.callCount == 0)
        }
    }

    @Test("A fresh actor restores suppression and late success cannot revive it")
    func suppressionSurvivesRelaunchAndBlocksLateSuccess() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let first = makeStore(defaults: defaults, source: source)
        let stale = try #require(await first.record(for: date))
        await first.suppressUntilNextUTCDay(from: date)

        let restoredSource = RandomSourceProbe(values: [Array(16 ... 31)])
        let restored = makeStore(defaults: defaults, source: restoredSource)
        await restored.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: date)

        #expect(await restored.record(for: date) == nil)
        #expect(await restored.hasSucceeded(
            day: stale.day,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: date) == false)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(restoredSource.callCount == 0)
    }

    @Test("Late yesterday success uses today's corrupt-marker suppression boundary")
    func lateYesterdaySuccessUsesOperationDayForSuppression() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let yesterday = try utcDate(year: 2026, month: 7, day: 16, hour: 23, minute: 59)
        let today = try utcDate(year: 2026, month: 7, day: 17)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let stale = try #require(await store.record(for: yesterday))
        defaults.set("corrupt", forKey: DailyActiveTokenStore.suppressedDayStorageKey)

        await store.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: today)

        #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            == "2026-07-17")
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(await store.record(for: today) == nil)
        #expect(source.callCount == 1)
    }

    @Test("Late yesterday success lookup uses today's wrong-type suppression boundary")
    func lateYesterdayLookupUsesOperationDayForSuppression() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let yesterday = try utcDate(year: 2026, month: 7, day: 16, hour: 23, minute: 59)
        let today = try utcDate(year: 2026, month: 7, day: 17)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let stale = try #require(await store.record(for: yesterday))
        await store.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: yesterday)
        defaults.set(Data("2026-07-16".utf8),
                     forKey: DailyActiveTokenStore.suppressedDayStorageKey)

        #expect(await store.hasSucceeded(
            day: stale.day,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: today) == false)
        #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            == "2026-07-17")
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(await store.record(for: today) == nil)
        #expect(source.callCount == 1)
    }

    @Test("A marker-first crash leaves residual live records unusable")
    func markerFirstCrashFailsClosedOnFreshActor() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let originalSource = RandomSourceProbe(values: [Array(0 ... 15)])
        let originalStore = makeStore(defaults: defaults, source: originalSource)
        let record = try #require(await originalStore.record(for: date))
        await originalStore.markSucceeded(
            day: record.day,
            token: record.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: date)
        // Simulate a process exit immediately after the marker-first write and
        // before suppressUntilNextUTCDay can remove either live record.
        defaults.set("2026-07-16", forKey: DailyActiveTokenStore.suppressedDayStorageKey)

        let restoredSource = RandomSourceProbe(values: [Array(16 ... 31)])
        let restored = makeStore(defaults: defaults, source: restoredSource)

        #expect(await restored.record(for: date) == nil)
        #expect(await restored.hasSucceeded(
            day: record.day,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: date) == false)
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(restoredSource.callCount == 0)
    }

    @Test("An expired marker clears crash residuals before next-day token generation")
    func expiredMarkerClearsResidualsBeforeResuming() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let yesterday = try utcDate(year: 2026, month: 7, day: 16)
        let today = try utcDate(year: 2026, month: 7, day: 17)
        let source = RandomSourceProbe(values: [
            Array(0 ... 15),
            Array(16 ... 31),
        ])
        let first = makeStore(defaults: defaults, source: source)
        let stale = try #require(await first.record(for: yesterday))
        await first.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: yesterday)
        defaults.set("2026-07-16", forKey: DailyActiveTokenStore.suppressedDayStorageKey)

        let restored = makeStore(defaults: defaults, source: source)
        let current = try #require(await restored.record(for: today))

        #expect(current.day == "2026-07-17")
        #expect(current.token == "EBESExQVFhcYGRobHB0eHw")
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.suppressedDayStorageKey) == nil)
        #expect(source.callCount == 2)
    }

    @Test("A future marker continues suppressing through forward and rolled-back clocks")
    func futureMarkerSurvivesClockMovement() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("2026-07-18", forKey: DailyActiveTokenStore.suppressedDayStorageKey)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)

        #expect(await store.record(for: try utcDate(
            year: 2026, month: 7, day: 17)) == nil)
        #expect(await store.record(for: try utcDate(
            year: 2026, month: 7, day: 15)) == nil)
        #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            == "2026-07-18")
        #expect(source.callCount == 0)
    }

    @Test("Suppression implementation persists its marker before clearing live records")
    func suppressionWriteOrderIsPinned() throws {
        let source = try Self.source(named:
            "QuotaMonitor/Core/Telemetry/DailyActiveTokenStore.swift")
        let method = try #require(source.range(
            of: "func suppressUntilNextUTCDay"))
        let body = source[method.lowerBound...]
        let markerWrite = try #require(body.range(
            of: "defaults.value.set(day, forKey: Self.suppressedDayStorageKey)"))
        let liveClear = try #require(body.range(of: "clearLiveRecords()"))

        #expect(markerWrite.lowerBound < liveClear.lowerBound)
    }

    @Test("Clear removes suppression as well as token and success")
    func clearRemovesEveryTelemetryRecord() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        await store.suppressUntilNextUTCDay(from: date)

        await store.clear()

        #expect(defaults.object(forKey: DailyActiveTokenStore.suppressedDayStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(await store.record(for: date) != nil)
    }
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
            token: first.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: beforeMidnight)
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
            channel: "direct",
            operationDate: atMidnight))
        #expect(await store.hasSucceeded(
            day: second.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: atMidnight) == false)

        await store.markSucceeded(
            day: second.day,
            token: second.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: atMidnight)
        #expect(await store.hasSucceeded(
            day: first.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: atMidnight) == false)
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
            token: original.token,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable",
            operationDate: date)

        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable",
            operationDate: date))
        #expect(await store.hasSucceeded(
            day: "2026-07-17",
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "direct|stable",
            operationDate: date) == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|41",
            brand: "Quota|Monitor",
            channel: "direct|stable",
            operationDate: date) == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2",
            brand: "40|Quota|Monitor",
            channel: "direct|stable",
            operationDate: date) == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "CodexMonitor",
            channel: "direct|stable",
            operationDate: date) == false)
        #expect(await store.hasSucceeded(
            day: original.day,
            version: "0.2|40",
            brand: "Quota|Monitor",
            channel: "app-store",
            operationDate: date) == false)
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
                channel: "direct",
                operationDate: date) == false)
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
            token: original.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date)

        let restoredSource = RandomSourceProbe(values: [])
        let restoredStore = makeStore(defaults: defaults, source: restoredSource)

        #expect(await restoredStore.record(for: date) == original)
        #expect(restoredSource.callCount == 0)
        #expect(await restoredStore.hasSucceeded(
            day: original.day,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date))
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
            token: original.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date)

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
            channel: "direct",
            operationDate: date) == false)
    }

    @Test("Clearing before a stale success write cannot resurrect success")
    func clearBeforeStaleMarkLeavesStoreEmpty() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let stale = try #require(await store.record(for: date))

        await store.clear()
        await store.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date)

        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
    }

    @Test("Clearing after a success write leaves both records empty")
    func markBeforeClearLeavesStoreEmpty() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let source = RandomSourceProbe(values: [Array(0 ... 15)])
        let store = makeStore(defaults: defaults, source: source)
        let record = try #require(await store.record(for: date))
        await store.markSucceeded(
            day: record.day,
            token: record.token,
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date)

        await store.clear()

        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
    }

    @Test("A stale token cannot overwrite success for a replacement token")
    func staleMarkCannotOverwriteReplacementSuccess() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = try utcDate(year: 2026, month: 7, day: 16)
        let source = RandomSourceProbe(values: [
            Array(0 ... 15),
            Array(16 ... 31),
        ])
        let store = makeStore(defaults: defaults, source: source)
        let stale = try #require(await store.record(for: date))
        await store.clear()
        let replacement = try #require(await store.record(for: date))
        await store.markSucceeded(
            day: replacement.day,
            token: replacement.token,
            version: "0.2.41",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date)

        await store.markSucceeded(
            day: stale.day,
            token: stale.token,
            version: "0.2.40",
            brand: "CodexMonitor",
            channel: "app-store",
            operationDate: date)

        let tokenData = try #require(
            defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) as? Data)
        #expect(try JSONDecoder().decode(DailyActiveTokenRecord.self, from: tokenData)
            == replacement)
        #expect(await store.hasSucceeded(
            day: replacement.day,
            version: "0.2.41",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: date))
        #expect(await store.hasSucceeded(
            day: stale.day,
            version: "0.2.40",
            brand: "CodexMonitor",
            channel: "app-store",
            operationDate: date) == false)
    }

    @Test("An invalid persisted token blocks success and self-heals")
    func invalidTokenBlocksSuccessWrite() async throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalid = DailyActiveTokenRecord(
            day: "2026-07-16",
            token: "not-a-canonical-token")
        defaults.set(
            try JSONEncoder().encode(invalid),
            forKey: DailyActiveTokenStore.tokenStorageKey)
        let source = RandomSourceProbe(values: [])
        let store = makeStore(defaults: defaults, source: source)

        await store.markSucceeded(
            day: "2026-07-16",
            token: "AAECAwQFBgcICQoLDA0ODw",
            version: "0.2.40",
            brand: "QuotaMonitor",
            channel: "direct",
            operationDate: try utcDate(year: 2026, month: 7, day: 16))

        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.object(forKey: DailyActiveTokenStore.successStorageKey) == nil)
        #expect(source.callCount == 0)
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

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
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
