import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Updater background checks")
struct UpdaterBackgroundCheckTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("A missing last check requests a background check")
    func missingLastCheck() {
        #expect(UpdaterController.shouldCheckInBackground(
            lastUpdateCheckDate: nil,
            now: now))
    }

    @Test("Six hours or less does not request another check")
    func withinThreshold() {
        let sixHours = TimeInterval(6 * 60 * 60)

        #expect(!UpdaterController.shouldCheckInBackground(
            lastUpdateCheckDate: now.addingTimeInterval(-sixHours),
            now: now))
        #expect(!UpdaterController.shouldCheckInBackground(
            lastUpdateCheckDate: now.addingTimeInterval(-sixHours + 1),
            now: now))
    }

    @Test("More than six hours requests another check")
    func beyondThreshold() {
        let sixHours = TimeInterval(6 * 60 * 60)

        #expect(UpdaterController.shouldCheckInBackground(
            lastUpdateCheckDate: now.addingTimeInterval(-sixHours - 1),
            now: now))
    }

    @Test("A disabled updater safely ignores lifecycle checks")
    func disabledUpdaterNoOp() {
        let runtime = UpdaterController.RuntimeConfiguration(
            updateAvailability: PersistentUpdateAvailability(
                defaults: .standard,
                currentInternalVersion: "1",
                persistenceEnabled: false),
            sparkleEnabled: false)
        let updater = UpdaterController(runtimeConfiguration: runtime)

        updater.checkInBackgroundIfNeeded(now: now)
        #expect(!updater.canCheckForUpdates)
    }

    @Test("Lifecycle checks preserve the automatic-check preference")
    func automaticCheckPreferenceIsRequired() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/UpdaterController.swift")

        #expect(source.contains(
            "guard let updater,\n              updater.automaticallyChecksForUpdates,"))
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
