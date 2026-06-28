import Foundation

/// QuotaMonitor's **private** store for Claude OAuth credentials that it
/// refreshed itself (via `ClaudeTokenRefresher`).
///
/// Deliberately lives under QuotaMonitor's own Application Support dir —
/// **never** `~/.claude/.credentials.json` and **never** Claude Code's
/// Keychain item. Anthropic rotates the refresh token on every grant, so if
/// we wrote our rotation back into Claude Code's store we could leave the
/// CLI holding a revoked token and force the user to re-login. Keeping our
/// own copy means a refresh can never corrupt the real `claude` login; the
/// trade-off is that QuotaMonitor and Claude Code maintain independent token
/// chains after the first bootstrap.
///
/// Stored in the canonical `{"claudeAiOauth": {...}}` shape so it loads back
/// through `ClaudeUsageClient.parseCredentials`.
enum ClaudeOAuthCache {

    /// `<appSupport>/QuotaMonitor/claude-oauth.json`. Honours the LocalQA
    /// home/app-support redirection so QA + tests stay isolated.
    static func defaultFileURL() -> URL {
        LocalQAEnvironment.applicationSupportDirectory()
            .appendingPathComponent("QuotaMonitor", isDirectory: true)
            .appendingPathComponent("claude-oauth.json")
    }

    /// Load previously-refreshed credentials, or nil when the cache is
    /// missing / unreadable / malformed.
    static func load(fileURL: URL = defaultFileURL()) -> ClaudeUsageClient.StoredCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return ClaudeUsageClient.parseCredentials(jsonData: data)
    }

    /// Delete the cache file. Called when the cached refresh token is
    /// definitively rejected (4xx invalid_grant) — otherwise a poisoned cache
    /// would shadow the still-valid file / Keychain tokens forever, since the
    /// cache is the highest-priority source. Best-effort; a missing file is
    /// not an error.
    static func clear(fileURL: URL = defaultFileURL()) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Persist refreshed credentials. Atomic write, clamped to 0600. Errors
    /// are logged but never thrown — a failed cache write must not break the
    /// in-memory token the caller is about to use.
    static func save(
        _ creds: RefreshedClaudeCredentials,
        scopes: [String]?,
        fileURL: URL = defaultFileURL()
    ) {
        var oauth: [String: Any] = [
            "accessToken": creds.accessToken,
            "expiresAt": creds.expiresAtMs,
        ]
        if let refreshToken = creds.refreshToken { oauth["refreshToken"] = refreshToken }
        if let scopes { oauth["scopes"] = scopes }
        let wrapper: [String: Any] = ["claudeAiOauth": oauth]
        guard let data = try? JSONSerialization.data(
            withJSONObject: wrapper, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            DeveloperLog.eventRecord(
                "claude_oauth_cache.write",
                category: "poller",
                provider: "claude",
                result: "success",
                fields: ["expires_at_ms": .double(creds.expiresAtMs)])
        } catch {
            Log.poller.error(
                "failed to write Claude OAuth cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
