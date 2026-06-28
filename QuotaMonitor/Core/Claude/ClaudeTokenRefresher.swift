import Foundation

/// Credentials produced by a successful refresh-token grant.
struct RefreshedClaudeCredentials: Sendable, Equatable {
    let accessToken: String
    /// Rotated refresh token. Anthropic rotates the refresh token on every
    /// grant, so the *new* one must be stored for the next refresh. Absent
    /// only if the server unexpectedly omits it.
    let refreshToken: String?
    /// Unix epoch in **milliseconds** (matching the on-disk CLI convention)
    /// at which the new access token expires.
    let expiresAtMs: Double
}

/// Mints a fresh Claude access token directly from a refresh token, the
/// same way the official `claude` CLI does — `POST`ing the refresh token to
/// Anthropic's OAuth token endpoint with the public Claude Code client_id.
///
/// **Why this exists.** The previous strategy (spawn `claude --version` and
/// wait for the Keychain to update) does not actually rotate the token in
/// current Claude Code, so an expired token could never recover. This
/// performs the refresh ourselves. The rotated credentials are persisted to
/// QuotaMonitor's *own* private store (`ClaudeOAuthCache`) — never back to
/// `~/.claude/.credentials.json` or Claude Code's Keychain item — so we can
/// never corrupt the user's real `claude` login.
///
/// Modelled on CodexBar's `ClaudeOAuthCredentialsStore`.
actor ClaudeTokenRefresher {
    /// Public OAuth client identifier used by the Claude Code CLI.
    /// Overridable via env for forward-compat if Anthropic rotates it.
    static let defaultClientID: String = {
        ProcessInfo.processInfo.environment["QM_CLAUDE_OAUTH_CLIENT_ID"]
            ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    }()

    static let defaultEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    enum RefreshError: Error, CustomStringConvertible {
        case http(Int, String)
        case malformed(String)
        case transport(any Error)

        var description: String {
            switch self {
            case .http(let code, let body):
                return "Claude token refresh HTTP \(code): \(body.prefix(120))"
            case .malformed(let s):
                return "malformed token-refresh response: \(s)"
            case .transport(let e):
                return "token-refresh transport error: \(e)"
            }
        }
    }

    private let session: URLSession
    private let endpoint: URL
    private let clientID: String

    init(
        session: URLSession = .shared,
        endpoint: URL = ClaudeTokenRefresher.defaultEndpoint,
        clientID: String = ClaudeTokenRefresher.defaultClientID
    ) {
        self.session = session
        self.endpoint = endpoint
        self.clientID = clientID
    }

    /// Exchange a refresh token for a fresh access token. Throws on
    /// transport failure or any non-200 response (caller treats that as
    /// "refresh unavailable" and surfaces the original auth error).
    func refresh(refreshToken: String) async throws -> RefreshedClaudeCredentials {
        let request = Self.makeRefreshRequest(
            url: endpoint, refreshToken: refreshToken, clientID: clientID)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.malformed("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RefreshError.http(http.statusCode, body)
        }
        return try Self.parseRefreshResponse(data: data, now: Date())
    }

    // MARK: - Pure helpers (unit-tested directly)

    static func makeRefreshRequest(
        url: URL = ClaudeTokenRefresher.defaultEndpoint,
        refreshToken: String,
        clientID: String = ClaudeTokenRefresher.defaultClientID
    ) -> URLRequest {
        let body = formURLEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Build an `application/x-www-form-urlencoded` body. We do NOT use
    /// `URLComponents.percentEncodedQuery`: it leaves `+` literal, but form
    /// decoders read `+` as a space — so a refresh token containing `+`
    /// (Anthropic tokens are base64-ish) would arrive corrupted and the grant
    /// would 400. Percent-encode against the RFC 3986 *unreserved* set only,
    /// which forces `+` → `%2B` and space → `%20`.
    static func formURLEncoded(_ pairs: [(String, String)]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
        }
        return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }

    static func parseRefreshResponse(
        data: Data,
        now: Date = Date()
    ) throws -> RefreshedClaudeCredentials {
        struct Wire: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw RefreshError.malformed("\(error)")
        }
        guard let access = wire.access_token, !access.isEmpty else {
            throw RefreshError.malformed("missing access_token")
        }
        // `expires_in` is seconds-from-now; convert to an absolute epoch in
        // ms so it matches `StoredCredentials.expiresAtMs`. Default to a
        // conservative 8h (Anthropic's observed value) when absent.
        let expiresIn = wire.expires_in ?? 28800
        let expiresAtMs = (now.timeIntervalSince1970 + expiresIn) * 1000
        return RefreshedClaudeCredentials(
            accessToken: access,
            refreshToken: wire.refresh_token,
            expiresAtMs: expiresAtMs)
    }
}
