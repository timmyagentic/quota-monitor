import CoreFoundation
import Foundation

enum AnonymousVersionReportingRuntime {
    static let appStoreApprovalInfoKey =
        "QMAnonymousVersionReportingAppStoreApproved"

    static func isAppStoreReportingApproved(
        infoDictionary: [String: Any]?
    ) -> Bool {
        guard let value = infoDictionary?[appStoreApprovalInfoKey] else {
            return false
        }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return false }
        return object === kCFBooleanTrue
    }

    static func resolveContext(
        version: String,
        appCodeName: String,
        infoDictionary: [String: Any]?,
        environment: [String: String]
    ) -> DailyActiveReportingContext? {
        DailyActiveReportingContext.resolve(
            version: version,
            appCodeName: appCodeName,
            infoDictionary: infoDictionary,
            environment: environment,
            appStoreReportingAllowed: isAppStoreReportingApproved(
                infoDictionary: infoDictionary))
    }

    static func shouldShowSettings(
        context: DailyActiveReportingContext?,
        isQARequested: Bool,
        isQAActive: Bool
    ) -> Bool {
        guard context != nil else { return false }
        return !isQARequested || isQAActive
    }
}
