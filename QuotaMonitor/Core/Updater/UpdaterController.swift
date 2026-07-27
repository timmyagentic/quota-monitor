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
    private static let backgroundCheckInterval = TimeInterval(6 * 60 * 60)

    struct RuntimeConfiguration {
        let updateAvailability: PersistentUpdateAvailability
        let sparkleEnabled: Bool
    }

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

    var updateChannel: UpdateChannel
    var privateBetaEnrolled: Bool
    var privateBetaStatusMessage: String?

    let updateAvailability: PersistentUpdateAvailability

    @ObservationIgnored
    private let updater: SPUUpdater?

    @ObservationIgnored
    private let userDriver: CustomUserDriver?

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let credentialStore: PrivateBetaCredentialStoring

    @ObservationIgnored
    private let enrollmentClient: PrivateBetaEnrollmentClient

    @ObservationIgnored
    private let sparkleDelegate: SparkleUpdateDelegate

    @ObservationIgnored
    private var privateBetaToken: String?

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    init(
        runtimeConfiguration: RuntimeConfiguration? = nil,
        defaults: UserDefaults? = nil,
        credentialStore: PrivateBetaCredentialStoring? = nil,
        enrollmentClient: PrivateBetaEnrollmentClient? = nil,
        onUpdateWindowClosed: @escaping @MainActor () -> Void = {}
    ) {
        let bundle = Bundle.main
        let resolvedDefaults = defaults
            ?? LocalQAEnvironment.userDefaults()
            ?? .standard
        let runtime = runtimeConfiguration ?? Self.makeDefaultRuntimeConfiguration(
            distribution: .current,
            defaults: defaults ?? LocalQAEnvironment.userDefaults(),
            standardDefaults: .standard,
            currentInternalVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            localQARequested: LocalQAEnvironment.isQARequested())
        let resolvedCredentialStore = credentialStore ?? PrivateBetaCredentialStore()
        let storedToken = runtime.sparkleEnabled
            ? resolvedCredentialStore.loadToken()
            : nil
        var selectedChannel = runtime.sparkleEnabled
            ? UpdateChannel(defaults: resolvedDefaults)
            : .stable
        if selectedChannel == .privateBeta && storedToken == nil {
            selectedChannel = .stable
            selectedChannel.persist(to: resolvedDefaults)
        }
        let stableFeedURL = bundle.object(
            forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let privateBetaFeedURL = bundle.object(
            forInfoDictionaryKey: "QMPrivateBetaFeedURL") as? String
            ?? "https://quota-monitor.timmyagentic.com/api/private-beta/appcast.xml"
        let resolvedEnrollmentClient = enrollmentClient ?? PrivateBetaEnrollmentClient(
            endpoint: URL(string:
                "https://quota-monitor.timmyagentic.com/api/private-beta/enroll")!)
        self.defaults = resolvedDefaults
        self.credentialStore = resolvedCredentialStore
        self.enrollmentClient = resolvedEnrollmentClient
        self.privateBetaToken = storedToken
        self.updateChannel = selectedChannel
        self.privateBetaEnrolled = storedToken != nil
        self.sparkleDelegate = SparkleUpdateDelegate(
            stableFeedURL: stableFeedURL,
            privateBetaFeedURL: privateBetaFeedURL,
            channel: selectedChannel)
        self.updateAvailability = runtime.updateAvailability

        guard runtime.sparkleEnabled else {
            self.updater = nil
            self.userDriver = nil
            canCheckForUpdates = false
            lastUpdateCheckDate = nil
            automaticallyChecksForUpdates = false
            Log.ui.info("Sparkle disabled for this runtime")
            return
        }

        let driver = CustomUserDriver(
            updateAvailability: runtime.updateAvailability,
            onUpdateWindowClosed: onUpdateWindowClosed)
        self.userDriver = driver

        self.updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: sparkleDelegate)

        // Seed @Observable mirrors from current state so the first
        // render after init doesn't briefly show the default-init
        // values before the KVO publishers fire.
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        applyUpdateChannelConfiguration(to: updater)

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

    static func makeRuntimeConfiguration(
        distribution: DistributionChannel,
        defaults: UserDefaults,
        currentInternalVersion: String,
        localQARequested: Bool
    ) -> RuntimeConfiguration {
        let isAppStore = distribution == .appStore
        return RuntimeConfiguration(
            updateAvailability: PersistentUpdateAvailability(
                defaults: defaults,
                currentInternalVersion: currentInternalVersion,
                persistenceEnabled: !isAppStore),
            sparkleEnabled: !isAppStore && !localQARequested)
    }

    static func makeDefaultRuntimeConfiguration(
        distribution: DistributionChannel,
        defaults: UserDefaults?,
        standardDefaults: UserDefaults,
        currentInternalVersion: String,
        localQARequested: Bool
    ) -> RuntimeConfiguration {
        guard !localQARequested || defaults != nil else {
            return RuntimeConfiguration(
                updateAvailability: PersistentUpdateAvailability(
                    defaults: standardDefaults,
                    currentInternalVersion: currentInternalVersion,
                    persistenceEnabled: false),
                sparkleEnabled: false)
        }
        return makeRuntimeConfiguration(
            distribution: distribution,
            defaults: defaults ?? standardDefaults,
            currentInternalVersion: currentInternalVersion,
            localQARequested: localQARequested)
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

    /// Lifecycle-triggered check that stays silent unless Sparkle discovers an
    /// update. Sparkle's own 24-hour schedule remains unchanged; this only
    /// catches long gaps while the app was asleep or inactive.
    func checkInBackgroundIfNeeded(now: Date = Date()) {
        guard let updater,
              updater.automaticallyChecksForUpdates,
              updater.canCheckForUpdates,
              Self.shouldCheckInBackground(
                lastUpdateCheckDate: updater.lastUpdateCheckDate,
                now: now) else {
            return
        }
        updater.checkForUpdatesInBackground()
    }

    static func shouldCheckInBackground(
        lastUpdateCheckDate: Date?,
        now: Date
    ) -> Bool {
        guard let lastUpdateCheckDate else { return true }
        return now.timeIntervalSince(lastUpdateCheckDate) > backgroundCheckInterval
    }

    /// Primary action for the persistent update badge. If the Sparkle user
    /// driver still has an active install reply, use it immediately; otherwise
    /// ask Sparkle to re-check, which re-opens the update window for the known
    /// available version.
    func installAvailableUpdate() {
        guard updateAvailability.isVisible else {
            checkNow()
            return
        }
        if userDriver?.installAvailableUpdateIfPossible() == true {
            return
        }
        checkNow()
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

    func setUpdateChannel(_ channel: UpdateChannel, checkImmediately: Bool = true) {
        if channel == .privateBeta && privateBetaToken == nil {
            privateBetaStatusMessage = L10n.privateBetaEnrollmentRequired
            return
        }
        updateChannel = channel
        channel.persist(to: defaults)
        sparkleDelegate.channel = channel
        if let updater {
            applyUpdateChannelConfiguration(to: updater)
            updater.resetUpdateCycle()
            if checkImmediately && updater.canCheckForUpdates {
                updater.checkForUpdates()
            }
        }
        privateBetaStatusMessage = nil
    }

    func enrollPrivateBeta(code: String) async {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalizedCode.isEmpty else {
            privateBetaStatusMessage = L10n.privateBetaEnrollmentRequired
            return
        }
        do {
            let enrollment = try await enrollmentClient.enroll(
                code: normalizedCode,
                deviceLabel: Host.current().localizedName ?? "Mac")
            try credentialStore.saveToken(enrollment.token)
            privateBetaToken = enrollment.token
            privateBetaEnrolled = true
            setUpdateChannel(.privateBeta)
            privateBetaStatusMessage = L10n.privateBetaEnrollmentSucceeded
        } catch {
            privateBetaStatusMessage = error.localizedDescription
        }
    }

    func leavePrivateBeta() {
        setUpdateChannel(.stable)
        do {
            try credentialStore.deleteToken()
            privateBetaToken = nil
            privateBetaEnrolled = false
            privateBetaStatusMessage = nil
        } catch {
            privateBetaStatusMessage = error.localizedDescription
        }
    }

    private func applyUpdateChannelConfiguration(to updater: SPUUpdater) {
        if updateChannel == .privateBeta, let privateBetaToken {
            updater.httpHeaders = ["Authorization": "Bearer \(privateBetaToken)"]
        } else {
            updater.httpHeaders = nil
        }
    }
}
