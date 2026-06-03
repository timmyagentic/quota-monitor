import Foundation
import LocalAuthentication

/// Fetches live quota usage from Anthropic's OAuth-protected
/// `/api/oauth/usage` endpoint. The endpoint is undocumented but powers
/// the official `claude` CLI's quota meter and is the only source of
/// truth for Pro / Max plan usage.
///
/// **Refresh policy.** This client never refreshes the access token
/// itself. When the local token is expired (or the server returns 401),
/// we delegate the actual OAuth refresh to the user's `claude` CLI by
/// spawning it via `ClaudeCLIRefreshTrigger`. The CLI rotates the
/// refresh token in the system Keychain, then we re-read the freshest
/// access token. Rationale: refresh tokens **rotate** server-side; if
/// both the CLI and CodexMonitor refresh independently, whoever loses
/// the race ends up holding a revoked refresh token and breaks the
/// other process for hours. Letting the CLI own the refresh keeps the
/// CLI working, and we just consume what it produces.
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
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshTrigger: ClaudeCLIRefreshTrigger

    /// Parsed credentials regardless of expiry. Kept in a struct (not a
    /// bare `String`) so `loadAccessToken` can decide whether to delegate
    /// a refresh to the CLI without re-parsing.
    struct StoredCredentials {
        let accessToken: String
        /// Unix epoch in **milliseconds** (CLI convention). Optional —
        /// older captures didn't include it.
        let expiresAtMs: Double?
        let scopes: [String]?
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

    init(
        session: URLSession = .shared,
        refreshTrigger: ClaudeCLIRefreshTrigger = ClaudeCLIRefreshTrigger.shared
    ) {
        self.session = session
        self.refreshTrigger = refreshTrigger
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
        guard let token = try await loadAccessToken() else {
            throw FetchError.noCredentials
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Required header per Anthropic's beta gating. Matches CodexBar.
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaMonitor/0.2", forHTTPHeaderField: "User-Agent")

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
            // the next `loadAccessToken` call doesn't keep handing it
            // back from the locally-fresh file shortcut, and drop the
            // cache. Then ask the CLI to refresh once. If that doesn't
            // produce a fresher token (CLI not installed, refresh-cooldown
            // active, RT revoked → user must re-login) we surface
            // .unauthorized.
            if let bad = cachedToken {
                rejectedTokens.insert(bad)
            }
            cachedToken = nil
            if !retryAfterRefresh, await refreshTrigger.triggerRefreshIfAllowed() {
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
            let retry = (http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init))
            throw FetchError.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
    }


    // MARK: - Decoding

    /// Parse the `/usage` response. The shape we observe:
    /// ```
    /// { "rate_limit_tier": "max5x",
    ///   "five_hour":  {"utilization": 60.0, "resets_at": "2026-..."},
    ///   "seven_day":  {"utilization": 12.0, "resets_at": "..."},
    ///   "seven_day_opus": {...}, "seven_day_sonnet": {...}
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
        }
        struct WindowWire: Decodable {
            let utilization: Double?
            let used_percent: Double?
            let resets_at: String?
            let reset_at: String?
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

        // Anthropic's current `/api/oauth/usage` returns `utilization`
        // already in percent (e.g. 60.0 means 60%). Older CodexBar
        // captures showed `used_percent` as 0..100 too. Some very early
        // beta captures used 0..1 ratios — we keep that compat by
        // heuristic: a value <= 1.5 is treated as a 0..1 ratio (so 0.42
        // → 42%), anything larger is already a percent.
        // Tests in `ClaudeUsageDecoderTests` lock this with real fixtures.
        func mkWindow(_ w: WindowWire?, duration: TimeInterval) -> ClaudeUsageSnapshot.Window? {
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
            let pct = raw <= 1.5 ? raw * 100 : raw
            return .init(usedPercent: pct, resetAt: reset, windowDuration: duration)
        }

        return .init(
            capturedAt: capturedAt,
            tier: wire.rate_limit_tier,
            fiveHour:    mkWindow(wire.five_hour,        duration: 5 * 3600),
            sevenDay:    mkWindow(wire.seven_day,        duration: 7 * 86400),
            sevenDayOpus:   mkWindow(wire.seven_day_opus,   duration: 7 * 86400),
            sevenDaySonnet: mkWindow(wire.seven_day_sonnet, duration: 7 * 86400))
    }

    // MARK: - Credential loading

    /// File-first, keychain-fallback. Returns nil only when neither source
    /// yielded a token (caller turns it into `.noCredentials`).
    ///
    /// **Expired-token path.** When the local token is expired we ask the
    /// CLI to refresh (synchronously, with a short timeout — see
    /// `ClaudeCLIRefreshTrigger`). On success we re-read; on failure we
    /// surface whatever stale token we had so the eventual 401 path can
    /// fail explicitly rather than silently returning nil.
    private func loadAccessToken() async throws -> String? {
        if let cached = cachedToken {
            return cached
        }

        // Strictly file-first. The Keychain read is what triggers
        // macOS's password prompt when the running binary's code
        // signature doesn't match the item's ACL — and ad-hoc dev
        // rebuilds invalidate that ACL on every launch. So skip the
        // Keychain entirely when the file already holds a fresh,
        // not-server-rejected token.
        let fileCreds = Self.readStoredCredentialsFile()
        if let f = fileCreds, isUsable(f) {
            cachedToken = f.accessToken
            return f.accessToken
        }

        // File missing, locally stale, or carrying a token the server
        // has already 401'd. Consult the Keychain — the CLI writes
        // refreshes there, so it may hold a newer token even when the
        // file looks locally fresh.
        let kcCreds = await readKeychainCredsIfAllowed()
        if let k = kcCreds, isUsable(k) {
            cachedToken = k.accessToken
            return k.accessToken
        }

        // Both stale (or only one source exists and it's stale). Ask the
        // CLI to refresh. The trigger handles its own coalescing and
        // cooldown — multiple concurrent expired-token detections share
        // a single `claude` invocation.
        if fileCreds != nil || kcCreds != nil {
            if let exp = (fileCreds ?? kcCreds)?.expiresAtMs {
                Log.poller.info("claude token expired (\(exp, privacy: .public)ms), asking CLI to refresh")
                DeveloperLog.eventRecord(
                    "claude_credentials.expired",
                    category: "poller",
                    provider: "claude",
                    fields: ["expires_at_ms": .double(exp)])
            }
            if await refreshTrigger.triggerRefreshIfAllowed() {
                // Re-read after the CLI updates the Keychain (and
                // possibly the file). Same file-first ordering — if the
                // CLI rewrote the file we don't need to touch the
                // Keychain again.
                if let f = Self.readStoredCredentialsFile(), isUsable(f) {
                    cachedToken = f.accessToken
                    return f.accessToken
                }
                if let k = await readKeychainCredsIfAllowed(), isUsable(k) {
                    cachedToken = k.accessToken
                    return k.accessToken
                }
            }
            // Refresh blocked or didn't help. Return whatever stale
            // token we have so the caller can hit the server and
            // surface a real `unauthorized`.
            if let f = fileCreds {
                cachedToken = f.accessToken
                return f.accessToken
            }
            if let k = kcCreds {
                cachedToken = k.accessToken
                return k.accessToken
            }
        }

        return nil
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
            // Mirror to disk if the user has explicitly opted in. This
            // turns the next-launch behaviour from "Keychain prompt"
            // into "silent file read", because the file is read first
            // and only falls through to Keychain when the file is
            // missing/stale. Why opt-in: see
            // `SettingsStore.mirrorClaudeKeychainToFile` doc.
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
    /// `~/.claude/.credentials.json`. Opt-in via
    /// `SettingsStore.mirrorClaudeKeychainToFile` (default OFF) — see
    /// the setting's doc for the security rationale.
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
    static func isExpired(_ creds: StoredCredentials) -> Bool {
        guard let expMs = creds.expiresAtMs else { return false }
        return Date().timeIntervalSince1970 >= (expMs / 1000.0 - 60)
    }

    /// Parse the canonical `{"claudeAiOauth": {...}}` wrapper. Used by
    /// both the file reader and the Keychain reader.
    static func parseCredentials(jsonData: Data) -> StoredCredentials? {
        struct Wrapper: Decodable {
            struct Inner: Decodable {
                let accessToken: String?
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
            scopes: inner.scopes)
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
