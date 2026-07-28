import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Update check intent")
struct UpdateCheckIntentTests {
    @Test("Manual checks present checking UI by default")
    func manualChecksPresentCheckingUI() {
        let intent = UpdateCheckIntent()

        #expect(intent.presentsCheckingUI)
    }

    @Test("Badge rediscovery stays quiet and installs exactly once")
    func badgeRediscoveryIsConsumedOnce() {
        var intent = UpdateCheckIntent()

        intent.requestDirectInstall()

        #expect(!intent.presentsCheckingUI)
        #expect(intent.consumeDiscovery() == .installAvailableUpdate)
        #expect(intent.consumeDiscovery() == .manual)
        #expect(intent.presentsCheckingUI)
    }

    @Test("Terminal results reset a pending badge request")
    func terminalResultResetsPendingRequest() {
        var intent = UpdateCheckIntent()
        intent.requestDirectInstall()

        intent.reset()

        #expect(intent.consumeDiscovery() == .manual)
    }

    @Test("Persisted badge clicks arm a quiet rediscovery before checking")
    func updaterRoutesPersistedBadgeThroughDirectIntent() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/UpdaterController.swift")
        let install = try Self.methodBody(
            source, signature: "func installAvailableUpdate()")
        let fallback = try #require(
            install.range(of: "userDriver?.prepareDirectInstallRediscovery()"))
        let check = try #require(
            install.range(of: "updater?.checkForUpdates()"))

        #expect(fallback.lowerBound < check.lowerBound)
    }

    private static func methodBody(_ source: String, signature: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw CocoaError(.formatting)
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
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
