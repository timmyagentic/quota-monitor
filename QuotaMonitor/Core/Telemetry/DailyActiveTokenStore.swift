import Foundation
import Security

struct DailyActiveTokenRecord: Codable, Equatable, Sendable {
    let day: String
    let token: String
}

private struct DailyActiveSuccessRecord: Codable, Equatable, Sendable {
    let day: String
    let version: String
    let brand: String
    let channel: String
}

/// `UserDefaults` supports concurrent access, but Foundation does not declare
/// it `Sendable`. Keep that unchecked boundary local instead of weakening the
/// token store's actor isolation or retroactively conforming a system type.
struct DailyActiveUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

actor DailyActiveTokenStore {
    typealias RandomBytes = @Sendable () -> [UInt8]?

    static let tokenStorageKey = "telemetry.dailyActiveToken.v1"
    static let successStorageKey = "telemetry.dailyActiveSuccess.v1"
    static let suppressedDayStorageKey = "telemetry.dailyActiveSuppressedDay.v1"

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let defaults: DailyActiveUserDefaults
    private let calendar: Calendar
    private let randomBytes: RandomBytes

    init(
        defaults: DailyActiveUserDefaults = DailyActiveUserDefaults(.standard),
        calendar: Calendar = DailyActiveTokenStore.utcCalendar,
        randomBytes: @escaping RandomBytes = DailyActiveTokenStore.secureRandomBytes
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.randomBytes = randomBytes
    }

    func record(for date: Date = Date()) -> DailyActiveTokenRecord? {
        let day = dayIdentifier(for: date)
        guard !isSuppressed(day: day) else { return nil }
        if let stored = restoredTokenRecord(), stored.day == day {
            return stored
        }

        guard let bytes = randomBytes(), bytes.count == 16 else {
            return nil
        }
        let record = DailyActiveTokenRecord(
            day: day,
            token: Self.base64URLToken(for: bytes))
        guard let data = try? JSONEncoder().encode(record) else {
            return nil
        }
        defaults.value.set(data, forKey: Self.tokenStorageKey)
        return record
    }

    func markSucceeded(
        day: String,
        token: String,
        version: String,
        brand: String,
        channel: String
    ) {
        let expectedToken = DailyActiveTokenRecord(day: day, token: token)
        guard isValid(expectedToken), !isSuppressed(day: day) else { return }
        guard restoredTokenRecord() == expectedToken else { return }
        let record = DailyActiveSuccessRecord(
            day: day,
            version: version,
            brand: brand,
            channel: channel)
        guard isValid(record), let data = try? JSONEncoder().encode(record) else {
            return
        }
        defaults.value.set(data, forKey: Self.successStorageKey)
    }

    func hasSucceeded(
        day: String,
        version: String,
        brand: String,
        channel: String
    ) -> Bool {
        let expected = DailyActiveSuccessRecord(
            day: day,
            version: version,
            brand: brand,
            channel: channel)
        guard isValid(expected) else { return false }
        guard !isSuppressed(day: day) else { return false }
        guard let storedValue = defaults.value.object(forKey: Self.successStorageKey) else {
            return false
        }
        guard
            let data = storedValue as? Data,
            let stored = try? JSONDecoder().decode(DailyActiveSuccessRecord.self, from: data),
            isValid(stored)
        else {
            defaults.value.removeObject(forKey: Self.successStorageKey)
            return false
        }
        return stored == expected
    }

    func clear() {
        defaults.value.removeObject(forKey: Self.suppressedDayStorageKey)
        defaults.value.removeObject(forKey: Self.tokenStorageKey)
        defaults.value.removeObject(forKey: Self.successStorageKey)
    }

    func suppressUntilNextUTCDay(from date: Date = Date()) {
        let day = dayIdentifier(for: date)
        // Persist the suppression boundary before erasing the live state. If
        // the process exits between these writes, the next actor clears any
        // residual token/success before it can be reused.
        defaults.value.set(day, forKey: Self.suppressedDayStorageKey)
        clearLiveRecords()
    }

    private func isSuppressed(day: String) -> Bool {
        guard isValidDay(day) else { return true }
        guard let storedValue = defaults.value.object(
            forKey: Self.suppressedDayStorageKey) else {
            return false
        }
        guard let suppressedDay = storedValue as? String,
              isValidDay(suppressedDay) else {
            defaults.value.set(day, forKey: Self.suppressedDayStorageKey)
            clearLiveRecords()
            return true
        }
        guard day > suppressedDay else {
            clearLiveRecords()
            return true
        }
        defaults.value.removeObject(forKey: Self.suppressedDayStorageKey)
        return false
    }

    private func clearLiveRecords() {
        defaults.value.removeObject(forKey: Self.tokenStorageKey)
        defaults.value.removeObject(forKey: Self.successStorageKey)
    }

    private func restoredTokenRecord() -> DailyActiveTokenRecord? {
        guard let storedValue = defaults.value.object(forKey: Self.tokenStorageKey) else {
            return nil
        }
        guard
            let data = storedValue as? Data,
            let record = try? JSONDecoder().decode(DailyActiveTokenRecord.self, from: data),
            isValid(record)
        else {
            defaults.value.removeObject(forKey: Self.tokenStorageKey)
            return nil
        }
        return record
    }

    private func isValid(_ record: DailyActiveTokenRecord) -> Bool {
        isValidDay(record.day) && Self.isCanonicalToken(record.token)
    }

    private func isValid(_ record: DailyActiveSuccessRecord) -> Bool {
        isValidDay(record.day)
            && record.version.isEmpty == false
            && record.brand.isEmpty == false
            && record.channel.isEmpty == false
    }

    private func isValidDay(_ day: String) -> Bool {
        let components = day.split(separator: "-", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            components[0].count == 4,
            components[1].count == 2,
            components[2].count == 2,
            components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
            let year = Int(components[0]),
            let month = Int(components[1]),
            let dayOfMonth = Int(components[2]),
            (1 ... 9999).contains(year)
        else {
            return false
        }

        let dateComponents = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: dayOfMonth)
        guard let date = calendar.date(from: dateComponents) else { return false }
        return dayIdentifier(for: date) == day
    }

    private func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    private static func base64URLToken(for bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isCanonicalToken(_ token: String) -> Bool {
        guard
            token.utf8.count == 22,
            token.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            })
        else {
            return false
        }

        let base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=="
        guard let data = Data(base64Encoded: base64), data.count == 16 else {
            return false
        }
        return base64URLToken(for: Array(data)) == token
    }

    private static func secureRandomBytes() -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes
    }
}
