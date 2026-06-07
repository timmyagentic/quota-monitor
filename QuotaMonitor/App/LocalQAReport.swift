import Foundation

struct LocalQAWindowReport: Codable, Equatable {
    let title: String
    let identifier: String?
    let isVisible: Bool
    let isKeyWindow: Bool
}

struct LocalQAMenuBarReport: Codable, Equatable {
    let codexEvents: Int
    let codexSessions: Int
    let codexTokens: Int64
    let claudeEvents: Int
    let claudeSessions: Int
    let claudeTokens: Int64
}

struct LocalQASettingsReport: Codable, Equatable {
    let language: String
    let enabledProviders: [String]
    let menuBarIconProviders: [String]
    let menuBarLabelStyle: String
    let quotaDisplayMode: String
    let showDockIconForWindows: Bool
    let developerModeEnabled: Bool
    let pollIntervalSeconds: Int
}

struct LocalQAReport: Codable, Equatable {
    let generatedAt: String
    let pid: Int
    let bundleIdentifier: String
    let qaSteps: [String]
    let databasePath: String
    let developerLogPath: String
    let statusItemVisibility: String
    let lastError: String?
    let settings: LocalQASettingsReport
    let windows: [LocalQAWindowReport]
    let menuBar: LocalQAMenuBarReport?

    @discardableResult
    func write(to outputDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(
            "app-state.json",
            isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
        return url
    }
}
