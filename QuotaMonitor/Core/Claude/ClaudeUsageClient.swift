import Foundation
import LocalAuthentication

/// Fetches live quota usage from Anthropic's OAuth-protected
/// `/api/oauth/usage` endpoint. The endpoint is undocumented but powers
/// the official `claude` CLI's quota meter and is the only source of
/// truth for Pro / Max plan usage.
///
/// **Refresh policy.** When the local token is expired (or the server
/// returns 401), this client refreshes the access token itself via
/// `ClaudeTokenRefresher` (a direct OAuth refresh-token grant), exactly
/// like the official `claude` CLI does. The rotated credentials are stored
/// in QuotaMonitor's **own** private cache (`ClaudeOAuthCache`) — never
/// written back to `~/.claude/.credentials.json` or Claude Code's Keychain
/// item — so a refresh can never strand the real `claude` login. Rationale:
/// the previous approach (spawn `claude --version` and wait for the Keychain
/// to update) does not actually rotate the token in current Claude Code, so
/// an expired token could never recover. Refresh tokens **rotate**
/// server-side, so QuotaMonitor prefers its own cached refresh token and
/// only bootstraps from Claude Code's token once.
///
/// Credential lookup order:
///   1. `~/.claude/.credentials.json` (file written by Claude Code CLI
///      on every login). No keychain prompt — strongly preferred.
///   2. macOS Keychain `Claude Code-credentials` service. The production
///      path shells through `/usr/bin/security` with a short timeout so a
///      background poller cannot hang inside Security.framework; if the
///      keychain cannot be read non-interactively, we surface the
///      credential as unavailable instead. Skipped entirely when policy
///      is `.never`.
///
/// Token requirement: scope must include `user:profile`. CLI-only tokens
/// scoped to `user:inference` get a 403 — we surface that as
/// `.insufficientScope` so the UI can tell the user to re-login.
actor ClaudeUsageClient: ClaudeUsageFetching {
    private static let fallbackClaudeCodeVersion = "2.1.0"

    enum FetchError: Error, CustomStringConvertible {
        case noCredentials
        case insufficientScope
        case unauthorized
        /// 429 Too Many Requests. `retryAfter` is the server-suggested
        /// cool-off in seconds (parsed from `Retry-After` header), or nil
        /// if the header was absent / unparseable.
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int, String)
        case malformed(String)
        case transport(any Error)

        var description: String {
            switch self {
            case .noCredentials:
                return "No Claude Code credentials found (run `claude login`)"
            case .insufficientScope:
                return "Claude token lacks the `user:profile` scope — re-run `claude login`"
            case .unauthorized:
                return "Claude token rejected (expired or revoked)"
            case .rateLimited(let retry):
                if let retry {
                    return "Anthropic /usage rate-limited (HTTP 429); retry in ~\(Int(retry))s"
                }
                return "Anthropic /usage rate-limited (HTTP 429)"
            case .http(let code, let body):
                return "Anthropic /usage HTTP \(code): \(body.prefix(120))"
            case .malformed(let s):
                return "malformed /usage response: \(s)"
            case .transport(let e):
                return "Anthropic /usage transport error: \(e)"
            }
        }

        /// Persistent auth failure (expired/revoked token, missing creds,
        /// bad scope) vs a transient 429 / network / HTTP blip. The menu bar
        /// uses this to surface an actionable re-login hint instead of
        /// leaving stale numbers up. Classified on the typed case — never by
        /// re-parsing the description, whose `.http` form embeds the server
        /// body and could otherwise false-match an auth keyword.
        var isAuthClass: Bool {
            switch self {
            case .noCredentials, .unauthorized, .insufficientScope:
                return true
            case .rateLimited, .http, .malformed, .transport:
                return false
            }
        }
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Performs the direct OAuth refresh-token grant. `nil` disables direct
    /// refresh (the token is then used until it 401s, surfacing `.unauthorized`).
    private let tokenRefresher: ClaudeTokenRefresher?
    /// Where refreshed credentials are cached. Injected in tests.
    private let oauthCacheURL: URL
    /// Test seam: overrides the real file + Keychain readers with a scripted
    /// candidate list so credential wiring can be tested without touching
    /// `~/.claude` or the real Keychain. `nil` in production.
    private let externalCredentialSources: (@Sendable () async -> [StoredCredentials])?
    private let claudeCodeVersionProvider: @Sendable () -> String?

    /// Parsed credentials regardless of expiry. Kept in a struct (not a
    /// bare `String`) so `loadAccessToken` can decide whether to delegate
    /// a refresh to the CLI without re-parsing.
    struct StoredCredentials {
        let accessToken: String
        /// Unix epoch in **milliseconds** (CLI convention). Optional —
        /// older captures didn't include it.
        let expiresAtMs: Double?
        let scopes: [String]?
        /// OAuth refresh token. Lets us mint a fresh access token directly
        /// (see `ClaudeTokenRefresher`) instead of waiting on the `claude`
        /// CLI. Optional — Keychain blobs and old captures may omit it.
        let refreshToken: String?
    }

    /// In-process token cache. Set on the first successful read; cleared
    /// when the server reports the token is bad (`unauthorized`) or when
    /// we trigger a CLI refresh. Avoids re-prompting the Keychain ACL on
    /// every poll.
    private var cachedToken: String?
    /// Tokens the server has 401'd in this process run. Treated as expired
    /// by `loadAccessToken` even when the source they came from claims
    /// they're locally fresh — e.g. the file's `expiresAtMs` is still in
    /// the future but Anthropic has already revoked the token server-side
    /// (split-brain refresh from another client, manual logout on web,
    /// etc.). Without this, the file-first shortcut would keep returning
    /// the same dead token forever, never falling through to the Keychain
    /// where the CLI may have written a fresh one. Cleared on the next
    /// successful 200 so a long-lived auth bounce doesn't accumulate.
    private var rejectedTokens: Set<String> = []
    /// Set to true when the user clicks "Deny" / cancels the prompt OR
    /// the keychain query would require UI / returns auth-class errors.
    /// Stops us from asking again in this process.
    private var keychainBlocked = false
    /// Single-flight guard for the direct refresh grant. Concurrent
    /// `fetch()` calls (e.g. a manual Refresh overlapping a scheduled poll)
    /// can both reach `performDirectRefresh` across the network suspension;
    /// without this they would fire two refresh-token grants and the second
    /// would burn the just-rotated refresh token. Concurrent callers await
    /// the same in-flight task instead.
    private var inFlightRefresh: Task<StoredCredentials?, Never>?

    init(
        session: URLSession = .shared,
        tokenRefresher: ClaudeTokenRefresher? = ClaudeTokenRefresher(),
        oauthCacheURL: URL = ClaudeOAuthCache.defaultFileURL(),
        externalCredentialSources: (@Sendable () async -> [StoredCredentials])? = nil,
        claudeCodeVersionProvider: @escaping @Sendable () -> String? = {
            ClaudeCodeVersionDetector.detectVersion()
        }
    ) {
        self.session = session
        self.tokenRefresher = tokenRefresher
        self.oauthCacheURL = oauthCacheURL
        self.externalCredentialSources = externalCredentialSources
        self.claudeCodeVersionProvider = claudeCodeVersionProvider
    }

    /// Test accessor for the private credential loader.
    func _loadAccessTokenForTest() async throws -> String? {
        try await loadAccessToken()
    }

    /// One-shot fetch. Caller decides retry / scheduling.
    func fetch() async throws -> ClaudeUsageSnapshot {
        try await fetchInternal(retryAfterRefresh: false)
    }

    /// `retryAfterRefresh` caps the 401-recovery loop at one extra round-trip.
    /// On the first 401 we ask the CLI to refresh and re-enter with
    /// `retryAfterRefresh = true`; if that 401s again we surface
    /// `.unauthorized` so the user sees a real failure.
    private func fetchInternal(retryAfterRefresh: Bool) async throws -> ClaudeUsageSnapshot {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            throw FetchError.noCredentials
        }
        // Resolve the Claude Code version for the User-Agent. (Token freshness
        // is handled by `loadAccessToken`'s direct refresh, not by any CLI
        // side effect.)
        let userAgent = Self.claudeCodeUserAgent(versionString: claudeCodeVersionProvider())
        guard let token = try await loadAccessToken() else {
            throw FetchError.noCredentials
        }

        let req = Self.makeUsageRequest(
            url: endpoint,
            token: token,
            userAgent: userAgent)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw FetchError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.malformed("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            // The token we just used works. Discard the rejection
            // ledger so a brief auth bounce earlier in this run doesn't
            // keep gating future reads against tokens that are once
            // again valid.
            rejectedTokens.removeAll()
            return try Self.decode(data: data, capturedAt: Date())
        case 401:
            // Server says the token is bad. Blacklist the exact token so
            // `loadAccessToken` won't keep handing it back from the
            // locally-fresh shortcut, and drop the in-process cache. Then
            // retry once: `loadAccessToken` now sees every source as
            // unusable and performs a direct refresh. If that can't produce
            // a fresher token (no refresh token, or the refresh itself
            // fails → RT revoked, user must re-login) we surface
            // `.unauthorized`.
            if let bad = cachedToken {
                rejectedTokens.insert(bad)
            }
            cachedToken = nil
            if !retryAfterRefresh {
                return try await fetchInternal(retryAfterRefresh: true)
            }
            throw FetchError.unauthorized
        case 403:
            // Anthropic returns 403 when token's scope doesn't include
            // `user:profile`. Distinguish from generic auth so we can
            // tell the user *why*.
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.lowercased().contains("scope") {
                throw FetchError.insufficientScope
            }
            throw FetchError.http(403, body)
        case 429:
            // Server-side rate limit. Honour `Retry-After` if present so
            // the poller can back off (default 30 min in the poller's
            // currentInterval). Otherwise the 5-min poll cadence will
            // self-amplify and keep getting 429'd.
            let retry = Self.retryAfterSeconds(from: http)
            throw FetchError.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
    }

    static func makeUsageRequest(
        url: URL,
        token: String,
        userAgent: String
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    static func claudeCodeUserAgent(versionString: String?) -> String {
        let version = normalizedClaudeCodeVersion(versionString)
            ?? fallbackClaudeCodeVersion
        return "claude-code/\(version)"
    }

    static func normalizedClaudeCodeVersion(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let pattern = #"[0-9]+(?:\.[0-9]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let matchRange = Range(match.range, in: raw) else {
            return nil
        }
        return String(raw[matchRange])
    }

    static func retryAfterSeconds(
        from response: HTTPURLResponse,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds > 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let remaining = date.timeIntervalSince(now)
        return remaining > 0 ? remaining.rounded() : nil
    }


    // MARK: - Decoding

    /// Parse the `/usage` response. The shape we observe:
    /// ```
    /// { "rate_limit_tier": "max5x",
    ///   "five_hour":  {"utilization": 60.0, "resets_at": "2026-..."},
    ///   "seven_day":  {"utilization": 12.0, "resets_at": "..."},
    ///   "seven_day_opus": {...}, "seven_day_sonnet": {...},
    ///   "limits": [{"kind": "weekly_scoped", "percent": 2.0,
    ///                "scope": {"model": {"display_name": "Fable"}}}]
    /// }
    /// ```
    /// All keys are optional — Free plans in particular omit most.
    /// `extra_usage` (pay-as-you-go overflow) is intentionally NOT
    /// decoded: the product team decided we don't surface dollar-billed
    /// overflow in CodexMonitor.
    static func decode(data: Data, capturedAt: Date) throws -> ClaudeUsageSnapshot {
        struct Wire: Decodable {
            let rate_limit_tier: String?
            let five_hour: WindowWire?
            let seven_day: WindowWire?
            let seven_day_opus: WindowWire?
            let seven_day_sonnet: WindowWire?
            let seven_day_fable: WindowWire?
            let limits: [ScopedLimitWire]?
        }
        struct WindowWire: Decodable {
            let utilization: Double?
            let used_percent: Double?
            let resets_at: String?
            let reset_at: String?
        }
        struct ScopedLimitWire: Decodable {
            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: ScopeWire?
        }
        struct ScopeWire: Decodable {
            let model: ScopeModelWire?
        }
        struct ScopeModelWire: Decodable {
            let display_name: String?
        }

        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw FetchError.malformed("\(error)")
        }

        func parseDate(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            return ISO8601.parse(s)
        }

        // Anthropic's `/api/oauth/usage` returns `utilization` as a literal
        // percentage (e.g. 1.0 means 1%). Older `used_percent` captures use
        // the same 0...100 scale. Magnitude cannot distinguish that scale
        // from an obsolete ratio-shaped capture: multiplying values <= 1.5
        // makes a fresh window jump from 1% to 100%.
        // Tests in `ClaudeUsageDecoderTests` lock this with real fixtures.
        func mkWindow(
            _ w: WindowWire?,
            duration: TimeInterval
        ) -> ClaudeUsageSnapshot.Window? {
            guard let w else { return nil }
            let resetStr = w.resets_at ?? w.reset_at
            guard let reset = parseDate(resetStr) else { return nil }
            let raw: Double
            if let u = w.utilization {
                raw = u
            } else if let p = w.used_percent {
                raw = p
            } else {
                return nil
            }
            return .init(usedPercent: raw, resetAt: reset, windowDuration: duration)
        }

        // The modern `limits[].percent` field is explicitly 0...100 too.
        func mkLimitWindow(
            _ w: ScopedLimitWire,
            duration: TimeInterval
        ) -> ClaudeUsageSnapshot.Window? {
            guard let percent = w.percent,
                  percent.isFinite,
                  let reset = parseDate(w.resets_at) else { return nil }
            return .init(
                usedPercent: percent,
                resetAt: reset,
                windowDuration: duration)
        }

        let structuredLimits = wire.limits ?? []
        let structuredFiveHour = structuredLimits
            .first { $0.kind == "session" }
            .flatMap { mkLimitWindow($0, duration: 5 * 3600) }
        let structuredSevenDay = structuredLimits
            .first { $0.kind == "weekly_all" }
            .flatMap { mkLimitWindow($0, duration: 7 * 86400) }

        // A short-lived top-level `seven_day_fable` variant is accepted as a
        // fallback. Fable is a modern field whose utilization is always a
        // literal percentage, even when `limits[]` is absent. The
        // self-describing limits array is the source of truth and replaces
        // the fallback when both are present.
        var weeklyScoped: [ClaudeUsageSnapshot.WeeklyScopedLimit] = []
        if let window = mkWindow(
            wire.seven_day_fable,
            duration: 7 * 86400) {
            weeklyScoped.append(.init(key: "fable", window: window))
        }
        for limit in structuredLimits where limit.kind == "weekly_scoped" {
            guard let wireName = limit.scope?.model?.display_name,
                  let key = ClaudeUsageSnapshot.WeeklyScopedLimit.canonicalKey(
                    for: wireName),
                  let window = mkLimitWindow(
                    limit,
                    duration: 7 * 86400) else { continue }
            let decoded = ClaudeUsageSnapshot.WeeklyScopedLimit(
                key: key,
                displayName: wireName,
                window: window)
            if let index = weeklyScoped.firstIndex(where: { $0.key == key }) {
                weeklyScoped[index] = decoded
            } else {
                weeklyScoped.append(decoded)
            }
        }

        return .init(
            capturedAt: capturedAt,
            tier: wire.rate_limit_tier,
            fiveHour: structuredFiveHour ?? mkWindow(
                wire.five_hour,
                duration: 5 * 3600),
            sevenDay: structuredSevenDay ?? mkWindow(
                wire.seven_day,
                duration: 7 * 86400),
            sevenDayOpus: mkWindow(
                wire.seven_day_opus,
                duration: 7 * 86400),
            sevenDaySonnet: mkWindow(
                wire.seven_day_sonnet,
                duration: 7 * 86400),
            weeklyScoped: weeklyScoped)
    }

    // MARK: - Credential loading

    /// Resolve a usable access token. Priority order:
    ///   1. QuotaMonitor's own refreshed cache (`ClaudeOAuthCache`).
    ///   2. `~/.claude/.credentials.json` (cheap, no Keychain prompt).
    ///   3. Claude Code's Keychain item (read non-interactively).
    ///
    /// **Expired-token path.** When every source is expired or has been
    /// server-rejected this run, perform a direct OAuth refresh
    /// (`ClaudeTokenRefresher`) using the highest-priority refresh token and
    /// persist the result to the private cache. On refresh failure we return
    /// the best stale token so the eventual 401 path surfaces a real
    /// `.unauthorized` instead of silently returning nil.
    private func loadAccessToken() async throws -> String? {
        if let cached = cachedToken {
            return cached
        }

        // 1. Our own refreshed cache holds the freshest token we minted.
        let cacheCreds = ClaudeOAuthCache.load(fileURL: oauthCacheURL)
        if let c = cacheCreds, isUsable(c) {
            cachedToken = c.accessToken
            return c.accessToken
        }

        // 2 & 3. External sources (Claude Code's file, then Keychain). In
        // production these are read lazily so a usable file token never
        // triggers a Keychain prompt; tests script them via the seam.
        var candidates: [StoredCredentials] = []
        if let c = cacheCreds { candidates.append(c) }

        if let override = externalCredentialSources {
            let external = await override()
            for e in external where isUsable(e) {
                cachedToken = e.accessToken
                return e.accessToken
            }
            candidates.append(contentsOf: external)
        } else {
            // Strictly file-first. The Keychain read is what triggers
            // macOS's password prompt when the running binary's code
            // signature doesn't match the item's ACL — so skip it entirely
            // when the file already holds a fresh, not-rejected token.
            let fileCreds = Self.readStoredCredentialsFile()
            if let f = fileCreds, isUsable(f) {
                cachedToken = f.accessToken
                return f.accessToken
            }
            let kcCreds = await readKeychainCredsIfAllowed()
            if let k = kcCreds, isUsable(k) {
                cachedToken = k.accessToken
                return k.accessToken
            }
            if let f = fileCreds { candidates.append(f) }
            if let k = kcCreds { candidates.append(k) }
        }

        // Nothing usable. Try a direct refresh; fall back to a stale token
        // so the server can surface a real `.unauthorized`.
        guard !candidates.isEmpty else { return nil }

        if let exp = candidates.first?.expiresAtMs {
            DeveloperLog.eventRecord(
                "claude_credentials.expired",
                category: "poller",
                provider: "claude",
                fields: ["expires_at_ms": .double(exp)])
        }

        if case .mustRefresh(let refreshToken) = Self.resolveToken(
            candidates: candidates, rejected: rejectedTokens),
           let refreshed = await performDirectRefresh(
            refreshToken: refreshToken, candidates: candidates) {
            cachedToken = refreshed.accessToken
            return refreshed.accessToken
        }

        if let stale = candidates.first {
            cachedToken = stale.accessToken
            return stale.accessToken
        }
        return nil
    }

    /// Mint a fresh access token from `refreshToken`, persist it to the
    /// private cache (carrying over the source's scopes), and return it.
    /// Returns nil when no refresher is configured or the refresh fails.
    /// Never touches `~/.claude` or Claude Code's Keychain.
    /// Single-flight wrapper around `doDirectRefresh`. The check-then-set of
    /// `inFlightRefresh` runs with no suspension point between, so two
    /// concurrent callers can't both create a grant: the first installs the
    /// task, the second awaits it.
    private func performDirectRefresh(
        refreshToken: String,
        candidates: [StoredCredentials]
    ) async -> StoredCredentials? {
        if let existing = inFlightRefresh {
            return await existing.value
        }
        let task = Task<StoredCredentials?, Never> { [refreshToken, candidates] in
            await self.doDirectRefresh(refreshToken: refreshToken, candidates: candidates)
        }
        inFlightRefresh = task
        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    private func doDirectRefresh(
        refreshToken: String,
        candidates: [StoredCredentials]
    ) async -> StoredCredentials? {
        guard let refresher = tokenRefresher else { return nil }

        // Distinct refresh tokens to try, highest-priority first: the one
        // `resolveToken` picked, then any others the candidate sources carry.
        // A revoked *cached* refresh token must not permanently block recovery
        // — if it 4xxes we drop the poisoned cache and fall through to the
        // lower-priority file / Keychain refresh token in the same pass.
        var ordered: [String] = []
        var seen = Set<String>()
        for rt in [refreshToken] + candidates.compactMap(\.refreshToken)
        where !rt.isEmpty && seen.insert(rt).inserted {
            ordered.append(rt)
        }

        for rt in ordered {
            let scopes = candidates.first { $0.refreshToken == rt }?.scopes
            do {
                let refreshed = try await refresher.refresh(refreshToken: rt)
                ClaudeOAuthCache.save(refreshed, scopes: scopes, fileURL: oauthCacheURL)
                // The freshly-minted token is valid again even if a prior token
                // was rejected earlier this run.
                rejectedTokens.remove(refreshed.accessToken)
                Log.poller.info(
                    "claude token refreshed directly (expires \(refreshed.expiresAtMs, privacy: .public)ms)")
                DeveloperLog.eventRecord(
                    "claude_token.refresh.finish",
                    category: "poller",
                    provider: "claude",
                    result: "success",
                    fields: ["expires_at_ms": .double(refreshed.expiresAtMs)])
                return StoredCredentials(
                    accessToken: refreshed.accessToken,
                    expiresAtMs: refreshed.expiresAtMs,
                    scopes: scopes,
                    refreshToken: refreshed.refreshToken)
            } catch {
                // Log only the error TYPE to OSLog — never the server response
                // body, which `RefreshError.http`'s description embeds. The
                // sanitized DeveloperLog file path keeps the detail.
                Log.poller.error(
                    "claude token refresh failed: \(String(describing: type(of: error)), privacy: .public)")
                DeveloperLog.eventRecord(
                    "claude_token.refresh.fail",
                    level: .error,
                    category: "poller",
                    provider: "claude",
                    result: "failure",
                    message: String(describing: error),
                    fields: ["error_type": .string(String(describing: type(of: error)))])

                let definitive = Self.isDefinitiveRefreshFailure(error)
                // A definitively-rejected *cached* refresh token is poison —
                // delete the cache so it stops shadowing valid lower-priority
                // sources on the next poll (and this pass).
                if definitive, ClaudeOAuthCache.load(fileURL: oauthCacheURL)?.refreshToken == rt {
                    ClaudeOAuthCache.clear(fileURL: oauthCacheURL)
                }
                // Transient failures (network / 5xx) shouldn't burn through the
                // other refresh tokens — bail and let the next poll retry. Only
                // a definitive rejection justifies trying the next token.
                if !definitive { return nil }
            }
        }
        return nil
    }

    /// A refresh failure the server will keep rejecting (a 4xx such as
    /// `invalid_grant`), as opposed to a transient network / 5xx blip we
    /// should simply retry later.
    static func isDefinitiveRefreshFailure(_ error: any Error) -> Bool {
        if case ClaudeTokenRefresher.RefreshError.http(let code, _) = error {
            return (400..<500).contains(code)
        }
        return false
    }

    /// A credential is usable when it's not locally expired AND its
    /// access token hasn't been rejected by the server during this
    /// process run.
    private func isUsable(_ creds: StoredCredentials) -> Bool {
        !Self.isExpired(creds) && !rejectedTokens.contains(creds.accessToken)
    }

    /// Wraps the Keychain fallback in actor-state-aware error handling.
    /// Sets `keychainBlocked` on no-such-item or reads that would
    /// require Keychain UI so we don't keep retrying a path that cannot
    /// complete from a background poller.
    private func readKeychainCredsIfAllowed() async -> StoredCredentials? {
        guard LocalQAEnvironment.allowsExternalDataSources() else { return nil }
        let snap = SettingsStore.snapshot()
        guard snap.keychainPolicy != .never, !keychainBlocked else { return nil }
        switch Self.readKeychainTokenOutcomeViaSecurityTool(timeout: 2) {
        case .ok(_, let raw):
            // Mirror to disk when enabled. This turns the next-launch
            // behaviour from "Keychain prompt" into "silent file read",
            // because the file is read first and only falls through to
            // Keychain when the file is missing/stale. For the security
            // trade-off, see `SettingsStore.mirrorClaudeKeychainToFile`.
            if snap.mirrorClaudeKeychainToFile {
                Self.writeStoredCredentialsFile(jsonData: raw)
            }
            return Self.parseCredentials(jsonData: raw)
        case .denied, .interactionNotAllowed, .notFound:
            keychainBlocked = true
            DeveloperLog.eventRecord(
                "claude_credentials.keychain.unavailable",
                category: "poller",
                provider: "claude",
                result: "skipped")
            return nil
        case .otherError:
            return nil
        }
    }

    /// Read `~/.claude/.credentials.json`. Format observed:
    /// ```
    /// { "claudeAiOauth": { "accessToken": "...", "refreshToken": "...",
    ///                      "expiresAt": 1735000000000, "scopes": [...] } }
    /// ```
    /// We only read; we never write. If the file is stale and the CLI's
    /// Keychain copy is fresher (CLI ≥ 2.1.x stops mirroring refreshes
    /// to disk), `loadAccessToken` falls through to the Keychain path.
    static func readStoredCredentialsFile() -> StoredCredentials? {
        let path = credentialsFilePath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return parseCredentials(jsonData: data)
    }

    /// Mirror a Keychain-sourced credentials blob to
    /// `~/.claude/.credentials.json`. Controlled by
    /// `SettingsStore.mirrorClaudeKeychainToFile` (default ON when the
    /// preference is missing) — see the setting's doc for the security
    /// trade-off.
    ///
    /// Implementation notes:
    ///   - Writes to a temporary sibling then `rename(2)`s into place
    ///     so a crash mid-write can never leave a half-written file.
    ///   - Permissions clamp to 0600 (owner-only). The CLI uses the
    ///     same mode so we're not weakening any guarantee that was
    ///     already there.
    ///   - If the destination file already contains a *fresher* token
    ///     (greater `expiresAtMs`) we leave it alone — this catches
    ///     the rare case where the CLI just refreshed and we're
    ///     about to overwrite with a stale Keychain copy.
    ///   - Errors are logged but never thrown; the caller's bearer
    ///     token is unaffected if the mirror fails.
    static func writeStoredCredentialsFile(jsonData: Data) {
        guard let new = parseCredentials(jsonData: jsonData) else { return }
        let path = credentialsFilePath()
        let url = URL(fileURLWithPath: path)
        // Don't overwrite a fresher file the CLI may have just written.
        if let existing = readStoredCredentialsFile(),
           let exMs = existing.expiresAtMs,
           let newMs = new.expiresAtMs,
           exMs > newMs {
            return
        }
        do {
            // Make sure the parent dir exists. Claude Code creates
            // `~/.claude/` on first login but a fresh dev box that's
            // never run the CLI won't have it.
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Atomic write via NSData's `.atomic` option (writes to a
            // tempfile then renames). Then chmod down — `.atomic`
            // doesn't take attribute hints so we set 0600 in a second
            // step. The two-step window is fine because the rename
            // result inherits umask, which on macOS dev boxes is
            // already 0022 → 0644 worst case before chmod runs.
            try jsonData.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            Log.poller.info(
                "mirrored Claude credentials to \(path, privacy: .public) (expires \(new.expiresAtMs ?? 0, privacy: .public)ms)")
            DeveloperLog.eventRecord(
                "claude_credentials.mirror.finish",
                category: "poller",
                provider: "claude",
                result: "success",
                fields: [
                    "path": .string(path),
                    "expires_at_ms": .double(new.expiresAtMs ?? 0)
                ])
        } catch {
            Log.poller.error(
                "failed to mirror Claude credentials to disk: \(error.localizedDescription, privacy: .public)")
            DeveloperLog.eventRecord(
                "claude_credentials.mirror.fail",
                level: .error,
                category: "poller",
                provider: "claude",
                result: "failure",
                message: error.localizedDescription,
                fields: [
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
        }
    }

    /// Returns true when the stored credentials are within 60s of expiry
    /// (or already past). Tokens with no `expiresAtMs` are treated as
    /// fresh — older CLI captures didn't include the field.
    static func isExpired(_ creds: StoredCredentials, now: Date = Date()) -> Bool {
        guard let expMs = creds.expiresAtMs else { return false }
        return now.timeIntervalSince1970 >= (expMs / 1000.0 - 60)
    }

    /// Outcome of inspecting the candidate credential sources.
    enum TokenResolution: Equatable {
        /// A usable (unexpired, not server-rejected) access token.
        case ready(String)
        /// Every candidate is unusable, but here's the highest-priority
        /// refresh token to mint a fresh one with.
        case mustRefresh(String)
        /// Nothing usable and no refresh token to recover with.
        case unavailable
    }

    /// Pure decision used by `loadAccessToken`. `candidates` are the
    /// credential sources in priority order (QM cache → file → Keychain).
    /// Picks the first usable token; failing that, the first refresh token;
    /// failing that, `.unavailable`. Preferring the highest-priority refresh
    /// token means we re-use QuotaMonitor's own (cache) rotation chain and
    /// only bootstrap from Claude Code's token when we have none of our own.
    static func resolveToken(
        candidates: [StoredCredentials],
        rejected: Set<String>,
        now: Date = Date()
    ) -> TokenResolution {
        for creds in candidates
        where !isExpired(creds, now: now) && !rejected.contains(creds.accessToken) {
            return .ready(creds.accessToken)
        }
        for creds in candidates {
            if let rt = creds.refreshToken, !rt.isEmpty {
                return .mustRefresh(rt)
            }
        }
        return .unavailable
    }

    /// Parse the canonical `{"claudeAiOauth": {...}}` wrapper. Used by
    /// both the file reader and the Keychain reader.
    static func parseCredentials(jsonData: Data) -> StoredCredentials? {
        struct Wrapper: Decodable {
            struct Inner: Decodable {
                let accessToken: String?
                let refreshToken: String?
                let expiresAt: Double?
                let scopes: [String]?
            }
            let claudeAiOauth: Inner?
        }
        guard let inner = (try? JSONDecoder().decode(Wrapper.self, from: jsonData))?
                .claudeAiOauth,
              let access = inner.accessToken
        else { return nil }
        return StoredCredentials(
            accessToken: access,
            expiresAtMs: inner.expiresAt,
            scopes: inner.scopes,
            refreshToken: inner.refreshToken)
    }

    /// Resolve `~/.claude/.credentials.json`.
    static func credentialsFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String {
        let homeDirectory = LocalQAEnvironment.homeDirectory(
            environment: environment,
            arguments: arguments)
        let home = (homeDirectory.path as NSString).appendingPathComponent(".claude")
        return (home as NSString).appendingPathComponent(".credentials.json")
    }


    /// Outcome of a keychain read.
    enum KeychainOutcome: Sendable {
        case ok(token: String, raw: Data)
        case notFound
        case denied               // user clicked Deny, or item ACL refused us
        case interactionNotAllowed // we asked for non-interactive read and it'd need UI
        case otherError
    }

    static func readKeychainTokenOutcomeViaSecurityTool(
        timeout: TimeInterval
    ) -> KeychainOutcome {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            return .notFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .otherError
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .interactionNotAllowed
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: err, encoding: .utf8)?.lowercased() ?? ""
            if message.contains("could not be found") || message.contains("not found") {
                return .notFound
            }
            if message.contains("user interaction is not allowed") {
                return .interactionNotAllowed
            }
            return .otherError
        }
        return decodeKeychainPasswordData(out)
    }

    static func decodeKeychainPasswordData(_ data: Data) -> KeychainOutcome {
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return .otherError }
        let bytes = Data(raw.utf8)
        if let creds = parseCredentials(jsonData: bytes) {
            return .ok(token: creds.accessToken, raw: bytes)
        }
        if (try? JSONSerialization.jsonObject(with: bytes)) != nil {
            return .otherError
        }
        return .ok(token: raw, raw: bytes)
    }

    /// Pull `Claude Code-credentials` (service name) generic password from
    /// the login keychain without allowing Security.framework to present
    /// authentication UI. This runs from a background poller; an
    /// interactive prompt can otherwise leave the poller permanently
    /// suspended with no log output.
    ///
    /// **Multiple-item disambiguation.** Some dev machines (and previous
    /// CodexMonitor bugs) ended up with more than one item under this
    /// service. `kSecMatchLimitOne` returns an arbitrary match, which
    /// can be the stale one — we observed exactly this on 2026-05-07.
    /// Borrowed from CodexBar: query with `kSecMatchLimitAll`, sort by
    /// `kSecAttrModificationDate` desc, then re-fetch the data of the
    /// freshest persistent ref. CodexBar source:
    /// https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift#L1485-L1517
    static func readKeychainTokenOutcome() -> KeychainOutcome {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            return .notFound
        }
        let listQuery = keychainListQuery()
        var listResult: CFTypeRef?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        switch listStatus {
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed
        case errSecSuccess:
            break
        default:
            return .otherError
        }
        guard let items = listResult as? [[String: Any]], !items.isEmpty else {
            return .notFound
        }
        // Sort by modification date desc; fall back to creation date,
        // then to insertion order.
        let sorted = items.enumerated().sorted { lhs, rhs in
            let lDate = (lhs.element[kSecAttrModificationDate as String] as? Date)
                ?? (lhs.element[kSecAttrCreationDate as String] as? Date)
                ?? .distantPast
            let rDate = (rhs.element[kSecAttrModificationDate as String] as? Date)
                ?? (rhs.element[kSecAttrCreationDate as String] as? Date)
                ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.offset < rhs.offset
        }
        guard let ref = sorted.first?.element[kSecValuePersistentRef as String] as? Data else {
            return .otherError
        }
        // Re-fetch the data using the persistent ref of the freshest item.
        let dataQuery = keychainDataQuery(persistentRef: ref)
        var dataResult: CFTypeRef?
        let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
        switch dataStatus {
        case errSecSuccess:
            guard let data = dataResult as? Data else { return .otherError }
            // Keychain may contain either the bare token or the same
            // JSON wrapper as the on-disk file. Use the canonical parser
            // so we tolerate non-string fields like `expiresAt: 1778…`
            // (Number).
            if let creds = parseCredentials(jsonData: data) {
                return .ok(token: creds.accessToken, raw: data)
            }
            // If the blob *parses as JSON* but we couldn't extract creds,
            // it's a shape we don't understand — DO NOT fall through to
            // returning the raw JSON as a token (that's how the
            // pre-2026-05-07 bug snuck through and returned a 1+KB blob
            // as the bearer).
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .otherError
            }
            // Genuine bare-string token (very old captures).
            if let s = String(data: data, encoding: .utf8) {
                return .ok(token: s.trimmingCharacters(in: .whitespacesAndNewlines), raw: data)
            }
            return .otherError
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed
        default:
            return .otherError
        }
    }

    static func keychainListQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: nonInteractiveKeychainContext(),
            keychainAuthenticationUIKey: keychainAuthenticationUIFailValue,
        ]
    }

    static func keychainDataQuery(persistentRef: Data) -> [String: Any] {
        [
            kSecValuePersistentRef as String: persistentRef,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: nonInteractiveKeychainContext(),
            keychainAuthenticationUIKey: keychainAuthenticationUIFailValue,
        ]
    }

    // `kSecUseAuthenticationUIFail` is deprecated in favor of LAContext, but
    // the older generic-password path can still ignore LAContext on macOS.
    // Keep the public constant's raw value here so we get the old no-UI
    // behavior without pulling a deprecation warning into every build.
    static let keychainAuthenticationUIKey = kSecUseAuthenticationUI as String
    static let keychainAuthenticationUIFailValue = "u_AuthUIF"

    private static func nonInteractiveKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Persist `keychainPolicy = .never` on the main actor. Currently
    /// only invoked by the "Disable now" button surfaced in the menu bar
    /// after we detect a denial.
    static func persistKeychainDisabled() async {
        await MainActor.run {
            SettingsStore.shared.keychainPolicy = .never
        }
    }

}

