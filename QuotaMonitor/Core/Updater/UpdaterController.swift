import Foundation
import Sparkle
import Combine

/// Thin SwiftUI-friendly wrapper around Sparkle's `SPUUpdater` using a
/// custom `SPUUserDriver`.  Owned for the lifetime of the app by
/// `QuotaMonitorApp` (single instance) and exposed to views via the
/// SwiftUI Environment so the Settings tab can render a "Check Now"
/// button bound to live availability state and a toggle bound to the
/// scheduled-checks flag.
///
/// **Why a wrapper instead of binding views directly to Sparkle's
/// types.** `SPUUpdater` exposes its mutable state as KVO-observable
/// Objective-C properties (`canCheckForUpdates`, `lastUpdateCheckDate`,
/// `automaticallyChecksForUpdates`). SwiftUI's modern Observation
/// (`@Observable`) doesn't track those automatically — views bound to a
/// raw `SPUUpdater` wouldn't re-render when Sparkle flips the flag at
/// the end of a check. This wrapper bridges KVO → `@Observable` via
/// Combine's `publisher(for:)` so view bodies stay reactive without
/// every call site needing to import Combine.
///
/// **Why we replaced `SPUStandardUpdaterController`.** The standard
/// controller uses Sparkle's built-in system-style update alert, which
/// renders release notes as plain HTML in a fixed WebView.  We swap it
/// for a direct `SPUUpdater` + custom `CustomUserDriver` so the update
/// window can show animated, concise release notes in a WKWebView with
/// our own CSS.
@MainActor
@Observable
final class UpdaterController {
    /// `true` when Sparkle is idle and a new check can start. Mirrors
    /// `SPUUpdater.canCheckForUpdates`. Bound to the "Check Now"
    /// button's `disabled` state so the user can't fire a second check
    /// while one is in flight (Sparkle would no-op anyway, but the
    /// disabled state is the visible cue).
    var canCheckForUpdates: Bool = true

    /// Timestamp of the most recent successful or failed check, or nil
    /// if no check has ever run on this machine. Settings tab shows
    /// "Last checked: <relative date>" off this.
    var lastUpdateCheckDate: Date?

    /// User preference: do automatic background checks on the
    /// SUScheduledCheckInterval cadence (defined in Info.plist; default
    /// 24 h). Mirrors `SPUUpdater.automaticallyChecksForUpdates`, which
    /// itself reads/writes `UserDefaults` key `SUEnableAutomaticChecks`.
    /// Bound to a `Toggle` in Advanced settings.
    var automaticallyChecksForUpdates: Bool = true

    @ObservationIgnored
    private let updater: SPUUpdater?

    @ObservationIgnored
    private let userDriver: CustomUserDriver?

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    init(onUpdateWindowClosed: @escaping @MainActor () -> Void = {}) {
        if DistributionChannel.current == .appStore {
            self.updater = nil
            self.userDriver = nil
            canCheckForUpdates = false
            lastUpdateCheckDate = nil
            automaticallyChecksForUpdates = false
            Log.ui.info("Sparkle disabled for App Store build")
            return
        }

        let driver = CustomUserDriver(
            onUpdateWindowClosed: onUpdateWindowClosed)
        self.userDriver = driver

        let bundle = Bundle.main
        self.updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: nil)

        // Seed @Observable mirrors from current state so the first
        // render after init doesn't briefly show the default-init
        // values before the KVO publishers fire.
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        // Bridge KVO → @Observable. Sparkle fires these on the main
        // queue already, so the `.receive(on:)` hop is defensive
        // rather than strictly required, but it costs nothing and
        // future-proofs against Sparkle changing its callback
        // threading.
        updater.publisher(for: \.canCheckForUpdates, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)

        updater.publisher(for: \.lastUpdateCheckDate, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &cancellables)

        // Start the updater (equivalent to the old
        // `SPUStandardUpdaterController(startingUpdater: true, …)`).
        do {
            try updater.start()
        } catch {
            Log.ui.error("Failed to start Sparkle updater: \(error)")
        }
    }

    /// Whether the custom update window is currently on screen. Lets
    /// `WindowManager` count the Sparkle update window as an app-owned window
    /// when deciding the activation policy, even though it isn't in the
    /// `WindowManager` registry.
    var isUpdateWindowVisible: Bool { userDriver?.isUpdateWindowVisible ?? false }

    /// User-triggered check. Routes through the custom user driver,
    /// which surfaces the SwiftUI update window with animated release
    /// notes + download/install progress. Safe to call repeatedly —
    /// Sparkle dedups internally.
    func checkNow() {
        updater?.checkForUpdates()
    }

    /// Persist the user's automatic-check preference. Writes through
    /// to `SUEnableAutomaticChecks` in UserDefaults and restarts
    /// Sparkle's schedule timer. The KVO publisher then mirrors the
    /// new value back into our `@Observable` property.
    func setAutomaticallyChecks(_ enabled: Bool) {
        guard let updater else {
            automaticallyChecksForUpdates = false
            return
        }
        updater.automaticallyChecksForUpdates = enabled
    }
}
