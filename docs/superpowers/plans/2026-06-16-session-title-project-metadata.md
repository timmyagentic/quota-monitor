# Session Title and Project Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** History and Sessions must show a real session/thread title as the primary label, while project or working-directory names are stored and rendered as secondary metadata.

**Architecture:** Split the overloaded `sessions.title` meaning into explicit session title plus project metadata. Add nullable `sessions.project_name` and `sessions.cwd`, migrate existing cwd-derived titles into `project_name`, then enrich Codex rows from Codex thread metadata and Claude rows from Claude Code `ai-title` events. Query models expose both fields so the History and Sessions rows can render title, project, model, events, and time without pretending a project directory is a session name.

**Tech Stack:** Swift 6, SwiftUI, GRDB migrations and queries, Swift Testing, local Codex JSONL/SQLite metadata, Claude Code JSONL import.

---

## File Structure

**New files:**
- `QuotaMonitor/Core/Storage/SessionMetadataMigration.swift` - testable helpers for v11 legacy title reclassification and one-time importer header rereads.
- `QuotaMonitor/Core/Importer/CodexSessionMetadataStore.swift` - reads Codex thread metadata from `CODEX_HOME/sqlite/state_5.sqlite` and falls back to `CODEX_HOME/session_index.jsonl`.
- `QuotaMonitor/Features/Sessions/SessionRowMetadataView.swift` - shared compact metadata row for Sessions and History session rows.
- `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift` - focused schema, metadata, parser, and query tests for this feature.

**Modified files:**
- `QuotaMonitor/Core/Storage/Migrations.swift` - add v11 session metadata columns, backfill existing project names, and force one scan to reclassify session headers.
- `QuotaMonitor/Core/Storage/Records.swift` - add `projectName` and `cwd` to `SessionRecord`.
- `QuotaMonitor/Core/Analytics/Aggregator.swift` - add `projectName` and `cwd` to `SessionRow`.
- `QuotaMonitor/Core/Analytics/AggregatorSessions.swift` - select/search the new fields.
- `QuotaMonitor/Core/Analytics/AggregatorHistory.swift` - select the new fields for day detail rows.
- `QuotaMonitor/Core/Importer/RolloutEvent.swift` - decode Codex `session_meta.payload.cwd` as today and leave title metadata to the new metadata store.
- `QuotaMonitor/Core/Importer/RolloutParser.swift` - return `cwd` and `projectName`; stop using cwd leaf as `title`.
- `QuotaMonitor/Core/Importer/ImportEngine.swift` - load Codex metadata once per scan, enrich parsed sessions, and replace the old titleless reparse trigger with metadata-incomplete reparse logic.
- `QuotaMonitor/Core/Importer/ClaudeImportEngine.swift` - parse Claude `ai-title`, preserve `cwd`/`projectName`, and persist all session header fields.
- `QuotaMonitor/Features/Sessions/SessionsView.swift` - use real title as the primary label and shared project metadata as secondary text.
- `QuotaMonitor/Features/History/HistoryView.swift` - use the same row semantics in day detail rows.
- `QuotaMonitor/Features/Sessions/SessionDetailView.swift` - show the real title in the header and project metadata near session id/model metadata.
- `QuotaMonitor/Core/Localization/L10n.swift` - add short labels for project metadata if the UI needs them.
- `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` - describe the user-visible display fix.

## Data Contract

After implementation:

- `sessions.title` means "real session/thread title" only. It may be nil.
- `sessions.project_name` means a short display project name, normally the cwd leaf such as `quota-monitor`.
- `sessions.cwd` means the full working directory path when the source exposes one.
- Existing databases with cwd-derived `title` values are migrated by copying `title` into `project_name` and clearing `title`.
- Migration reclassification logic is shared by v11 and a direct unit-test helper. Do not test historical migration behavior by inserting a legacy row after a fresh fully migrated `DatabaseManager` init; that only tests the final schema.
- Metadata readers fail open. Codex SQLite metadata failures must not abort a scan or discard titles already read from `session_index.jsonl`.
- Incremental imports preserve existing `title`, `project_name`, and `cwd` when the newly parsed tail slice does not contain header metadata.
- Search matches `title`, `project_name`, `cwd`, `agent_nickname`, `last_model_id`, and `session_id`.
- UI row primary text uses `title` or `L10n.untitledSession`.
- UI row secondary text includes project metadata when present.

