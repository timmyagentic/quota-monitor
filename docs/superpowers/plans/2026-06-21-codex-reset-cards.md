# Codex Reset Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the user's available Codex active reset-card count and expiration times in the QuotaMonitor menu-bar Codex block.

**Architecture:** Keep Codex quota windows and reset-card details as separate read-only data surfaces. `account/rateLimits/read` continues to drive 5h/7d quota rows and can provide an available-count fallback; a new `CodexResetCreditsClient` reads `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) and fetches `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` for per-card expiration times. The UI renders a compact reset-card row under Codex quota rows. Consuming reset cards is a permanent non-goal for QuotaMonitor.

**Tech Stack:** Swift 6, SwiftUI, Foundation `URLSession`, Swift Testing, existing `LocalQAEnvironment`, `SessionScanner`, `ISO8601`, and `L10n`.

---

## File Structure

- Modify `QuotaMonitor/Core/AppServer/AppServerTypes.swift`
  Decode reset-card available count from both direct WHAM snake_case and current app-server camelCase payloads.
- Modify `QuotaMonitor/Core/Models/RateLimitSnapshot.swift`
  Carry `resetCreditsAvailable` as a count-only fallback alongside Codex quota windows.
- Create `QuotaMonitor/Core/Models/CodexResetCreditsSnapshot.swift`
  Define the domain model used by AppEnvironment and SwiftUI.
- Create `QuotaMonitor/Core/RateLimits/CodexResetCreditsClient.swift`
  Read Codex auth, call the reset-credit endpoint, decode available card expirations, and return a snapshot.
- Modify `QuotaMonitor/App/AppEnvironment.swift`
  Store latest reset-credit snapshot, refresh it from background and manual refresh paths, and preserve count-only fallback when detailed lookup fails.
- Create `QuotaMonitor/Features/MenuBar/CodexResetCreditsRow.swift`
  Render one compact menu-bar row for available count and nearest expiration, with full list in `.help`.
- Modify `QuotaMonitor/Features/MenuBar/ProviderBlock.swift`
  Insert the reset-card row under Codex quota rows.
- Modify `QuotaMonitor/Core/Localization/L10n.swift`
  Add English and Simplified Chinese copy for reset-card row states.
- Modify `CHANGELOG.md` and `CHANGELOG.zh-Hans.md`
  Add user-facing Unreleased notes.
- Add tests:
  - `Tests/QuotaMonitorTests/RateLimitsDecoderTests.swift`
  - `Tests/QuotaMonitorTests/CodexResetCreditsClientTests.swift`
  - `Tests/QuotaMonitorTests/CodexResetCreditsSnapshotTests.swift`
  - `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift`

## Task 1: Decode Reset-Card Count From Existing Codex Payload

**Files:**
- Modify: `QuotaMonitor/Core/AppServer/AppServerTypes.swift`
- Modify: `QuotaMonitor/Core/Models/RateLimitSnapshot.swift`
- Test: `Tests/QuotaMonitorTests/RateLimitsDecoderTests.swift`

- [ ] **Step 1: Write failing decoder tests**

Add these tests to `RateLimitsDecoderTests`:

```swift
@Test("camelCase rateLimitResetCredits decodes available count")
func decodeCamelResetCreditsCount() throws {
    let json = """
    {
      "rateLimitResetCredits": { "availableCount": 2 },
      "rateLimits": {
        "planType": "pro",
        "primary": {
          "usedPercent": 1,
          "windowDurationMins": 300,
          "resetsAt": 1781169600
        },
        "secondary": {
          "usedPercent": 31,
          "windowDurationMins": 10080,
          "resetsAt": 1781510400
        }
      }
    }
    """
    let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
    let snap = RateLimitSnapshot(from: payload, capturedAt: Date(timeIntervalSince1970: 1_781_100_000))

    #expect(payload.resetCreditsAvailable == 2)
    #expect(snap.resetCreditsAvailable == 2)
}

