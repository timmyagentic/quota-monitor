import CoreFoundation
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Anonymous version reporting runtime gate")
struct AnonymousVersionReportingRuntimeTests {
    @Test("Only a real CFBoolean true approves App Store reporting")
    func appStoreGateRejectsMissingFalseAndMistypedValues() {
        let values: [Any?] = [nil, false, "true", 1, NSNumber(value: 1)]

        for value in values {
            var info: [String: Any] = [
                DistributionChannel.infoDictionaryKey: DistributionChannel.appStore.rawValue,
            ]
            if let value {
                info[AnonymousVersionReportingRuntime.appStoreApprovalInfoKey] = value
            }

            #expect(AnonymousVersionReportingRuntime.isAppStoreReportingApproved(
                infoDictionary: info) == false)
            #expect(AnonymousVersionReportingRuntime.resolveContext(
                version: "0.2.41",
                appCodeName: "QuotaMonitor",
                infoDictionary: info,
                environment: [:]) == nil)
        }
    }

    @Test("A real CFBoolean true approves App Store reporting")
    func appStoreGateAcceptsOnlyBooleanTrue() {
        let info: [String: Any] = [
            DistributionChannel.infoDictionaryKey: DistributionChannel.appStore.rawValue,
            AnonymousVersionReportingRuntime.appStoreApprovalInfoKey: kCFBooleanTrue as Any,
        ]

        #expect(AnonymousVersionReportingRuntime.isAppStoreReportingApproved(
            infoDictionary: info))
        #expect(AnonymousVersionReportingRuntime.resolveContext(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: info,
            environment: [:]) == DailyActiveReportingContext(
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "app-store"))
    }

    @Test("Developer ID reporting never requires the App Store approval key")
    func developerIDDoesNotRequireAppStoreApproval() {
        let info: [String: Any] = [
            DistributionChannel.infoDictionaryKey: DistributionChannel.developerID.rawValue,
        ]

        #expect(AnonymousVersionReportingRuntime.resolveContext(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: info,
            environment: [:]) == DailyActiveReportingContext(
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id"))
    }

    @Test("Runtime context stays strict for version, brand, and distribution")
    func invalidRuntimeMetadataFailsClosed() {
        let validInfo: [String: Any] = [
            DistributionChannel.infoDictionaryKey: DistributionChannel.developerID.rawValue,
        ]

        #expect(AnonymousVersionReportingRuntime.resolveContext(
            version: "unknown",
            appCodeName: "QuotaMonitor",
            infoDictionary: validInfo,
            environment: [:]) == nil)
        #expect(AnonymousVersionReportingRuntime.resolveContext(
            version: "0.2.41",
            appCodeName: "UnknownMonitor",
            infoDictionary: validInfo,
            environment: [:]) == nil)
        #expect(AnonymousVersionReportingRuntime.resolveContext(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: [:],
            environment: [:]) == nil)
    }

    @Test("Settings visibility allows production and active QA but hides malformed QA")
    func settingsVisibilityHonorsRuntimeAndQAState() {
        let context = DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id")

        #expect(AnonymousVersionReportingRuntime.shouldShowSettings(
            context: context,
            isQARequested: false,
            isQAActive: false))
        #expect(AnonymousVersionReportingRuntime.shouldShowSettings(
            context: context,
            isQARequested: true,
            isQAActive: true))
        #expect(AnonymousVersionReportingRuntime.shouldShowSettings(
            context: context,
            isQARequested: true,
            isQAActive: false) == false)
        #expect(AnonymousVersionReportingRuntime.shouldShowSettings(
            context: nil,
            isQARequested: false,
            isQAActive: false) == false)
    }
}
