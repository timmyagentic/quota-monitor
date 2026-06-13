import Foundation
import OSLog

enum DeveloperLogLevel: String, Sendable, Encodable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum DeveloperLogValue: Sendable, Encodable,
                        ExpressibleByStringLiteral,
                        ExpressibleByIntegerLiteral,
                        ExpressibleByFloatLiteral,
                        ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }

    func sanitizedForDeveloperLog() -> DeveloperLogValue {
        switch self {
        case .string(let value): .string(DeveloperLogSanitizer.sanitize(value))
        case .int, .double, .bool: self
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value):    try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value):   try container.encode(value)
        }
    }
}

struct DeveloperLogOperation: Sendable {
    let id: String
    let event: String
    let category: String
    let trigger: String?
    let provider: String?
    let parentID: String?
    let startedAt: Date
}

private struct DeveloperLogRecord: Encodable {
    let timestamp: String
    let level: DeveloperLogLevel
    let category: String
    let event: String
    let appRunID: String
    let operationID: String?
    let parentOperationID: String?
    let trigger: String?
    let provider: String?
    let durationMilliseconds: Int?
    let result: String?
    let message: String?
    let fields: [String: DeveloperLogValue]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(timestamp, forKey: DynamicCodingKey("ts"))
        try container.encode(level.rawValue, forKey: DynamicCodingKey("level"))
        try container.encode(category, forKey: DynamicCodingKey("cat"))
        try container.encode(event, forKey: DynamicCodingKey("event"))
        try container.encode(appRunID, forKey: DynamicCodingKey("app_run_id"))
        try container.encodeIfPresent(operationID, forKey: DynamicCodingKey("op_id"))
        try container.encodeIfPresent(parentOperationID, forKey: DynamicCodingKey("parent_op_id"))
        try container.encodeIfPresent(trigger, forKey: DynamicCodingKey("trigger"))
        try container.encodeIfPresent(provider, forKey: DynamicCodingKey("provider"))
        try container.encodeIfPresent(durationMilliseconds, forKey: DynamicCodingKey("duration_ms"))
        try container.encodeIfPresent(result, forKey: DynamicCodingKey("result"))
        try container.encodeIfPresent(
            message.map(DeveloperLogSanitizer.sanitize),
            forKey: DynamicCodingKey("message"))
        for (key, value) in fields where !Self.reservedKeys.contains(key) {
            try container.encode(value.sanitizedForDeveloperLog(),
                                 forKey: DynamicCodingKey(stringValue: key))
        }
    }

    private static let reservedKeys: Set<String> = [
        "ts", "level", "cat", "event", "app_run_id", "op_id",
        "parent_op_id", "trigger", "provider", "duration_ms",
        "result", "message"
    ]
}

private enum DeveloperLogSanitizer {
    private static let maxStringCharacters = 2_048

    private static let redactionPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s"',;<>]+"#),
        try! NSRegularExpression(
            pattern: #"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?token|auth[_-]?token|__cf_chl_[A-Za-z0-9_]+|cf_clearance)\s*[:=]\s*)[^\s"'&,;<>]+"#)
    ]

    static func sanitize(_ value: String) -> String {
        var sanitized = value
        for pattern in redactionPatterns {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = pattern.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "$1<redacted>")
        }

        guard sanitized.count > maxStringCharacters else { return sanitized }
        return String(sanitized.prefix(maxStringCharacters))
            + "...[truncated; original_chars=\(sanitized.count)]"
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
    }
}