@Test("snake_case rate_limit_reset_credits decodes available count")
func decodeSnakeResetCreditsCount() throws {
    let json = """
    {
      "rate_limit_reset_credits": { "available_count": 3 },
      "rate_limit": {
        "primary_window": {
          "used_percent": 5,
          "limit_window_seconds": 18000,
          "reset_at": 1781169600
        }
      }
    }
    """
    let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
    let snap = RateLimitSnapshot(from: payload, capturedAt: Date(timeIntervalSince1970: 1_781_100_000))

    #expect(payload.resetCreditsAvailable == 3)
    #expect(snap.resetCreditsAvailable == 3)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter RateLimitsDecoderTests
```

Expected: FAIL because `RateLimitsPayload.resetCreditsAvailable` and `RateLimitSnapshot.resetCreditsAvailable` do not exist.

- [ ] **Step 3: Implement decoder count support**

In `QuotaMonitor/Core/AppServer/AppServerTypes.swift`, add a reset-credit summary and wire it into `RateLimitsPayload`:

```swift
struct RateLimitResetCreditsSummary: Decodable {
    let availableCount: Int?

    private enum CodingKeys: String, CodingKey {
        case availableCountCamel = "availableCount"
        case availableCountSnake = "available_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(Int.self, forKey: .availableCountCamel)
            ?? c.decodeIfPresent(Int.self, forKey: .availableCountSnake)
        self.availableCount = raw.map { max(0, $0) }
    }
}
```

Then update `RateLimitsPayload`:

```swift
struct RateLimitsPayload: Decodable {
    let planType: String?
    let rateLimit: RateLimitGroup?
    let additionalRateLimits: [AdditionalRateLimit]?
    let resetCreditsAvailable: Int?

    private enum CodingKeys: String, CodingKey {
        case planTypeSnake = "plan_type"
        case rateLimitSnake = "rate_limit"
        case additionalRateLimitsSnake = "additional_rate_limits"
        case resetCreditsSnake = "rate_limit_reset_credits"
        case planTypeCamel = "planType"
        case rateLimitsCamel = "rateLimits"
        case rateLimitsByLimitIdCamel = "rateLimitsByLimitId"
        case resetCreditsCamel = "rateLimitResetCredits"
    }
}
```

Inside `RateLimitsPayload.init(from:)`, after additional-rate-limit decoding:

```swift
let camelCredits = try c.decodeIfPresent(
    RateLimitResetCreditsSummary.self,
    forKey: .resetCreditsCamel)
let snakeCredits = try c.decodeIfPresent(
    RateLimitResetCreditsSummary.self,
    forKey: .resetCreditsSnake)
self.resetCreditsAvailable = camelCredits?.availableCount
    ?? snakeCredits?.availableCount
```

In `QuotaMonitor/Core/Models/RateLimitSnapshot.swift`, add the stored property and map it:

```swift
struct RateLimitSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let planType: String?
    let primary: Window?
    let secondary: Window?
    let additional: [Additional]
    let resetCreditsAvailable: Int?
}
```

Update `init(from:capturedAt:)`:

```swift
self.resetCreditsAvailable = payload.resetCreditsAvailable
```

Update every explicit `RateLimitSnapshot(...)` construction in tests to pass `resetCreditsAvailable: nil` unless the test asserts a count.

- [ ] **Step 4: Run decoder tests**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter RateLimitsDecoderTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/Core/AppServer/AppServerTypes.swift QuotaMonitor/Core/Models/RateLimitSnapshot.swift Tests/QuotaMonitorTests/RateLimitsDecoderTests.swift
git commit -m "feat: decode Codex reset credit count"
```

## Task 2: Add Read-Only Codex Reset Credits Client

**Files:**
- Create: `QuotaMonitor/Core/Models/CodexResetCreditsSnapshot.swift`
- Create: `QuotaMonitor/Core/RateLimits/CodexResetCreditsClient.swift`
- Test: `Tests/QuotaMonitorTests/CodexResetCreditsClientTests.swift`
- Test: `Tests/QuotaMonitorTests/CodexResetCreditsSnapshotTests.swift`

