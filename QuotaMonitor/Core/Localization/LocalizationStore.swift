import Foundation
import SwiftUI
import Observation
import os

/// Runtime locale switcher.
///
/// **Why we don't use the system `AppleLanguages` UserDefault.**
/// Setting `AppleLanguages` requires a relaunch to take effect, and the
/// product spec is "switch language → UI updates immediately, no
/// restart, no menu-bar flicker." So we maintain our own `language`
/// state and dispatch every UI string through `L10n` which reads from
/// `LocalizationStore.currentLanguage`. Mutating the language re-fires
/// every `@Observable` reader → SwiftUI redraws. We also bump
/// `tickForceRedraw` so views can `@Environment(LocalizationStore.self)`
/// and re-evaluate their bodies — without that, `Text(L10n.foo)` would
/// not re-render because `L10n.foo` is a static read SwiftUI can't track.
///
/// **Persistence.** UserDefaults `app.language` ("en" / "zh-Hans"). On
/// first launch the field is nil and `OnboardingView` forces
/// the user to pick before they see the rest of the app.
///
/// **Concurrency.** `LocalizationStore` is `@MainActor` because the
/// observable change notifications must be delivered on main. But the
/// raw language read (`L10n.t`) needs to be callable from any context
/// SwiftUI evaluates a `Text` from — including non-isolated property
/// initializers. So the read path goes through a nonisolated `OSAllocatedUnfairLock`
/// -guarded static, written on every `set(_:)`. Treat the lock-backed
/// global as the source of truth for *what character bytes to render*;
/// treat the `@Observable language` as the source of truth for
/// *triggering redraws*. They are kept consistent in `set(_:)`.
///
/// **Why not String Catalog (.xcstrings).** Dev box has Command Line
/// Tools only, no Xcode. `.xcstrings` is editable as JSON but the SPM
/// resource pipeline for it is fragile under CLT. Plain Swift dict is
/// type-safe at the call site (see `L10n`), zero filesystem IO, and the
/// translation surface is small enough that a Swift file is fine. If we
/// ever go App Store with a real translation team, swap `L10n.t` for a
/// String Catalog without changing call sites.
@MainActor
@Observable
final class LocalizationStore {
    static let shared = LocalizationStore()

    enum Language: String, CaseIterable, Identifiable, Sendable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"

        var id: String { rawValue }

        /// Native name shown in the picker — always rendered in its OWN
        /// language so a user who can't read the current UI language
        /// can still find their language.
        var nativeName: String {
            switch self {
            case .english: return "English"
            case .simplifiedChinese: return "简体中文"
            }
        }

        var locale: Locale { Locale(identifier: rawValue) }
    }

    /// `nil` = not yet chosen. The first-launch onboarding sheet only
    /// dismisses after the user picks a value, so any rendering during
    /// onboarding falls through to English (see `currentLanguage`).
    private(set) var language: Language?

    /// Bumped on every `set(_:)`. Views that want to re-render on
    /// language change can read this property as a dependency.
    private(set) var tickForceRedraw: Int = 0

    /// Effective language for rendering. Uses English if onboarding has
    /// not run yet, so the onboarding view itself is readable.
    var currentLanguage: Language { language ?? .english }

    var locale: Locale { currentLanguage.locale }

    /// True iff the user has not yet completed first-launch onboarding.
    var needsOnboarding: Bool { language == nil }

    private let userDefaultsKey = "app.language"
    private let defaults: UserDefaults

    private init() {
        self.defaults = LocalQAEnvironment.userDefaults() ?? .standard
        if let raw = defaults.string(forKey: userDefaultsKey),
           let lang = Language(rawValue: raw) {
            self.language = lang
            Self.activeLanguageBytes.withLock { $0 = lang }
        }
    }

    /// Set + persist. Triggers SwiftUI redraws via `@Observable` (the
    /// `tickForceRedraw` bump is what guarantees views holding an
    /// `@Environment(LocalizationStore.self)` re-evaluate even though
    /// they don't read `language` directly — `L10n.foo` is a plain
    /// static call SwiftUI can't track).
    func set(_ language: Language) {
        Self.activeLanguageBytes.withLock { $0 = language }
        self.language = language
        self.tickForceRedraw &+= 1
        defaults.set(language.rawValue, forKey: userDefaultsKey)
    }

    /// Test/preview hook. To re-trigger first-launch onboarding in
    /// development, delete the UserDefaults key by hand:
    ///   `defaults delete dev.tjzhou.QuotaMonitor app.language`
    func resetForTesting() {
        Self.activeLanguageBytes.withLock { $0 = .english }
        self.language = nil
        self.tickForceRedraw &+= 1
        defaults.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - nonisolated read path

    /// Lock-guarded language byte. Read by `L10n.t` from any isolation
    /// context (View body is MainActor but property initializers and
    /// background formatting code may not be). Writers are exclusively
    /// `set(_:)` / `init` / `resetForTesting()`, all on MainActor.
    nonisolated static let activeLanguageBytes = OSAllocatedUnfairLock(
        initialState: Language.english)

    /// The language `L10n.t` should dispatch on. Safe to call from any
    /// thread; reflects the most recent `set(_:)` immediately.
    nonisolated static var activeLanguage: Language {
        activeLanguageBytes.withLock { $0 }
    }
}
