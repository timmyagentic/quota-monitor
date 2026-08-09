import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Localized date formatter cache", .serialized)
struct LocalizedDateFormattingTests {
    private let referenceDate = Date(timeIntervalSince1970: 1_754_755_200)
    private let formattedDate = Date(timeIntervalSince1970: 1_754_755_200 + 7_200)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("runtime language switching preserves relative and absolute formatting")
    func runtimeLanguageSwitching() {
        let englishBefore = LocalizationTestSupport.withLanguage(.english) {
            formattedValues()
        }
        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            formattedValues()
        }
        let englishAfter = LocalizationTestSupport.withLanguage(.english) {
            formattedValues()
        }

        #expect(englishBefore.relative == "in 2 hr.")
        #expect(chinese.relative == "2小时后")
        #expect(englishBefore.relative == legacyRelative(language: .english))
        #expect(chinese.relative == legacyRelative(language: .simplifiedChinese))
        #expect(englishBefore.shortDate == legacyAbsolute(
            language: .english,
            timeStyle: .short))
        #expect(englishBefore.mediumDate == legacyAbsolute(
            language: .english,
            timeStyle: .medium))
        #expect(chinese.shortDate == legacyAbsolute(
            language: .simplifiedChinese,
            timeStyle: .short))
        #expect(chinese.mediumDate == legacyAbsolute(
            language: .simplifiedChinese,
            timeStyle: .medium))
        #expect(englishAfter.relative == englishBefore.relative)
        #expect(englishAfter.shortDate == englishBefore.shortDate)
        #expect(englishAfter.mediumDate == englishBefore.mediumDate)
    }

    @Test("repeated renders construct one formatter per language and style")
    func repeatedRendersReuseFormatters() {
        let cache = LocalizedDateFormatterCache()
        let languageSequence: [LocalizationStore.Language] = [
            .english,
            .simplifiedChinese,
            .english,
        ]

        for language in languageSequence {
            for _ in 0..<25 {
                _ = cache.relativeString(
                    for: formattedDate,
                    relativeTo: referenceDate,
                    language: language,
                    timeZone: utc)
                for style in LocalizedDateFormatting.AbsoluteStyle.allCases {
                    _ = cache.string(
                        from: referenceDate,
                        style: style,
                        language: language,
                        timeZone: utc)
                }
            }
        }

        #expect(cache.constructionCounts.relative == 2)
        #expect(cache.constructionCounts.absolute ==
            LocalizedDateFormatting.AbsoluteStyle.allCases.count * 2)
        #expect(cache.constructionCounts.total ==
            LocalizedDateFormatting.AbsoluteStyle.allCases.count * 2 + 2)
    }

    @Test("component styles follow the requested app language")
    func componentStylesFollowAppLanguage() {
        let styles: [(LocalizedDateFormatting.AbsoluteStyle, String)] = [
            (.monthDayShortTime, "MMMdhm"),
            (.timeWithSeconds, "hms"),
            (.abbreviatedWeekdayMonthDay, "EEEMMMd"),
            (.fullWeekdayMonthDayYear, "EEEEMMMMdyyyy"),
            (.shortTime, "hm"),
            (.yearMonthDay, "yyyyMMMd"),
            (.monthDay, "MMMd"),
        ]

        for (style, template) in styles {
            let english = LocalizationTestSupport.withLanguage(.english) {
                LocalizedDateFormatting.string(
                    from: referenceDate,
                    style: style,
                    timeZone: utc)
            }
            let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
                LocalizedDateFormatting.string(
                    from: referenceDate,
                    style: style,
                    timeZone: utc)
            }

            #expect(english == localizedTemplate(
                template,
                language: .english))
            #expect(chinese == localizedTemplate(
                template,
                language: .simplifiedChinese))
            #expect(english != chinese)
        }
    }

    @Test("date-heavy surfaces use the app-language formatter")
    func dateHeavySurfacesUseAppLanguageFormatter() throws {
        let paths = [
            "QuotaMonitor/Features/Sessions/SessionDetailView.swift",
            "QuotaMonitor/Features/History/HistoryView.swift",
            "QuotaMonitor/Features/Dashboard/Sections/ActivityHeatmap.swift",
            "QuotaMonitor/Features/Dashboard/Sections/TrendsSection.swift",
        ]

        for path in paths {
            let source = try sourceFile(path)
            #expect(source.contains("LocalizedDateFormatting.string"))
            #expect(!source.contains(".formatted(.dateTime"))
        }
    }

    @Test("formatter caches follow the requested time zone")
    func timeZoneIsPartOfCacheKey() throws {
        let cache = LocalizedDateFormatterCache()
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let utcValue = cache.string(
            from: referenceDate,
            style: .mediumDateShortTime,
            language: .english,
            timeZone: utc)
        let losAngelesValue = cache.string(
            from: referenceDate,
            style: .mediumDateShortTime,
            language: .english,
            timeZone: losAngeles)
        let utcRelative = cache.relativeString(
            for: formattedDate,
            relativeTo: referenceDate,
            language: .english,
            timeZone: utc)
        let losAngelesRelative = cache.relativeString(
            for: formattedDate,
            relativeTo: referenceDate,
            language: .english,
            timeZone: losAngeles)

        #expect(utcValue == legacyAbsolute(
            language: .english,
            timeStyle: .short,
            timeZone: utc))
        #expect(losAngelesValue == legacyAbsolute(
            language: .english,
            timeStyle: .short,
            timeZone: losAngeles))
        #expect(utcRelative == legacyRelative(language: .english, timeZone: utc))
        #expect(losAngelesRelative == legacyRelative(
            language: .english,
            timeZone: losAngeles))
        #expect(utcValue != losAngelesValue)
        #expect(cache.constructionCounts.absolute == 2)
        #expect(cache.constructionCounts.relative == 2)
    }

    private func formattedValues() -> (relative: String, shortDate: String, mediumDate: String) {
        (
            relative: LocalizedDateFormatting.relativeString(
                for: formattedDate,
                relativeTo: referenceDate,
                timeZone: utc),
            shortDate: LocalizedDateFormatting.string(
                from: referenceDate,
                style: .mediumDateShortTime,
                timeZone: utc),
            mediumDate: LocalizedDateFormatting.string(
                from: referenceDate,
                style: .mediumDateMediumTime,
                timeZone: utc)
        )
    }

    private func legacyAbsolute(
        language: LocalizationStore.Language,
        timeStyle: DateFormatter.Style,
        timeZone: TimeZone? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timeZone ?? utc
        formatter.dateStyle = .medium
        formatter.timeStyle = timeStyle
        return formatter.string(from: referenceDate)
    }

    private func legacyRelative(
        language: LocalizationStore.Language,
        timeZone: TimeZone? = nil
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .short
        if var calendar = formatter.calendar {
            calendar.timeZone = timeZone ?? utc
            formatter.calendar = calendar
        }
        return formatter.localizedString(for: formattedDate, relativeTo: referenceDate)
    }

    private func localizedTemplate(
        _ template: String,
        language: LocalizationStore.Language
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: referenceDate)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