- [ ] **Step 1: Write failing snapshot tests**

Create `Tests/QuotaMonitorTests/CodexResetCreditsSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex reset credits snapshot")
struct CodexResetCreditsSnapshotTests {
    @Test("available credits are sorted by expiration")
    func availableCreditsSortedByExpiration() throws {
        let later = try #require(ISO8601.parse("2026-07-18T00:28:14.459108Z"))
        let earlier = try #require(ISO8601.parse("2026-07-12T00:16:55.107346Z"))
        let snapshot = CodexResetCreditsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_781_000_000),
            availableCount: 2,
            credits: [
                CodexResetCredit(grantedAt: nil, expiresAt: later),
                CodexResetCredit(grantedAt: nil, expiresAt: earlier)
            ],
            detailStatus: .complete)

        #expect(snapshot.credits.map(\.expiresAt) == [earlier, later])
        #expect(snapshot.nextExpiration == earlier)
        #expect(snapshot.hasDetailedExpirations)
    }

    @Test("count-only fallback has no detailed expirations")
    func countOnlyFallback() {
        let snapshot = CodexResetCreditsSnapshot.countOnly(
            availableCount: 2,
            capturedAt: Date(timeIntervalSince1970: 1_781_000_000))

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.isEmpty)
        #expect(snapshot.nextExpiration == nil)
        #expect(!snapshot.hasDetailedExpirations)
    }
}
```

- [ ] **Step 2: Write failing client tests**

Create `Tests/QuotaMonitorTests/CodexResetCreditsClientTests.swift`:

```swift
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex reset credits client")
struct CodexResetCreditsClientTests {
    private func makeAuthFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-reset-credits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        try """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "codex-access-token",
            "account_id": "codex-account-id"
          }
        }
        """.write(to: auth, atomically: true, encoding: .utf8)
        return auth
    }

    @Test("fetches available reset credits and sets Codex headers")
    func fetchesAvailableCredits() async throws {
        let authFile = try makeAuthFile()
        let endpoint = URL(string: "https://example.test/rate-limit-reset-credits")!
        final class RequestBox: @unchecked Sendable {
            var request: URLRequest?
        }
        let box = RequestBox()
        let client = CodexResetCreditsClient(
            authFileURL: authFile,
            endpoint: endpoint,
            loader: { request in
                box.request = request
                let response = HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                let body = """
                {
                  "available_count": 2,
                  "credits": [
                    {
                      "status": "available",
                      "granted_at": "2026-06-12T00:16:55.107346Z",
                      "expires_at": "2026-07-12T00:16:55.107346Z"
                    },
                    {
                      "status": "redeemed",
                      "granted_at": "2026-06-13T00:16:55.107346Z",
                      "expires_at": "2026-07-13T00:16:55.107346Z"
                    },
                    {
                      "status": "available",
                      "granted_at": "2026-06-18T00:28:14.459108Z",
                      "expires_at": "2026-07-18T00:28:14.459108Z"
                    }
                  ]
                }
                """
                return (Data(body.utf8), response)
            })

        let snapshot = try await client.fetchResetCredits()

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 2)
        #expect(snapshot.detailStatus == .complete)
        #expect(box.request?.value(forHTTPHeaderField: "Authorization") == "Bearer codex-access-token")
        #expect(box.request?.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "codex-account-id")
        #expect(box.request?.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(box.request?.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    }

    @Test("missing auth file surfaces noCredentials")
    func missingAuthFile() async throws {
        let client = CodexResetCreditsClient(
            authFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-auth.json"),
            endpoint: URL(string: "https://example.test/reset")!,
            loader: { _ in Issue.record("loader must not run without auth"); throw URLError(.badURL) })

        do {
            _ = try await client.fetchResetCredits()
            Issue.record("expected noCredentials")
        } catch let error as CodexResetCreditsClient.FetchError {
            #expect(error == .noCredentials)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter CodexResetCredits
```