actor DeveloperFileLogger {
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let appRunID: @Sendable () -> String
    private let clock: @Sendable () -> Date
    private let maxFileBytes: UInt64
    private let encoder: JSONEncoder

    init(fileURL: URL = DeveloperFileLogger.defaultLogURL(),
         isEnabled: @escaping @Sendable () -> Bool = {
             SettingsStore.developerModeEnabledNonisolated
         },
         appRunID: @escaping @Sendable () -> String = { DeveloperLog.appRunID },
         clock: @escaping @Sendable () -> Date = Date.init,
         maxFileBytes: UInt64 = 20 * 1024 * 1024) {
        self.fileURL = fileURL
        self.rotatedFileURL = URL(fileURLWithPath: fileURL.path + ".1")
        self.isEnabled = isEnabled
        self.appRunID = appRunID
        self.clock = clock
        self.maxFileBytes = maxFileBytes
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    nonisolated static func defaultLogDirectory() -> URL {
        let appSupport = LocalQAEnvironment.applicationSupportDirectory()
        return appSupport
            .appendingPathComponent("QuotaMonitor", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    nonisolated static func defaultLogURL() -> URL {
        defaultLogDirectory()
            .appendingPathComponent("quotamonitor-dev.log", isDirectory: false)
    }

    @discardableResult
    func record(level: DeveloperLogLevel,
                category: String,
                event: String = "log.message",
                operationID: String? = nil,
                parentOperationID: String? = nil,
                trigger: String? = nil,
                provider: String? = nil,
                durationMilliseconds: Int? = nil,
                result: String? = nil,
                message: String? = nil,
                fields: [String: DeveloperLogValue] = [:],
                force: Bool = false) -> Bool {
        guard force || isEnabled() else { return false }

        let record = DeveloperLogRecord(
            timestamp: Self.timestamp(clock()),
            level: level,
            category: category,
            event: event,
            appRunID: appRunID(),
            operationID: operationID,
            parentOperationID: parentOperationID,
            trigger: trigger,
            provider: provider,
            durationMilliseconds: durationMilliseconds,
            result: result,
            message: message,
            fields: fields)

        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try append(data)
            return true
        } catch {
            return false
        }
    }

    func deleteLogFile() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: rotatedFileURL)
    }

    private func append(_ data: Data) throws {
        let parent = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try rotateIfNeeded(incomingBytes: UInt64(data.count))
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotateIfNeeded(incomingBytes: UInt64) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let current = attrs[.size] as? UInt64 ?? 0
        guard current + incomingBytes > maxFileBytes else { return }
        try? fm.removeItem(at: rotatedFileURL)
        try fm.moveItem(at: fileURL, to: rotatedFileURL)
    }

    private nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum DeveloperLog {
    nonisolated static let appRunID = UUID().uuidString
    private static let logger = DeveloperFileLogger()

    nonisolated static var logFileURL: URL {
        DeveloperFileLogger.defaultLogURL()
    }

    nonisolated static func startOperation(
        _ event: String,
        category: String,
        trigger: String? = nil,
        provider: String? = nil,
        parent: DeveloperLogOperation? = nil,
        fields: [String: DeveloperLogValue] = [:]
    ) -> DeveloperLogOperation {
        let op = DeveloperLogOperation(
            id: UUID().uuidString,
            event: event,
            category: category,
            trigger: trigger,
            provider: provider,
            parentID: parent?.id,
            startedAt: Date())
        eventRecord(
            event + ".start",
            level: .info,
            category: category,
            operation: op,
            trigger: trigger,
            provider: provider,
            fields: fields)
        return op
    }

    nonisolated static func finishOperation(
        _ operation: DeveloperLogOperation,
        result: String = "success",
        fields: [String: DeveloperLogValue] = [:]
    ) {
        eventRecord(
            operation.event + ".finish",
            level: .info,
            category: operation.category,
            operation: operation,
            trigger: operation.trigger,
            provider: operation.provider,
            durationMilliseconds: durationMilliseconds(since: operation.startedAt),
            result: result,
            fields: fields)
    }

    nonisolated static func failOperation(
        _ operation: DeveloperLogOperation,
        error: Error,
        fields: [String: DeveloperLogValue] = [:]
    ) {
        var next = fields
        next["error_type"] = .string(String(describing: type(of: error)))
        next["error_message"] = .string(error.localizedDescription)
        eventRecord(
            operation.event + ".fail",
            level: .error,
            category: operation.category,
            operation: operation,
            trigger: operation.trigger,
            provider: operation.provider,
            durationMilliseconds: durationMilliseconds(since: operation.startedAt),
            result: "failure",
            message: String(describing: error),
            fields: next)
    }

    nonisolated static func eventRecord(
        _ event: String,
        level: DeveloperLogLevel = .info,
        category: String,
        operation: DeveloperLogOperation? = nil,
        trigger: String? = nil,
        provider: String? = nil,
        durationMilliseconds: Int? = nil,
        result: String? = nil,
        message: String? = nil,
        fields: [String: DeveloperLogValue] = [:]
    ) {
        emitUnifiedLog(
            level: level,
            category: category,
            event: event,
            operation: operation,
            trigger: trigger,
            provider: provider,
            durationMilliseconds: durationMilliseconds,
            result: result,
            message: message,
            fields: fields)
        guard SettingsStore.developerModeEnabledNonisolated else { return }
        Task.detached(priority: .utility) {
            await logger.record(
                level: level,
                category: category,
                event: event,
                operationID: operation?.id,
                parentOperationID: operation?.parentID,
                trigger: trigger ?? operation?.trigger,
                provider: provider ?? operation?.provider,
                durationMilliseconds: durationMilliseconds,
                result: result,
                message: message,
                fields: fields)
        }
    }

    nonisolated static func debug(_ message: @autoclosure () -> String,
                                  category: String) {
        record(level: .debug, category: category, message: message)
    }

    nonisolated static func info(_ message: @autoclosure () -> String,
                                 category: String) {
        record(level: .info, category: category, message: message)
    }

    nonisolated static func warning(_ message: @autoclosure () -> String,
                                    category: String) {
        record(level: .warning, category: category, message: message)
    }

    nonisolated static func warn(_ message: @autoclosure () -> String,
                                 category: String) {
        warning(message(), category: category)
    }

    nonisolated static func error(_ message: @autoclosure () -> String,
                                  category: String) {
        record(level: .error, category: category, message: message)
    }

    nonisolated static func modeChanged(enabled: Bool) {
        Task.detached(priority: .utility) {
            if enabled {
                emitUnifiedLog(
                    level: .info,
                    category: "settings",
                    event: "developer_mode.enabled",
                    message: "developer mode enabled")
                await logger.record(
                    level: .info,
                    category: "settings",
                    event: "developer_mode.enabled",
                    message: "developer mode enabled",
                    force: true)
            } else {
                emitUnifiedLog(
                    level: .info,
                    category: "settings",
                    event: "developer_mode.disabled",
                    message: "developer mode disabled")
                await logger.deleteLogFile()
            }
        }
    }

    private nonisolated static func record(
        level: DeveloperLogLevel,
        category: String,
        message: () -> String
    ) {
        eventRecord(
            "log.message",
            level: level,
            category: category,
            message: message())
    }

    private nonisolated static func durationMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    nonisolated static func osLogSummary(
        event: String,
        category: String,
        operation: DeveloperLogOperation? = nil,
        trigger: String? = nil,
        provider: String? = nil,
        durationMilliseconds: Int? = nil,
        result: String? = nil,
        message: String? = nil,
        fields: [String: DeveloperLogValue] = [:]
    ) -> String {
        var parts = [
            "event=\(event)",
            "cat=\(category)"
        ]
        if let provider = provider ?? operation?.provider {
            parts.append("provider=\(provider)")
        }
        if let trigger = trigger ?? operation?.trigger {
            parts.append("trigger=\(trigger)")
        }
        if let result {
            parts.append("result=\(result)")
        }
        if let durationMilliseconds {
            parts.append("duration_ms=\(durationMilliseconds)")
        }
        if let operation {
            parts.append("op_id=\(operation.id)")
        }
        for key in ["reason", "error_type", "error_message"] {
            if let value = fields[key]?.osLogString {
                parts.append("\(key)=\(DeveloperLogSanitizer.sanitize(value))")
            }
        }
        if let message {
            parts.append("message=\(DeveloperLogSanitizer.sanitize(message))")
        }
        return parts.joined(separator: " ")
    }

    private nonisolated static func emitUnifiedLog(
        level: DeveloperLogLevel,
        category: String,
        event: String,
        operation: DeveloperLogOperation? = nil,
        trigger: String? = nil,
        provider: String? = nil,
        durationMilliseconds: Int? = nil,
        result: String? = nil,
        message: String? = nil,
        fields: [String: DeveloperLogValue] = [:]
    ) {
        guard level != .debug || SettingsStore.developerModeEnabledNonisolated else { return }
        let summary = osLogSummary(
            event: event,
            category: category,
            operation: operation,
            trigger: trigger,
            provider: provider,
            durationMilliseconds: durationMilliseconds,
            result: result,
            message: message,
            fields: fields)
        let unifiedLogger = Log.logger(category: category)
        switch level {
        case .debug:
            unifiedLogger.debug("\(summary, privacy: .public)")
        case .info:
            unifiedLogger.info("\(summary, privacy: .public)")
        case .warning:
            unifiedLogger.warning("\(summary, privacy: .public)")
        case .error:
            unifiedLogger.error("\(summary, privacy: .public)")
        }
    }
}

private extension DeveloperLogValue {
    var osLogString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .bool(let value): return value ? "true" : "false"
        }
    }
}
