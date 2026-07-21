import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("What's New presentation")
struct WhatsNewPresentationTests {
    @Test("Existing users receive an unseen important campaign")
    func existingUserGetsPendingCampaign() {
        #expect(decision() == .presentOnNextUserInteraction)
    }

    @Test("The same campaign is not presented twice")
    func handledCampaignDoesNotRepeat() {
        #expect(decision(handled: ["campaign-a"]) == .none)
    }

    @Test("A new important campaign can present after the previous one")
    func newerCampaignPresents() {
        #expect(decision(campaignID: "campaign-b",
                         handled: ["campaign-a"])
            == .presentOnNextUserInteraction)
    }

    @Test("Fresh installs suppress the current campaign permanently")
    func onboardingSuppressionSurvivesRelaunch() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhatsNewPresentationStore(defaults: defaults)

        let firstLaunch = decision(onboardingNeeded: true)
        #expect(firstLaunch == .markHandledWithoutPresenting)
        if firstLaunch == .markHandledWithoutPresenting {
            store.markHandled("campaign-a")
        }

        #expect(decision(handled: store.handledCampaignIDs) == .none)
    }

    @Test("Local QA requires an explicit preview and never writes seen state")
    func localQADoesNotAutoPresent() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhatsNewPresentationStore(defaults: defaults)

        #expect(decision(isLocalQA: true) == .none)
        #expect(store.handledCampaignIDs.isEmpty)
    }

    @Test("First deliberate interaction presents, persists, and consumes pending state")
    func interactionConsumesPendingCampaign() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))
        var presentationCount = 0
        let coordinator = WhatsNewCoordinator(
            content: content,
            defaults: defaults,
            onboardingNeeded: false,
            isLocalQA: false,
            present: { presentationCount += 1 })

        #expect(coordinator.presentPendingIfNeeded())
        #expect(presentationCount == 1)
        #expect(WhatsNewPresentationStore(defaults: defaults)
            .hasHandled(content.campaign.id))
        #expect(!coordinator.presentPendingIfNeeded())
        #expect(presentationCount == 1)
    }

    @Test("Manual presentation consumes pending state without repeating the window")
    func manualPresentationConsumesPendingCampaign() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))
        var automaticPresentationCount = 0
        let coordinator = WhatsNewCoordinator(
            content: content,
            defaults: defaults,
            onboardingNeeded: false,
            isLocalQA: false,
            present: { automaticPresentationCount += 1 })

        coordinator.recordPresentationRequested()

        #expect(WhatsNewPresentationStore(defaults: defaults)
            .hasHandled(content.campaign.id))
        #expect(!coordinator.presentPendingIfNeeded())
        #expect(automaticPresentationCount == 0)
    }

    @Test("Handled campaign history survives later campaigns and rollbacks")
    func handledHistoryPreventsRollbackRepeats() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhatsNewPresentationStore(defaults: defaults)

        store.markHandled("campaign-a")
        store.markHandled("campaign-b")

        #expect(store.handledCampaignIDs == ["campaign-a", "campaign-b"])
        #expect(decision(campaignID: "campaign-a",
                         handled: store.handledCampaignIDs) == .none)
    }

    @Test("Manual Local QA presentation never writes campaign history")
    func manualLocalQAPresentationDoesNotPersist() throws {
        let suite = "WhatsNewPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))
        let coordinator = WhatsNewCoordinator(
            content: content,
            defaults: defaults,
            onboardingNeeded: false,
            isLocalQA: true,
            present: {})

        coordinator.recordPresentationRequested()

        #expect(WhatsNewPresentationStore(defaults: defaults)
            .handledCampaignIDs.isEmpty)
    }

    @Test("Manual-only and missing campaigns never auto-present")
    func nonAutomaticCampaignsStayManual() {
        #expect(decision(autoPresent: false) == .none)
        #expect(decision(campaignID: nil) == .none)
    }

    private func decision(
        campaignID: String? = "campaign-a",
        autoPresent: Bool = true,
        handled: Set<String> = [],
        onboardingNeeded: Bool = false,
        isLocalQA: Bool = false
    ) -> WhatsNewAutomaticPresentationDecision {
        WhatsNewPresentationPolicy.decision(
            campaignID: campaignID,
            autoPresent: autoPresent,
            handledCampaignIDs: handled,
            onboardingNeeded: onboardingNeeded,
            isLocalQA: isLocalQA)
    }

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/")
    }()
}

@Suite("What's New page navigation")
struct WhatsNewPageNavigationTests {
    @Test func navigationStopsAtBothEdges() {
        #expect(WhatsNewPageNavigation.previousIndex(from: 0, pageCount: 3) == 0)
        #expect(WhatsNewPageNavigation.nextIndex(from: 0, pageCount: 3) == 1)
        #expect(WhatsNewPageNavigation.nextIndex(from: 2, pageCount: 3) == 2)
        #expect(WhatsNewPageNavigation.previousIndex(from: 2, pageCount: 3) == 1)
    }

    @Test func emptyCampaignNavigationIsSafe() {
        #expect(WhatsNewPageNavigation.previousIndex(from: 4, pageCount: 0) == 0)
        #expect(WhatsNewPageNavigation.nextIndex(from: 4, pageCount: 0) == 0)
    }
}
