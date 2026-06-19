import Foundation

protocol CodexResetCreditsFetching: Sendable, AnyObject {
    func fetchResetCredits() async throws -> CodexResetCreditsSnapshot
}

actor CodexResetCreditsClient: CodexResetCreditsFetching {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum FetchError: Error, CustomStringConvertible, Equatable {
        case disabledInLocalQA
        case noCredentials
        case http(Int, String)
        case malformed(String)
        case transport(String)

        var description: String {
            switch self {
            case .disabledInLocalQA:
                return "Codex reset credits are disabled in local QA"
            case .noCredentials:
                return "No Codex ChatGPT credentials found (run `codex login`)"
            case .http(let code, let body):
                return "Codex reset credits HTTP \(code): \(body.prefix(120))"
            case .malformed(let message):
                return "malformed Codex reset credits response: \(message)"
            case .transport(let message):
                return "Codex reset credits transport error: \(message)"
            }
        }
    }

    private let authFileURL: URL
    private let endpoint: URL
    private let loader: DataLoader

    init(
        // `defaultCodexHome()` is optional only in App Store builds with no
        // authorized folder; live Codex reset credits is a network feature
        // that doesn't run under that sandbox anyway, so fall back to ~/.codex
        // to keep a valid default. Developer ID builds always get a non-nil URL.
        authFileURL: URL = (SessionScanner.defaultCodexHome()
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true))
            .appendingPathComponent("auth.json", isDirectory: false),
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
        loader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.authFileURL = authFileURL
        self.endpoint = endpoint
        self.loader = loader
    }

    func fetchResetCredits() async throws -> CodexResetCreditsSnapshot {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            throw FetchError.disabledInLocalQA
        }
        let auth = try Self.loadAuth(from: authFileURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
        } catch {
            throw FetchError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.malformed("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
        do {
            let wire = try JSONDecoder().decode(WireResponse.self, from: data)
            return wire.snapshot(capturedAt: Date())
        } catch {
            throw FetchError.malformed(String(describing: error))
        }
    }

    private static func loadAuth(from url: URL) throws -> CodexAuth {
        guard let data = try? Data(contentsOf: url),
              let wire = try? JSONDecoder().decode(AuthFile.self, from: data),
              let access = wire.tokens?.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else {
            throw FetchError.noCredentials
        }
        let account = wire.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexAuth(
            accessToken: access,
            accountID: account?.isEmpty == false ? account : nil)
    }

    private struct CodexAuth: Sendable {
        let accessToken: String
        let accountID: String?
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            private enum CodingKeys: String, CodingKey {
                case accessTokenSnake = "access_token"
                case accountIDSnake = "account_id"
                case accessTokenCamel = "accessToken"
                case accountIDCamel = "accountID"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.accessToken = try c.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                    ?? c.decodeIfPresent(String.self, forKey: .accessTokenCamel)
                self.accountID = try c.decodeIfPresent(String.self, forKey: .accountIDSnake)
                    ?? c.decodeIfPresent(String.self, forKey: .accountIDCamel)
            }
        }

        let tokens: Tokens?
    }

    private struct WireResponse: Decodable {
        let availableCount: Int?
        let credits: [WireCredit]?

        private enum CodingKeys: String, CodingKey {
            case availableCountSnake = "available_count"
            case availableCountCamel = "availableCount"
            case credits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.availableCount = try c.decodeIfPresent(Int.self, forKey: .availableCountCamel)
                ?? c.decodeIfPresent(Int.self, forKey: .availableCountSnake)
            self.credits = try c.decodeIfPresent([WireCredit].self, forKey: .credits)
        }

        func snapshot(capturedAt: Date) -> CodexResetCreditsSnapshot {
            let availableCredits = (credits ?? []).compactMap(\.availableCredit)
            return CodexResetCreditsSnapshot(
                capturedAt: capturedAt,
                availableCount: availableCount ?? availableCredits.count,
                credits: availableCredits,
                detailStatus: .complete)
        }
    }

    private struct WireCredit: Decodable {
        let status: String?
        let grantedAt: String?
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case grantedAtSnake = "granted_at"
            case grantedAtCamel = "grantedAt"
            case expiresAtSnake = "expires_at"
            case expiresAtCamel = "expiresAt"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.status = try c.decodeIfPresent(String.self, forKey: .status)
            self.grantedAt = try c.decodeIfPresent(String.self, forKey: .grantedAtSnake)
                ?? c.decodeIfPresent(String.self, forKey: .grantedAtCamel)
            self.expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAtSnake)
                ?? c.decodeIfPresent(String.self, forKey: .expiresAtCamel)
        }

        var availableCredit: CodexResetCredit? {
            guard status?.lowercased() == "available",
                  let expiresAt,
                  let expires = ISO8601.parse(expiresAt)
            else { return nil }
            return CodexResetCredit(
                grantedAt: grantedAt.flatMap(ISO8601.parse),
                expiresAt: expires)
        }
    }
}