Expected: FAIL because `CodexResetCreditsSnapshot`, `CodexResetCredit`, and `CodexResetCreditsClient` do not exist.

- [ ] **Step 4: Add snapshot model**

Create `QuotaMonitor/Core/Models/CodexResetCreditsSnapshot.swift`:

```swift
import Foundation

struct CodexResetCredit: Equatable, Sendable {
    let grantedAt: Date?
    let expiresAt: Date
}

struct CodexResetCreditsSnapshot: Equatable, Sendable {
    enum DetailStatus: Equatable, Sendable {
        case complete
        case countOnly
    }

    let capturedAt: Date
    let availableCount: Int
    let credits: [CodexResetCredit]
    let detailStatus: DetailStatus

    init(
        capturedAt: Date,
        availableCount: Int,
        credits: [CodexResetCredit],
        detailStatus: DetailStatus
    ) {
        self.capturedAt = capturedAt
        self.availableCount = max(0, availableCount)
        self.credits = credits.sorted { $0.expiresAt < $1.expiresAt }
        self.detailStatus = detailStatus
    }

    static func countOnly(
        availableCount: Int,
        capturedAt: Date = Date()
    ) -> CodexResetCreditsSnapshot {
        CodexResetCreditsSnapshot(
            capturedAt: capturedAt,
            availableCount: availableCount,
            credits: [],
            detailStatus: .countOnly)
    }

    var nextExpiration: Date? {
        credits.first?.expiresAt
    }

    var hasDetailedExpirations: Bool {
        detailStatus == .complete && !credits.isEmpty
    }
}
```

- [ ] **Step 5: Add read-only client**

Create `QuotaMonitor/Core/RateLimits/CodexResetCreditsClient.swift`:

```swift
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
        authFileURL: URL = SessionScanner.defaultCodexHome()
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
              let access = wire.tokens?.accessToken,
              !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                case accessToken = "access_token"
                case accountID = "account_id"
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
                availableCount: max(0, availableCount ?? availableCredits.count),
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
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
        }

        var availableCredit: CodexResetCredit? {
            guard status == "available",
                  let expiresAt,
                  let expires = ISO8601.parse(expiresAt)
            else { return nil }
            return CodexResetCredit(
                grantedAt: grantedAt.flatMap(ISO8601.parse),
                expiresAt: expires)
        }
    }
}
```