enum ClaudeCodeVersionDetector {
    private static let cachedVersion: String? = detectVersionUncached()

    static func detectVersion() -> String? {
        cachedVersion
    }

    private static func detectVersionUncached() -> String? {
        guard LocalQAEnvironment.allowsExternalDataSources() else { return nil }
        let env = augmentedEnvironment()
        let home = env["HOME"] ?? NSHomeDirectory()
        guard let binary = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: env["CLAUDE_BINARY"],
            home: home,
            loginShellPath: discoverClaudeViaLoginShell(environment: env),
            path: env["PATH"] ?? "",
            desktopBundlePath: ClaudeBinaryLocator.discoverClaudeDesktopBundle(
                home: home,
                isExecutable: FileManager.default.isExecutableFile(atPath:)),
            isExecutable: FileManager.default.isExecutableFile(atPath:))
        else { return nil }
        return versionFromPath(binary) ?? versionFromProcess(binary: binary, environment: env)
    }

    private static func versionFromPath(_ path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let marker = components.firstIndex(of: "claude-code"),
              components.indices.contains(marker + 1) else { return nil }
        return ClaudeUsageClient.normalizedClaudeCodeVersion(components[marker + 1])
    }

    private static func versionFromProcess(
        binary: String,
        environment: [String: String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = [
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
        ].compactMap { $0 }.joined(separator: "\n")
        let userAgent = ClaudeUsageClient.claudeCodeUserAgent(versionString: output)
        let version = userAgent.replacingOccurrences(of: "claude-code/", with: "")
        return version == "2.1.0" ? nil : version
    }

    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
        ]
        let loginParts = (loginShellPATH(environment: env) ?? "")
            .split(separator: ":")
            .map(String.init)
        let existingParts = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let merged = (loginParts + extras + existingParts).reduce(into: [String]()) { acc, dir in
            if !acc.contains(dir) { acc.append(dir) }
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    private static func loginShellPATH(environment: [String: String]) -> String? {
        runLoginShellLine(
            environment: environment,
            command: #"printf %s "$PATH""#)
    }

    private static func discoverClaudeViaLoginShell(environment: [String: String]) -> String? {
        runLoginShellLine(
            environment: environment,
            command: "command -v claude")
    }

    private static func runLoginShellLine(
        environment: [String: String],
        command: String
    ) -> String? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", command]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
