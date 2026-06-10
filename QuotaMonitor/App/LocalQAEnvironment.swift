import Foundation

struct LocalQAResolvedConfiguration: Equatable {
    let isActive: Bool
    let homeDirectory: URL?
    let defaultsSuite: String?
    let outputDirectory: URL?
    let codexHomeDirectory: URL?
    let steps: [String]?
}

enum LocalQAEnvironment {
    static let modeKey = "QUOTAMONITOR_QA_MODE"
    static let homeKey = "QUOTAMONITOR_QA_HOME"
    static let defaultsSuiteKey = "QUOTAMONITOR_QA_DEFAULTS_SUITE"
    static let outputDirectoryKey = "QUOTAMONITOR_QA_OUTPUT_DIR"
    static let stepsKey = "QUOTAMONITOR_QA_STEPS"
    static let codexHomeKey = "CODEX_HOME"
    static let configArgument = "--quotamonitor-qa-config"
    static let configBase64Argument = "--quotamonitor-qa-config-base64"
    static let invalidQADefaultsSuite = "dev.tjzhou.QuotaMonitor.InvalidQA"

    static func resolvedConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> LocalQAResolvedConfiguration? {
        if let inlineConfiguration = inlineLaunchConfiguration(arguments: arguments) {
            return inlineConfiguration
        }
        if let fileConfiguration = fileLaunchConfiguration(arguments: arguments) {
            return fileConfiguration
        }

        guard environment[modeKey] == "1" else { return nil }
        return LocalQAResolvedConfiguration(
            isActive: true,
            homeDirectory: directoryURL(environment[homeKey]),
            defaultsSuite: qaDefaultsSuite(environment[defaultsSuiteKey]),
            outputDirectory: directoryURL(environment[outputDirectoryKey]),
            codexHomeDirectory: directoryURL(environment[codexHomeKey]),
            steps: stepNames(environment[stepsKey]))
    }

    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        activeConfiguration(environment: environment, arguments: arguments) != nil
    }

    static func homeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL {
        if let home = activeConfiguration(
            environment: environment,
            arguments: arguments)?.homeDirectory {
            return home
        }
        if let home = directoryURL(environment[homeKey]) {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func applicationSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL {
        if let home = activeConfiguration(
            environment: environment,
            arguments: arguments)?.homeDirectory {
            return home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        if let home = directoryURL(environment[homeKey]) {
            return home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func userDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> UserDefaults? {
        let configuration = activeConfiguration(
            environment: environment,
            arguments: arguments)
        let suite = configuration?.defaultsSuite
            ?? qaDefaultsSuite(environment[defaultsSuiteKey])
        if configuration != nil && suite == nil {
            return UserDefaults(suiteName: invalidQADefaultsSuite)
        }
        guard let suite else {
            return .standard
        }
        return UserDefaults(suiteName: suite)
    }

    static func processEnvironmentOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: String] {
        guard let configuration = activeConfiguration(
            environment: environment,
            arguments: arguments) else {
            return [:]
        }

        var overrides: [String: String] = [:]
        if let home = configuration.homeDirectory {
            overrides["HOME"] = home.path
        }
        if let codexHome = configuration.codexHomeDirectory
            ?? configuration.homeDirectory?.appendingPathComponent(".codex", isDirectory: true) {
            overrides[codexHomeKey] = codexHome.path
        }
        return overrides
    }

    @discardableResult
    static func applyProcessEnvironmentOverridesIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: String] {
        let overrides = processEnvironmentOverrides(
            environment: environment,
            arguments: arguments)
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        return overrides
    }

    static func codexHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard let configuration = activeConfiguration(
            environment: environment,
            arguments: arguments) else { return nil }
        if let codexHome = configuration.codexHomeDirectory {
            return codexHome
        }
        return configuration.homeDirectory?
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func allowsExternalDataSources(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        !isActive(environment: environment, arguments: arguments)
    }

    private static func activeConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> LocalQAResolvedConfiguration? {
        guard let configuration = resolvedConfiguration(
            environment: environment,
            arguments: arguments),
              configuration.isActive else { return nil }
        return configuration
    }

    private static func inlineLaunchConfiguration(
        arguments: [String]
    ) -> LocalQAResolvedConfiguration? {
        guard let rawPayload = launchConfigurationValue(
            argumentName: configBase64Argument,
            arguments: arguments),
              let data = Data(base64Encoded: rawPayload),
              let decoded = try? JSONDecoder().decode(LaunchConfigurationFile.self, from: data)
        else { return nil }
        return resolvedConfiguration(from: decoded)
    }

    private static func fileLaunchConfiguration(
        arguments: [String]
    ) -> LocalQAResolvedConfiguration? {
        guard let rawPath = launchConfigurationValue(
            argumentName: configArgument,
            arguments: arguments) else { return nil }
        let url = URL(
            fileURLWithPath: (rawPath as NSString).expandingTildeInPath,
            isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LaunchConfigurationFile.self, from: data)
        else { return nil }
        return resolvedConfiguration(from: decoded)
    }

    private static func resolvedConfiguration(
        from decoded: LaunchConfigurationFile
    ) -> LocalQAResolvedConfiguration {
        LocalQAResolvedConfiguration(
            isActive: decoded.mode ?? true,
            homeDirectory: directoryURL(decoded.home),
            defaultsSuite: qaDefaultsSuite(decoded.defaultsSuite),
            outputDirectory: directoryURL(decoded.outputDirectory),
            codexHomeDirectory: directoryURL(decoded.codexHome),
            steps: decoded.steps?.compactMap { nonEmpty($0) })
    }

    private static func launchConfigurationValue(
        argumentName: String,
        arguments: [String]
    ) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == argumentName,
               arguments.index(after: index) < arguments.endIndex {
                return arguments[arguments.index(after: index)]
            }
            if argument.hasPrefix("\(argumentName)=") {
                let value = argument.dropFirst(argumentName.count + 1)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }

    private static func directoryURL(_ raw: String?) -> URL? {
        guard let raw = nonEmpty(raw) else { return nil }
        return URL(
            fileURLWithPath: (raw as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func qaDefaultsSuite(_ raw: String?) -> String? {
        guard let suite = nonEmpty(raw) else { return nil }
        guard suite.hasPrefix("dev.tjzhou.QuotaMonitor."),
              suite != "dev.tjzhou.QuotaMonitor" else {
            return invalidQADefaultsSuite
        }
        return suite
    }

    private static func stepNames(_ raw: String?) -> [String]? {
        guard let raw = nonEmpty(raw) else { return nil }
        return raw.split(separator: ",")
            .compactMap { nonEmpty(String($0)) }
    }

    private struct LaunchConfigurationFile: Decodable {
        let mode: Bool?
        let home: String?
        let defaultsSuite: String?
        let outputDirectory: String?
        let codexHome: String?
        let steps: [String]?
    }
}
