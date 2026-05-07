import Foundation
import Testing
@testable import QuotaMonitor

/// Locks down the three pace-verdict shapes (`On pace` / `X% in deficit
/// [· Runs out in …]` / `X% in reserve`) plus their Simplified-Chinese
/// translations. Catches:
///   - regressions where a new branch (e.g. a 4th severity tier) gets
///     added without touching `L10n`,
///   - English-only literals creeping back into `QuotaPaceLabel.swift`,
///   - the percent rounding rule (`.rounded()`, not truncation — a 1.789
///     ratio must read "79%", not "78%"),
///   - duration-unit i18n in `formatDuration` (the `d/h/m` letters must
///     swap to 天/小时/分 under zh).
///
/// `LocalizationStore.activeLanguage` is the lock-guarded read path used
/// by `L10n.t`. We flip it directly via `activeLanguageBytes.withLock`
/// (the same primitive that `set(_:)` uses on MainActor) so we don't
/// have to bring up the @Observable singleton, and we restore the
/// previous value in a defer to keep tests order-independent.
///
/// **Why `.serialized`.** swift-testing parallelizes tests within a suite
/// by default. Because all tests here mutate the process-global
/// `activeLanguage` lock byte, parallel runs let one test's "Chinese"
/// flip leak into another test's "English" assertion (and vice versa).
/// The suite is cheap (microseconds), serializing it is the right call.
@Suite("QuotaPaceLabel verdicts", .serialized)
struct QuotaPaceLabelTests {

    // MARK: helpers

    private func withLanguage<T>(_ lang: LocalizationStore.Language,
                                 _ body: () -> T) -> T {
        let previous = LocalizationStore.activeLanguage
        LocalizationStore.activeLanguageBytes.withLock { $0 = lang }
        defer { LocalizationStore.activeLanguageBytes.withLock { $0 = previous } }
        return body()
    }

    // MARK: cold-start gating

    @Test("usedPercent < 3 yields no label (cold start signal too weak)")
    func coldStartHidden() {
        let r = QuotaPaceLabel.make(usedPercent: 2.0,
                                    paceRatio: 5.0,
                                    timeUntilReset: 3600)
        #expect(r == nil)
    }

