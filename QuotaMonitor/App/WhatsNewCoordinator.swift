import Foundation

enum WhatsNewAutomaticPresentationDecision: Equatable {
    /// No automatic work. Manual preview remains available.
    case none
    /// A fresh user is already learning the app through onboarding. Suppress
    /// this campaign permanently so it does not appear as a stale update tour
    /// on their second launch.
    case markHandledWithoutPresenting
    /// Wait until the user deliberately interacts with the menu-bar app. This
    /// keeps login-item launches from stealing focus.
    case presentOnNextUserInteraction
}

enum WhatsNewPresentationPolicy {
    static func decision(
        campaignID: String?,
        autoPresent: Bool,
        handledCampaignIDs: Set<String>,
        onboardingNeeded: Bool,
        isLocalQA: Bool
    ) -> WhatsNewAutomaticPresentationDecision {
        guard let campaignID, !campaignID.isEmpty, autoPresent else {
            return .none
        }
        guard !isLocalQA else {
            // Explicit `open-whats-new` QA previews must not mutate copied
            // product preferences or compete with other preview windows.
            return .none
        }
        guard !handledCampaignIDs.contains(campaignID) else { return .none }
        if onboardingNeeded {
            return .markHandledWithoutPresenting
        }
        return .presentOnNextUserInteraction
    }
}

@MainActor
final class WhatsNewPresentationStore {
    private static let handledCampaignsKey =
        "whatsNew.handledCampaignIDs"
    private static let legacyLastHandledCampaignKey =
        "whatsNew.lastHandledCampaignID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var handledCampaignIDs: Set<String> {
        var handled = Set(defaults.stringArray(
            forKey: Self.handledCampaignsKey) ?? [])
        if let legacy = defaults.string(
            forKey: Self.legacyLastHandledCampaignKey) {
            handled.insert(legacy)
        }
        return handled
    }

    func hasHandled(_ campaignID: String) -> Bool {
        handledCampaignIDs.contains(campaignID)
    }

    func markHandled(_ campaignID: String) {
        var handled = handledCampaignIDs
        handled.insert(campaignID)
        defaults.set(handled.sorted(), forKey: Self.handledCampaignsKey)
        // Keep writing the original single-value key so prerelease builds and
        // rollbacks still recognize the most recently handled campaign.
        defaults.set(campaignID, forKey: Self.legacyLastHandledCampaignKey)
    }
}

/// Coordinates one-time automatic presentation without owning the window.
/// `WindowManager` remains the sole AppKit window owner.
@MainActor
final class WhatsNewCoordinator {
    private let campaignID: String?
    private let store: WhatsNewPresentationStore
    private let present: @MainActor () -> Void
    private let persistsPresentation: Bool
    private var isPending = false

    init(
        content: WhatsNewContent?,
        defaults: UserDefaults,
        onboardingNeeded: Bool,
        isLocalQA: Bool,
        present: @escaping @MainActor () -> Void = {
            WindowManager.shared.show("whats-new")
        }
    ) {
        let store = WhatsNewPresentationStore(defaults: defaults)
        self.store = store
        self.campaignID = content?.campaign.id
        self.present = present
        self.persistsPresentation = !isLocalQA

        let decision = WhatsNewPresentationPolicy.decision(
            campaignID: content?.campaign.id,
            autoPresent: content?.campaign.autoPresent ?? false,
            handledCampaignIDs: store.handledCampaignIDs,
            onboardingNeeded: onboardingNeeded,
            isLocalQA: isLocalQA)
        switch decision {
        case .none:
            break
        case .markHandledWithoutPresenting:
            if let campaignID = content?.campaign.id {
                store.markHandled(campaignID)
            }
        case .presentOnNextUserInteraction:
            isPending = true
        }
    }

    /// Returns true when the interaction was consumed by the showcase.
    @discardableResult
    func presentPendingIfNeeded() -> Bool {
        guard isPending, campaignID != nil else { return false }
        // Persist at the moment presentation is requested. A crash or force-quit
        // should not turn the showcase into a launch-time nag; users can always
        // reopen it manually from the menu popover or Settings.
        recordPresentationRequested()
        present()
        return true
    }

    /// Called for every presentation route, including permanent manual links.
    /// This consumes an automatic pending campaign so manually reviewing it
    /// cannot make the same showcase appear again on the next status-item click.
    func recordPresentationRequested() {
        isPending = false
        guard persistsPresentation, let campaignID else { return }
        store.markHandled(campaignID)
    }
}