- [ ] **Step 6: Run client tests**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter CodexResetCredits
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add QuotaMonitor/Core/Models/CodexResetCreditsSnapshot.swift QuotaMonitor/Core/RateLimits/CodexResetCreditsClient.swift Tests/QuotaMonitorTests/CodexResetCreditsClientTests.swift Tests/QuotaMonitorTests/CodexResetCreditsSnapshotTests.swift
git commit -m "feat: add Codex reset credits client"
```

## Task 3: Wire Reset Credits Into AppEnvironment Refresh Flow

**Files:**
- Modify: `QuotaMonitor/App/AppEnvironment.swift`
- Test: `Tests/QuotaMonitorTests/RateLimitPollerTests.swift`

- [ ] **Step 1: Write a poller regression test for count preservation**

Add to `RateLimitPollerTests.makePayload` a `resetCreditsAvailable` parameter:

```swift
private func makePayload(
    primary: Double = 10,
    secondary: Double = 20,
    resetCreditsAvailable: Int? = nil
) throws -> RateLimitsPayload {
    let reset = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
    let resetCredits = resetCreditsAvailable.map {
        #""rateLimitResetCredits": { "availableCount": \#($0) },"#
    } ?? ""
    let json = """
    {
      \(resetCredits)
      "planType": "pro",
      "rateLimits": {
        "planType": "pro",
        "primary": {
          "usedPercent": \(primary),
          "windowDurationMins": 300,
          "resetsAt": \(reset)
        },
        "secondary": {
          "usedPercent": \(secondary),
          "windowDurationMins": 10080,
          "resetsAt": \(reset)
        }
      }
    }
    """
    return try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
}
```

Add test:

```swift
@Test("poller publishes reset credit count through RateLimitSnapshot")
func pollerPublishesResetCreditCount() async throws {
    let mock = MockCodexRateLimitsFetcher(script: [
        .success(try makePayload(resetCreditsAvailable: 2))
    ])
    let db = try makeDatabase()
    let snapshots = SnapshotBox()
    let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

    await poller.pollOnce()

    #expect(snapshots.all.first?.resetCreditsAvailable == 2)
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter RateLimitPollerTests/pollerPublishesResetCreditCount
```

Expected: FAIL until Task 1 code has updated all snapshot construction sites correctly.

- [ ] **Step 3: Add AppEnvironment reset-credit state and client**

In `AppEnvironment`, add properties:

```swift
var latestCodexResetCredits: CodexResetCreditsSnapshot?
var lastCodexResetCreditsError: String?
var isRefreshingCodexResetCredits = false
private let codexResetCreditsClient: any CodexResetCreditsFetching
```

Update `init`:

```swift
init(
    appServer: AppServerClient = AppServerClient(),
    codexResetCreditsClient: any CodexResetCreditsFetching = CodexResetCreditsClient()
) {
    self.appServer = appServer
    self.codexResetCreditsClient = codexResetCreditsClient
    DeveloperLog.eventRecord("app.environment.init", category: "app", trigger: "launch")
    Task { [weak self] in
        await MainActor.run { self?.startBackgroundPolling() }
    }
    Task { [weak self] in
        await self?.refreshPricingIfStale()
    }
}
```

- [ ] **Step 4: Add count-only fallback helper**

Add this method in `AppEnvironment`:

```swift
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
```

- [ ] **Step 5: Add standalone reset-credit refresh**

Add this method in `AppEnvironment`:

```swift
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
       let capturedAt = latestCodexResetCredits?.capturedAt,
       Date().timeIntervalSince(capturedAt) < interval {
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
    guard !isRefreshingCodexResetCredits else { return }
    isRefreshingCodexResetCredits = true
    let op = DeveloperLog.startOperation(
        "codex_reset_credits.refresh",
        category: "poller",
        trigger: trigger,
        provider: "codex",
        parent: parentOperation)

    Task { [client = codexResetCreditsClient, op] in
        defer { Task { @MainActor in self.isRefreshingCodexResetCredits = false } }
        do {
            let snapshot = try await Self.withTimeout(seconds: 10, context: "refreshCodexResetCredits") {
                try await client.fetchResetCredits()
            }
            await MainActor.run {
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
                self.lastCodexResetCreditsError = String(describing: error)
            }
            DeveloperLog.failOperation(op, error: error)
        }
    }
}
```

- [ ] **Step 6: Call reset-credit refresh from existing Codex paths**

In `refreshAll(throttle:trigger:)`, after `refreshRateLimits(...)`, add:

```swift
refreshCodexResetCredits(
    minInterval: throttle ? 30 : nil,
    trigger: trigger,
    parentOperation: op)
```

In `startCodexPoller` `onSnapshot`, after setting `latestRateLimits`:

```swift
self.applyCodexResetCreditsCountFallback(
    snapshot.resetCreditsAvailable,
    capturedAt: snapshot.capturedAt)
self.refreshCodexResetCredits(
    minInterval: 300,
    trigger: "poller")
```

In both `refreshRateLimits` success branches, after setting `latestRateLimits`:

```swift
self.applyCodexResetCreditsCountFallback(
    snapshot.resetCreditsAvailable,
    capturedAt: snapshot.capturedAt)
```

- [ ] **Step 7: Run targeted tests**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter RateLimitPollerTests
swift test --disable-keychain --filter CodexResetCredits
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add QuotaMonitor/App/AppEnvironment.swift Tests/QuotaMonitorTests/RateLimitPollerTests.swift
git commit -m "feat: refresh Codex reset credits"
```

## Task 4: Render Reset Cards In The Codex Menu-Bar Block

**Files:**
- Create: `QuotaMonitor/Features/MenuBar/CodexResetCreditsRow.swift`
- Modify: `QuotaMonitor/Features/MenuBar/ProviderBlock.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Test: `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift`

- [ ] **Step 1: Add localization tests**

Add to `BrandingLocalizationTests`:

```swift
@Test("Codex reset-card copy is concise in both languages")
func codexResetCardCopy() {
    let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
        (
            L10n.codexResetCardsTitle,
            L10n.codexResetCardsAvailable(2),
            L10n.codexResetCardsNoActive
        )
    }
    let en = LocalizationTestSupport.withLanguage(.english) {
        (
            L10n.codexResetCardsTitle,
            L10n.codexResetCardsAvailable(2),
            L10n.codexResetCardsNoActive
        )
    }

    #expect(zh.0 == "主动重置卡")
    #expect(zh.1 == "剩余 2 次")
    #expect(zh.2 == "无可用卡片")
    #expect(en.0 == "Reset cards")
    #expect(en.1 == "2 available")
    #expect(en.2 == "No active cards")
}
```

- [ ] **Step 2: Run localization test to verify failure**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter BrandingLocalizationTests/codexResetCardCopy
```

