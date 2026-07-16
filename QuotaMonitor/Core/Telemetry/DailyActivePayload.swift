import Foundation

struct DailyActivePayload: Codable, Equatable, Sendable {
    let schema: Int
    let day: String
    let token: String
    let version: String
    let brand: String
    let channel: String

    init?(
        day: String,
        token: String,
        version: String,
        brand: String,
        channel: String
    ) {
        guard
            Self.isValidDay(day),
            Self.isCanonicalToken(token),
            Self.isValidVersion(version),
            Self.allowedBrands.contains(brand),
            Self.allowedChannels.contains(channel)
        else {
            return nil
        }

        schema = 1
        self.day = day
        self.token = token
        self.version = version
        self.brand = brand
        self.channel = channel
    }

    static func utcDay(for date: Date) -> String {
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    static func isValidVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.utf8.count <= 64 else { return false }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty else { return false }
            guard component.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
                return false
            }
            return component.count == 1 || component.first != "0"
        }
    }

    private static let allowedBrands: Set<String> = ["quota-monitor", "codex-monitor"]
    private static let allowedChannels: Set<String> = ["developer-id", "app-store"]

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func isValidDay(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard
            bytes.count == 10,
            bytes[4] == 45,
            bytes[7] == 45,
            bytes.enumerated().allSatisfy({ index, byte in
                index == 4 || index == 7 || (48 ... 57).contains(byte)
            }),
            let year = Int(day.prefix(4)),
            let month = Int(day.dropFirst(5).prefix(2)),
            let dayOfMonth = Int(day.suffix(2)),
            (1 ... 9999).contains(year)
        else {
            return false
        }

        let components = DateComponents(
            timeZone: utcCalendar.timeZone,
            year: year,
            month: month,
            day: dayOfMonth)
        guard let date = utcCalendar.date(from: components) else { return false }
        return utcDay(for: date) == day
    }

    private static func isCanonicalToken(_ token: String) -> Bool {
        guard
            token.utf8.count == 22,
            token.utf8.allSatisfy({ byte in
                (48 ... 57).contains(byte)
                    || (65 ... 90).contains(byte)
                    || (97 ... 122).contains(byte)
                    || byte == 45
                    || byte == 95
            })
        else {
            return false
        }

        let base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=="
        guard let decoded = Data(base64Encoded: base64), decoded.count == 16 else {
            return false
        }
        let canonical = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == token
    }
}

struct DailyActiveReportingContext: Equatable, Sendable {
    let version: String
    let brand: String
    let channel: String

    static func resolve(
        version: String,
        appCodeName: String,
        infoDictionary: [String: Any]?,
        environment: [String: String],
        appStoreReportingAllowed: Bool
    ) -> DailyActiveReportingContext? {
        guard
            DailyActivePayload.isValidVersion(version),
            let brand = Branding.telemetrySlug(forCodeName: appCodeName),
            let distribution = DistributionChannel.telemetryChannel(
                infoDictionary: infoDictionary,
                environment: environment),
            distribution != .appStore || appStoreReportingAllowed
        else {
            return nil
        }

        return DailyActiveReportingContext(
            version: version,
            brand: brand,
            channel: distribution.telemetrySlug)
    }
}
