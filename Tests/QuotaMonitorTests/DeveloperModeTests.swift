import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Developer mode")
struct DeveloperModeTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private static func tempLogURL(_ name: String = #function) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(name).log", isDirectory: false)
    }

    private static func firstJSONLine(at url: URL) throws -> [String: Any] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let first = try #require(text.split(separator: "\n", omittingEmptySubsequences: true).first)
        let data = Data(String(first).utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test
    func defaultsToFalseOnFreshInstall() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.developerModeEnabled == false)
    }

    @Test
    func mutatingWritesToUserDefaults() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.developerModeEnabled = true
        #expect(d.bool(forKey: "settings.developerModeEnabled") == true)
    }

    @Test
    func storedTrueIsReadOnInit() {
        let d = Self.freshDefaults()
        d.set(true, forKey: "settings.developerModeEnabled")
        let store = SettingsStore(defaults: d)
        #expect(store.developerModeEnabled == true)
    }

    @Test
    func snapshotCarriesDeveloperMode() {
        let d = Self.freshDefaults()
        d.set(true, forKey: "settings.developerModeEnabled")
        let snap = SettingsStore.snapshot(defaults: d)
        #expect(snap.developerModeEnabled == true)
    }

    @Test
    func fileLoggerDoesNotCreateFileWhenDisabled() async throws {
        let url = try Self.tempLogURL()
        let logger = DeveloperFileLogger(fileURL: url, isEnabled: { false })

        let wrote = await logger.record(
            level: .info,
            category: "test",
            message: "should not write")

        #expect(wrote == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test
    func fileLoggerCreatesParentAndAppendsStructuredJSONLineWhenEnabled() async throws {
        let url = try Self.tempLogURL()
            .deletingLastPathComponent()
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("developer.log", isDirectory: false)
        let logger = DeveloperFileLogger(
            fileURL: url,
            isEnabled: { true },
            appRunID: { "app-run-test" },
            clock: { Date(timeIntervalSince1970: 0) })

        let wrote = await logger.record(
            level: .info,
            category: "scan",
            event: "scan.finish",
            operationID: "op-1",
            parentOperationID: "parent-1",
            trigger: "manual",
            provider: "codex",
            durationMilliseconds: 42,
            result: "success",
            message: "hello world",
            fields: [
                "scanned": 10,
                "changed": 2,
                "fast_mode": true
            ])

        #expect(wrote == true)
        let json = try Self.firstJSONLine(at: url)
        #expect(json["ts"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(json["level"] as? String == "INFO")
        #expect(json["cat"] as? String == "scan")
        #expect(json["event"] as? String == "scan.finish")
        #expect(json["app_run_id"] as? String == "app-run-test")
        #expect(json["op_id"] as? String == "op-1")
        #expect(json["parent_op_id"] as? String == "parent-1")
        #expect(json["trigger"] as? String == "manual")
        #expect(json["provider"] as? String == "codex")
        #expect(json["duration_ms"] as? Int == 42)
        #expect(json["result"] as? String == "success")
        #expect(json["message"] as? String == "hello world")
        #expect(json["scanned"] as? Int == 10)
        #expect(json["changed"] as? Int == 2)
        #expect(json["fast_mode"] as? Bool == true)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
    }

    @Test
    func fileLoggerEscapesMultilineMessagesAsJSON() async throws {
        let url = try Self.tempLogURL()
        let logger = DeveloperFileLogger(fileURL: url, isEnabled: { true })

        _ = await logger.record(
            level: .error,
            category: "scan",
            event: "scan.fail",
            message: "line one\nline two")

        let json = try Self.firstJSONLine(at: url)
        #expect(json["level"] as? String == "ERROR")
        #expect(json["message"] as? String == "line one\nline two")
    }

    @Test
    func fileLoggerRedactsSecretsAndTruncatesLongStrings() async throws {
        let url = try Self.tempLogURL()
        let logger = DeveloperFileLogger(fileURL: url, isEnabled: { true })
        let longTail = String(repeating: "x", count: 3_000)

        _ = await logger.record(
            level: .error,
            category: "appserver",
            event: "appserver.stderr",
            message: "access_token=message-secret \(longTail)",
            fields: [
                "stderr": .string("Authorization: Bearer field-secret \(longTail)"),
                "request": .string("https://example.test/path?__cf_chl_tk=challenge-secret&ok=1")
            ])

        let json = try Self.firstJSONLine(at: url)
        let message = try #require(json["message"] as? String)
        let stderr = try #require(json["stderr"] as? String)
        let request = try #require(json["request"] as? String)

        #expect(message.contains("message-secret") == false)
        #expect(stderr.contains("field-secret") == false)
        #expect(request.contains("challenge-secret") == false)
        #expect(message.contains("access_token=<redacted>"))
        #expect(stderr.contains("Authorization: Bearer <redacted>"))
        #expect(request.contains("__cf_chl_tk=<redacted>"))
        #expect(message.contains("...[truncated; original_chars="))
        #expect(stderr.contains("...[truncated; original_chars="))
    }

    @Test
    func fileLoggerDeletesExistingLogWhenDeveloperModeTurnsOff() async throws {
        let url = try Self.tempLogURL()
        let logger = DeveloperFileLogger(fileURL: url, isEnabled: { true })

        _ = await logger.record(level: .info, category: "test", message: "old log")
        #expect(FileManager.default.fileExists(atPath: url.path))

        await logger.deleteLogFile()

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test
    func fileLoggerRotatesExistingLogWhenItWouldExceedLimit() async throws {
        let url = try Self.tempLogURL()
        try "old log payload".write(to: url, atomically: true, encoding: .utf8)
        let rotatedURL = URL(fileURLWithPath: url.path + ".1")
        let logger = DeveloperFileLogger(
            fileURL: url,
            isEnabled: { true },
            maxFileBytes: 10)

        _ = await logger.record(
            level: .info,
            category: "scan",
            event: "scan.finish",
            message: "new log")

        #expect(try String(contentsOf: rotatedURL, encoding: .utf8) == "old log payload")
        let json = try Self.firstJSONLine(at: url)
        #expect(json["event"] as? String == "scan.finish")
        #expect(json["message"] as? String == "new log")
    }

    @Test
    func osLogSummaryUsesStableFieldsAndRedactsSecrets() {
        let summary = DeveloperLog.osLogSummary(
            event: "ratelimits.refresh.fail",
            category: "poller",
            trigger: "manual",
            provider: "codex",
            durationMilliseconds: 30_000,
            result: "failure",
            message: "Authorization: Bearer message-secret",
            fields: [
                "reason": "rate-limit-cooldown",
                "error_type": "ClientError",
                "error_message": "access_token=field-secret"
            ])

        #expect(summary.contains("event=ratelimits.refresh.fail"))
        #expect(summary.contains("cat=poller"))
        #expect(summary.contains("provider=codex"))
        #expect(summary.contains("trigger=manual"))
        #expect(summary.contains("result=failure"))
        #expect(summary.contains("duration_ms=30000"))
        #expect(summary.contains("reason=rate-limit-cooldown"))
        #expect(summary.contains("error_type=ClientError"))
        #expect(summary.contains("message-secret") == false)
        #expect(summary.contains("field-secret") == false)
        #expect(summary.contains("Authorization: Bearer <redacted>"))
        #expect(summary.contains("access_token=<redacted>"))
    }
}
