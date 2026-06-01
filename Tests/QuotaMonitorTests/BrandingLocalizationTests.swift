import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Branding localization")
struct BrandingLocalizationTests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/QuotaMonitorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    @Test("update-available copy is driven by Branding.appCodeName")
    func updateAvailableCopyUsesBrandingCodeName() throws {
        let sourceURL = Self.repoRoot()
            .appendingPathComponent("QuotaMonitor/Core/Localization/L10n.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let signature = "static func updateVersionAvailable(_ version: String) -> String"
        let start = try #require(source.range(of: signature)?.lowerBound)
        let remainder = source[start...]
        let end = try #require(remainder.range(of: "\n    }\n")?.upperBound)
        let body = String(remainder[..<end])

        #expect(body.contains("Branding.appCodeName"))
        #expect(!body.contains("\"QuotaMonitor \\(version)"))
    }
}