Expected: FAIL because the new L10n keys do not exist.

- [ ] **Step 3: Add L10n copy**

Add near the Codex quota strings in `L10n.swift`:

```swift
static var codexResetCardsTitle: String {
    t(en: "Reset cards", zh: "主动重置卡")
}

static func codexResetCardsAvailable(_ count: Int) -> String {
    t(en: "\(count) available", zh: "剩余 \(count) 次")
}

static var codexResetCardsNoActive: String {
    t(en: "No active cards", zh: "无可用卡片")
}

static func codexResetCardsNextExpires(_ formatted: String) -> String {
    t(en: "Next expires \(formatted)", zh: "最近 \(formatted) 过期")
}

static var codexResetCardsExpiryUnavailable: String {
    t(en: "Expiration times unavailable", zh: "暂时无法读取过期时间")
}

static func codexResetCardsHelp(_ lines: String) -> String {
    t(en: "Available reset-card expirations:\n\(lines)",
      zh: "可用主动重置卡过期时间：\n\(lines)")
}
```

- [ ] **Step 4: Add SwiftUI row**

Create `QuotaMonitor/Features/MenuBar/CodexResetCreditsRow.swift`:

```swift
import SwiftUI

struct CodexResetCreditsRow: View {
    let snapshot: CodexResetCreditsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L10n.codexResetCardsTitle)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(countLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(snapshot.availableCount > 0 ? .blue : .secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.caption2)
                Text(detailLabel)
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var countLabel: String {
        snapshot.availableCount > 0
            ? L10n.codexResetCardsAvailable(snapshot.availableCount)
            : L10n.codexResetCardsNoActive
    }

    private var detailLabel: String {
        if let next = snapshot.nextExpiration {
            return L10n.codexResetCardsNextExpires(Self.dateFormatter.string(from: next))
        }
        return snapshot.availableCount > 0
            ? L10n.codexResetCardsExpiryUnavailable
            : L10n.codexResetCardsNoActive
    }

    private var helpText: String {
        guard !snapshot.credits.isEmpty else { return detailLabel }
        let lines = snapshot.credits
            .map { "- \(Self.dateTimeFormatter.string(from: $0.expiresAt))" }
            .joined(separator: "\n")
        return L10n.codexResetCardsHelp(lines)
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static var dateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }
}
```

- [ ] **Step 5: Insert row under Codex quota rows**

In `ProviderBlock.codexQuotaInner(stats:)`, inside both `VStack` branches that render Codex quota rows, append:

```swift
if let resetCredits = env.latestCodexResetCredits {
    CodexResetCreditsRow(snapshot: resetCredits)
}
```

Place it after additional model-specific quota rows in the live `latestRateLimits` branch, and after 5h/7d rows in the database fallback branch.

