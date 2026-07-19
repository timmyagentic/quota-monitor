import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex real-data import probe", .serialized)
struct CodexRealDataImportProbeTests {

    @Test("imports an explicitly supplied read-only Codex snapshot")
    func importSnapshotWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let codexHomePath = environment["QM_CODEX_IMPORT_PROBE_HOME"],
              let databasePath = environment["QM_CODEX_IMPORT_PROBE_DB"]
        else {
            return
        }

        let database = try DatabaseManager(
            url: URL(fileURLWithPath: databasePath, isDirectory: false))
        let report = try await ImportEngine(
            database: database,
            codexHome: URL(fileURLWithPath: codexHomePath, isDirectory: true)
        ).performScan()
        if environment["QM_CODEX_IMPORT_PROBE_REFERENCE_REPRICE"] == "1" {
            // Mirror the app-level path on origin/main. New incremental runs
            // omit this flag so their transaction-scoped pricing is tested
            // independently against the already-priced reference database.
            try await database.pool.write { db in
                try PricingService.backfillAllValues(in: db)
            }
        }

        #expect(report.errors.isEmpty)
        print(
            "codex-real-data-probe "
                + "scanned=\(report.scannedFiles) "
                + "changed=\(report.changedFiles) "
                + "sessions=\(report.importedSessions) "
                + "events=\(report.importedEvents) "
                + "samples=\(report.importedRateLimitSamples) "
                + "incremental=\(report.incrementalFiles) "
                + "bytes=\(report.sourceBytesRead)")
    }
}