## Plan Corrections Before Implementation

These constraints are part of the implementation contract:

- Use a shared migration helper for legacy title reclassification so v11 and tests exercise the same SQL.
- Keep Codex metadata enrichment fail-soft: `session_index.jsonl` titles remain usable if `state_5.sqlite` is missing, unreadable, or has an unexpected schema.
- Preserve previously stored Claude/Codex header metadata during incremental tail scans that only include new usage events.
- Treat source-level UI tests as a guardrail only. Primary correctness must come from parser/import/query tests plus real-data QA.

## Task 1: Schema and Domain Model Split

**Files:**
- Create: `QuotaMonitor/Core/Storage/SessionMetadataMigration.swift`
- Modify: `QuotaMonitor/Core/Storage/Migrations.swift`
- Modify: `QuotaMonitor/Core/Storage/Records.swift`
- Modify: `QuotaMonitor/Core/Analytics/Aggregator.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Write the failing migration/domain test**

Create `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift` with the first suite:

```swift
import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Session title and project metadata")
struct SessionTitleProjectMetadataTests {
    private func makeDatabase(_ name: String = #function) throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-session-metadata-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseManager(url: dir.appendingPathComponent("quotamonitor.sqlite"))
    }

    @Test("v11 columns exist and legacy title is reclassified as project metadata")
    func migrationReclassifiesLegacyProjectTitle() throws {
        let db = try makeDatabase()
        try db.pool.write { conn in
            // Insert a legacy-shaped row into the final schema, then call the
            // shared helper directly. A fresh DatabaseManager has already run
            // every migration, so inserting after init cannot prove that v11
            // handled a historical row during migration.
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd,
                   source_path, started_at, updated_at, agent_nickname,
                   agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s1', 's1', NULL, 'game_backend_task2',
                   NULL, NULL,
                   '/Users/timmy/.codex/sessions/rollout-s1.jsonl',
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z', 'codex')
                """)
            try SessionMetadataMigration.reclassifyLegacyTitles(in: conn)
            let row = try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
            #expect(row?["title"] as String? == nil)
            #expect(row?["project_name"] as String? == "game_backend_task2")
            #expect(row?["cwd"] as String? == nil)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/migrationReclassifiesLegacyProjectTitle`
Expected: FAIL because `SessionMetadataMigration` and the new columns do not exist yet.

- [ ] **Step 3: Add testable v11 migration helpers**

Create `QuotaMonitor/Core/Storage/SessionMetadataMigration.swift`:

```swift
import GRDB

enum SessionMetadataMigration {
    static func reclassifyLegacyTitles(in db: Database) throws {
        try db.execute(sql: """
            UPDATE sessions
            SET project_name = CASE
                  WHEN project_name IS NULL OR project_name = ''
                  THEN NULLIF(title, '')
                  ELSE project_name
                END,
                title = NULL
            WHERE title IS NOT NULL AND title != ''
            """)
    }

    static func forceHeaderReread(in db: Database) throws {
        try db.execute(sql: """
            UPDATE import_state
            SET file_size = -1,
                file_mtime_ms = -1,
                byte_offset = 0
            WHERE session_id IN (
                SELECT session_id
                FROM sessions
                WHERE provider IN ('codex', 'claude')
            )
            """)
    }
}
```

- [ ] **Step 4: Add v11 migration**

Append this migration after v10 in `QuotaMonitor/Core/Storage/Migrations.swift`:

```swift
        // v11: split session title from project metadata.
        //
        // Before v11, Codex and Claude importers stored cwd leaf names in
        // sessions.title as a friendly fallback. That made History and
        // Sessions show project names as if they were session names. Move
        // those legacy values into project_name, clear title, and force one
        // scan so importers can repopulate true titles where the source has
        // them.
        migrator.registerMigration("v11-session-project-metadata") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "project_name", .text)
                t.add(column: "cwd", .text)
            }
            try SessionMetadataMigration.reclassifyLegacyTitles(in: db)
            try SessionMetadataMigration.forceHeaderReread(in: db)
        }
```

- [ ] **Step 5: Add stored fields to `SessionRecord`**

In `QuotaMonitor/Core/Storage/Records.swift`, add properties after `title`:

```swift
    var projectName: String?
    var cwd: String?
```

Add coding keys:

```swift
        case projectName = "project_name"
        case cwd
```

- [ ] **Step 6: Add read model fields to `SessionRow`**

In `QuotaMonitor/Core/Analytics/Aggregator.swift`, add fields after `title`:

```swift
    let projectName: String?
    let cwd: String?
```

- [ ] **Step 7: Update all `SessionRecord` initializers**

For every `SessionRecord(` call, insert:

```swift
                projectName: parsed.projectName,
                cwd: parsed.cwd,
```

For tests that insert `SessionRecord` directly, pass `projectName: nil, cwd: nil`.

- [ ] **Step 8: Run focused test**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/migrationReclassifiesLegacyProjectTitle`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add QuotaMonitor/Core/Storage/SessionMetadataMigration.swift QuotaMonitor/Core/Storage/Migrations.swift QuotaMonitor/Core/Storage/Records.swift QuotaMonitor/Core/Analytics/Aggregator.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Split session title from project metadata"
```

## Task 2: Codex Parser Returns Project Metadata, Not Title

**Files:**
- Modify: `QuotaMonitor/Core/Importer/RolloutParser.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add failing parser test**

Append this test to `SessionTitleProjectMetadataTests`:

```swift
    private func writeJSONL(_ content: String, name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-session-metadata-jsonl-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Codex parser treats cwd leaf as project metadata, not title")
    func codexParserSeparatesProjectFromTitle() throws {
        let url = try writeJSONL("""
        {"timestamp":"2026-06-15T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/game_backend_task2"}}
        {"timestamp":"2026-06-15T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """)
        let parsed = try #require(try RolloutParser.parse(fileURL: url))
        #expect(parsed.title == nil)
        #expect(parsed.projectName == "game_backend_task2")
        #expect(parsed.cwd == "/Volumes/SamsungDisk/Code/game_backend_task2")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/codexParserSeparatesProjectFromTitle`
Expected: FAIL because `ParsedSession` does not have `projectName` or `cwd`.

- [ ] **Step 3: Extend `ParsedSession`**

In `RolloutParser.swift`, add fields after `title`:

```swift
    var projectName: String?
    var cwd: String?
```

- [ ] **Step 4: Replace cwd-derived title fallback**

Replace the current `let title` block with:

```swift
        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()
```

Return:

```swift
            title: nil,
            projectName: projectName,
            cwd: cwd,
```

- [ ] **Step 5: Run focused test**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/codexParserSeparatesProjectFromTitle`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Core/Importer/RolloutParser.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Keep Codex project metadata out of session titles"
```

## Task 3: Codex Thread Title Metadata Store

**Files:**
- Create: `QuotaMonitor/Core/Importer/CodexSessionMetadataStore.swift`
- Modify: `QuotaMonitor/Core/Importer/ImportEngine.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add failing metadata-store tests**

Append:

```swift
    @Test("Codex metadata store reads session_index thread_name")
    func codexMetadataReadsSessionIndex() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"梳理项目现状","updated_at":"2026-06-15T03:01:30Z"}
        """.write(to: codexHome.appendingPathComponent("session_index.jsonl"),
                  atomically: true,
                  encoding: .utf8)

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "梳理项目现状")
    }

    @Test("Codex metadata store prefers threads sqlite title and cwd")
    func codexMetadataPrefersStateDatabase() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)",
                                    isDirectory: true)
        let sqliteDir = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"older title"}
        """.write(to: codexHome.appendingPathComponent("session_index.jsonl"),
                  atomically: true,
                  encoding: .utf8)

