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
    let appServer: AppServerClient

    var latestRateLimits: RateLimitSnapshot?
    /// Live Anthropic OAuth `/api/oauth/usage` snapshot, polled every
    /// 2 h by `ClaudeUsagePoller` and on-demand by the Refresh button
    /// (subject to the poller's own 60 s spam gap + 429 cooldown).
    /// Mirrors `latestRateLimits` so the menu bar can render Codex +
    /// Claude blocks symmetrically.
    var latestClaudeUsage: ClaudeUsageSnapshot?
    /// Last error from the Claude poller, surfaced in the menu bar so the
    /// user can see *why* their Claude block is empty (no creds, expired
    /// token, scope problem). Cleared on the next successful poll.
    var lastClaudeUsageError: String?
    /// When non-nil and in the future, the Claude `/usage` endpoint is
    /// in a 429 cooldown — manual Refresh clicks are silently dropped
    /// until this time elapses. The menu bar reads this to render an
    /// inline "limited, retry in X" notice so the user understands why
    /// the button looks unresponsive.
    var latestClaudeUsageCooldownUntil: Date?
    var lastScanReport: ImportEngine.ScanReport?
    var dashboardSnapshot: DashboardSnapshot?
    var billingBlocks: BillingBlocks.Snapshot?
    /// Provider-agnostic snapshot for the menu bar.
    /// Always reflects the union view, never affected by `providerFilter`.
    var menuBarSnapshot: MenuBarSnapshot?
    var isLoadingMenuBar = false
    var isRefreshingRateLimits = false
    var isScanning = false
    var isLoadingDashboard = false
    var isRefreshingPricing = false
    var lastPricingFetchedAt: Date?
    var lastPricingUpdateCount: Int?
    var lastError: String?

    /// Timestamps that drive the auto-refresh-on-popover-open time gates.
    /// The Refresh **button** never honours these — the user clicking
    /// "Refresh" is an explicit intent and we always run. Only the
    /// implicit popover-open path consults them, so reopening the
    /// popover three times in five seconds doesn't trigger three back-
    /// to-back file scans and three subprocess calls.
    ///
    /// Not `private` so ScanController (an extension in another file)
    /// can stamp `lastScanAt` after a successful scan.
    var lastRateLimitsRefreshAt: Date?
    var lastScanAt: Date?

    /// Top-level provider filter applied to dashboard / sessions / history.
    /// Defaults to `.all` (union view).
    var providerFilter: ProviderFilter = .all {
        didSet {
            if oldValue != providerFilter {
                refreshDashboard()
            }
        }
    }

    private var database: DatabaseManager?
    private var importEngine: ImportEngine?
    var claudeEngine: ClaudeImportEngine?
    private var poller: RateLimitPoller?
    private var claudeUsagePoller: ClaudeUsagePoller?
    let pricingSource = LiteLLMPricingSource()

    init(appServer: AppServerClient = AppServerClient()) {
        self.appServer = appServer
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
        let db = try DatabaseManager(url: DatabaseManager.defaultURL())
        let eng = ImportEngine(database: db)
        self.database = db
        self.importEngine = eng
        self.claudeEngine = ClaudeImportEngine(database: db)
        return (db, eng)
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
        guard snap.hasCompletedProviderOnboarding else { return }
        do {
            let (db, _) = try ensureServices()
            let enabled = snap.enabledProviders
            if enabled.contains("codex") {
                startCodexPoller(database: db)
            }
            if enabled.contains("claude") {
                startClaudePoller(database: db)
            }
        } catch {
            self.lastError = String(describing: error)
        }
    }

    /// Boot just the Codex rate-limit poller. Safe to call repeatedly —
    /// no-op if it's already running.
    private func startCodexPoller(database db: DatabaseManager) {
        guard poller == nil else { return }
        let interval = SettingsStore.snapshot().pollIntervalSeconds
        let p = RateLimitPoller(
            appServer: appServer,
            database: db,
            interval: .seconds(interval)
        ) { [weak self] snapshot in
            await MainActor.run {
                guard let self else { return }
                self.latestRateLimits = snapshot
            }
        }
        self.poller = p
        Task { await p.start() }
    }

    /// Boot just the Claude OAuth `/usage` poller. Independent lifecycle
    /// from the Codex poller — same transport pattern, but a much slower
    /// cadence: Anthropic edge-rate-limits this endpoint, so we hit it
    /// at most every 2 hours on the scheduled path. The menu-bar
    /// Refresh button calls `pollOnce()` via `refreshClaudeUsage()`
    /// too; the poller's own 60 s spam gap + 429 cooldown keep that
    /// safe.
    private func startClaudePoller(database db: DatabaseManager) {
        guard claudeUsagePoller == nil else { return }
        // Warm-start: hydrate the last persisted Claude snapshot from
        // the DB so the UI has something to show before the first
        // network poll lands. Avoids the "blank + 'unavailable'" first
        // impression when Anthropic 429s us at boot.
        Task { [weak self] in
            if let cached = try? await ClaudeUsageHydrator.loadLatest(database: db) {
                await MainActor.run {
                    guard let self, self.latestClaudeUsage == nil else { return }
                    self.latestClaudeUsage = cached
                }
            }
        }
        let cp = ClaudeUsagePoller(
            database: db,
            interval: .seconds(7200),
            onSnapshot: { [weak self] result in
                await MainActor.run {
                    guard let self else { return }
                    switch result {
                    case .success(let snap):
                        self.latestClaudeUsage = snap
                        self.lastClaudeUsageError = nil
                    case .failure(let err):
                        self.lastClaudeUsageError = String(describing: err)
                    }
                }
            },
            onCooldownChange: { [weak self] until in
                await MainActor.run {
                    self?.latestClaudeUsageCooldownUntil = until
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
        self.poller = nil
        self.latestRateLimits = nil
        Task { await p.stop() }
    }

    private func stopClaudePoller() {
        guard let cp = claudeUsagePoller else { return }
        self.claudeUsagePoller = nil
        self.latestClaudeUsage = nil
        self.lastClaudeUsageError = nil
        self.latestClaudeUsageCooldownUntil = nil
        Task { await cp.stop() }
    }

    /// React to a change in `SettingsStore.enabledProviders` — start /
    /// stop the matching pollers, snap the dashboard provider filter
    /// off any disabled provider, and refresh menu bar + dashboard so
    /// the UI immediately matches the new set.
    func applyEnabledProviders() {
        let enabled = SettingsStore.snapshot().enabledProviders
        do {
            let (db, _) = try ensureServices()
            if enabled.contains("codex") {
                startCodexPoller(database: db)
            } else {
                stopCodexPoller()
            }
            if enabled.contains("claude") {
                startClaudePoller(database: db)
            } else {
                stopClaudePoller()
            }
        } catch {
            self.lastError = String(describing: error)
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
            refreshDashboard()
        }
        refreshMenuBar()
    }

    /// Apply runtime-mutable settings without restarting the app.
    /// Path-based settings still need a relaunch (we surface that in the UI).
    func applySettings() {
        let snap = SettingsStore.snapshot()
        if let p = poller {
            Task { await p.updateInterval(.seconds(snap.pollIntervalSeconds)) }
        }
        // Deliberately NOT propagating `pollIntervalSeconds` to the Claude
        // poller: its endpoint is edge-rate-limited, the user's "every
        // 5 min" Codex preference would just earn 429s. It stays at the
        // 2 h cadence set in `startBackgroundPolling()`.
    }

    // MARK: - actions

    /// `minInterval` is honoured **only** by the auto-refresh-on-popover-open
    /// caller (it passes a non-nil interval). The explicit Refresh button
    /// passes nil → no gate → user-driven intent is never throttled.
    func refreshRateLimits(minInterval: TimeInterval? = nil) {
        guard !isRefreshingRateLimits else { return }
        let snap = SettingsStore.snapshot()
        // Hard gate: nothing external runs until the user has finished
        // onboarding. The popover's auto-refresh + the Refresh button
        // both route through here, and we don't want either spawning a
        // Codex app-server child before the user has even seen the
        // setup wizard.
        guard snap.hasCompletedProviderOnboarding else { return }
        // The Refresh button is hidden when Codex is disabled, but a
        // stale binding (e.g. user disabled Codex while a refresh was
        // in flight) could still call this — guard so we don't spawn a
        // child app-server process the user has explicitly opted out of.
        guard snap.enabledProviders.contains("codex") else { return }
        if let interval = minInterval, let last = lastRateLimitsRefreshAt,
           Date().timeIntervalSince(last) < interval {
            return
        }
        isRefreshingRateLimits = true
        lastError = nil

        Task { [appServer] in
            defer { Task { @MainActor in self.isRefreshingRateLimits = false } }
            // Codex side only. Claude `/usage` is fetched separately
            // via `refreshClaudeUsage()` — same Refresh button, but
            // routed through the Claude poller's own 60 s spam gap and
            // 429 cooldown so we can't earn rate-limit replies by
            // double-clicking.
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
                }
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
            }
        }
    }

    /// Ask the Claude `/usage` poller for a fresh fetch. Fire-and-forget:
    /// the poller's own 60 s spam gap and 429 cooldown decide whether
    /// the call actually goes through, and the snapshot (if any) lands
    /// via the `onSnapshot` callback. We surface nothing on a skip — a
    /// silently-dropped click is preferable to nag toasts.
    func refreshClaudeUsage() {
        let snap = SettingsStore.snapshot()
        // Hard gate: see `refreshRateLimits` — Keychain reads in
        // particular must not fire before the onboarding window.
        guard snap.hasCompletedProviderOnboarding else { return }
        guard snap.enabledProviders.contains("claude") else { return }
        guard let cp = claudeUsagePoller else { return }
        Task { await cp.pollOnce() }
    }

    /// Load the menu-bar snapshot. Always queries both providers + the
    /// Anthropic 5h block, regardless of `providerFilter`. Cheap enough to
    /// run on every popover open / scan / refresh.
    ///
    /// `precomputedBlocks` lets a caller that *just* loaded BillingBlocks
    /// (e.g. `refreshDashboard()`) hand the result through instead of
    /// re-running the same usage_events scan a second time. Nil means
    /// "no shared result, fetch fresh" — that's the right default for the
    /// stand-alone paths (popover open, scan completion, scenePhase wakeup).
    func refreshMenuBar(precomputedBlocks: BillingBlocks.Snapshot? = nil) {
        guard !isLoadingMenuBar else { return }
        isLoadingMenuBar = true
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isLoadingMenuBar = false } }
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
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
            }
        }
    }

    func refreshDashboard() {
        guard !isLoadingDashboard else { return }
        isLoadingDashboard = true

        let filter = providerFilter
        Task { [weak self] in
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
                self.refreshMenuBar(precomputedBlocks: blocks)
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
            }
        }
    }

    /// Promote the menu-bar app to a regular Dock-visible app so the
    /// dashboard window can take key focus.
    func activateForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Demote back to a menu-bar-only app once the last window closes.
    func demoteToAccessory() {
        NSApp.setActivationPolicy(.accessory)
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
