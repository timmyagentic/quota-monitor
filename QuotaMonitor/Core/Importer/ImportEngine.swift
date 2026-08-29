import Foundation
import GRDB

// Orchestrates: scan → diff against import_state → parse changed files →
// upsert sessions / append usage_events / append rate_limit_samples.
//
// Idempotency: unchanged files are skipped. Root Codex rollouts with a complete
// reducer checkpoint resume from their last committed byte offset; every other
// shape takes the conservative full-rebuild path.

actor ImportEngine {
    private static let proactiveMetadataBackfillWindow: TimeInterval = 7 * 24 * 60 * 60

    private let database: DatabaseManager
    private let codexHome: URL?
    private let securityScopedAccess: any SecurityScopedResourceAccessing
    private let maxCheckpointBytes: Int
    private var warnedOversizedSources: Set<RolloutSourceIdentity> = []
    private var cachedCodexSessionMetadata: (
        fingerprint: CodexSessionMetadataSourceFingerprint,
        metadata: [String: CodexSessionMetadata]
    )?

    private struct ProbedSource {
        let file: SessionFile
        let sessionId: String
        let fragmentName: String
        let headerFingerprint: FragmentFingerprint?
        let directState: ImportStateRecord?
    }

    private struct FragmentFingerprint {
        let length: Int64
        let hash: Data
    }

    private struct SourceKey: Hashable {
        let sessionId: String
        let fragmentName: String
    }

    private struct ScanCandidate {
        let file: SessionFile
        let sessionId: String
        let expectedState: ImportStateRecord?
        let replacesExistingSource: Bool
    }

    private enum PersistMode: Equatable {
        case replace
        case append
    }

    private struct ParsedCandidate {
        let output: CodexRolloutParseOutput
        let mode: PersistMode
    }

    private enum ImportStateConflict: Error, LocalizedError, CustomStringConvertible {
        case stale
        case fileChangedDuringParse

        var errorDescription: String? {
            switch self {
            case .stale:
                return "Codex import state changed while the file was being parsed"
            case .fileChangedDuringParse:
                return "Codex rollout changed while it was being parsed"
            }
        }

        var description: String {
            errorDescription ?? "Codex import-state conflict"
        }
    }

    struct ScanReport: Sendable {
        let scannedFiles: Int
        let changedFiles: Int
        let importedSessions: Int
        let importedEvents: Int
        let importedRateLimitSamples: Int
        /// Existing Codex sessions whose title/project metadata changed even
        /// though their rollout file itself did not. These are part of the UI
        /// read model and therefore need the same post-scan refresh as a newly
        /// imported session.
        let updatedSessionMetadata: Int
        let incrementalFiles: Int
        let sourceBytesRead: Int64
        let errors: [String]
        /// True when an App Store security-scoped root resolved but its scope
        /// could not be opened (folder moved/revoked). Surfaced to the user via
        /// `lastError` so a silently-empty import prompts a re-select instead.
        let scopeUnavailable: Bool

        init(
            scannedFiles: Int,
            changedFiles: Int,
            importedSessions: Int,
            importedEvents: Int,
            importedRateLimitSamples: Int,
            updatedSessionMetadata: Int = 0,
            incrementalFiles: Int = 0,
            sourceBytesRead: Int64 = 0,
            errors: [String],
            scopeUnavailable: Bool = false
        ) {
            self.scannedFiles = scannedFiles
            self.changedFiles = changedFiles
            self.importedSessions = importedSessions
            self.importedEvents = importedEvents
            self.importedRateLimitSamples = importedRateLimitSamples
            self.updatedSessionMetadata = updatedSessionMetadata
            self.incrementalFiles = incrementalFiles
            self.sourceBytesRead = sourceBytesRead
            self.errors = errors
            self.scopeUnavailable = scopeUnavailable
        }

        /// Whether this scan changed data consumed by the menu-bar or
        /// Dashboard aggregators. File/checkpoint churn alone does not count.
        var didChangeReadModel: Bool {
            importedSessions > 0
                || importedEvents > 0
                || importedRateLimitSamples > 0
                || updatedSessionMetadata > 0
        }

        static let empty = ScanReport(
            scannedFiles: 0, changedFiles: 0,
            importedSessions: 0, importedEvents: 0,
            importedRateLimitSamples: 0, errors: [])
    }

    init(
        database: DatabaseManager,
        codexHome: URL? = SessionScanner.defaultCodexHome(),
        securityScopedAccess: any SecurityScopedResourceAccessing =
            FoundationSecurityScopedResourceAccessing(),
        maxCheckpointBytes: Int = 4 * 1024 * 1024
    ) {
        self.database = database
        self.codexHome = codexHome
        self.securityScopedAccess = securityScopedAccess
        self.maxCheckpointBytes = max(0, maxCheckpointBytes)
    }

    func performScan(progress: ScanProgressHandler? = nil) async throws -> ScanReport {
        guard let codexHome else {
            return .empty
        }

        let scopedAccess = securityScopedAccess.access(codexHome)
        defer { scopedAccess.stop() }

        // App Store: the bookmark resolved but its security scope wouldn't open
        // (folder moved/revoked/TCC reset). Enumerating would silently find
        // nothing; instead report it so the user is told to re-select the folder.
        if DistributionChannel.current == .appStore, !scopedAccess.didStart {
            return ScanReport(
                scannedFiles: 0, changedFiles: 0,
                importedSessions: 0, importedEvents: 0,
                importedRateLimitSamples: 0,
                errors: ["codex history folder scope unavailable: \(codexHome.path)"],
                scopeUnavailable: true)
        }

        let discoveredFiles = SessionScanner.scan(codexHome: codexHome)
        let priorState: [String: ImportStateRecord] = try await database.pool.read { db in
            let rows = try ImportStateRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sourcePath, $0) })
        }
        var errors: [String] = []
        let metadataBackfillCutoff = ISO8601.fractional.string(
            from: Date().addingTimeInterval(-Self.proactiveMetadataBackfillWindow))

        let metadataFingerprint = try? CodexSessionMetadataStore.sourceFingerprint(
            codexHome: codexHome)
        let codexMetadata: [String: CodexSessionMetadata]
        let updatedSessionMetadata: Int
        let sessionMetadataCacheHit: Bool
        if let metadataFingerprint,
           let cached = cachedCodexSessionMetadata,
           cached.fingerprint == metadataFingerprint {
            codexMetadata = cached.metadata
            updatedSessionMetadata = 0
            sessionMetadataCacheHit = true
        } else {
            let loadResult = CodexSessionMetadataStore.loadResult(codexHome: codexHome)
            codexMetadata = loadResult.metadata
            updatedSessionMetadata = try await backfillCodexSessionMetadata(
                codexMetadata,
                activeSince: metadataBackfillCutoff)
            let fingerprintAfterLoad = try? CodexSessionMetadataStore.sourceFingerprint(
                codexHome: codexHome)
            if loadResult.isComplete,
               let metadataFingerprint,
               fingerprintAfterLoad == metadataFingerprint {
                cachedCodexSessionMetadata = (
                    fingerprint: metadataFingerprint,
                    metadata: codexMetadata)
            } else {
                cachedCodexSessionMetadata = nil
            }
            sessionMetadataCacheHit = false
        }

        // Proactively repair recent metadata only. Inactive history is best
        // effort, while actual rollout changes still enter the normal import
        // path below regardless of this cutoff.
        let metadataIncompleteCodexPaths: Set<String> = try await database.pool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT source_path FROM sessions
                WHERE provider = 'codex'
                  AND source_path IS NOT NULL
                  AND COALESCE(updated_at, started_at) >= ?
                  AND ((project_name IS NULL OR project_name = '')
                       OR (cwd IS NULL OR cwd = ''))
                """, arguments: [metadataBackfillCutoff])
            return Set(rows)
        }

        // Session ids let us recognize Codex import-state rows even when the
        // user moves or reauthorizes the entire history root. Restricting the
        // relocation lookup to the newly selected root would strand the old
        // state and make every file fail as a duplicate forever.
        let codexSessions: (ids: Set<String>, canonicalPaths: [String: String]) =
            try await database.pool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT session_id, source_path
                    FROM sessions
                    WHERE provider = 'codex'
                    """)
                var ids: Set<String> = []
                var paths: [String: String] = [:]
                for row in rows {
                    guard let sessionId: String = row["session_id"] else { continue }
                    ids.insert(sessionId)
                    if let path: String = row["source_path"], !path.isEmpty {
                        paths[sessionId] = path
                    }
                }
                return (ids, paths)
        }

        let codexRootPrefix = codexHome.standardizedFileURL.path + "/"
        var priorBySession: [String: [ImportStateRecord]] = [:]
        var priorByFragment: [SourceKey: [ImportStateRecord]] = [:]
        for state in priorState.values {
            guard let sessionId = state.sessionId,
                  codexSessions.ids.contains(sessionId)
                    || state.sourcePath.hasPrefix(codexRootPrefix)
            else { continue }
            priorBySession[sessionId, default: []].append(state)
            let key = SourceKey(
                sessionId: sessionId,
                fragmentName: (state.sourcePath as NSString).lastPathComponent)
            priorByFragment[key, default: []].append(state)
        }
        let sources = Self.selectCanonicalSources(
            discoveredFiles,
            priorState: priorState,
            canonicalPaths: codexSessions.canonicalPaths)
        var currentCodexPathsWithoutBackfillableProjectMetadata: [String] = []
        var changed: [ScanCandidate] = []
        for source in sources {
            let file = source.file
            let expected: ImportStateRecord?
            if let direct = source.directState {
                expected = direct
            } else {
                let key = SourceKey(
                    sessionId: source.sessionId,
                    fragmentName: source.fragmentName)
                expected = Self.relocationState(
                    from: priorByFragment[key] ?? [],
                    for: file,
                    canonicalPath: codexSessions.canonicalPaths[source.sessionId])
                    ?? Self.relocationStateMatchingIdentity(
                        from: priorBySession[source.sessionId] ?? [],
                        for: file)
                    ?? Self.relocationStateMatchingFingerprint(
                        from: priorBySession[source.sessionId] ?? [],
                        source: source)
            }

            if let expected,
               expected.sourcePath == file.path,
               expected.fileSize == file.fileSize,
               expected.fileMtimeMs == file.fileMtimeMs {
                // Size and millisecond mtime can collide across an atomic
                // replacement. A checkpointed root file is only unchanged if
                // the scanner's inode snapshot still matches its checkpoint.
                if !Self.checkpointSourceIsCurrent(expected, file: file) {
                    changed.append(ScanCandidate(
                        file: file,
                        sessionId: source.sessionId,
                        expectedState: expected,
                        replacesExistingSource: true))
                    continue
                }
                if metadataIncompleteCodexPaths.contains(file.path),
                   !expected.metadataProbeComplete {
                    if codexRolloutCanBackfillProjectMetadata(file) {
                        changed.append(ScanCandidate(
                            file: file,
                            sessionId: source.sessionId,
                            expectedState: expected,
                            replacesExistingSource: true))
                    } else {
                        currentCodexPathsWithoutBackfillableProjectMetadata.append(file.path)
                    }
                }
                continue
            }
            changed.append(ScanCandidate(
                file: file,
                sessionId: source.sessionId,
                expectedState: expected,
                replacesExistingSource: expected != nil))
        }
        if !currentCodexPathsWithoutBackfillableProjectMetadata.isEmpty {
            try await markCodexRolloutsWithoutBackfillableProjectMetadata(
                currentCodexPathsWithoutBackfillableProjectMetadata)
        }
        await progress?(ScanProgressUpdate(
            provider: "codex",
            completedFiles: 0,
            totalFiles: changed.count,
            currentFile: changed.first?.file.url.lastPathComponent))

        var importedSessions = 0
        var importedEvents = 0
        var importedSamples = 0
        var incrementalFiles = 0
        var sourceBytesRead: Int64 = 0

        for (index, candidate) in changed.enumerated() {
            let file = candidate.file
            do {
                if let parsedCandidate = try Self.parse(candidate: candidate) {
                    sourceBytesRead += parsedCandidate.output.sequentialBytesRead
                    if var parsed = parsedCandidate.output.session {
                        if parsed.sessionId == candidate.sessionId {
                            if let metadata = codexMetadata[parsed.sessionId] {
                                parsed.title = metadata.title
                                parsed.cwd = parsed.cwd ?? metadata.cwd
                                parsed.projectName = parsed.projectName
                                    ?? metadata.projectName
                            }
                            let counts = try await persist(
                                parsed: parsed,
                                output: parsedCandidate.output,
                                file: file,
                                expectedState: candidate.expectedState,
                                mode: parsedCandidate.mode)
                            importedSessions += 1
                            importedEvents += counts.events
                            importedSamples += counts.samples
                            if parsedCandidate.mode == .append {
                                incrementalFiles += 1
                            }
                        } else {
                            DeveloperLog.eventRecord(
                                "importer.codex.session_id.changed",
                                level: .warning,
                                category: "importer",
                                result: "deferred",
                                message: "session_meta changed after source selection",
                                fields: [
                                    "selected_session_id": .string(candidate.sessionId),
                                    "parsed_session_id": .string(parsed.sessionId)
                                ])
                        }
                    } else {
                        errors.append("no session id resolved: \(file.path)")
                    }
                } else {
                    DeveloperLog.eventRecord(
                        "importer.codex.source.wait",
                        level: .warning,
                        category: "importer",
                        result: "deferred",
                        message: "Codex source is not a stable append or replacement",
                        fields: ["session_id": .string(candidate.sessionId)])
                }
            } catch {
                errors.append("\(file.path): \(error)")
            }
            let nextIndex = index + 1
            let nextFile = nextIndex < changed.count
                ? changed[nextIndex].file.url.lastPathComponent
                : nil
            await progress?(ScanProgressUpdate(
                provider: "codex",
                completedFiles: nextIndex,
                totalFiles: changed.count,
                currentFile: nextFile))
        }

        // After all files are persisted, walk the parent chain to compute
        // root_session_id and contains_subagents for every Codex session.
        // Cheap (single pass, all in one transaction) and idempotent.
        if importedSessions > 0 {
            try await reconcileSessionTree()
        }

        // Each changed session was priced inside the same transaction that
        // persisted its rows and checkpoint. Catalog-wide repricing remains a
        // separate operation used only when catalog values actually change.

        let report = ScanReport(
            scannedFiles: discoveredFiles.count,
            changedFiles: changed.count,
            importedSessions: importedSessions,
            importedEvents: importedEvents,
            importedRateLimitSamples: importedSamples,
            updatedSessionMetadata: updatedSessionMetadata,
            incrementalFiles: incrementalFiles,
            sourceBytesRead: sourceBytesRead,
            errors: errors)

        Log.importer.info("scan ok scanned=\(report.scannedFiles) changed=\(report.changedFiles) sessions=\(report.importedSessions) events=\(report.importedEvents) samples=\(report.importedRateLimitSamples) incremental=\(report.incrementalFiles) bytes=\(report.sourceBytesRead) errors=\(report.errors.count)")
        DeveloperLog.eventRecord(
            "importer.scan.finish",
            category: "importer",
            result: "success",
            fields: [
                "scanned_files": .int(report.scannedFiles),
                "changed_files": .int(report.changedFiles),
                "imported_sessions": .int(report.importedSessions),
                "imported_events": .int(report.importedEvents),
                "imported_rate_limit_samples": .int(report.importedRateLimitSamples),
                "updated_session_metadata": .int(report.updatedSessionMetadata),
                "session_metadata_cache_hit": .bool(sessionMetadataCacheHit),
                "incremental_files": .int(report.incrementalFiles),
                "source_bytes_read": .int(Int(report.sourceBytesRead)),
                "errors": .int(report.errors.count)
            ])
        for err in report.errors.prefix(5) {
            Log.importer.error("\(err, privacy: .public)")
            DeveloperLog.eventRecord(
                "importer.scan.error",
                level: .error,
                category: "importer",
                result: "failure",
                message: err)
        }

        return report
    }

    // One logical Codex session may be continued in several rollout files.
    // Treat each filename as one fragment lineage: active/archive copies with
    // the same name still compete for a single canonical source, while a new
    // filename with the same session_meta id contributes additional history.
    private static func selectCanonicalSources(
        _ files: [SessionFile],
        priorState: [String: ImportStateRecord],
        canonicalPaths: [String: String]
    ) -> [ProbedSource] {
        var bySession: [String: [ProbedSource]] = [:]
        for file in files {
            let direct = priorState[file.path]
            let sessionId = probeSessionId(file: file, directState: direct)
                ?? direct?.sessionId
                ?? file.sessionIdHint
                ?? "unresolved:\(file.path)"
            let fragmentName = file.url.lastPathComponent
            bySession[sessionId, default: []].append(ProbedSource(
                file: file,
                sessionId: sessionId,
                fragmentName: fragmentName,
                headerFingerprint: fragmentFingerprint(
                    file: file,
                    directState: direct),
                directState: direct))
        }

        return bySession.flatMap { sessionId, sources in
            var fragments: [[ProbedSource]] = []
            for source in sources.sorted(by: { $0.file.path < $1.file.path }) {
                let matching = fragments.indices.filter { index in
                    fragments[index].contains {
                        sourceSharesFragment($0, source)
                    }
                }
                if let first = matching.first {
                    fragments[first].append(source)
                    for index in matching.dropFirst().reversed() {
                        fragments[first].append(contentsOf: fragments.remove(at: index))
                    }
                } else {
                    fragments.append([source])
                }
            }

            return fragments.compactMap { group in
                canonicalSource(
                    from: group,
                    canonicalPath: canonicalPaths[sessionId])
            }
        }.sorted { $0.file.path < $1.file.path }
    }

    private static func canonicalSource(
        from group: [ProbedSource],
        canonicalPath: String?
    ) -> ProbedSource? {
        var byIdentity: [RolloutSourceIdentity: ProbedSource] = [:]
        for source in group {
            if let current = byIdentity[source.file.sourceIdentity] {
                if source.file.path == canonicalPath
                    || (current.file.path != canonicalPath
                        && sourceIsPreferred(source, to: current))
                {
                    byIdentity[source.file.sourceIdentity] = source
                }
            } else {
                byIdentity[source.file.sourceIdentity] = source
            }
        }

        let candidates = Array(byIdentity.values)
        let canonical = candidates.first { $0.file.path == canonicalPath }
        let active = candidates
            .filter { $0.file.bucket == "active" }
            .sorted(by: sourceIsPreferred)
        let tracked = candidates
            .filter { $0.directState != nil }
            .sorted(by: sourceIsPreferred)
        return canonical
            ?? tracked.first
            ?? active.first
            ?? candidates.sorted(by: sourceIsPreferred).first
    }

    private static func sourceSharesFragment(
        _ lhs: ProbedSource,
        _ rhs: ProbedSource
    ) -> Bool {
        if lhs.fragmentName == rhs.fragmentName { return true }
        guard let lhsFingerprint = lhs.headerFingerprint,
              let rhsFingerprint = rhs.headerFingerprint
        else { return false }
        let length = min(lhsFingerprint.length, rhsFingerprint.length)
        guard length > 0,
              let lhsHash = fingerprintHash(
                  file: lhs.file,
                  cached: lhsFingerprint,
                  length: length),
              let rhsHash = fingerprintHash(
                  file: rhs.file,
                  cached: rhsFingerprint,
                  length: length)
        else { return false }
        return lhsHash == rhsHash
    }

    private static func fragmentFingerprint(
        file: SessionFile,
        directState: ImportStateRecord?
    ) -> FragmentFingerprint? {
        if let data = directState?.parserCheckpoint,
           let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data) {
            return FragmentFingerprint(
                length: min(checkpoint.offset, RolloutParser.fingerprintWindowBytes),
                hash: checkpoint.prefixHash)
        }
        guard let reader = try? RolloutRecordReader(fileURL: file.url) else {
            return nil
        }
        defer { try? reader.close() }
        let end = min(file.fileSize, RolloutParser.fingerprintWindowBytes)
        guard let hash = try? reader.sha256(in: 0..<end) else { return nil }
        return FragmentFingerprint(length: end, hash: hash)
    }

    private static func fingerprintHash(
        file: SessionFile,
        cached: FragmentFingerprint?,
        length: Int64
    ) -> Data? {
        guard length >= 0, length <= file.fileSize else { return nil }
        if let cached, cached.length == length { return cached.hash }
        guard let reader = try? RolloutRecordReader(fileURL: file.url) else {
            return nil
        }
        defer { try? reader.close() }
        return try? reader.sha256(in: 0..<length)
    }

    private static func sourceIsPreferred(
        _ lhs: ProbedSource,
        to rhs: ProbedSource
    ) -> Bool {
        if lhs.file.bucket != rhs.file.bucket {
            return lhs.file.bucket == "active"
        }
        if lhs.file.fileMtimeMs != rhs.file.fileMtimeMs {
            return lhs.file.fileMtimeMs > rhs.file.fileMtimeMs
        }
        if lhs.file.fileSize != rhs.file.fileSize {
            return lhs.file.fileSize > rhs.file.fileSize
        }
        return lhs.file.path < rhs.file.path
    }

    private static func probeSessionId(
        file: SessionFile,
        directState: ImportStateRecord?
    ) -> String? {
        if let directState,
           directState.fileSize == file.fileSize,
           directState.fileMtimeMs == file.fileMtimeMs,
           checkpointSourceIsCurrent(directState, file: file),
           let sessionId = directState.sessionId,
           !sessionId.isEmpty {
            return sessionId
        }

        // session_meta is emitted at the head of Codex rollouts. Bound the
        // probe so cold import does not become two full passes.
        let probeLimit = 256 * 1024
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            guard let head = try handle.read(upToCount: probeLimit), !head.isEmpty else {
                return nil
            }
            let completeBuffer = file.fileSize <= Int64(head.count)
            let lines = head.split(separator: 0x0A, omittingEmptySubsequences: false)
            let eventDecoder = JSONDecoder()
            for (index, line) in lines.enumerated() {
                if index == lines.count - 1, !completeBuffer { break }
                guard let event = RolloutEvent.decode(
                    line: Data(line),
                    decoder: eventDecoder) else { continue }
                if case .sessionMeta(let meta, _) = event,
                   let sessionId = meta.id,
                   !sessionId.isEmpty {
                    return sessionId
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func relocationState(
        from states: [ImportStateRecord],
        for file: SessionFile,
        canonicalPath: String?
    ) -> ImportStateRecord? {
        if let canonicalPath,
           let state = states.first(where: { $0.sourcePath == canonicalPath }) {
            return state
        }
        let matchingIdentity = states.filter { state in
            guard let data = state.parserCheckpoint,
                  let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data)
            else { return false }
            return checkpoint.sourceIdentity == file.sourceIdentity
        }
        if matchingIdentity.count == 1 { return matchingIdentity[0] }
        return states.count == 1 ? states[0] : nil
    }

    private static func relocationStateMatchingIdentity(
        from states: [ImportStateRecord],
        for file: SessionFile
    ) -> ImportStateRecord? {
        let matching = states.filter { state in
            guard let data = state.parserCheckpoint,
                  let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data)
            else { return false }
            return checkpoint.sourceIdentity == file.sourceIdentity
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func relocationStateMatchingFingerprint(
        from states: [ImportStateRecord],
        source: ProbedSource
    ) -> ImportStateRecord? {
        let matching = states.filter { state in
            guard let data = state.parserCheckpoint,
                  let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data)
            else { return false }
            let length = min(checkpoint.offset, RolloutParser.fingerprintWindowBytes)
            guard length > 0,
                  let sourceHash = fingerprintHash(
                      file: source.file,
                      cached: source.headerFingerprint,
                      length: length)
            else { return false }
            return checkpoint.prefixHash == sourceHash
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func checkpointSourceIsCurrent(
        _ state: ImportStateRecord,
        file: SessionFile
    ) -> Bool {
        guard let data = state.parserCheckpoint else { return true }
        guard let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data),
              checkpoint.offset == state.byteOffset,
              checkpoint.sourceIdentity == file.sourceIdentity,
              checkpoint.offset <= file.fileSize,
              let reader = try? RolloutRecordReader(fileURL: file.url)
        else { return false }
        defer { try? reader.close() }
        let window = RolloutParser.fingerprintWindowBytes
        let headEnd = min(checkpoint.offset, window)
        let boundaryStart = max(0, checkpoint.offset - window)
        return (try? reader.sha256(in: 0..<headEnd)) == checkpoint.prefixHash
            && (try? reader.sha256(in: boundaryStart..<checkpoint.offset))
                == checkpoint.boundaryHash
    }

    private static func parse(candidate: ScanCandidate) throws -> ParsedCandidate? {
        let file = candidate.file
        let expected = candidate.expectedState
        let checkpoint: CodexRolloutCheckpoint? = expected.flatMap { state in
            guard state.byteOffset > 0,
                  let data = state.parserCheckpoint,
                  let decoded = try? CodexRolloutCheckpoint.decoded(from: data),
                  decoded.offset == state.byteOffset
            else { return nil }
            return decoded
        }

        if let checkpoint,
           checkpoint.sourceIdentity == file.sourceIdentity,
           file.fileSize >= checkpoint.offset {
            do {
                let output = try RolloutParser.parseIncrementally(
                    fileURL: file.url,
                    fallbackSessionId: candidate.sessionId,
                    checkpoint: checkpoint)
                if output.checkpoint != nil {
                    return ParsedCandidate(output: output, mode: .append)
                }
            } catch is RolloutParserError {
                // Codex can rewrite a rollout while keeping its inode, which
                // strands the committed checkpoint. Reparse from byte zero
                // below instead of rejecting the source forever; the file is
                // the record of truth and `hasIncompleteTail` still holds the
                // last-known-good rows while a rewrite is mid-flight.
            }
        }

        let output = try RolloutParser.parseIncrementally(
            fileURL: file.url,
            fallbackSessionId: candidate.sessionId)
        let replacedIdentity = checkpoint.map {
            $0.sourceIdentity != output.snapshot.sourceIdentity
        } ?? false
        if (replacedIdentity || candidate.replacesExistingSource),
           output.hasIncompleteTail {
            return nil
        }
        return ParsedCandidate(output: output, mode: .replace)
    }

    static func verifyCurrentSource(
        file: SessionFile,
        output: CodexRolloutParseOutput
    ) throws {
        let reader = try RolloutRecordReader(fileURL: file.url)
        defer { try? reader.close() }
        let window = RolloutParser.fingerprintWindowBytes
        let headEnd = min(output.endOffset, window)
        let boundaryStart = max(0, output.endOffset - window)
        guard reader.snapshot.sourceIdentity == output.snapshot.sourceIdentity,
              reader.snapshot.size >= output.snapshot.size,
              try reader.sha256(in: 0..<headEnd) == output.prefixHash,
              try reader.sha256(in: boundaryStart..<output.endOffset)
                == output.endBoundaryHash,
              reader.snapshot.size != output.snapshot.size
                || reader.snapshot.mtimeMs == output.snapshot.mtimeMs
        else {
            throw ImportStateConflict.fileChangedDuringParse
        }
    }

    private func backfillCodexSessionMetadata(
        _ metadataBySessionId: [String: CodexSessionMetadata],
        activeSince: String
    ) async throws -> Int {
        guard !metadataBySessionId.isEmpty else { return 0 }
        let now = ISO8601.fractional.string(from: Date())

        return try await database.pool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, title, project_name, cwd
                FROM sessions
                WHERE provider = 'codex'
                  AND COALESCE(updated_at, started_at) >= ?
                """, arguments: [activeSince])
            var updateCount = 0

            for row in rows {
                guard let sessionId: String = row["session_id"],
                      let metadata = metadataBySessionId[sessionId]
                else { continue }

                let currentTitle = Self.nonEmpty(row["title"] as String?)
                let currentProjectName = Self.nonEmpty(row["project_name"] as String?)
                let currentCwd = Self.nonEmpty(row["cwd"] as String?)
                let nextCwd = currentCwd ?? metadata.cwd
                let nextProjectName = currentProjectName ?? metadata.projectName
                let nextTitle = metadata.title ?? currentTitle

                guard nextTitle != currentTitle
                    || nextProjectName != currentProjectName
                    || nextCwd != currentCwd
                else { continue }

                try db.execute(sql: """
                    UPDATE sessions
                    SET title = ?, project_name = ?, cwd = ?, imported_at = ?
                    WHERE provider = 'codex' AND session_id = ?
                    """, arguments: [
                        nextTitle,
                        nextProjectName,
                        nextCwd,
                        now,
                        sessionId
                    ])
                updateCount += 1
            }
            return updateCount
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func markCodexRolloutsWithoutBackfillableProjectMetadata(
        _ sourcePaths: [String]
    ) async throws {
        let uniquePaths = Set(sourcePaths)
        guard !uniquePaths.isEmpty else { return }
        let now = ISO8601.fractional.string(from: Date())

        try await database.pool.write { db in
            for path in uniquePaths {
                try db.execute(sql: """
                    UPDATE import_state
                    SET metadata_probe_complete = 1,
                        last_imported_at = ?
                    WHERE source_path = ?
                      AND metadata_probe_complete = 0
                    """, arguments: [now, path])
            }
        }
    }

    private func codexRolloutCanBackfillProjectMetadata(_ file: SessionFile) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return false }
        defer { try? handle.close() }

        do {
            let eventDecoder = JSONDecoder()
            for line in try LineReader(handle: handle) {
                guard let event = RolloutEvent.decode(
                    line: line,
                    decoder: eventDecoder) else { continue }
                if case .sessionMeta(let meta, _) = event,
                   let cwd = Self.nonEmpty(meta.cwd) {
                    return !(cwd as NSString).lastPathComponent.isEmpty
                }
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: - persist

    private struct PersistCounts { let events: Int; let samples: Int }

    private func persist(
        parsed: ParsedSession,
        output: CodexRolloutParseOutput,
        file: SessionFile,
        expectedState: ImportStateRecord?,
        mode: PersistMode
    ) async throws -> PersistCounts {
        try Self.verifyCurrentSource(file: file, output: output)

        let checkpointData: Data?
        if let checkpoint = output.checkpoint {
            let encoded = try checkpoint.encoded()
            checkpointData = encoded.count <= maxCheckpointBytes ? encoded : nil
            if checkpointData == nil {
                if warnedOversizedSources.insert(output.snapshot.sourceIdentity).inserted {
                    Log.importer.warning(
                        "Codex checkpoint exceeded \(self.maxCheckpointBytes) bytes; future changes will rebuild \(file.url.lastPathComponent, privacy: .public)")
                }
            } else {
                warnedOversizedSources.remove(output.snapshot.sourceIdentity)
            }
        } else {
            checkpointData = nil
        }
        let now = ISO8601.fractional.string(from: Date())
        let nextState = ImportStateRecord(
            sourcePath: file.path,
            sessionId: parsed.sessionId,
            fileSize: output.snapshot.size,
            fileMtimeMs: output.snapshot.mtimeMs,
            lastImportedAt: now,
            byteOffset: checkpointData == nil ? 0 : output.endOffset,
            parserCheckpoint: checkpointData,
            metadataProbeComplete: true)

        let replacedSessionId = expectedState?.sessionId.flatMap { oldSessionId in
            oldSessionId == parsed.sessionId ? nil : oldSessionId
        }
        let counts = try await database.pool.write { db in
            try Self.validateExpectedState(
                expectedState,
                targetPath: file.path,
                in: db)

            // 1. Upsert the session row.
            let existing = try SessionRecord
                .filter(Column("session_id") == parsed.sessionId)
                .fetchOne(db)
            let sourceMoved = expectedState?.sourcePath != nil
                && expectedState?.sourcePath != file.path
            let sourceWasPrimary = sourceMoved
                && existing?.sourcePath == expectedState?.sourcePath
            let sessionSourcePath = if existing?.sourcePath == nil || sourceWasPrimary {
                file.path
            } else {
                existing?.sourcePath
            }
            let parsedIsLatest = Self.timestamp(
                parsed.updatedAt,
                isSameOrAfter: existing?.updatedAt)

            let sessionRecord = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: existing?.rootSessionId ?? parsed.rootSessionId,
                parentSessionId: parsed.parentSessionId ?? existing?.parentSessionId,
                title: parsed.title ?? existing?.title,
                projectName: parsed.projectName ?? existing?.projectName,
                cwd: parsed.cwd ?? existing?.cwd,
                sourcePath: sessionSourcePath,
                startedAt: Self.earliestTimestamp(existing?.startedAt, parsed.startedAt),
                updatedAt: Self.latestTimestamp(existing?.updatedAt, parsed.updatedAt),
                agentNickname: parsed.agentNickname ?? existing?.agentNickname,
                agentRole: parsed.agentRole ?? existing?.agentRole,
                lastModelId: parsedIsLatest
                    ? parsed.lastModelId ?? existing?.lastModelId
                    : existing?.lastModelId ?? parsed.lastModelId,
                latestPlanType: parsedIsLatest
                    ? parsed.latestPlanType ?? existing?.latestPlanType
                    : existing?.latestPlanType ?? parsed.latestPlanType,
                // Filled in by reconcileSessionTree() after the full scan
                // when we can see this session's children.
                containsSubagents: false,
                createdAt: existing?.createdAt ?? now,
                importedAt: now,
                provider: "codex")
            try sessionRecord.save(db)

            // 2. A full rebuild replaces only this physical fragment. Sibling
            // fragments share the logical session and must remain intact.
            let previousPath = expectedState?.sourcePath
            if mode == .replace {
                for sourcePath in Set([file.path, previousPath].compactMap { $0 }) {
                    try UsageEventRecord
                        .filter(Column("session_id") == parsed.sessionId
                            && Column("source_path") == sourcePath)
                        .deleteAll(db)
                    try RateLimitSampleRecord
                        .filter(Column("source_kind") == "jsonl"
                            && Column("source_session_id") == parsed.sessionId
                            && Column("source_path") == sourcePath)
                        .deleteAll(db)
                }
            } else if let previousPath, previousPath != file.path {
                try db.execute(sql: """
                    UPDATE usage_events
                    SET source_path = ?
                    WHERE session_id = ? AND source_path = ?
                    """, arguments: [file.path, parsed.sessionId, previousPath])
                try db.execute(sql: """
                    UPDATE rate_limit_samples
                    SET source_path = ?
                    WHERE source_kind = 'jsonl'
                      AND source_session_id = ?
                      AND source_path = ?
                    """, arguments: [file.path, parsed.sessionId, previousPath])
            }
            let insertedEventIds = try Self.insertUsageEvents(
                parsed.usageDeltas,
                sessionId: parsed.sessionId,
                sourcePath: file.path,
                in: db)
            try Self.insertRateLimitSamples(
                parsed.rateLimitSamples,
                sessionId: parsed.sessionId,
                sourcePath: file.path,
                in: db)

            // 3. Derive prices before advancing the cursor. Any pricing or
            // checkpoint failure rolls the whole batch back together.
            try PricingService.backfillValues(in: db, eventIds: insertedEventIds)

            // 4. Save the reducer state and cursor atomically. The session row
            // names one canonical source, so stale aliases are state only and
            // can be consolidated without touching user JSONL files.
            try nextState.save(db)
            if let oldPath = expectedState?.sourcePath, oldPath != file.path {
                try ImportStateRecord.deleteOne(db, key: oldPath)
            }
            try Self.removeDuplicateSourceStates(
                sessionId: parsed.sessionId,
                targetPath: file.path,
                sourceFile: file,
                sourceFingerprint: FragmentFingerprint(
                    length: min(
                        output.endOffset,
                        RolloutParser.fingerprintWindowBytes),
                    hash: output.prefixHash),
                in: db)

            return PersistCounts(
                events: parsed.usageDeltas.count,
                samples: parsed.rateLimitSamples.count)
        }
        if let replacedSessionId {
            Log.importer.warning(
                "Codex source changed session id from \(replacedSessionId, privacy: .public) to \(parsed.sessionId, privacy: .public); preserved prior history")
            DeveloperLog.eventRecord(
                "importer.session_id.replaced",
                level: .warning,
                category: "importer",
                fields: [
                    "source_file": .string(file.url.lastPathComponent),
                    "old_session_id": .string(replacedSessionId),
                    "new_session_id": .string(parsed.sessionId),
                    "prior_history_preserved": .bool(true)
                ])
        }
        return counts
    }

    private static func validateExpectedState(
        _ expected: ImportStateRecord?,
        targetPath: String,
        in db: Database
    ) throws {
        if let expected {
            let current = try ImportStateRecord
                .filter(Column("source_path") == expected.sourcePath)
                .fetchOne(db)
            guard current == expected else { throw ImportStateConflict.stale }
            if expected.sourcePath != targetPath {
                let target = try ImportStateRecord
                    .filter(Column("source_path") == targetPath)
                    .fetchOne(db)
                guard target == nil else { throw ImportStateConflict.stale }
            }
        } else {
            let target = try ImportStateRecord
                .filter(Column("source_path") == targetPath)
                .fetchOne(db)
            guard target == nil else { throw ImportStateConflict.stale }
        }
    }

    private static func removeDuplicateSourceStates(
        sessionId: String,
        targetPath: String,
        sourceFile: SessionFile,
        sourceFingerprint: FragmentFingerprint,
        in db: Database
    ) throws {
        let siblings = try ImportStateRecord
            .filter(Column("session_id") == sessionId
                && Column("source_path") != targetPath)
            .fetchAll(db)
        for sibling in siblings {
            guard let data = sibling.parserCheckpoint,
                  let checkpoint = try? CodexRolloutCheckpoint.decoded(from: data)
            else { continue }
            let length = min(checkpoint.offset, RolloutParser.fingerprintWindowBytes)
            let matchesFingerprint = length > 0
                && fingerprintHash(
                    file: sourceFile,
                    cached: sourceFingerprint,
                    length: length) == checkpoint.prefixHash
            guard checkpoint.sourceIdentity == sourceFile.sourceIdentity
                    || matchesFingerprint
            else { continue }
            try UsageEventRecord
                .filter(Column("session_id") == sessionId
                    && Column("source_path") == sibling.sourcePath)
                .deleteAll(db)
            try RateLimitSampleRecord
                .filter(Column("source_kind") == "jsonl"
                    && Column("source_session_id") == sessionId
                    && Column("source_path") == sibling.sourcePath)
                .deleteAll(db)
            try ImportStateRecord.deleteOne(db, key: sibling.sourcePath)
        }
    }

    private static func timestamp(
        _ candidate: String?,
        isSameOrAfter existing: String?
    ) -> Bool {
        guard let candidate else { return false }
        guard let existing else { return true }
        if let candidateDate = ISO8601.parse(candidate),
           let existingDate = ISO8601.parse(existing) {
            return candidateDate >= existingDate
        }
        return candidate >= existing
    }

    private static func earliestTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if let lhsDate = ISO8601.parse(lhs), let rhsDate = ISO8601.parse(rhs) {
            return lhsDate <= rhsDate ? lhs : rhs
        }
        return min(lhs, rhs)
    }

    private static func latestTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if let lhsDate = ISO8601.parse(lhs), let rhsDate = ISO8601.parse(rhs) {
            return lhsDate >= rhsDate ? lhs : rhs
        }
        return max(lhs, rhs)
    }

    private static func insertUsageEvents(
        _ deltas: [UsageDelta],
        sessionId: String,
        sourcePath: String,
        in db: Database
    ) throws -> [Int64] {
        var insertedIds: [Int64] = []
        insertedIds.reserveCapacity(deltas.count)
        for delta in deltas {
            let event = UsageEventRecord(
                id: nil,
                sessionId: sessionId,
                timestamp: delta.timestamp,
                modelId: delta.modelId,
                inputTokens: delta.inputTokens,
                cachedInputTokens: delta.cachedInputTokens,
                outputTokens: delta.outputTokens,
                reasoningOutputTokens: delta.reasoningOutputTokens,
                totalTokens: delta.totalTokens,
                valueUsd: 0,
                // The shared storage column is provider-neutral: Claude writes
                // cache_creation_input_tokens, Codex writes
                // cache_write_input_tokens. Both are cache-write input.
                cacheCreationTokens: delta.cacheWriteInputTokens,
                provider: "codex",
                modelInferred: delta.modelInferred,
                providerMessageId: nil,
                codexTurnId: delta.turnId,
                codexServiceTierPreference: delta.serviceTierPreference?.rawValue,
                sourcePath: sourcePath)
            try event.insert(db)
            insertedIds.append(db.lastInsertedRowID)
        }
        return insertedIds
    }

    private static func insertRateLimitSamples(
        _ drafts: [RateLimitSampleDraft],
        sessionId: String,
        sourcePath: String,
        in db: Database
    ) throws {
        for draft in drafts {
            let windowStart: String? = draft.windowDuration.flatMap { duration in
                guard duration > 0,
                      let resetAt = ISO8601.parse(draft.resetsAt)
                else { return nil }
                return ISO8601.fractional.string(
                    from: resetAt.addingTimeInterval(-duration))
            }
            let sample = RateLimitSampleRecord(
                id: nil,
                sourceKind: "jsonl",
                sourceSessionId: sessionId,
                bucket: draft.bucket,
                sampleTimestamp: draft.sampleTimestamp,
                planType: draft.planType,
                limitName: draft.limitName,
                windowStart: windowStart,
                resetsAt: draft.resetsAt,
                usedPercent: draft.usedPercent,
                remainingPercent: draft.remainingPercent,
                sourcePath: sourcePath)
            try sample.insert(db)
        }
    }

    // MARK: - reconcile session tree

    /// Walk every Codex session's parent chain and update:
    ///   - `root_session_id` to the topmost ancestor (cycle-safe; capped at 64 hops)
    ///   - `contains_subagents` to true iff the session has at least one child
    ///
    /// Mirrors codex-pacer's `recompute_conversation_links`. We don't maintain
    /// a separate `conversation_links` table — `sessions.root_session_id` and
    /// `contains_subagents` are enough for the queries we surface today.
    private func reconcileSessionTree() async throws {
        try await database.pool.write { db in
            // Pull (id, parent) for every Codex session in one query.
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, parent_session_id
                FROM sessions
                WHERE provider = 'codex'
                """)
            var parents: [String: String?] = [:]
            for row in rows {
                let id: String = row["session_id"] ?? ""
                let parent: String? = row["parent_session_id"]
                parents[id] = parent
            }

            var hasChildren: Set<String> = []
            for case let parent? in parents.values {
                hasChildren.insert(parent)
            }

            for sessionId in parents.keys {
                let root = Self.resolveRoot(sessionId, in: parents)
                let containsSubagents = hasChildren.contains(sessionId)
                try db.execute(sql: """
                    UPDATE sessions
                    SET root_session_id = ?, contains_subagents = ?
                    WHERE session_id = ?
                    """, arguments: [root, containsSubagents, sessionId])
            }
        }
    }

    /// Walk parent links until we find a session whose parent is missing or nil,
    /// or we exceed the safety cap (cycle protection). Returns the topmost id.
    private static func resolveRoot(
        _ sessionId: String, in parents: [String: String?]
    ) -> String {
        var current = sessionId
        var seen: Set<String> = [current]
        for _ in 0..<64 {
            guard let parentOpt = parents[current], let parent = parentOpt else {
                return current
            }
            if seen.contains(parent) { return current } // cycle guard
            seen.insert(parent)
            current = parent
        }
        return current
    }
}