        let db = try DatabaseQueue(path: sqliteDir.appendingPathComponent("state_5.sqlite").path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL
                )
                """)
            try conn.execute(sql: """
                INSERT INTO threads (id, title, cwd)
                VALUES ('s1', '真实会话标题', '/Volumes/SamsungDisk/Code/quota-monitor')
                """)
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "真实会话标题")
        #expect(metadata["s1"]?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(metadata["s1"]?.projectName == "quota-monitor")
    }

    @Test("Codex metadata store keeps session_index title when state sqlite is unusable")
    func codexMetadataFallsBackWhenStateDatabaseFails() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)",
                                    isDirectory: true)
        let sqliteDir = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"session index title"}
        """.write(to: codexHome.appendingPathComponent("session_index.jsonl"),
                  atomically: true,
                  encoding: .utf8)

        let db = try DatabaseQueue(path: sqliteDir.appendingPathComponent("state_5.sqlite").path)
        try db.write { conn in
            try conn.execute(sql: "CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "session index title")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/codexMetadata`
Expected: FAIL because `CodexSessionMetadataStore` does not exist.

- [ ] **Step 3: Implement metadata store**

Create `QuotaMonitor/Core/Importer/CodexSessionMetadataStore.swift`:

```swift
import Foundation
import GRDB

struct CodexSessionMetadata: Sendable, Equatable {
    let title: String?
    let cwd: String?

    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? nil : leaf
    }
}

enum CodexSessionMetadataStore {
    static func load(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        var result = (try? loadSessionIndex(codexHome: codexHome)) ?? [:]
        do {
            try overlayStateDatabase(codexHome: codexHome, into: &result)
        } catch {
            // Optional: Log.importer.warning("Failed to read Codex state metadata: \(error.localizedDescription)")
            return result
        }
        return result
    }

    private static func overlayStateDatabase(
        codexHome: URL,
        into result: inout [String: CodexSessionMetadata]
    ) throws {
        let sqlite = codexHome
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path) else {
            return
        }
        let config = Configuration(readonly: true)
        let db = try DatabaseQueue(path: sqlite.path, configuration: config)
        let rows = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT id, title, cwd
                FROM threads
                WHERE id IS NOT NULL
                """)
        }
        for row in rows {
            guard let id: String = row["id"], !id.isEmpty else { continue }
            result[id] = CodexSessionMetadata(
                title: nonEmpty(row["title"]),
                cwd: nonEmpty(row["cwd"]))
        }
    }

    private static func loadSessionIndex(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        var result: [String: CodexSessionMetadata] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  !id.isEmpty
            else { continue }
            result[id] = CodexSessionMetadata(
                title: nonEmpty(object["thread_name"] as? String),
                cwd: nil)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Enrich Codex imports**

In `ImportEngine.performScan`, load metadata before the file loop:

```swift
        let codexMetadata: [String: CodexSessionMetadata]
        do {
            codexMetadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        } catch {
            codexMetadata = [:]
        }
```

This keeps the import scan resilient if `session_index.jsonl` or the SQLite state database is temporarily unreadable.

Before persist:

```swift
                    var enriched = parsed
                    if let metadata = codexMetadata[parsed.sessionId] {
                        enriched.title = metadata.title
                        enriched.cwd = parsed.cwd ?? metadata.cwd
                        enriched.projectName = parsed.projectName ?? metadata.projectName
                    }
                    let counts = try await persist(parsed: enriched, file: file)
```

- [ ] **Step 5: Replace titleless reparse trigger**

Replace `titlelessCodexPaths` with `metadataIncompleteCodexPaths`:

```swift
        let metadataIncompleteCodexPaths: Set<String> = try await database.pool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT source_path FROM sessions
                WHERE provider = 'codex'
                  AND source_path IS NOT NULL
                  AND ((project_name IS NULL OR project_name = '')
                       OR (cwd IS NULL OR cwd = ''))
                """)
            return Set(rows)
        }
```

Update the changed filter:

```swift
            if metadataIncompleteCodexPaths.contains(file.path) { return true }
```

- [ ] **Step 6: Run focused tests**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/codexMetadata`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add QuotaMonitor/Core/Importer/CodexSessionMetadataStore.swift QuotaMonitor/Core/Importer/ImportEngine.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Import Codex session titles from thread metadata"
```

## Task 4: Claude `ai-title` and Project Metadata Parsing

**Files:**
- Modify: `QuotaMonitor/Core/Importer/ClaudeImportEngine.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add failing Claude parser test**

Append:

```swift
    @Test("Claude parser uses ai-title as session title and cwd as project metadata")
    func claudeParserSeparatesTitleAndProject() throws {
        let url = try writeJSONL("""
        {"type":"ai-title","aiTitle":"Review PR #59 default setting","sessionId":"c1"}
        {"type":"user","sessionId":"c1","timestamp":"2026-06-15T10:00:00.000Z","cwd":"/Volumes/SamsungDisk/Code/quota-monitor","message":{"role":"user","content":"review this PR"}}
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """)
        let parsed = try #require(try ClaudeRolloutParser.parse(fileURL: url).session)
        #expect(parsed.title == "Review PR #59 default setting")
        #expect(parsed.projectName == "quota-monitor")
        #expect(parsed.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Claude incremental scan preserves existing title and project metadata")
    func claudeIncrementalScanPreservesExistingHeaderMetadata() async throws {
        let db = try makeDatabase()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-root-\(UUID().uuidString)",
                                    isDirectory: true)
        let projectDir = root.appendingPathComponent("-Volumes-SamsungDisk-Code-quota-monitor",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let rollout = projectDir.appendingPathComponent("c1.jsonl")
        try """
        {"type":"ai-title","aiTitle":"Review PR #59 default setting","sessionId":"c1"}
        {"type":"user","sessionId":"c1","timestamp":"2026-06-15T10:00:00.000Z","cwd":"/Volumes/SamsungDisk/Code/quota-monitor","message":{"role":"user","content":"review this PR"}}
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:02:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":6}}}
        """.utf8))

        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 'c1'
                """)
        })
        #expect(row["title"] as String? == "Review PR #59 default setting")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --disable-keychain --filter SessionTitleProjectMetadataTests/claudeParserSeparatesTitleAndProject
