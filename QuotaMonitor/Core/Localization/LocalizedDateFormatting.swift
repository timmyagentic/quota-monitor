import Foundation

/// Main-actor formatter cache for language-sensitive dates rendered by SwiftUI.
/// Cache keys include the locale and time zone so runtime language or system
/// time-zone changes never reuse a formatter with stale presentation settings.
@MainActor
enum LocalizedDateFormatting {
    enum AbsoluteStyle: Hashable, Sendable {
        case mediumDateShortTime
        case mediumDateMediumTime
    }

    private static let cache = LocalizedDateFormatterCache()

    static func relativeString(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        cache.relativeString(
            for: date,
            relativeTo: referenceDate,
            language: LocalizationStore.activeLanguage,
            timeZone: timeZone)
    }

    static func string(
        from date: Date,
        style: AbsoluteStyle,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        cache.string(
            from: date,
            style: style,
            language: LocalizationStore.activeLanguage,
            timeZone: timeZone)
    }
}

/// Owns mutable Foundation formatters behind main-actor isolation. Keeping this
/// as an instance also lets tests verify cache misses without resetting global
/// production state.
@MainActor
final class LocalizedDateFormatterCache {
    struct ConstructionCounts: Equatable, Sendable {
        fileprivate(set) var relative = 0
        fileprivate(set) var absolute = 0

        var total: Int { relative + absolute }
    }

    private struct LocaleTimeZoneKey: Hashable {
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    private struct AbsoluteKey: Hashable {
        let localeTimeZone: LocaleTimeZoneKey
        let style: LocalizedDateFormatting.AbsoluteStyle
    }

    private var relativeFormatters: [LocaleTimeZoneKey: RelativeDateTimeFormatter] = [:]
    private var absoluteFormatters: [AbsoluteKey: DateFormatter] = [:]
    private(set) var constructionCounts = ConstructionCounts()

    func relativeString(
        for date: Date,
        relativeTo referenceDate: Date,
        language: LocalizationStore.Language,
        timeZone: TimeZone
    ) -> String {
        let key = key(language: language, timeZone: timeZone)
        let formatter: RelativeDateTimeFormatter
        if let cached = relativeFormatters[key] {
            formatter = cached
        } else {
            formatter = RelativeDateTimeFormatter()
            formatter.locale = language.locale
            formatter.unitsStyle = .short
            if var calendar = formatter.calendar {
                calendar.timeZone = timeZone
                formatter.calendar = calendar
            }
            relativeFormatters[key] = formatter
            constructionCounts.relative += 1
        }
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    func string(
        from date: Date,
        style: LocalizedDateFormatting.AbsoluteStyle,
        language: LocalizationStore.Language,
        timeZone: TimeZone
    ) -> String {
        let key = AbsoluteKey(
            localeTimeZone: key(language: language, timeZone: timeZone),
            style: style)
        let formatter: DateFormatter
        if let cached = absoluteFormatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            switch style {
            case .mediumDateShortTime:
                formatter.timeStyle = .short
            case .mediumDateMediumTime:
                formatter.timeStyle = .medium
            }
            absoluteFormatters[key] = formatter
            constructionCounts.absolute += 1
        }
        return formatter.string(from: date)
    }

    private func key(
        language: LocalizationStore.Language,
        timeZone: TimeZone
    ) -> LocaleTimeZoneKey {
        LocaleTimeZoneKey(
            localeIdentifier: language.locale.identifier,
            timeZoneIdentifier: timeZone.identifier)
    }
}
