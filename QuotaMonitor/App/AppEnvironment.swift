import Foundation
import Observation
import AppKit
import GRDB

// Single source of truth for shared services and live UI state.
// Lazily constructs DatabaseManager + ImportEngine on first use so the menu bar
// can launch even if the SQLite directory has a permission issue.
//
// Big methods live in topic-focused extensions:
//   - PricingController.swift  — LiteLLM refresh + per-row edits
//   - ScanController.swift     — file scan + CSV export
//   - QueryFacade.swift        — sessions / history / day queries

@Observable
@MainActor
final class AppEnvironment {
    /// Process-wide shared instance. The AppKit `AppDelegate` (which owns
    /// the status item) and the SwiftUI `Window` scenes must reference the
    /// same `@Observable` state. Matches the `SettingsStore.shared` /
    /// `LocalizationStore.shared` pattern. `UserDefaultsMigration` still
    /// runs first because `QuotaMonitorApp.init` triggers the first access
    /// only after calling it.
    static let shared = AppEnvironment()

    let appServer: AppServerClient

    var latestRateLimits: RateLimitSnapshot?
    var latestCodexResetCredits: CodexResetCreditsSnapshot?
    var lastCodexResetCreditsError: String?
    /// Live Anthropic OAuth `/api/oauth/usage` snapshot, polled every
    /// ~10 min by `ClaudeUsagePoller` and on-demand by the Refresh button
    /// (subject to the poller's own 60 s spam gap + 429 cooldown).
    /// Mirrors `latestRateLimits` so the menu bar can render Codex +
    /// Claude blocks symmetrically.
    var latestClaudeUsage: ClaudeUsageSnapshot?
    /// Last error from the Claude poller, surfaced in the menu bar so the
    /// user can see *why* their Claude block is empty (no creds, expired
    /// token, scope problem). Cleared on the next successful poll.
    var lastClaudeUsageError: String?
    /// Whether `lastClaudeUsageError` is a *persistent* auth failure
    /// (expired/revoked token, missing creds, bad scope) vs a transient
    /// 429 / network blip. Computed from the typed `FetchError` (not by
    /// re-parsing the string), so the menu bar surfaces a re-login hint
    /// next to stale numbers only when the user actually must act.
    var lastClaudeUsageErrorIsAuthClass = false
    /// When non-nil and in the future, the Claude `/usage` endpoint is
    /// in a 429 cooldown — manual Refresh clicks are silently dropped
    /// until this time elapses. The menu bar reads this to render an
    /// inline "limited, retry in X" notice so the user understands why
    /// the button looks unresponsive.
    var latestClaudeUsageCooldownUntil: Date?
    var lastScanReport: ImportEngine.ScanReport?
    var scanProgress: ScanProgress?
    var dashboardSnapshot: DashboardSnapshot?
    var billingBlocks: BillingBlocks.Snapshot?
    /// Provider-agnostic snapshot for the menu bar.
    /// Always reflects the union view, never affected by `providerFilter`.
    var menuBarSnapshot: MenuBarSnapshot?
    var isLoadingMenuBar = false
    /// Coalescing flag for `refreshMenuBar`. When a refresh is requested
    /// while another is in flight, we set this and bail; the current
    /// task notices it in its `defer` and fires one trailing re-run so
    /// chained callers (refreshDashboard, runScan) can't be silently
    /// dropped. At most one queued re-run — `true` stays `true` whether
    /// 1 or 10 calls arrived during the in-flight window.
    private var menuBarRefreshPending = false
    var scanProgressStates: [String: ScanProviderProgress] = [:]
    var scanProgressRunID: UUID?
    var isRefreshingRateLimits = false
    var isRefreshingCodexResetCredits = false
    var isScanning = false
    /// Coalescing flag for the Claude file-watcher. A `~/.claude` write that
    /// lands while a scan is already running can't just rely on `runScan`'s
    /// `isScanning` early-return: if the append happened after the importer
    /// already read that JSONL file, that FSEvents notification would be lost
    /// and the menu bar could stay stale until the next write / manual
    /// refresh. So a write-during-scan sets this; the in-flight scan's `defer`
    /// fires exactly one trailing Claude-only rescan. At most one queued
    /// re-run regardless of how many writes arrived during the window.
    private var claudeFileWatchScanPending = false
    var isLoadingDashboard = false
    /// Internal re-entrancy guard for `refreshPricingFromLiteLLM`. Not
    /// observed by any view — opted out of `@Observable` tracking so it
    /// doesn't churn the dependency graph on every settings refresh.
    /// Lives on the type rather than as a `private var` because the
    /// owning method sits in a `PricingController.swift` extension and
    /// Swift extensions can't add stored properties.
    @ObservationIgnored
    var isRefreshingPricing = false
    var lastError: String?

    /// True when the status item has been detected as clipped/hidden and
    /// we have promoted to a permanent Dock icon as the fallback entry.
    /// Consulted by `demoteToAccessory()` / `applyDockIconPolicy()` so
    /// closing the last window does NOT drop the Dock icon while the menu
    /// bar remains unreachable.
    var menuBarUnreachable = false

    /// Timestamps that drive the auto-refresh-on-popover-open time gates.
    /// The Refresh **button** never honours these — the user clicking
    /// "Refresh" is an explicit intent and we always run. Only the
    /// implicit popover-open path consults them, so reopening the
    /// popover three times in five seconds doesn't trigger three back-
    /// to-back file scans and three subprocess calls.
    ///
    /// Not `private` so ScanController (an extension in another file)
    /// can stamp these after a successful scan.
    var lastRateLimitsRefreshAt: Date?
    /// Throttle timestamps keyed by scan **scope** (see `scanThrottleKey`),
    /// not a single global clock. A Claude-only file-watch scan and the
    /// popover's full (all-providers) scan have independent throttles, so a
    /// burst of `~/.claude` writes can't starve Codex imports: a watcher scan
    /// no longer stamps the timestamp the full scan throttles against.
    var lastScanAtByScope: [String: Date] = [:]