swift test --disable-keychain --filter SessionTitleProjectMetadataTests/claudeIncrementalScanPreservesExistingHeaderMetadata
```

Expected: FAIL because Claude parsed sessions do not expose `projectName` and `cwd`, `ai-title` is ignored, and incremental tail scans do not yet preserve existing header metadata.

- [ ] **Step 3: Extend Claude parsed session**

In `ParsedClaudeSession`, add:

```swift
    let projectName: String?
    let cwd: String?
```

In `ClaudeRolloutParser.parse`, track:

```swift
        var cwd: String? = nil
```

When reading each raw line:

```swift
            if cwd == nil, let rawCwd = raw["cwd"] as? String, !rawCwd.isEmpty {
                cwd = rawCwd
            }
            if title == nil, type == "ai-title" {
                title = raw["aiTitle"] as? String
            }
```

Remove the old `if title == nil, let cwd = raw["cwd"]` fallback.

Before constructing `ParsedClaudeSession`, derive:

```swift
        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()
```

Return `projectName` and `cwd`.

- [ ] **Step 4: Persist Claude metadata**

In `ClaudeImportEngine.persist`, resolve header metadata before constructing `SessionRecord`:

```swift
            let resolvedTitle = parsed.title ?? (resetSession ? nil : existing?.title)
            let resolvedProjectName = parsed.projectName ?? (resetSession ? nil : existing?.projectName)
            let resolvedCwd = parsed.cwd ?? (resetSession ? nil : existing?.cwd)
