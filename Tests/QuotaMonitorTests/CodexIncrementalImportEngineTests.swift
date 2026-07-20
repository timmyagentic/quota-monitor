import Darwin
import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Codex incremental import engine")
struct CodexIncrementalImportEngineTests {
    private let sessionId = "11111111-2222-4333-8444-555555555555"

    @Test("scanner and parser persist the same integer file mtime")
    func scannerAndParserMtimeMatch() throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let seconds = 1_700_049_380
        let nanoseconds = 733_999_931
        var times = [
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
        ]
        let result = harness.rollout.path.withCString { path in
            Darwin.utimensat(AT_FDCWD, path, &times, 0)
        }
        #expect(result == 0)

        let scanned = try #require(
            SessionScanner.scan(codexHome: harness.codexHome).first)
        let reader = try RolloutRecordReader(fileURL: harness.rollout)
        defer { try? reader.close() }
        let expected = Int64(seconds) * 1_000 + Int64(nanoseconds) / 1_000_000
        #expect(scanned.fileMtimeMs == expected)
        #expect(reader.snapshot.mtimeMs == expected)
        #expect(scanned.sourceIdentity == reader.snapshot.sourceIdentity)
    }

    @Test("post-parse verification rejects same-inode content replacement")
    func postParseVerificationChecksFingerprints() throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let file = try #require(
            SessionScanner.scan(codexHome: harness.codexHome).first)
        let output = try RolloutParser.parseIncrementally(
            fileURL: file.url,
            fallbackSessionId: sessionId)

        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("[".utf8))
        try handle.close()

        let seconds = Int(output.snapshot.mtimeMs / 1_000)
        let nanoseconds = Int(output.snapshot.mtimeMs % 1_000) * 1_000_000
            + 999_999
        var times = [
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
        ]
        let result = file.path.withCString { path in
            Darwin.utimensat(AT_FDCWD, path, &times, 0)
        }
        #expect(result == 0)
        let current = try RolloutRecordReader(fileURL: file.url)
        #expect(current.snapshot.sourceIdentity == output.snapshot.sourceIdentity)
        #expect(current.snapshot.size == output.snapshot.size)
        #expect(current.snapshot.mtimeMs == output.snapshot.mtimeMs)
        try current.close()

        #expect(throws: (any Error).self) {
            try ImportEngine.verifyCurrentSource(file: file, output: output)
        }
    }

    @Test("different filename UUIDs with one session_meta id import once")
    func changedFileUsesActualSessionMetaId() async throws {
        let actualSessionId = "99999999-8888-4777-8666-555555555555"
        let misleadingSessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let lines = [
            metaLine(
                timestamp: "2026-07-19T00:00:00.000Z",
                sessionId: actualSessionId),
            contextLine(timestamp: "2026-07-19T00:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T00:00:02.000Z",
                total: usage(input: 40, cached: 5, output: 5, reasoning: 1),
                last: usage(input: 40, cached: 5, output: 5, reasoning: 1)),
        ]
        let harness = try makeHarness(lines: lines)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let archivedDirectory = harness.codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archivedDirectory,
            withIntermediateDirectories: true)
        let alias = archivedDirectory.appendingPathComponent(
            "rollout-2026-07-19T00-00-01-\(misleadingSessionId).jsonl")
        try rolloutData(lines).write(to: alias)

        let report = try await harness.engine.performScan()
        #expect(report.scannedFiles == 2)
        #expect(report.importedSessions == 1)
        #expect(report.importedEvents == 1)
        #expect(report.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).isEmpty)
        #expect(try await usageRows(
            sessionId: actualSessionId,
            in: harness.database).map(\.totalTokens) == [45])
        #expect(try await importState(
            at: harness.rollout.path,
            in: harness.database).sessionId == actualSessionId)
        #expect(try await optionalImportState(
            at: alias.path,
            in: harness.database) == nil)
    }

    @Test("one filename UUID with two real session_meta ids stays two sessions")
    func sameFilenameHintDoesNotMergeDifferentSessionMetaIds() async throws {
        let secondSessionId = "99999999-8888-4777-8666-555555555555"
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let archivedDirectory = harness.codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archivedDirectory,
            withIntermediateDirectories: true)
        let secondFile = archivedDirectory.appendingPathComponent(
            harness.rollout.lastPathComponent)
        try rolloutData([
            metaLine(
                timestamp: "2026-07-19T01:00:00.000Z",
                sessionId: secondSessionId),
            contextLine(timestamp: "2026-07-19T01:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T01:00:02.000Z",
                total: usage(input: 40, cached: 5, output: 5, reasoning: 1),
                last: usage(input: 40, cached: 5, output: 5, reasoning: 1)),
        ]).write(to: secondFile)

        let report = try await harness.engine.performScan()
        #expect(report.scannedFiles == 2)
        #expect(report.importedSessions == 2)
        #expect(report.importedEvents == 2)
        #expect(report.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [110])
        #expect(try await usageRows(
            sessionId: secondSessionId,
            in: harness.database).map(\.totalTokens) == [45])
    }

    @Test("append imports only the tail, preserves row IDs, and prices new events")
    func appendPreservesRowsAndPricesTail() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let firstReport = try await harness.engine.performScan()
        #expect(firstReport.changedFiles == 1)
        #expect(firstReport.incrementalFiles == 0)
        #expect(firstReport.importedEvents == 1)
        #expect(firstReport.errors.isEmpty)

        let before = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(before.count == 1)
        #expect(before[0].valueUsd > 0)
        #expect(beforeState.byteOffset > 0)
        #expect(beforeState.parserCheckpoint != nil)

        let tail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(tail.utf8), to: harness.rollout)

        let secondReport = try await harness.engine.performScan()
        #expect(secondReport.changedFiles == 1)
        #expect(secondReport.incrementalFiles == 1)
        #expect(secondReport.importedEvents == 1)
        #expect(secondReport.sourceBytesRead == Int64(tail.utf8.count))
        #expect(secondReport.errors.isEmpty)

        let after = try await usageRows(in: harness.database)
        let afterState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(after.count == 2)
        #expect(after[0] == before[0], "incremental import must not rewrite old rows")
        #expect(after.map(\.totalTokens) == [110, 68])
        #expect(afterState.byteOffset == beforeState.byteOffset + Int64(tail.utf8.count))
        #expect(afterState.parserCheckpoint != beforeState.parserCheckpoint)

        // gpt-5.4 standard pricing: uncached input $2.50/M,
        // cached input $0.25/M, and output $15/M.
        #expect(abs(after[0].valueUsd - 0.000355) < 1e-15)
        #expect(abs(after[1].valueUsd - 0.00025875) < 1e-15)
    }

    @Test("partial JSON can be truncated and retried without advancing the cursor")
    func partialJSONIsRewrittenExactlyOnce() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeRows = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)

        let completeLine = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2))
        let splitIndex = completeLine.utf8.count / 2
        let bytes = Data(completeLine.utf8)
        let firstHalf = bytes.prefix(splitIndex)
        try append(Data(firstHalf), to: harness.rollout)

        let partialReport = try await harness.engine.performScan()
        #expect(partialReport.changedFiles == 1)
        #expect(partialReport.incrementalFiles == 1)
        #expect(partialReport.importedEvents == 0)
        #expect(partialReport.errors.isEmpty)

        let partialRows = try await usageRows(in: harness.database)
        let partialState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(partialRows == beforeRows)
        #expect(partialState.byteOffset == beforeState.byteOffset)
        #expect(partialState.parserCheckpoint == beforeState.parserCheckpoint)
        #expect(partialState.fileSize > beforeState.fileSize)

        let writer = try FileHandle(forWritingTo: harness.rollout)
        try writer.truncate(atOffset: UInt64(partialState.byteOffset))
        try writer.close()
        try append(bytes + Data("\n".utf8), to: harness.rollout)
        let completedReport = try await harness.engine.performScan()
        #expect(completedReport.changedFiles == 1)
        #expect(completedReport.incrementalFiles == 1)
        #expect(completedReport.importedEvents == 1)
        #expect(completedReport.sourceBytesRead == Int64(completeLine.utf8.count + 1))
        #expect(completedReport.errors.isEmpty)

        let completedRows = try await usageRows(in: harness.database)
        let completedState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(completedRows.count == 2)
        #expect(completedRows[0] == beforeRows[0])
        #expect(completedRows.map(\.totalTokens) == [110, 68])
        #expect(completedState.byteOffset == completedState.fileSize)

        let noOpReport = try await harness.engine.performScan()
        #expect(noOpReport.changedFiles == 0)
        #expect(try await usageRows(in: harness.database) == completedRows)
    }

    @Test("in-place truncation waits while atomic replacement rebuilds")
    func truncationWaitsAndReplacementRebuilds() async throws {
        let initialLines = prefixLines() + [
            tokenLine(
                timestamp: "2026-07-19T00:00:04.000Z",
                total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
                last: usage(input: 60, cached: 5, output: 8, reasoning: 2)),
        ]
        let harness = try makeHarness(lines: initialLines)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [110, 68])

        let truncatedLines = [
            metaLine(timestamp: "2026-07-19T01:00:00.000Z"),
            contextLine(timestamp: "2026-07-19T01:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T01:00:02.000Z",
                total: usage(input: 40, cached: 5, output: 5, reasoning: 1),
                last: usage(input: 40, cached: 5, output: 5, reasoning: 1)),
        ]
        let truncatedData = rolloutData(truncatedLines)
        try overwriteInPlace(truncatedData, at: harness.rollout)

        let truncatedReport = try await harness.engine.performScan()
        #expect(truncatedReport.changedFiles == 1)
        #expect(truncatedReport.incrementalFiles == 0)
        #expect(truncatedReport.importedEvents == 0)
        #expect(truncatedReport.sourceBytesRead == 0)
        #expect(truncatedReport.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [110, 68])

        let oldIdentity = try sourceIdentity(of: harness.rollout)
        let replacementLines = [
            metaLine(timestamp: "2026-07-19T02:00:00.000Z"),
            contextLine(timestamp: "2026-07-19T02:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T02:00:02.000Z",
                total: usage(input: 60, cached: 10, output: 10, reasoning: 2),
                last: usage(input: 60, cached: 10, output: 10, reasoning: 2)),
            tokenLine(
                timestamp: "2026-07-19T02:00:03.000Z",
                total: usage(input: 85, cached: 12, output: 15, reasoning: 3),
                last: usage(input: 25, cached: 2, output: 5, reasoning: 1)),
        ]
        let replacementData = rolloutData(replacementLines)
        let stagedReplacement = harness.rollout
            .deletingLastPathComponent()
            .appendingPathComponent("replacement.jsonl")
        try replacementData.write(to: stagedReplacement)
        let replacementIdentity = try sourceIdentity(of: stagedReplacement)
        #expect(replacementIdentity != oldIdentity)
        try FileManager.default.removeItem(at: harness.rollout)
        try FileManager.default.moveItem(at: stagedReplacement, to: harness.rollout)

        let replacementReport = try await harness.engine.performScan()
        #expect(replacementReport.changedFiles == 1)
        #expect(replacementReport.incrementalFiles == 0)
        #expect(replacementReport.importedEvents == 2)
        #expect(replacementReport.sourceBytesRead == Int64(replacementData.count))
        #expect(replacementReport.errors.isEmpty)
        #expect(try sourceIdentity(of: harness.rollout) == replacementIdentity)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [70, 30])
    }

    @Test("an existing archived canonical outranks an unrelated active copy")
    func archivedCanonicalRemainsAuthoritativeWhilePresent() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let archivedDirectory = harness.codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archivedDirectory,
            withIntermediateDirectories: true)
        let archivedRollout = archivedDirectory
            .appendingPathComponent(harness.rollout.lastPathComponent)
        try FileManager.default.moveItem(at: harness.rollout, to: archivedRollout)
        let relocation = try await harness.engine.performScan()
        #expect(relocation.incrementalFiles == 1)
        let archivedFile = try #require(
            SessionScanner.scan(codexHome: harness.codexHome).first)
        let beforeRows = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: archivedFile.path,
            in: harness.database)

        let replacementPrefix = rolloutData([
            metaLine(timestamp: "2026-07-19T03:00:00.000Z"),
            contextLine(timestamp: "2026-07-19T03:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T03:00:02.000Z",
                total: usage(input: 60, cached: 10, output: 10, reasoning: 2),
                last: usage(input: 60, cached: 10, output: 10, reasoning: 2)),
        ])
        let finalLine = tokenLine(
            timestamp: "2026-07-19T03:00:03.000Z",
            total: usage(input: 85, cached: 12, output: 15, reasoning: 3),
            last: usage(input: 25, cached: 2, output: 5, reasoning: 1))
        let finalLineData = Data(finalLine.utf8)
        let splitIndex = finalLineData.count / 2
        var partialReplacement = replacementPrefix
        partialReplacement.append(finalLineData.prefix(splitIndex))

        try partialReplacement.write(to: harness.rollout)

        let partial = try await harness.engine.performScan()
        #expect(partial.scannedFiles == 2)
        #expect(partial.changedFiles == 0)
        #expect(partial.importedSessions == 0)
        #expect(partial.importedEvents == 0)
        #expect(partial.errors.isEmpty)
        #expect(try await usageRows(in: harness.database) == beforeRows)
        #expect(try await importState(
            at: archivedFile.path,
            in: harness.database) == beforeState)
        #expect(try await optionalImportState(
            at: harness.rollout.path,
            in: harness.database) == nil)

        var completion = Data(finalLineData.dropFirst(splitIndex))
        completion.append(Data("\n".utf8))
        try append(completion, to: harness.rollout)
        let stillCanonical = try await harness.engine.performScan()
        #expect(stillCanonical.changedFiles == 0)
        #expect(try await usageRows(in: harness.database) == beforeRows)

        // Only after the committed canonical disappears may the complete
        // active source become the replacement authority.
        try FileManager.default.removeItem(at: archivedFile.url)

        let completed = try await harness.engine.performScan()
        #expect(completed.changedFiles == 1)
        #expect(completed.importedSessions == 1)
        #expect(completed.importedEvents == 2)
        #expect(completed.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [70, 30])
        let completedState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(completedState.byteOffset == completedState.fileSize)
        #expect(try await optionalImportState(
            at: archivedFile.path,
            in: harness.database) == nil)
    }

    @Test("same-inode active to archived relocation resumes from the checkpoint")
    func relocationResumesCheckpoint() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeRows = try await usageRows(in: harness.database)
        let beforeIdentity = try sourceIdentity(of: harness.rollout)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(beforeState.sessionId == sessionId)
        #expect(harness.rollout.path.hasPrefix(
            harness.codexHome.standardizedFileURL.path + "/"))

        let archivedDirectory = harness.codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archivedDirectory,
            withIntermediateDirectories: true)
        let archivedRollout = archivedDirectory
            .appendingPathComponent(harness.rollout.lastPathComponent)
        try FileManager.default.moveItem(at: harness.rollout, to: archivedRollout)
        #expect(try sourceIdentity(of: archivedRollout) == beforeIdentity)
        let relocatedFile = try #require(
            SessionScanner.scan(codexHome: harness.codexHome).first)
        #expect(relocatedFile.sessionIdHint == sessionId)

        let tail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(tail.utf8), to: archivedRollout)

        let report = try await harness.engine.performScan()
        #expect(report.scannedFiles == 1)
        #expect(report.changedFiles == 1)
        #expect(report.incrementalFiles == 1)
        #expect(report.importedEvents == 1)
        #expect(report.sourceBytesRead == Int64(tail.utf8.count))
        #expect(report.errors.isEmpty)

        let afterRows = try await usageRows(in: harness.database)
        #expect(afterRows.count == 2)
        #expect(afterRows[0] == beforeRows[0])
        #expect(afterRows.map(\.totalTokens) == [110, 68])
        #expect(try await optionalImportState(
            at: harness.rollout.path,
            in: harness.database) == nil)
        let archivedState = try await importState(
            at: relocatedFile.path,
            in: harness.database)
        #expect(archivedState.sessionId == sessionId)

        let sourcePath = try await harness.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT source_path FROM sessions WHERE session_id = ?",
                arguments: [sessionId])
        }
        #expect(sourcePath == relocatedFile.path)
    }

    @Test("same-size same-mtime inode replacement still rebuilds")
    func identityOnlyReplacementRebuilds() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        let beforeIdentity = try sourceIdentity(of: harness.rollout)
        var oldStat = Darwin.stat()
        #expect(harness.rollout.path.withCString {
            Darwin.lstat($0, &oldStat)
        } == 0)

        let replacementLines = [
            metaLine(timestamp: "2026-07-19T00:00:00.000Z"),
            taskLine(timestamp: "2026-07-19T00:00:01.000Z"),
            contextLine(timestamp: "2026-07-19T00:00:02.000Z"),
            tokenLine(
                timestamp: "2026-07-19T00:00:03.000Z",
                total: usage(input: 200, cached: 30, output: 20, reasoning: 4),
                last: usage(input: 200, cached: 30, output: 20, reasoning: 4)),
        ]
        let replacementData = rolloutData(replacementLines)
        #expect(Int64(replacementData.count) == beforeState.fileSize)

        let staged = harness.rollout
            .deletingLastPathComponent()
            .appendingPathComponent("same-metadata-replacement.jsonl")
        try replacementData.write(to: staged)
        var times = [oldStat.st_atimespec, oldStat.st_mtimespec]
        #expect(staged.path.withCString {
            Darwin.utimensat(AT_FDCWD, $0, &times, 0)
        } == 0)
        let replacementIdentity = try sourceIdentity(of: staged)
        #expect(replacementIdentity != beforeIdentity)
        try FileManager.default.removeItem(at: harness.rollout)
        try FileManager.default.moveItem(at: staged, to: harness.rollout)

        let scanned = try #require(
            SessionScanner.scan(codexHome: harness.codexHome).first)
        #expect(scanned.fileSize == beforeState.fileSize)
        #expect(scanned.fileMtimeMs == beforeState.fileMtimeMs)
        #expect(scanned.sourceIdentity == replacementIdentity)

        let report = try await harness.engine.performScan()
        #expect(report.changedFiles == 1)
        #expect(report.incrementalFiles == 0)
        #expect(report.sourceBytesRead == beforeState.fileSize)
        #expect(report.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [220])
    }

    @Test("checkpoint cap transition rebuilds later without token or price drift")
    func oversizedCheckpointFallbackIsExact() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let initialParse = try RolloutParser.parseIncrementally(
            fileURL: harness.rollout)
        let initialCheckpoint = try #require(initialParse.checkpoint)
        let checkpointCap = try initialCheckpoint.encoded().count
        let engine = ImportEngine(
            database: harness.database,
            codexHome: harness.codexHome,
            maxCheckpointBytes: checkpointCap)

        let firstReport = try await engine.performScan()
        #expect(firstReport.errors.isEmpty)
        let firstRows = try await usageRows(in: harness.database)
        let firstState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(firstState.byteOffset == firstState.fileSize)
        #expect(firstState.parserCheckpoint != nil)

        let firstTail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(firstTail.utf8), to: harness.rollout)
        let grownCheckpoint = try #require(
            RolloutParser.parseIncrementally(fileURL: harness.rollout).checkpoint)
        #expect(try grownCheckpoint.encoded().count > checkpointCap)

        let secondReport = try await engine.performScan()
        #expect(secondReport.incrementalFiles == 1)
        #expect(secondReport.sourceBytesRead == Int64(firstTail.utf8.count))
        #expect(secondReport.errors.isEmpty)
        let secondRows = try await usageRows(in: harness.database)
        let secondState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(secondRows.count == 2)
        #expect(secondRows[0] == firstRows[0])
        #expect(secondRows.map(\.totalTokens) == [110, 68])
        #expect(secondState.byteOffset == 0)
        #expect(secondState.parserCheckpoint == nil)

        let secondTail = tokenLine(
            timestamp: "2026-07-19T00:00:05.000Z",
            total: usage(input: 190, cached: 30, output: 25, reasoning: 7),
            last: usage(input: 30, cached: 5, output: 7, reasoning: 2)) + "\n"
        try append(Data(secondTail.utf8), to: harness.rollout)
        let finalSize = (try FileManager.default.attributesOfItem(
            atPath: harness.rollout.path)[.size] as? NSNumber)?.int64Value ?? 0

        let thirdReport = try await engine.performScan()
        #expect(thirdReport.incrementalFiles == 0)
        #expect(thirdReport.sourceBytesRead == finalSize)
        #expect(thirdReport.errors.isEmpty)
        let thirdRows = try await usageRows(in: harness.database)
        let thirdState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(thirdRows.count == 3)
        #expect(thirdRows.map(\.inputTokens) == [100, 60, 30])
        #expect(thirdRows.map(\.cachedInputTokens) == [20, 5, 5])
        #expect(thirdRows.map(\.outputTokens) == [10, 8, 7])
        #expect(thirdRows.map(\.reasoningOutputTokens) == [3, 2, 2])
        #expect(thirdRows.map(\.totalTokens) == [110, 68, 37])
        #expect(Array(thirdRows.prefix(2)).map { $0.valueUsd.bitPattern }
            == secondRows.map { $0.valueUsd.bitPattern })
        #expect(thirdRows[2].valueUsd > 0)
        #expect(thirdState.byteOffset == 0)
        #expect(thirdState.parserCheckpoint == nil)
    }

    @Test("source session-id replacement preserves prior history")
    func sourceSessionReplacementPreservesHistory() async throws {
        let replacementSessionId = "99999999-8888-4777-8666-555555555555"
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let oldRows = try await usageRows(in: harness.database)
        try await harness.database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO rate_limit_samples
                    (source_kind, source_session_id, bucket, sample_timestamp,
                     plan_type, limit_name, window_start, resets_at,
                     used_percent, remaining_percent)
                VALUES ('jsonl', ?, 'primary', '2026-07-19T00:00:03.000Z',
                        'pro', 'codex', NULL, '2026-07-19T05:00:03.000Z',
                        25, 75)
                """, arguments: [sessionId])
        }
        let oldSampleID = try await harness.database.pool.read { db in
            let sampleID = try Int64.fetchOne(db, sql: """
                SELECT id FROM rate_limit_samples
                WHERE source_kind = 'jsonl' AND source_session_id = ?
                """, arguments: [sessionId])
            return try #require(sampleID)
        }

        let replacementData = rolloutData([
            metaLine(
                timestamp: "2026-07-19T01:00:00.000Z",
                sessionId: replacementSessionId),
            contextLine(timestamp: "2026-07-19T01:00:01.000Z"),
            tokenLine(
                timestamp: "2026-07-19T01:00:02.000Z",
                total: usage(input: 40, cached: 5, output: 5, reasoning: 1),
                last: usage(input: 40, cached: 5, output: 5, reasoning: 1)),
        ])
        let staged = harness.rollout
            .deletingLastPathComponent()
            .appendingPathComponent("different-session.jsonl")
        try replacementData.write(to: staged)
        try FileManager.default.removeItem(at: harness.rollout)
        try FileManager.default.moveItem(at: staged, to: harness.rollout)

        let report = try await harness.engine.performScan()
        #expect(report.changedFiles == 1)
        #expect(report.incrementalFiles == 0)
        #expect(report.errors.isEmpty)
        #expect(try await usageRows(in: harness.database) == oldRows)
        let replacementRows = try await usageRows(
            sessionId: replacementSessionId,
            in: harness.database)
        #expect(replacementRows.map(\.totalTokens) == [45])
        #expect(replacementRows[0].valueUsd > 0)

        let preservedSample = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rate_limit_samples
                WHERE id = ? AND source_session_id = ?
                """, arguments: [oldSampleID, sessionId])
        }
        #expect(preservedSample == 1)
        let sessionCount = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions WHERE session_id IN (?, ?)
                """, arguments: [sessionId, replacementSessionId])
        }
        #expect(sessionCount == 2)
        let state = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(state.sessionId == replacementSessionId)
    }

    @Test("checkpoint save failure rolls back rows, prices, session, and cursor")
    func checkpointFailureRollsBackTransaction() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeRows = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        let beforeImportedAt = try await sessionImportedAt(in: harness.database)

        let tail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(tail.utf8), to: harness.rollout)
        try await harness.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_checkpoint_update
                BEFORE UPDATE ON import_state
                BEGIN
                    SELECT RAISE(ABORT, 'forced checkpoint failure');
                END
                """)
        }

        let failedReport = try await harness.engine.performScan()
        #expect(failedReport.changedFiles == 1)
        #expect(failedReport.importedSessions == 0)
        #expect(failedReport.importedEvents == 0)
        #expect(failedReport.errors.count == 1)
        #expect(failedReport.errors[0].contains("forced checkpoint failure"))
        #expect(try await usageRows(in: harness.database) == beforeRows)
        #expect(try await importState(
            at: harness.rollout.path,
            in: harness.database) == beforeState)
        #expect(try await sessionImportedAt(in: harness.database) == beforeImportedAt)

        try await harness.database.pool.write { db in
            try db.execute(sql: "DROP TRIGGER reject_checkpoint_update")
        }
        let recoveredReport = try await harness.engine.performScan()
        #expect(recoveredReport.changedFiles == 1)
        #expect(recoveredReport.incrementalFiles == 1)
        #expect(recoveredReport.importedEvents == 1)
        #expect(recoveredReport.errors.isEmpty)

        let recoveredRows = try await usageRows(in: harness.database)
        let recoveredState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        #expect(recoveredRows.count == 2)
        #expect(recoveredRows[0] == beforeRows[0])
        #expect(recoveredRows[1].valueUsd > 0)
        #expect(recoveredState.byteOffset == recoveredState.fileSize)
        #expect(recoveredState.byteOffset > beforeState.byteOffset)
    }

    @Test("moving the entire Codex home preserves same-inode incremental state")
    func movedCodexHomeResumesCheckpoint() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeRows = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        let beforeIdentity = try sourceIdentity(of: harness.rollout)

        let movedCodexHome = harness.root.appendingPathComponent(
            "moved-codex-home",
            isDirectory: true)
        try FileManager.default.moveItem(
            at: harness.codexHome,
            to: movedCodexHome)
        let movedFile = try #require(
            SessionScanner.scan(codexHome: movedCodexHome).first)
        #expect(try sourceIdentity(of: movedFile.url) == beforeIdentity)

        let tail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(tail.utf8), to: movedFile.url)

        let report = try await ImportEngine(
            database: harness.database,
            codexHome: movedCodexHome
        ).performScan()
        #expect(report.scannedFiles == 1)
        #expect(report.changedFiles == 1)
        #expect(report.incrementalFiles == 1)
        #expect(report.importedEvents == 1)
        #expect(report.sourceBytesRead == Int64(tail.utf8.count))
        #expect(report.errors.isEmpty)

        let afterRows = try await usageRows(in: harness.database)
        #expect(afterRows.count == 2)
        #expect(afterRows[0] == beforeRows[0])
        #expect(afterRows.map(\.totalTokens) == [110, 68])
        #expect(try await optionalImportState(
            at: beforeState.sourcePath,
            in: harness.database) == nil)
        let movedState = try await importState(
            at: movedFile.path,
            in: harness.database)
        #expect(movedState.sessionId == sessionId)
        #expect(movedState.byteOffset == movedState.fileSize)
        #expect(movedState.byteOffset == beforeState.byteOffset + Int64(tail.utf8.count))
    }

    @Test("a fresh active source wins over a divergent archived duplicate")
    func activeSourceIsCanonicalForFreshDuplicates() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let archivedDirectory = harness.codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archivedDirectory,
            withIntermediateDirectories: true)
        let duplicate = archivedDirectory.appendingPathComponent(
            harness.rollout.lastPathComponent)
        var divergent = prefixLines()
        divergent[3] = tokenLine(
            timestamp: "2026-07-19T00:00:03.000Z",
            total: usage(input: 900, cached: 0, output: 90, reasoning: 0),
            last: usage(input: 900, cached: 0, output: 90, reasoning: 0))
        try rolloutData(divergent).write(to: duplicate)
        #expect(try sourceIdentity(of: duplicate)
            != sourceIdentity(of: harness.rollout))

        let report = try await harness.engine.performScan()
        #expect(report.scannedFiles == 2)
        #expect(report.changedFiles == 1)
        #expect(report.importedSessions == 1)
        #expect(report.importedEvents == 1)
        #expect(report.incrementalFiles == 0)
        #expect(report.errors.isEmpty)
        #expect(try await usageRows(in: harness.database).map(\.totalTokens) == [110])
        #expect(try await importState(
            at: harness.rollout.path,
            in: harness.database).sessionId == sessionId)
        #expect(try await optionalImportState(
            at: duplicate.path,
            in: harness.database) == nil)
    }

    @Test("stale duplicate import state consolidates while appending once")
    func staleDuplicateImportStateSelfHealsExactlyOnce() async throws {
        let harness = try makeHarness(lines: prefixLines())
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = try await harness.engine.performScan()
        let beforeRows = try await usageRows(in: harness.database)
        let beforeState = try await importState(
            at: harness.rollout.path,
            in: harness.database)
        let stalePath = harness.root.appendingPathComponent(
            "stale-rollout.jsonl").path
        let staleState = ImportStateRecord(
            sourcePath: stalePath,
            sessionId: beforeState.sessionId,
            fileSize: beforeState.fileSize,
            fileMtimeMs: beforeState.fileMtimeMs,
            lastImportedAt: beforeState.lastImportedAt,
            byteOffset: beforeState.byteOffset,
            parserCheckpoint: beforeState.parserCheckpoint,
            metadataProbeComplete: beforeState.metadataProbeComplete)
        try await harness.database.pool.write { db in
            try staleState.insert(db)
        }

        let tail = tokenLine(
            timestamp: "2026-07-19T00:00:04.000Z",
            total: usage(input: 160, cached: 25, output: 18, reasoning: 5),
            last: usage(input: 60, cached: 5, output: 8, reasoning: 2)) + "\n"
        try append(Data(tail.utf8), to: harness.rollout)

        let report = try await harness.engine.performScan()
        #expect(report.changedFiles == 1)
        #expect(report.incrementalFiles == 1)
        #expect(report.importedEvents == 1)
        #expect(report.errors.isEmpty)
        let rows = try await usageRows(in: harness.database)
        #expect(rows.count == 2)
        #expect(rows[0] == beforeRows[0])
        #expect(rows.map(\.totalTokens) == [110, 68])
        #expect(try await optionalImportState(
            at: stalePath,
            in: harness.database) == nil)
        #expect(try await importState(
            at: harness.rollout.path,
            in: harness.database).byteOffset > beforeState.byteOffset)
    }

    private struct Harness {
        let root: URL
        let codexHome: URL
        let rollout: URL
        let database: DatabaseManager
        let engine: ImportEngine
    }

    private struct UsageRow: Equatable {
        let id: Int64
        let timestamp: String
        let modelId: String
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64
        let totalTokens: Int64
        let valueUsd: Double
    }

    private struct UsageFixture {
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int

        var total: Int { input + output }
    }

    private func makeHarness(lines: [String]) throws -> Harness {
        let testScratchRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
            .appendingPathComponent(".build/test-scratch", isDirectory: true)
        let root = testScratchRoot
            .appendingPathComponent(
                "qm-codex-incremental-engine-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionDirectory = codexHome.appendingPathComponent(
            "sessions/2026/07/19",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true)
        let rollout = sessionDirectory.appendingPathComponent(
            "rollout-2026-07-19T00-00-00-\(sessionId).jsonl")
        try rolloutData(lines).write(to: rollout)
        // FileManager's temporary-directory URL may be expressed through the
        // /var -> /private/var alias. Use the scanner's URL so assertions key
        // import_state with the exact source path the importer persists.
        let discoveredRollout = try #require(
            SessionScanner.scan(codexHome: codexHome).first?.url)
        let database = try DatabaseManager(
            url: root.appendingPathComponent("quotamonitor.sqlite"))
        return Harness(
            root: root,
            codexHome: codexHome,
            rollout: discoveredRollout,
            database: database,
            engine: ImportEngine(database: database, codexHome: codexHome))
    }

    private func prefixLines() -> [String] {
        [
            metaLine(timestamp: "2026-07-19T00:00:00.000Z"),
            taskLine(timestamp: "2026-07-19T00:00:01.000Z"),
            contextLine(timestamp: "2026-07-19T00:00:02.000Z"),
            tokenLine(
                timestamp: "2026-07-19T00:00:03.000Z",
                total: usage(input: 100, cached: 20, output: 10, reasoning: 3),
                last: usage(input: 100, cached: 20, output: 10, reasoning: 3)),
        ]
    }

    private func metaLine(
        timestamp: String,
        sessionId explicitSessionId: String? = nil
    ) -> String {
        let resolvedSessionId = explicitSessionId ?? sessionId
        return #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(resolvedSessionId)","cwd":"/fixture/incremental-project"}}"#
    }

    private func taskLine(timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"fixture-turn"}}"#
    }

    private func contextLine(timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"fixture-turn","model":"gpt-5.4"}}"#
    }

    private func usage(
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int
    ) -> UsageFixture {
        UsageFixture(
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning)
    }

    private func tokenLine(
        timestamp: String,
        total: UsageFixture,
        last: UsageFixture
    ) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usageJSON(total)),"last_token_usage":\#(usageJSON(last))}}}"#
    }

    private func usageJSON(_ value: UsageFixture) -> String {
        #"{"input_tokens":\#(value.input),"cached_input_tokens":\#(value.cached),"output_tokens":\#(value.output),"reasoning_output_tokens":\#(value.reasoning),"total_tokens":\#(value.total)}"#
    }

    private func rolloutData(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func overwriteInPlace(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    private func sourceIdentity(of url: URL) throws -> RolloutSourceIdentity {
        let reader = try RolloutRecordReader(fileURL: url)
        defer { try? reader.close() }
        return reader.snapshot.sourceIdentity
    }

    private func usageRows(
        sessionId explicitSessionId: String? = nil,
        in database: DatabaseManager
    ) async throws -> [UsageRow] {
        let resolvedSessionId = explicitSessionId ?? sessionId
        return try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, timestamp, model_id,
                       input_tokens, cached_input_tokens, output_tokens,
                       reasoning_output_tokens, total_tokens, value_usd
                FROM usage_events
                WHERE session_id = ?
                ORDER BY timestamp, id
                """, arguments: [resolvedSessionId]).map { row in
                UsageRow(
                    id: row["id"],
                    timestamp: row["timestamp"],
                    modelId: row["model_id"],
                    inputTokens: row["input_tokens"],
                    cachedInputTokens: row["cached_input_tokens"],
                    outputTokens: row["output_tokens"],
                    reasoningOutputTokens: row["reasoning_output_tokens"],
                    totalTokens: row["total_tokens"],
                    valueUsd: row["value_usd"])
            }
        }
    }

    private func importState(
        at path: String,
        in database: DatabaseManager
    ) async throws -> ImportStateRecord {
        try #require(await optionalImportState(at: path, in: database))
    }

    private func optionalImportState(
        at path: String,
        in database: DatabaseManager
    ) async throws -> ImportStateRecord? {
        try await database.pool.read { db in
            try ImportStateRecord
                .filter(Column("source_path") == path)
                .fetchOne(db)
        }
    }

    private func sessionImportedAt(in database: DatabaseManager) async throws -> String {
        try await database.pool.read { db in
            let importedAt = try String.fetchOne(
                db,
                sql: "SELECT imported_at FROM sessions WHERE session_id = ?",
                arguments: [sessionId])
            return try #require(importedAt)
        }
    }
}