    @Test("missing / non-finite paceRatio yields no label")
    func missingPace() {
        #expect(QuotaPaceLabel.make(usedPercent: 50,
                                    paceRatio: nil,
                                    timeUntilReset: 3600) == nil)
        #expect(QuotaPaceLabel.make(usedPercent: 50,
                                    paceRatio: .infinity,
                                    timeUntilReset: 3600) == nil)
        #expect(QuotaPaceLabel.make(usedPercent: 50,
                                    paceRatio: 0,
                                    timeUntilReset: 3600) == nil)
    }

    // MARK: on pace

    @Test("ratio in [0.85, 1.15] reads 'On pace' / '节奏正常'")
    func onPaceBothLanguages() {
        let en = withLanguage(.english) {
            QuotaPaceLabel.make(usedPercent: 25, paceRatio: 1.0, timeUntilReset: 3600)
        }
        #expect(en?.text == "On pace")
        #expect(en?.severity == .neutral)

        let zh = withLanguage(.simplifiedChinese) {
            QuotaPaceLabel.make(usedPercent: 25, paceRatio: 1.0, timeUntilReset: 3600)
        }
        #expect(zh?.text == "节奏正常")
        #expect(zh?.severity == .neutral)
    }

    // MARK: deficit (with ETA)

    @Test("ratio > 1.15 with ETA before reset includes 'Runs out in …'")
    func deficitWithEtaEnglish() {
        // usedPercent=50, ratio=2.0 → elapsedFraction = 0.25, windowLen = 4*timeUntilReset.
        // ETA-from-start = windowLen / 2 = 2*timeUntilReset; etaFromNow =
        // 2*timeUntilReset − 1*timeUntilReset = timeUntilReset → exactly at
        // reset → projection guard rejects it. Use ratio=1.8 instead so the
        // ETA lands strictly inside the remaining window.
        let r = withLanguage(.english) {
            QuotaPaceLabel.make(usedPercent: 50, paceRatio: 1.8, timeUntilReset: 3600)
        }
        // 80% deficit → "80% in deficit · Runs out in …"
        #expect(r?.text.hasPrefix("80% in deficit · Runs out in ") == true)
        #expect(r?.severity == .danger)   // > 50% deficit ⇒ danger
    }

    @Test("Chinese deficit-with-eta uses 超出节奏 N% · 预计 X后耗尽 + 中文单位")
    func deficitWithEtaChinese() {
        let r = withLanguage(.simplifiedChinese) {
            QuotaPaceLabel.make(usedPercent: 50, paceRatio: 1.8, timeUntilReset: 3600)
        }
        let txt = r?.text ?? ""
        #expect(txt.hasPrefix("超出节奏 80% · 预计 "))
        #expect(txt.hasSuffix("后耗尽"))
        // formatDuration always emits at least one of 天/小时/分 under zh.
        #expect(txt.contains("天") || txt.contains("小时") || txt.contains("分"))
    }

    @Test("deficit ≤ 50% is .warning, > 50% is .danger")
    func deficitSeverityBreakpoint() {
        // ratio 1.4 → 40% deficit → warning
        let warn = QuotaPaceLabel.make(usedPercent: 50,
                                       paceRatio: 1.4,
                                       timeUntilReset: 3600)
        #expect(warn?.severity == .warning)

        // ratio 1.8 → 80% deficit → danger
        let danger = QuotaPaceLabel.make(usedPercent: 50,
                                         paceRatio: 1.8,
                                         timeUntilReset: 3600)
        #expect(danger?.severity == .danger)
    }

    // MARK: deficit (no ETA — only reachable on overshoot)

    @Test("deficit-no-ETA fallback (overshoot path) localizes prefix only")
    func deficitNoEtaOvershoot() {
        // `etaToHundred` returns nil only when `elapsedFraction >= 1`
        // (i.e. usedPercent / ratio >= 100), which in practice means the
        // user has overshot 100% — the projection guard refuses to
        // produce an ETA. This branch is rare but reachable; pin both
        // languages so the bare-prefix path never reverts to a hardcoded
        // English literal.
        let en = withLanguage(.english) {
            QuotaPaceLabel.make(usedPercent: 100, paceRatio: 1.5, timeUntilReset: 3600)
        }
        #expect(en?.text == "50% in deficit")
        #expect(en?.severity == .warning)

        let zh = withLanguage(.simplifiedChinese) {
            QuotaPaceLabel.make(usedPercent: 100, paceRatio: 1.5, timeUntilReset: 3600)
        }
        #expect(zh?.text == "超出节奏 50%")
    }

    // MARK: reserve

    @Test("ratio < 0.85 reads 'X% in reserve' / '节余 X%'")
    func reserveBothLanguages() {
        // ratio=0.61 → 39% reserve (matches user-reported screenshot value)
        let en = withLanguage(.english) {
            QuotaPaceLabel.make(usedPercent: 30, paceRatio: 0.61, timeUntilReset: 3600)
        }
        #expect(en?.text == "39% in reserve")
        #expect(en?.severity == .good)

        let zh = withLanguage(.simplifiedChinese) {
            QuotaPaceLabel.make(usedPercent: 30, paceRatio: 0.61, timeUntilReset: 3600)
        }
        #expect(zh?.text == "节余 39%")
        #expect(zh?.severity == .good)
    }

    // MARK: percent rounding

    @Test("percent rounds (not truncates): ratio 1.789 → '79%' not '78%'")
    func percentRoundingNotTruncation() {
        let r = withLanguage(.english) {
            QuotaPaceLabel.make(usedPercent: 50, paceRatio: 1.789, timeUntilReset: 3600)
        }
        // The user's reported screenshot showed "79% in deficit"; truncation
        // would have produced "78%". Pin the rounding contract.
        #expect(r?.text.hasPrefix("79% in deficit") == true)
    }
}