- [ ] **Step 6: Run localization and build tests**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter BrandingLocalizationTests/codexResetCardCopy
swift build --disable-keychain
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add QuotaMonitor/Core/Localization/L10n.swift QuotaMonitor/Features/MenuBar/CodexResetCreditsRow.swift QuotaMonitor/Features/MenuBar/ProviderBlock.swift Tests/QuotaMonitorTests/BrandingLocalizationTests.swift
git commit -m "feat: show Codex reset cards in menu bar"
```

## Task 5: Update Changelogs And Run Full Verification

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Add English changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add a Summary bullet:

```markdown
- Codex now shows available reset cards and their expiration times in the menu bar
```

Under `### Added`, add:

```markdown
- **Codex reset-card visibility.** The menu bar now shows how many Codex active reset cards are available and when the available cards expire.
```

- [ ] **Step 2: Add Chinese changelog entry**

In `CHANGELOG.zh-Hans.md`, under `## [Unreleased]`, add a Summary bullet:

```markdown
- Codex 现在会在菜单栏显示可用主动重置卡数量和过期时间
```

Under `### 新增`, add:

```markdown
- **Codex 主动重置卡可见性。** 菜单栏现在会显示 Codex 当前还有几张主动重置卡可用，以及可用卡片的过期时间。
```

- [ ] **Step 3: Run targeted tests**

Run:

```bash
source ~/.swiftly/env.sh
swift test --disable-keychain --filter RateLimitsDecoderTests
swift test --disable-keychain --filter CodexResetCredits
swift test --disable-keychain --filter RateLimitPollerTests
swift test --disable-keychain --filter BrandingLocalizationTests
```

Expected: PASS.

- [ ] **Step 4: Run full static gate**

Run:

```bash
./qa/run-static.sh
```

Expected: PASS. This runs shell/Python checks, release-note validation, `swift build`, and `swift test --disable-keychain`.

- [ ] **Step 5: Optional local runtime smoke**

Run:

```bash
./script/build_and_run.sh
```

Expected: App launches; opening the menu bar after a refresh shows Codex 5h/7d quota rows and a reset-card row. If the account has active cards, the row shows the available count and nearest expiration. If the detailed endpoint fails but `account/rateLimits/read` returns a count, the row shows the count and "Expiration times unavailable."

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CHANGELOG.zh-Hans.md
git commit -m "docs: note Codex reset-card visibility"
```

## Execution Notes

- Start from a clean updated `main`, then create an isolated worktree before implementation:

```bash
git fetch origin
git switch main
git pull --ff-only
mkdir -p /Volumes/SamsungDisk/Code/.worktrees
git worktree add -b codex/codex-reset-cards /Volumes/SamsungDisk/Code/.worktrees/quota-monitor-codex-reset-cards main
cd /Volumes/SamsungDisk/Code/.worktrees/quota-monitor-codex-reset-cards
```

- Do not implement `POST /wham/rate-limit-reset-credits/consume` anywhere in QuotaMonitor. The app is a read-only monitor, and consuming reset cards is outside the product boundary.
- Do not persist reset-card detail rows into SQLite in this first version. The data is small, live-only, and naturally refreshed with Codex live quota polling.
- Do not let reset-card fetch failures overwrite or hide existing 5h/7d Codex quota rows.

## Self-Review

- Spec coverage: The plan covers available count, per-card expiration times, menu-bar UI, manual/background refresh, localization, and changelogs.
- Write-safety: The plan only uses `GET /wham/rate-limit-reset-credits`; no consume endpoint, consume client method, consume button, or confirmation flow is implemented.
- Type consistency: `CodexResetCreditsSnapshot`, `CodexResetCredit`, `CodexResetCreditsClient`, and `CodexResetCreditsFetching` are introduced before they are referenced by `AppEnvironment` and SwiftUI.
- Test coverage: Decoder, client, snapshot behavior, poller propagation, localization, build, and full static QA are covered.
