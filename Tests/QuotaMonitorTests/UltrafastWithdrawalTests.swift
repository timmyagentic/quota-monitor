import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Ultrafast reintroduction compatibility")
struct UltrafastWithdrawalTests {
    @Test(arguments: ["v23-quota-cycle-evidence", "v24-codex-ultrafast-reread", "v25-withdraw-ultrafast-pricing"])
    func retainsHistoryAndSchedulesReread(migration: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qm-withdraw-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue, upTo: migration)
        try queue.write { db in
            _ = try PricingService.installBundledCatalog(in: db)
            try db.execute(sql: """
                INSERT INTO sessions(session_id, root_session_id, source_path, created_at, imported_at, provider)
                VALUES ('history', 'history', '/synthetic/missing.jsonl', '2026-10-10', '2026-10-10', 'codex');
                INSERT INTO usage_events(session_id, timestamp, model_id, input_tokens, total_tokens, value_usd, provider, codex_turn_id, codex_service_tier_preference)
                VALUES ('history', '2026-10-10T00:00:00Z', 'gpt-6.1-sol', 100000, 100000, 0.2, 'codex', 'turn-old', 'ultrafast');
                INSERT INTO usage_events(session_id, timestamp, model_id, input_tokens, total_tokens, value_usd, provider, codex_service_tier_preference)
                VALUES ('history', '2026-10-10T00:00:01Z', 'gpt-6.1-sol', 100000, 100000, 0.2, 'codex', NULL);
                INSERT INTO import_state(source_path, session_id, file_size, file_mtime_ms, byte_offset, parser_checkpoint, last_imported_at)
                VALUES ('/synthetic/missing.jsonl', 'history', 123, 456, 123, X'010203', '2026-10-10');
                INSERT OR REPLACE INTO pricing_catalog(model_id, display_name, input_price_per_million, cached_input_price_per_million, output_price_per_million, effective_model_id, updated_at, price_source)
                VALUES ('gpt-6.1-sol-ultrafast', 'legacy', 12, 0.6, 60, 'gpt-6.1-sol-ultrafast', '2026-10-10', 'bundled');
                """)
        }
        for _ in 0..<2 {
            let manager = try DatabaseManager(url: url)
            try manager.pool.read { db in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events") == 2)
                let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM usage_events WHERE codex_turn_id = 'turn-old'"))
                #expect(row["input_tokens"] as Int == 100000)
                #expect(row["codex_service_tier_preference"] as String == "ultrafast")
                #expect(abs((row["value_usd"] as Double) - 1.2) < 0.000001)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM usage_events WHERE codex_service_tier_preference IS NULL") == 1)
                let cursor = try #require(try Row.fetchOne(db, sql: "SELECT * FROM import_state"))
                #expect(cursor["file_size"] as Int == -1)
                #expect(cursor["byte_offset"] as Int == 0)
                #expect(cursor["parser_checkpoint"] as Data? == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM pricing_catalog WHERE model_id LIKE '%-ultrafast%'") == 4)
                #expect(try !migrator.hasBeenSuperseded(db))
            }
        }
    }

    @Test func checkpointEvidenceAndNewValuesRecognizeUltrafast() throws {
        #expect(CodexServiceTierPreference(rolloutValue: "ultrafast") == .ultrafast)
        #expect(CodexServiceTierPreference(rolloutValue: "priority") == .priority)
        let state = CodexRolloutReducerState(
            sessionId: "synthetic", pendingServiceTierPreference: .ultrafast,
            activeTurn: ActiveCodexTurn(id: "old-turn", serviceTierPreference: .ultrafast),
            sawSessionMeta: true, isIncrementalRootEligible: true)
        let checkpoint = CodexRolloutCheckpoint(offset: 0, state: state,
            sourceIdentity: RolloutSourceIdentity(device: 1, inode: 1, birthtimeNs: 1),
            prefixHash: Data(), boundaryHash: Data())
        for version in [1, 2] {
            var json = try #require(JSONSerialization.jsonObject(with: checkpoint.encoded()) as? [String: Any])
            json["version"] = version
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try CodexRolloutCheckpoint.decoded(from: data)
            #expect(decoded.version == 2)
            #expect(decoded.state.activeTurn?.serviceTierPreference?.rawValue == "ultrafast")
            #expect(decoded.state.pendingServiceTierPreference?.rawValue == "ultrafast")
        }
    }
}
