import Foundation
import Testing

/// Locks the persistent update badge's self-heal contract in `CustomUserDriver`:
///
///   - A *transient* updater error (`showUpdaterError`, e.g. the appcast is
///     briefly unreachable / rate-limited) must NOT clear the badge, so a
///     known-available update doesn't vanish on a network blip.
///   - A *definitive* "no update found" (`showUpdateNotFoundWithError`, Sparkle
///     fetched the appcast and there is genuinely nothing newer) MUST clear the
///     badge, so a stale affordance self-heals instead of lingering forever.
///
/// Asserted structurally (source-level) to match this repo's GUI-free test
/// convention — the driver's real paths build an `NSWindow`, which can't run in
/// a headless test environment.
@Suite("Update badge self-heal")
struct CustomUserDriverBadgeSelfHealTests {

    @Test("Transient errors preserve the badge; only a definitive not-found clears it")
    func badgeSelfHealsOnlyOnDefinitiveNotFound() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/CustomUserDriver.swift")

        let transientError = try Self.methodBody(source, signature: "func showUpdaterError")
        #expect(!transientError.contains("updateAvailability.clear()"))

        let definitiveNotFound = try Self.methodBody(
            source, signature: "func showUpdateNotFoundWithError")
        #expect(definitiveNotFound.contains("updateAvailability.clear()"))
    }

    /// The slice of `source` from `signature` up to the next method declaration.
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