    /// Bucket a scan's *requested* provider scope into a throttle key. `nil`
    /// (every enabled provider — the popover/manual full scan) is "all";
    /// a scoped request (e.g. the watcher's `["claude"]`) gets its own key.
    nonisolated static func scanThrottleKey(forRequested providers: Set<String>?) -> String {
        guard let providers, !providers.isEmpty else { return "all" }
        return providers.sorted().joined(separator: ",")
    }

    /// Top-level provider filter applied to dashboard / sessions / history.
    /// Defaults to `.all` (union view).
    var providerFilter: ProviderFilter = .all {
        didSet {
            if oldValue != providerFilter {
                DeveloperLog.eventRecord(
                    "settings.provider_filter.change",
                    category: "settings",
                    trigger: "user",
                    fields: [
                        "old_value": .string(oldValue.rawValue),
                        "new_value": .string(providerFilter.rawValue)
                    ])
                refreshDashboard(trigger: "settings")
            }
        }
    }

    private var database: DatabaseManager?
    private var importEngine: ImportEngine?
    var claudeEngine: ClaudeImportEngine?
    private var poller: RateLimitPoller?
    private var claudeUsagePoller: ClaudeUsagePoller?
    /// Watches `~/.claude/projects` and triggers a Claude-only rescan on
    /// write, so local usage/cost stays current without opening the popover.
    private var claudeFileWatcher: ClaudeFileWatcher?
    /// Throttle for file-watch-triggered scans. The Claude import is cheap
    /// (incremental byte-offset read), so this can be short — it just stops
    /// a chatty session from scanning on every keystroke-sized append.
    static let claudeFileWatchScanMinInterval: TimeInterval = 5
    private let codexResetCreditsClient: any CodexResetCreditsFetching
    private var lastCodexResetCreditsRefreshAttemptAt: Date?
    let pricingSource = LiteLLMPricingSource()

    init(
        appServer: AppServerClient = AppServerClient(),
        codexResetCreditsClient: any CodexResetCreditsFetching = CodexResetCreditsClient(),
        startBackgroundTasks: Bool = true
    ) {
        self.appServer = appServer
        self.codexResetCreditsClient = codexResetCreditsClient
        DeveloperLog.eventRecord("app.environment.init", category: "app", trigger: "launch")
        guard startBackgroundTasks else { return }
        // Boot background polling immediately so it doesn't depend on the user
        // ever opening the menu bar. Idempotent — safe if .task fires later too.
        Task { [weak self] in
            await MainActor.run { self?.startBackgroundPolling() }
        }
        // Stale-pricing check: if no row has ever been fetched from LiteLLM, or
        // the freshest fetched_at is >24h old, kick a one-shot refresh. Best
        // effort — silently tolerated if offline.
        Task { [weak self] in
            await self?.refreshPricingIfStale()
        }
    }

    // MARK: - lazy services

    func ensureServices() throws -> (DatabaseManager, ImportEngine) {
        if let db = database, let eng = importEngine { return (db, eng) }
        let op = DeveloperLog.startOperation(
            "services.init",
            category: "app",
            trigger: "lazy",
            fields: ["database_path": .string(DatabaseManager.defaultURL().path)])
        do {
            let db = try DatabaseManager(url: DatabaseManager.defaultURL())
            let eng = ImportEngine(database: db)
            self.database = db
            self.importEngine = eng
            self.claudeEngine = ClaudeImportEngine(database: db)
            DeveloperLog.finishOperation(op)
            return (db, eng)
        } catch {
            DeveloperLog.failOperation(op, error: error)
            throw error
        }
    }