```

Use these values in the Claude `SessionRecord(` initializer:

```swift
                title: resolvedTitle,
                projectName: resolvedProjectName,
                cwd: resolvedCwd,
```

Do not preserve an existing title when `parsed.title` is non-nil, and do not keep stale metadata across a reset if the full source no longer exposes it. The preservation rule is specifically for incremental tail scans where the parsed slice does not include `ai-title` or `cwd`.

- [ ] **Step 5: Run focused test**

Run:

```bash
swift test --disable-keychain --filter SessionTitleProjectMetadataTests/claudeParserSeparatesTitleAndProject
swift test --disable-keychain --filter SessionTitleProjectMetadataTests/claudeIncrementalScanPreservesExistingHeaderMetadata
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Core/Importer/ClaudeImportEngine.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Import Claude session titles separately from project metadata"
```

## Task 5: Query Layer Search and Row Models

**Files:**
- Modify: `QuotaMonitor/Core/Analytics/AggregatorSessions.swift`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorHistory.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add failing query test**

Append:

```swift
    @Test("Session search matches title and project metadata separately")
    func sessionSearchMatchesTitleAndProject() throws {
        let db = try makeDatabase()
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd, source_path, started_at, updated_at,
                   agent_nickname, agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s1', 's1', NULL, 'Review PR #59 default setting',
                   'quota-monitor', '/Volumes/SamsungDisk/Code/quota-monitor',
                   NULL, '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z', 'codex')
                """)
            try conn.execute(sql: """
                INSERT INTO usage_events
                  (session_id, timestamp, model_id, input_tokens,
                   cached_input_tokens, output_tokens, reasoning_output_tokens,
                   total_tokens, value_usd, provider, cache_creation_tokens,
                   model_inferred)
                VALUES
                  ('s1', '2026-06-15T10:02:00Z', 'gpt-5.5',
                   10, 0, 5, 0, 15, 0.01, 'codex', 0, 0)
                """)
        }

        let byTitle = try db.pool.read { conn in
            try Aggregator.fetchSessions(db: conn, search: "default setting")
        }
        let byProject = try db.pool.read { conn in
            try Aggregator.fetchSessions(db: conn, search: "quota-monitor")
        }

        #expect(byTitle.first?.title == "Review PR #59 default setting")
        #expect(byTitle.first?.projectName == "quota-monitor")
        #expect(byTitle.first?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(byProject.first?.sessionId == "s1")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/sessionSearchMatchesTitleAndProject`
Expected: FAIL until query selects/searches the new fields.

- [ ] **Step 3: Update session list SQL**

In every `SELECT` that builds `SessionRow`, add:

```sql
          s.project_name,
          s.cwd,
```

In every `SessionRow(` mapping, add:

```swift
                    projectName: row["project_name"],
                    cwd: row["cwd"],
```

- [ ] **Step 4: Update search predicate**

In `Aggregator.fetchSessions`, replace the search predicate with:

```sql
                (LOWER(COALESCE(s.title,''))          LIKE ?
              OR LOWER(COALESCE(s.project_name,''))   LIKE ?
              OR LOWER(COALESCE(s.cwd,''))            LIKE ?
              OR LOWER(COALESCE(s.agent_nickname,'')) LIKE ?
              OR LOWER(COALESCE(s.last_model_id,''))  LIKE ?
              OR LOWER(s.session_id)                  LIKE ?)
```

Update the argument count:

```swift
            args.append(contentsOf: Array(repeating: pattern, count: 6))
```

- [ ] **Step 5: Run focused test**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/sessionSearchMatchesTitleAndProject`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Core/Analytics/AggregatorSessions.swift QuotaMonitor/Core/Analytics/AggregatorHistory.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Expose project metadata in session queries"
```

## Task 6: UI Rows Show Title Primary and Project Secondary

**Files:**
- Create: `QuotaMonitor/Features/Sessions/SessionRowMetadataView.swift`
- Modify: `QuotaMonitor/Features/Sessions/SessionsView.swift`
- Modify: `QuotaMonitor/Features/History/HistoryView.swift`
- Modify: `QuotaMonitor/Features/Sessions/SessionDetailView.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Test: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add source-level guard test**

This test is only a source-level guard that both row surfaces use the shared metadata view and keep `L10n.untitledSession` for missing true titles. Parser, import, and query tests provide the behavioral proof; real-data QA in Task 8 verifies the rendered app.

Append:

```swift
    @Test("History and Sessions rows route through the shared metadata view")
    func sessionRowsUseSharedProjectMetadataView() throws {
        let sessions = try String(contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/Sessions/SessionsView.swift"))
        let history = try String(contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/History/HistoryView.swift"))
        #expect(sessions.contains("SessionRowMetadataView(row: row"))
        #expect(history.contains("SessionRowMetadataView(row: session"))
        #expect(sessions.contains("L10n.untitledSession"))
        #expect(history.contains("L10n.untitledSession"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/sessionRowsUseSharedProjectMetadataView`
Expected: FAIL because the shared view does not exist and the old inline row rendering is still present.

- [ ] **Step 3: Create shared metadata view**

Create `QuotaMonitor/Features/Sessions/SessionRowMetadataView.swift`:

```swift
import SwiftUI

struct SessionRowMetadataView: View {
    let row: SessionRow
    let showsUpdatedRelativeTime: Bool

    init(row: SessionRow, showsUpdatedRelativeTime: Bool = false) {
        self.row = row
        self.showsUpdatedRelativeTime = showsUpdatedRelativeTime
    }

    var body: some View {
        HStack(spacing: 8) {
            if let project = row.projectName, !project.isEmpty {
                Label(project, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let agent = row.agentNickname, !agent.isEmpty {
                Text(agent)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(Capsule())
            }
            if row.containsSubagents {
                Label(L10n.subagents, systemImage: "person.2.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .help(L10n.helpSpawnedSubagents)
            }
            if let model = row.lastModelId, !model.isEmpty {
                Text(model).font(.caption2).foregroundStyle(.secondary)
            }
            Text(L10n.eventsCount(row.eventCount))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if showsUpdatedRelativeTime, let updated = row.updatedAt {
                Text(formatRelative(updated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatRelative(_ iso: String) -> String {
        guard let date = ISO8601.parse(iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 4: Use shared view in `SessionsView`**

Keep the primary title expression as:

```swift
                Text(row.title?.isEmpty == false ? row.title! : L10n.untitledSession)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
```

Replace the inline second and third metadata rows with:

```swift
            SessionRowMetadataView(row: row, showsUpdatedRelativeTime: true)
```

- [ ] **Step 5: Use shared view in `HistoryView`**

In `ExpandableSessionRow`, keep primary title as:

```swift
                        Text(session.title?.isEmpty == false ? session.title! : L10n.untitledSession)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
```

Replace the inline metadata `HStack` with:

```swift
                        HStack(spacing: 8) {
                            SessionRowMetadataView(row: session)
                            if let started = session.startedAt {
                                Text(timeRange(started: started, ended: session.updatedAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
```

- [ ] **Step 6: Show project metadata in session detail header**

In `SessionDetailView`, below the title, add:

```swift
            if let project = detail.header.projectName, !project.isEmpty {
                Label(project, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 7: Run focused test**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/sessionRowsUseSharedProjectMetadataView`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add QuotaMonitor/Features/Sessions/SessionRowMetadataView.swift QuotaMonitor/Features/Sessions/SessionsView.swift QuotaMonitor/Features/History/HistoryView.swift QuotaMonitor/Features/Sessions/SessionDetailView.swift QuotaMonitor/Core/Localization/L10n.swift Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Show project names as session metadata"
```

## Task 7: End-to-End Import Regression

**Files:**
- Modify: `Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift`

- [ ] **Step 1: Add Codex import regression**

Append:

```swift
    @Test("Codex scan persists real title and project metadata")
    func codexScanPersistsTitleAndProjectMetadata() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)",
                                    isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent("sessions/2026/06/15",
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"梳理项目现状","updated_at":"2026-06-15T03:01:30Z"}
        """.write(to: codexHome.appendingPathComponent("session_index.jsonl"),
                  atomically: true,
                  encoding: .utf8)

        let rollout = sessionsDir.appendingPathComponent("rollout-2026-06-15T11-01-20-s1.jsonl")
        try """
        {"timestamp":"2026-06-15T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/quota-monitor"}}
        {"timestamp":"2026-06-15T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(row["title"] as String? == "梳理项目现状")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }
```

- [ ] **Step 2: Run test**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests/codexScanPersistsTitleAndProjectMetadata`
Expected: PASS.

- [ ] **Step 3: Run full focused suite**

Run: `swift test --disable-keychain --filter SessionTitleProjectMetadataTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/QuotaMonitorTests/SessionTitleProjectMetadataTests.swift
git commit -m "Cover session title metadata end to end"
```

## Task 8: Changelog and Verification

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Add release-note entries**

In `CHANGELOG.md` under `## [Unreleased]`, add:

```markdown
### Fixed
- **Session rows show real titles.** History and Sessions now keep project folder names as secondary metadata, so rows no longer present repeated project names as if they were session titles.
```

In `CHANGELOG.zh-Hans.md` under `## [Unreleased]`, add:

```markdown
### 修复
- **会话行显示真实标题。** 历史和会话页面现在会把项目文件夹名作为次要信息展示，不再把重复的项目名当作会话标题。
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
swift test --disable-keychain --filter SessionTitleProjectMetadataTests
swift test --disable-keychain --filter RolloutParserTests
swift test --disable-keychain --filter ClaudeRolloutParserIncrementalTests
swift test --disable-keychain --filter Aggregator
```

Expected: all selected suites PASS.

- [ ] **Step 3: Run static verification**

Run: `./qa/run-static.sh`
Expected: release-note validation passes, Python checks pass, and Swift tests pass.

- [ ] **Step 4: Run real-data UI verification**

Use the QuotaMonitor local QA flow against real local history:

```bash
./qa/prepare-computer-use-real-data.sh
./qa/run-local.sh real-data
```

Expected in the app:
- History day detail primary row text contains titles such as `梳理项目现状`.
- Project names such as `quota-monitor` appear on the secondary metadata line.
- Rows with no true source title show `Untitled session` / `未命名会话`, not `quota-monitor` as the primary title.
- Search finds rows by either session title or project name.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md CHANGELOG.zh-Hans.md
git commit -m "Document session title display fix"
```

## Review Checklist

- [ ] v11 uses the shared migration helper, and the helper has a direct regression test.
- [ ] `sessions.title` no longer stores cwd leaf fallback values for new imports.
- [ ] Existing cwd-derived titles are moved to `project_name` and cleared from `title`.
- [ ] Codex title lookup handles `state_5.sqlite` and `session_index.jsonl`.
- [ ] Codex title lookup keeps `session_index.jsonl` titles if SQLite metadata lookup fails.
- [ ] Claude title lookup handles `ai-title`.
- [ ] Incremental Claude imports keep existing explicit title/project metadata when a tail scan does not see header rows.
- [ ] Search includes both real title and project metadata.
- [ ] History, Sessions, and Session Detail use the same primary/secondary semantics.
- [ ] Full static verification passes with `./qa/run-static.sh`.
