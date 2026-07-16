import AppKit

enum AnonymousVersionReportingDisclosure {
    @MainActor
    static func present() async -> AnonymousVersionReportingDisclosureChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.anonymousVersionReportingDisclosureTitle
        alert.informativeText = L10n.anonymousVersionReportingDisclosureMessage
        alert.addButton(withTitle: L10n.anonymousVersionReportingAllowButton)
        alert.addButton(withTitle: L10n.anonymousVersionReportingNotNowButton)
        return alert.runModal() == .alertFirstButtonReturn ? .allow : .notNow
    }
}