    /// Boot the background rate-limit poller. Idempotent.
    ///
    /// Hard-gated on onboarding completion so a fresh-install user
    /// doesn't see a Keychain ACL prompt fire before the onboarding
    /// window can render. `finishOnboarding` calls
    /// `applyEnabledProviders()` (which routes through the
    /// `startCodexPoller` / `startClaudePoller` entry points directly)
    /// once the user clicks Continue, so the gate self-clears.
    func startBackgroundPolling() {
        let snap = SettingsStore.snapshot()
        DeveloperLog.eventRecord(
            "poller.background.start.request",
            category: "poller",
            trigger: "launch",
            fields: [
                "enabled_providers": .string(snap.enabledProviders.sorted().joined(separator: ",")),
                "onboarding_done": .bool(snap.hasCompletedProviderOnboarding)
            ])
        guard snap.hasCompletedProviderOnboarding else {
            DeveloperLog.eventRecord(
                "poller.background.start.skip",
                category: "poller",
                trigger: "launch",
                result: "skipped",
                fields: ["reason": "onboarding"])
            return
        }
        do {
            let (db, _) = try ensureServices()
            let enabled = snap.enabledProviders
            if enabled.contains("codex") {
                startCodexPoller(database: db)
            }
            if enabled.contains("claude") {
                startClaudePoller(database: db)
            }
            ensureClaudeFileWatcher()
            guard LocalQAEnvironment.allowsExternalDataSources() else {
                DeveloperLog.eventRecord(
                    "poller.background.start.skip",
                    category: "poller",
                    trigger: "launch",
                    result: "skipped",
                    fields: ["reason": "local-qa"])
                return
            }
        } catch {
            self.lastError = String(describing: error)
            DeveloperLog.eventRecord(
                "poller.background.start.fail",
                level: .error,
                category: "poller",
                trigger: "launch",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
        }
    }

    /// Boot just the Codex rate-limit poller. Safe to call repeatedly —
    /// no-op if it's already running.
    private func startCodexPoller(database db: DatabaseManager) {
        // Warm-start from the persisted snapshot even in local QA. QA
        // disables external app-server calls, but the shadow DB may
        // already contain copied 5h / 7d samples that the UI should show.
        Task { [weak self] in
            if let cached = try? await RateLimitsHydrator.loadLatest(database: db) {
                await MainActor.run {
                    guard let self, self.latestRateLimits == nil else { return }
                    self.latestRateLimits = cached
                    self.applyCodexResetCreditsCountFallback(
                        cached.resetCreditsAvailable,
                        capturedAt: cached.capturedAt)
                }
            }
        }
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            DeveloperLog.eventRecord(
                "poller.codex.start.skip",
                category: "poller",
                provider: "codex",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }
        guard poller == nil else {
            DeveloperLog.eventRecord(
                "poller.codex.start.skip",
                level: .debug,
                category: "poller",
                provider: "codex",
                result: "skipped",
                fields: ["reason": "already-running"])
            return
        }
        DeveloperLog.eventRecord("poller.codex.start", category: "poller", provider: "codex")
        let interval = SettingsStore.snapshot().pollIntervalSeconds
        let p = RateLimitPoller(
            appServer: appServer,
            database: db,
            interval: .seconds(interval)
        ) { [weak self] snapshot in
            await MainActor.run {
                guard let self else { return }
                self.latestRateLimits = snapshot
                self.lastRateLimitsRefreshAt = snapshot.capturedAt
                self.applyCodexResetCreditsCountFallback(
                    snapshot.resetCreditsAvailable,
                    capturedAt: snapshot.capturedAt)
                self.refreshCodexResetCredits(
                    minInterval: 300,
                    trigger: "poller")
            }
        }
        self.poller = p
        Task { await p.start() }
    }

    /// Boot just the Claude OAuth `/usage` poller. Independent lifecycle
    /// from the Codex poller — same transport pattern, on a ~10 min
    /// scheduled cadence (`ClaudeUsagePoller.defaultInterval`). Anthropic
    /// edge-rate-limits this endpoint, so the 429 cooldown ladder backs
    /// off automatically if we get limited. The menu-bar
    /// Refresh button calls `pollOnce()` via `refreshClaudeUsage()`
    /// too; the poller's own 60 s spam gap + 429 cooldown keep that
    /// safe.
    private func startClaudePoller(database db: DatabaseManager) {
        // Same local-cache warm-start as Codex: QA blocks external OAuth
        // reads but should still render copied `claude_oauth` rows.
        Task { [weak self] in
            if let cached = try? await ClaudeUsageHydrator.loadLatest(database: db) {
                await MainActor.run {
                    guard let self, self.latestClaudeUsage == nil else { return }
                    self.latestClaudeUsage = cached
                }
            }
        }
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            DeveloperLog.eventRecord(
                "poller.claude.start.skip",
                category: "poller",
                provider: "claude",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }
        guard claudeUsagePoller == nil else {
            DeveloperLog.eventRecord(
                "poller.claude.start.skip",
                level: .debug,
                category: "poller",
                provider: "claude",
                result: "skipped",
                fields: ["reason": "already-running"])
            return
        }
        DeveloperLog.eventRecord("poller.claude.start", category: "poller", provider: "claude")
        let cp = ClaudeUsagePoller(
            database: db,
            interval: ClaudeUsagePoller.defaultInterval,
            onSnapshot: { [weak self] result in
                await MainActor.run {
                    guard let self else { return }
                    switch result {
                    case .success(let snap):
                        self.latestClaudeUsage = snap.preservingStaleFiveHour(
                            from: self.latestClaudeUsage)
                        self.lastClaudeUsageError = nil
                        self.lastClaudeUsageErrorIsAuthClass = false
                    case .failure(let err):
                        self.lastClaudeUsageError = String(describing: err)
                        self.lastClaudeUsageErrorIsAuthClass =
                            (err as? ClaudeUsageClient.FetchError)?.isAuthClass ?? false
                    }
                }
            },
            onCooldownChange: { [weak self] until in
                await MainActor.run {
                    guard let self else { return }
                    self.latestClaudeUsageCooldownUntil = until
                    if until != nil {
                        self.lastClaudeUsageError = nil
                        self.lastClaudeUsageErrorIsAuthClass = false
                    }
                }
            }
        )
        self.claudeUsagePoller = cp
        Task { await cp.start() }
    }

    /// Stop a provider's poller when the user disables it. Clears the
    /// associated UI state so the dashboard / menu bar can immediately
    /// reflect "we are no longer tracking this".
    private func stopCodexPoller() {
        guard let p = poller else { return }
        DeveloperLog.eventRecord("poller.codex.stop", category: "poller", provider: "codex")
        self.poller = nil
        self.latestRateLimits = nil
        self.latestCodexResetCredits = nil
        self.lastCodexResetCreditsError = nil
        self.lastCodexResetCreditsRefreshAttemptAt = nil
        Task { await p.stop() }
    }

    private func stopClaudePoller() {
        guard let cp = claudeUsagePoller else { return }
        DeveloperLog.eventRecord("poller.claude.stop", category: "poller", provider: "claude")
        self.claudeUsagePoller = nil
        self.latestClaudeUsage = nil
        self.lastClaudeUsageError = nil
        self.lastClaudeUsageErrorIsAuthClass = false
        self.latestClaudeUsageCooldownUntil = nil
        Task { await cp.stop() }
    }

    /// Start the Claude transcript file-watcher. Self-gating + idempotent:
    /// no-op in Local QA (scans there are driven by scripted steps), when
    /// Claude is disabled / onboarding isn't done, when no Claude directory
    /// exists yet, or when it's already running. On a write it triggers a
    /// **Claude-only** rescan, throttled and routed through `runScan`'s
    /// `isScanning` guard so a busy session can't cause a scan storm and
    /// Codex is never re-parsed.
    private func ensureClaudeFileWatcher() {
        guard claudeFileWatcher == nil else { return }
        guard LocalQAEnvironment.allowsExternalDataSources() else { return }
        let snap = SettingsStore.snapshot()
        guard snap.hasCompletedProviderOnboarding,
              snap.enabledProviders.contains("claude") else { return }
        let dirs = ClaudeFileWatcher.watchedDirectories(
            home: LocalQAEnvironment.homeDirectory())
        guard !dirs.isEmpty else {
            DeveloperLog.eventRecord(
                "claude_file_watch.start.skip",
                category: "scan",
                provider: "claude",
                result: "skipped",
                fields: ["reason": "no-claude-directory"])
            return
        }
        let watcher = ClaudeFileWatcher(directories: dirs) { [weak self] in
            Task { @MainActor in
                self?.triggerClaudeFileWatchScan()
            }
        }
        watcher.start()
        self.claudeFileWatcher = watcher
        DeveloperLog.eventRecord(
            "claude_file_watch.start",
            category: "scan",
            provider: "claude",
            result: "success",
            fields: ["watched_dirs": .int(dirs.count)])
    }

    /// Entry point for a Claude transcript write. When a scan is already
    /// running we can't drop the event (the append may post-date the
    /// importer's read of that file), so we mark a trailing rescan that the
    /// in-flight scan's `defer` will fire. Otherwise we scan now, throttled so
    /// a burst of small appends can't cause a scan storm.
    @MainActor
    func triggerClaudeFileWatchScan() {
        guard !isScanning else {
            claudeFileWatchScanPending = true
            DeveloperLog.eventRecord(
                "claude_file_watch.scan.coalesced",
                category: "scan",
                trigger: "claude-file-watch",
                provider: "claude",
                result: "coalesced")
            return
        }
        runScan(
            minInterval: Self.claudeFileWatchScanMinInterval,
            providers: ["claude"],
            trigger: "claude-file-watch")
    }

    /// Fire the trailing Claude-only rescan queued by a write that arrived
    /// mid-scan, if any. Called from `runScan`'s `defer` once `isScanning`
    /// clears. Throttle-free on purpose: it's coalesced to at most one run per
    /// scan, so it represents real un-imported bytes rather than spam.
    @MainActor
    func runPendingClaudeFileWatchScanIfNeeded() {
        guard claudeFileWatchScanPending else { return }
        claudeFileWatchScanPending = false
        runScan(providers: ["claude"], trigger: "claude-file-watch-trailing")
    }

    /// Test seam: whether a coalesced trailing Claude file-watch rescan is
    /// currently queued. Not used in production.
    var _claudeFileWatchScanPendingForTest: Bool { claudeFileWatchScanPending }

    private func stopClaudeFileWatcher() {
        guard claudeFileWatcher != nil else { return }
        claudeFileWatcher?.stop()
        self.claudeFileWatcher = nil
        DeveloperLog.eventRecord(
            "claude_file_watch.stop", category: "scan", provider: "claude")
    }

    /// React to a change in `SettingsStore.enabledProviders` — start /
    /// stop the matching pollers, snap the dashboard provider filter
    /// off any disabled provider, and refresh menu bar + dashboard so
    /// the UI immediately matches the new set.
    func applyEnabledProviders() {
        let enabled = SettingsStore.snapshot().enabledProviders
        DeveloperLog.eventRecord(
            "settings.enabled_providers.apply",
            category: "settings",
            trigger: "settings",
            fields: ["enabled_providers": .string(enabled.sorted().joined(separator: ","))])
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            stopCodexPoller()
            stopClaudePoller()
            stopClaudeFileWatcher()
            DeveloperLog.eventRecord(
                "settings.enabled_providers.apply.skip_live_sources",
                category: "settings",
                trigger: "settings",
                result: "skipped",
                fields: ["reason": "local-qa"])
            refreshMenuBar(trigger: "settings")
            refreshDashboard(trigger: "settings")
            return
        }
        do {
            let (db, _) = try ensureServices()
            if enabled.contains("codex") {
                startCodexPoller(database: db)
            } else {
                stopCodexPoller()
            }
            if enabled.contains("claude") {
                startClaudePoller(database: db)
                ensureClaudeFileWatcher()
            } else {
                stopClaudePoller()
                stopClaudeFileWatcher()
            }
        } catch {
            self.lastError = String(describing: error)
            DeveloperLog.eventRecord(
                "settings.enabled_providers.apply.fail",
                level: .error,
                category: "settings",
                trigger: "settings",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
        }
        // Snap the toolbar filter off a disabled provider. We never
        // synthesize a single-provider filter — the union view (`.all`)
        // is always a valid fallback even when only one provider is
        // active (it just renders the one that's left).
        if !enabled.contains(providerFilter.rawValue),
           providerFilter != .all {
            providerFilter = .all  // didSet refreshes dashboard
        } else {
            // didSet on providerFilter would have done this for us in
            // the snap branch; in the no-snap branch we still need to
            // re-render because composition / forecast filtering changed.
            refreshDashboard(trigger: "settings")
        }
        refreshMenuBar(trigger: "settings")
    }

    /// Apply runtime-mutable settings without restarting the app.
    /// Path-based settings still need a relaunch (we surface that in the UI).
    func applySettings() {
        let snap = SettingsStore.snapshot()
        DeveloperLog.eventRecord(
            "settings.runtime.apply",
            category: "settings",
            trigger: "settings",
            fields: ["poll_interval_seconds": .int(snap.pollIntervalSeconds)])
        if let p = poller {
            Task { await p.updateInterval(.seconds(snap.pollIntervalSeconds)) }
        }
        // Deliberately NOT propagating `pollIntervalSeconds` to the Claude
        // poller: its endpoint is edge-rate-limited and shares no semantics
        // with the Codex window. It stays on its own fixed cadence
        // (`ClaudeUsagePoller.defaultInterval`) set in `startBackgroundPolling()`.
    }

    // MARK: - actions

    /// Single shared fan-out used by BOTH the menu-bar popover open hook
    /// and the explicit Refresh button. The only difference between those
    /// two callers is `throttle`: the popover-open caller passes `true` so
    /// reopening the popover three times in a row doesn't trigger three
    /// back-to-back JSONL scans + Codex app-server calls; the Refresh
    /// button passes `false` because clicking it is explicit user intent.
    /// Keeping this in one place guarantees both paths stay in sync (e.g.
    /// the scan-progress bar appears for either when a scan actually runs).
    func refreshAll(throttle: Bool, trigger: String) {
        if LocalQAEnvironment.isActive() {
            DeveloperLog.eventRecord(
                "refresh.all.qa_local_only",
                category: "app",
                trigger: trigger,
                fields: ["throttle": .bool(throttle)])
            refreshRateLimits(
                minInterval: throttle ? 30 : nil,
                trigger: trigger)
            runScan(
                minInterval: throttle ? 20 : nil,
                trigger: trigger)
            return
        }

        let op = DeveloperLog.startOperation(
            "refresh.all",
            category: "app",
            trigger: trigger,
            fields: ["throttle": .bool(throttle)])
        refreshRateLimits(
            minInterval: throttle ? 30 : nil,
            trigger: trigger,
            parentOperation: op,
            bypassMinimumGap: !throttle && trigger == "manual")
        refreshCodexResetCredits(
            minInterval: throttle ? 30 : nil,
            trigger: trigger,
            parentOperation: op)
        refreshClaudeUsage(trigger: trigger, parentOperation: op)
        runScan(
            minInterval: throttle ? 20 : nil,
            trigger: trigger,
            parentOperation: op)
        DeveloperLog.finishOperation(op, result: "scheduled")
        // runScan's tail re-runs refreshMenuBar(), so no need to repeat here.
    }

    private func applyCodexResetCreditsCountFallback(
        _ count: Int?,
        capturedAt: Date
    ) {
        guard let count else { return }
        if let current = latestCodexResetCredits,
           current.detailStatus == .complete,
           current.availableCount == count {
            return
        }
        latestCodexResetCredits = CodexResetCreditsSnapshot.countOnly(
            availableCount: count,
            capturedAt: capturedAt)
    }

    func installLocalQAMockCodexResetCredits(now: Date = Date()) {
        latestCodexResetCredits = CodexResetCreditsSnapshot(
            capturedAt: now,
            availableCount: 2,
            credits: [
                CodexResetCredit(
                    grantedAt: now.addingTimeInterval(-60 * 60),
                    expiresAt: now.addingTimeInterval(2 * 60 * 60)),
                CodexResetCredit(
                    grantedAt: now.addingTimeInterval(-24 * 60 * 60),
                    expiresAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
            ],
            detailStatus: .complete)
        lastCodexResetCreditsError = nil
        DeveloperLog.eventRecord(
            "codex_reset_credits.qa_mock.install",
            category: "poller",
            trigger: "qa",
            provider: "codex",
            fields: ["available_count": .int(2)])
    }

    func refreshCodexResetCredits(
        minInterval: TimeInterval? = nil,
        trigger: String = "manual",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            DeveloperLog.eventRecord(
                "codex_reset_credits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }
        let snap = SettingsStore.snapshot()
        guard snap.hasCompletedProviderOnboarding else {
            DeveloperLog.eventRecord(
                "codex_reset_credits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "onboarding"])
            return
        }
        guard snap.enabledProviders.contains("codex") else {
            DeveloperLog.eventRecord(
                "codex_reset_credits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "codex-disabled"])
            return
        }
        if let interval = minInterval,
           let lastAttempt = lastCodexResetCreditsRefreshAttemptAt,
           Date().timeIntervalSince(lastAttempt) < interval {
            DeveloperLog.eventRecord(
                "codex_reset_credits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "throttled"])
            return
        }
        guard !isRefreshingCodexResetCredits else {
            DeveloperLog.eventRecord(
                "codex_reset_credits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "already-refreshing"])
            return
        }
        isRefreshingCodexResetCredits = true
        lastCodexResetCreditsRefreshAttemptAt = Date()
        let op = DeveloperLog.startOperation(
            "codex_reset_credits.refresh",
            category: "poller",
            trigger: trigger,
            provider: "codex",
            parent: parentOperation)

        Task { [weak self, client = codexResetCreditsClient, op] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isRefreshingCodexResetCredits = false
                }
            }
            do {
                let snapshot = try await Self.withTimeout(
                    seconds: 10,
                    context: "refreshCodexResetCredits"
                ) {
                    try await client.fetchResetCredits()
                }
                await MainActor.run {
                    guard let self else { return }
                    self.latestCodexResetCredits = snapshot
                    self.lastCodexResetCreditsError = nil
                }
                DeveloperLog.finishOperation(
                    op,
                    fields: [
                        "available_count": .int(snapshot.availableCount),
                        "detail_count": .int(snapshot.credits.count)
                    ])
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastCodexResetCreditsError = String(describing: error)
                }
                DeveloperLog.failOperation(op, error: error)
            }
        }
    }

    /// `minInterval` is honoured by the auto-refresh-on-popover-open caller
    /// (it passes a non-nil interval). The explicit Refresh button also sets
    /// `bypassMinimumGap` so user-driven intent can force a fresh Codex usage
    /// request unless the app is already in a 429 cooldown.
    func refreshRateLimits(
        minInterval: TimeInterval? = nil,
        trigger: String = "manual",
        parentOperation: DeveloperLogOperation? = nil,
        bypassMinimumGap: Bool = false
    ) {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            let op = DeveloperLog.startOperation(
                "ratelimits.hydrate",
                category: "poller",
                trigger: trigger,
                provider: "codex",
                parent: parentOperation,
                fields: ["source": "local-db"])
            do {
                let (db, _) = try ensureServices()
                Task { [weak self, op] in
                    do {
                        let cached = try await RateLimitsHydrator.loadLatest(database: db)
                        await MainActor.run {
                            guard let self else { return }
                            self.latestRateLimits = cached
                            if cached != nil {
                                self.lastRateLimitsRefreshAt = Date()
                            }
                            self.applyCodexResetCreditsCountFallback(
                                cached?.resetCreditsAvailable,
                                capturedAt: cached?.capturedAt ?? Date())
                        }
                        DeveloperLog.finishOperation(
                            op,
                            result: cached == nil ? "no-data" : "success",
                            fields: [
                                "primary_used_percent": .double(cached?.primary?.usedPercent ?? -1),
                                "secondary_used_percent": .double(cached?.secondary?.usedPercent ?? -1)
                            ])
                    } catch {
                        await MainActor.run { self?.lastError = String(describing: error) }
                        DeveloperLog.failOperation(op, error: error)
                    }
                }
            } catch {
                self.lastError = String(describing: error)
                DeveloperLog.failOperation(op, error: error)
            }
            return
        }
        guard !isRefreshingRateLimits else {
            DeveloperLog.eventRecord(
                "ratelimits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "already-refreshing"])
            return
        }
        let snap = SettingsStore.snapshot()
        // Hard gate: nothing external runs until the user has finished
        // onboarding. The popover's auto-refresh + the Refresh button
        // both route through here, and we don't want either spawning a
        // Codex app-server child before the user has even seen the
        // setup wizard.
        guard snap.hasCompletedProviderOnboarding else {
            DeveloperLog.eventRecord(
                "ratelimits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "onboarding"])
            return
        }
        // The Refresh button is hidden when Codex is disabled, but a
        // stale binding (e.g. user disabled Codex while a refresh was
        // in flight) could still call this — guard so we don't spawn a
        // child app-server process the user has explicitly opted out of.
        guard snap.enabledProviders.contains("codex") else {
            DeveloperLog.eventRecord(
                "ratelimits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: ["reason": "codex-disabled"])
            return
        }
        if let interval = minInterval, let last = lastRateLimitsRefreshAt,
           Date().timeIntervalSince(last) < interval {
            DeveloperLog.eventRecord(
                "ratelimits.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: [
                    "reason": "throttled",
                    "min_interval_seconds": .double(interval),
                    "elapsed_seconds": .double(Date().timeIntervalSince(last))
                ])
            return
        }
        isRefreshingRateLimits = true
        lastError = nil
        let op = DeveloperLog.startOperation(
            "ratelimits.refresh",
            category: "poller",
            trigger: trigger,
            provider: "codex",
            parent: parentOperation,
            fields: [
                "min_interval_seconds": minInterval.map(DeveloperLogValue.double) ?? .string("none"),
                "bypass_minimum_gap": .bool(bypassMinimumGap)
            ])

        if let poller {
            Task { [op] in
                let outcome = await poller.pollOnce(
                    trigger: trigger,
                    bypassMinimumGap: bypassMinimumGap)
                await MainActor.run {
                    self.isRefreshingRateLimits = false
                    switch outcome {
                    case .success(let snapshot):
                        self.latestRateLimits = snapshot
                        self.lastRateLimitsRefreshAt = snapshot.capturedAt
                        self.applyCodexResetCreditsCountFallback(
                            snapshot.resetCreditsAvailable,
                            capturedAt: snapshot.capturedAt)
                        DeveloperLog.finishOperation(
                            op,
                            fields: [
                                "plan_type": .string(snapshot.planType ?? ""),
                                "primary_used_percent": .double(snapshot.primary?.usedPercent ?? -1),
                                "secondary_used_percent": .double(snapshot.secondary?.usedPercent ?? -1)
                            ])
                    case .skipped(let reason):
                        let reasonLabel: String
                        var fields: [String: DeveloperLogValue] = [:]
                        switch reason {
                        case .minimumGap(let elapsed, let minimum):
                            reasonLabel = "minimum-gap"
                            fields["elapsed_seconds"] = .int(elapsed)
                            fields["minimum_gap_seconds"] = .int(minimum)
                        case .rateLimitCooldown(let remaining, let until):
                            reasonLabel = "rate-limit-cooldown"
                            fields["remaining_seconds"] = .int(remaining)
                            fields["cooldown_until"] = .string(ISO8601.fractional.string(from: until))
                        }
                        fields["reason"] = .string(reasonLabel)
                        DeveloperLog.finishOperation(op, result: "skipped", fields: fields)
                    case .failure(let message):
                        self.lastError = message
                        DeveloperLog.failOperation(
                            op,
                            error: RateLimitsRefreshError(message: message))
                    }
                }
            }
            return
        }

        Task { [appServer, op] in
            defer { Task { @MainActor in self.isRefreshingRateLimits = false } }
            // Fallback for early launch or test wiring before the Codex
            // poller is available. Normal app paths use the poller above
            // so scheduled, popover, and manual callers share one throttle.
            do {
                // Hard 30s cap so a hung app-server child or wedged
                // AppServerClient actor can't strand the spinner forever.
                let payload = try await Self.withTimeout(
                    seconds: 30, context: "refreshRateLimits"
                ) {
                    try await appServer.readRateLimits()
                }
                let snapshot = RateLimitSnapshot(from: payload)
                await MainActor.run {
                    self.latestRateLimits = snapshot
                    self.lastRateLimitsRefreshAt = Date()
                    self.applyCodexResetCreditsCountFallback(
                        snapshot.resetCreditsAvailable,
                        capturedAt: snapshot.capturedAt)
                }
                DeveloperLog.finishOperation(
                    op,
                    fields: [
                        "plan_type": .string(snapshot.planType ?? ""),
                        "primary_used_percent": .double(snapshot.primary?.usedPercent ?? -1),
                        "secondary_used_percent": .double(snapshot.secondary?.usedPercent ?? -1)
                    ])
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
                DeveloperLog.failOperation(op, error: error)
            }
        }
    }

    /// Ask the Claude `/usage` poller for a fresh fetch. Fire-and-forget:
    /// the poller's own 60 s spam gap and 429 cooldown decide whether
    /// the call actually goes through, and the snapshot (if any) lands
    /// via the `onSnapshot` callback. We surface nothing on a skip — a
    /// silently-dropped click is preferable to nag toasts.
    func refreshClaudeUsage(
        trigger: String = "manual",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            DeveloperLog.eventRecord(
                "claude_usage.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "claude",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return
        }
        let snap = SettingsStore.snapshot()
        // Hard gate: see `refreshRateLimits` — Keychain reads in
        // particular must not fire before the onboarding window.
        guard snap.hasCompletedProviderOnboarding else {
            DeveloperLog.eventRecord(
                "claude_usage.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "claude",
                result: "skipped",
                fields: ["reason": "onboarding"])
            return
        }
        guard snap.enabledProviders.contains("claude") else {
            DeveloperLog.eventRecord(
                "claude_usage.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "claude",
                result: "skipped",
                fields: ["reason": "claude-disabled"])
            return
        }
        guard let cp = claudeUsagePoller else {
            DeveloperLog.eventRecord(
                "claude_usage.refresh.skip",
                category: "poller",
                operation: parentOperation,
                trigger: trigger,
                provider: "claude",
                result: "skipped",
                fields: ["reason": "poller-not-started"])
            return
        }
        DeveloperLog.eventRecord(
            "claude_usage.refresh.request",
            category: "poller",
            operation: parentOperation,
            trigger: trigger,
            provider: "claude")
        // The explicit Refresh button (trigger == "manual") bypasses the
        // poller's 60s spam gap so a click always re-polls; the 429 cooldown
        // is still honoured inside `pollOnce`. Throttled popover/scan
        // refreshes keep the gap.
        let force = trigger == "manual"
        Task { await cp.pollOnce(force: force) }
    }

    /// Load the menu-bar snapshot. Always queries both providers + the
    /// Anthropic 5h block, regardless of `providerFilter`. Cheap enough to
    /// run on every popover open / scan / refresh.
    ///
    /// `precomputedBlocks` lets a caller that *just* loaded BillingBlocks
    /// (e.g. `refreshDashboard()`) hand the result through instead of
    /// re-running the same usage_events scan a second time. Nil means
    /// "no shared result, fetch fresh" — that's the right default for the
    /// stand-alone paths (popover open, scan completion, settings change).
    func refreshMenuBar(
        precomputedBlocks: BillingBlocks.Snapshot? = nil,
        trigger: String = "internal",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard !isLoadingMenuBar else {
            // Coalesce: a refresh is already running. Mark a trailing
            // re-run so the chained call (typically from
            // `refreshDashboard` / `runScan` tail) doesn't get silently
            // dropped — which used to leave `menuBarSnapshot` lagging
            // one tick behind `dashboardSnapshot`. The trailing call
            // can't reuse `precomputedBlocks` (they may be stale by
            // the time it fires) so it'll re-read BillingBlocks.
            menuBarRefreshPending = true
            DeveloperLog.eventRecord(
                "menubar.refresh.skip",
                category: "ui",
                operation: parentOperation,
                trigger: trigger,
                result: "queued",
                fields: ["reason": "already-loading"])
            return
        }
        isLoadingMenuBar = true
        let op = DeveloperLog.startOperation(
            "menubar.refresh",
            category: "ui",
            trigger: trigger,
            parent: parentOperation,
            fields: ["precomputed_blocks": .bool(precomputedBlocks != nil)])
        Task { [weak self, op] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isLoadingMenuBar = false
                    if self.menuBarRefreshPending {
                        self.menuBarRefreshPending = false
                        self.refreshMenuBar(trigger: "coalesced")
                    }
                }
            }
            do {
                let (db, _) = try self.ensureServices()
                let snap: MenuBarSnapshot = try await db.pool.read { conn in
                    let perProvider = try Aggregator.fetchPerProviderStats(db: conn)
                    let blocks = try precomputedBlocks
                        ?? BillingBlocks.loadSnapshot(db: conn, provider: .claude)
                    return MenuBarSnapshot(
                        codex: perProvider["codex"] ?? MenuBarSnapshot.empty("codex"),
                        claude: perProvider["claude"] ?? MenuBarSnapshot.empty("claude"),
                        anthropicBlocks: blocks)
                }
                await MainActor.run { self.menuBarSnapshot = snap }
                DeveloperLog.finishOperation(op)
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
                DeveloperLog.failOperation(op, error: error)
            }
        }
    }

    func refreshDashboard(
        trigger: String = "internal",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard !isLoadingDashboard else {
            DeveloperLog.eventRecord(
                "dashboard.refresh.skip",
                category: "ui",
                operation: parentOperation,
                trigger: trigger,
                result: "skipped",
                fields: ["reason": "already-loading"])
            return
        }
        isLoadingDashboard = true

        let filter = providerFilter
        let op = DeveloperLog.startOperation(
            "dashboard.refresh",
            category: "ui",
            trigger: trigger,
            parent: parentOperation,
            fields: ["filter": .string(filter.rawValue)])
        Task { [weak self, op] in
            guard let self else { return }
            defer { Task { @MainActor in self.isLoadingDashboard = false } }
            do {
                let (db, _) = try self.ensureServices()
                let snapshot = try await Aggregator.loadDashboard(
                    from: db.pool, provider: filter)
                // Billing blocks are an Anthropic concept — only meaningful
                // when the active filter includes Claude data.
                let blocks: BillingBlocks.Snapshot? = (filter == .codex) ? nil
                    : try await db.pool.read { conn in
                        try BillingBlocks.loadSnapshot(db: conn, provider: .claude)
                    }
                await MainActor.run {
                    self.dashboardSnapshot = snapshot
                    self.billingBlocks = blocks
                }
                // Menu bar is provider-agnostic — refresh alongside the
                // dashboard so price edits, filter toggles, and settings
                // changes keep both views in sync.
                self.refreshMenuBar(
                    precomputedBlocks: blocks,
                    trigger: "dashboard",
                    parentOperation: op)
                DeveloperLog.finishOperation(
                    op,
                    fields: [
                        "filter": .string(filter.rawValue),
                        "has_billing_blocks": .bool(blocks != nil)
                    ])
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
                DeveloperLog.failOperation(
                    op,
                    error: error,
                    fields: ["filter": .string(filter.rawValue)])
            }
        }
    }

    /// Bring a just-opened window (Dashboard / Settings / Onboarding)
    /// forward over the menu-bar popover. When the user has
    /// `showDockIconForWindows` ON, also promote to `.regular` so the
    /// Dock icon appears and the app shows in Cmd+Tab. When OFF
    /// (default), stay in `.accessory` — windows still get key focus
    /// from `activate(ignoringOtherApps:)` alone.
    func activateForWindow() {
        DeveloperLog.eventRecord(
            "window.activate",
            category: "ui",
            trigger: "user",
            fields: ["show_dock_icon": .bool(SettingsStore.shared.showDockIconForWindows)])
        if SettingsStore.shared.showDockIconForWindows {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Demote back to a menu-bar-only app once the last window closes.
    /// Gates on the *current* policy rather than the setting: in the
    /// normal flow (setting ON, we promoted on open) the policy is
    /// `.regular` and we demote; in the mid-session-toggle-OFF flow
    /// (`applyDockIconPolicy` deferred the demote to here) the policy
    /// is also `.regular`, so this still fires. With the setting OFF
    /// the whole time we never promoted, the policy is already
    /// `.accessory`, and we no-op.
    func demoteToAccessory(excludingWindowIDs: Set<String> = []) {
        guard Self.shouldDemoteToAccessory(
            currentlyRegular: NSApp.activationPolicy() == .regular,
            menuBarUnreachable: menuBarUnreachable,
            hasVisibleAppWindow: Self.hasVisibleAppWindow(
                excludingWindowIDs: excludingWindowIDs)) else { return }
        DeveloperLog.eventRecord("window.demote_to_accessory", category: "ui")
        NSApp.setActivationPolicy(.accessory)
    }

    /// Whether any app-owned window is currently on screen, excluding the
    /// given ids. AppKit now owns exactly the four `WindowManager` windows
    /// (all plain `NSWindow`), so this defers to that registry — no more
    /// scanning `NSApp.windows` and filtering out the popover / status-bar
    /// host by `NSPanel` / classname heuristics.
    static func hasVisibleAppWindow(excludingWindowIDs: Set<String> = []) -> Bool {
        WindowManager.shared.hasVisibleWindow(excluding: excludingWindowIDs)
    }

    /// Re-apply the activation policy based on the current setting.
    /// Called from the Settings toggle's binding so a flip takes
    /// effect immediately. Looks at `NSApp.windows` to decide whether
    /// any app-owned window is currently on screen.
    ///
    /// Bidirectional now that Settings is a plain `Window(id:)` scene
    /// rather than `Settings { }`. The previous implementation only
    /// promoted because demoting under `Settings { }` made macOS
    /// deactivate the app, which SwiftUI took as a cue to close the
    /// very Settings window the user was toggling — yanking the
    /// window out from under their cursor. Regular `Window` scenes
    /// survive that deactivation, so demoting on toggle OFF is safe
    /// and matches the "immediate effect" UX users expect.
    func applyDockIconPolicy() {
        let anyWindowOpen = Self.hasVisibleAppWindow()
        guard anyWindowOpen else { return }
        DeveloperLog.eventRecord(
            "settings.dock_icon_policy.apply",
            category: "settings",
            trigger: "settings",
            fields: [
                "any_window_open": true,
                "show_dock_icon": .bool(SettingsStore.shared.showDockIconForWindows)
            ])
        if SettingsStore.shared.showDockIconForWindows {
            NSApp.setActivationPolicy(.regular)
        } else if !menuBarUnreachable {
            // Toggle OFF with a window still open: drop the Dock icon
            // right now. The Settings window stays put because it's a
            // `Window(id:)` scene, not the auto-closing `Settings { }`
            // scene the old code had to dance around.
            //
            // EXCEPT when the menu-bar icon is unreachable — then the
            // Dock icon is the user's only visible entry and we keep it.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - dock policy predicate

    /// Pure decision for `demoteToAccessory()`. Only demote when we are
    /// currently `.regular`, the menu-bar icon is reachable, and no other
    /// app window still needs the Dock/Cmd-Tab presence.
    nonisolated static func shouldDemoteToAccessory(
        currentlyRegular: Bool,
        menuBarUnreachable: Bool,
        hasVisibleAppWindow: Bool = false) -> Bool {
        currentlyRegular && !menuBarUnreachable && !hasVisibleAppWindow
    }

    nonisolated static func activationPolicyForMenuBarReachability(
        clipped: Bool,
        showDockIconForWindows: Bool,
        hasVisibleAppWindow: Bool) -> NSApplication.ActivationPolicy {
        if clipped { return .regular }
        if showDockIconForWindows && hasVisibleAppWindow { return .regular }
        return .accessory
    }

    // MARK: - timeout helper

    /// Hard time-bound for long-running async work. Race the operation against
    /// a sleep; whichever finishes first wins. On timeout we cancel the work
    /// task (best-effort — synchronous parser loops won't observe cancellation)
    /// and surface a `BoundedWorkTimeoutError`, so the caller's `defer` can
    /// reset its `isLoading…` flag and free the UI.
    ///
    /// We deliberately do NOT wait for the abandoned work task to finish: it
    /// is allowed to keep running in the background. The point of the timeout
    /// is liveness for the UI flag, not preemption of CPU-bound parsing.
    nonisolated static func withTimeout<R: Sendable>(
        seconds: Int,
        context: String,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let workTask = Task<R, Error>(operation: operation)
        return try await withThrowingTaskGroup(of: R?.self) { group in
            group.addTask {
                try await workTask.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                workTask.cancel()
                return nil
            }
            defer { group.cancelAll() }
            for try await result in group {
                if let r = result { return r }
                throw BoundedWorkTimeoutError(context: context, seconds: seconds)
            }
            throw BoundedWorkTimeoutError(context: context, seconds: seconds)
        }
    }
}

struct BoundedWorkTimeoutError: LocalizedError, Sendable {
    let context: String
    let seconds: Int
    var errorDescription: String? { "\(context) timed out after \(seconds)s" }
}

private struct RateLimitsRefreshError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
