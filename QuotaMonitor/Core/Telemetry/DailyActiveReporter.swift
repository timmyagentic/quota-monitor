import Foundation

enum DailyActiveReportingEligibility: Sendable {
    case undecided
    case enabled
    case disabled
    case localQA

    var permitsReporting: Bool { self == .enabled }
}

struct DailyActiveTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let retryAfter: String?

    init(statusCode: Int, retryAfter: String? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

protocol DailyActiveTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DailyActiveTransportResponse
}

final class DailyActiveURLSessionTransport: NSObject, DailyActiveTransport,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = makeEphemeralConfiguration()) {
        super.init()
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    func send(_ request: URLRequest) async throws -> DailyActiveTransportResponse {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return DailyActiveTransportResponse(
            statusCode: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor DailyActiveReporter {
    typealias Now = @Sendable () -> Date
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias InitialJitter = @Sendable () -> Duration
    typealias Eligibility = @Sendable () async -> DailyActiveReportingEligibility
    typealias Context = @Sendable () async -> DailyActiveReportingContext?

    static let endpoint = URL(
        string: "https://quota-monitor.timmyagentic.com/api/v1/daily-active")!
    static let periodicInterval = Duration.seconds(6 * 60 * 60)
    static let maximumRetryCount = 3
    static let maximumRetryAfter = Duration.seconds(15 * 60)

    private static let retryDelays: [Duration] = [
        .seconds(30),
        .seconds(60),
        .seconds(120),
    ]

    private let store: DailyActiveTokenStore
    private let transport: any DailyActiveTransport
    private let now: Now
    private let sleep: Sleep
    private let initialJitter: InitialJitter
    private let eligibility: Eligibility
    private let context: Context

    private var isStarted = false
    private var generation: UInt = 0
    private var lifecycleTask: Task<Void, Never>?

    init(
        store: DailyActiveTokenStore,
        transport: any DailyActiveTransport = DailyActiveURLSessionTransport(),
        now: @escaping Now = Date.init,
        sleep: @escaping Sleep = { duration in
            try await Task<Never, Never>.sleep(for: duration)
        },
        initialJitter: @escaping InitialJitter = {
            .seconds(Double.random(in: 0 ... 300))
        },
        eligibility: @escaping Eligibility,
        context: @escaping Context
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.initialJitter = initialJitter
        self.eligibility = eligibility
        self.context = context
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation &+= 1
        let currentGeneration = generation
        let delay = initialJitter()
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle(
                generation: currentGeneration,
                initialDelay: delay)
        }
    }

    func stop() {
        guard isStarted || lifecycleTask != nil else { return }
        isStarted = false
        generation &+= 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    private func runLifecycle(generation: UInt, initialDelay: Duration) async {
        if initialDelay > .zero {
            guard await wait(initialDelay, generation: generation) else { return }
        }

        guard isCurrent(generation) else { return }
        await attemptCurrentTrigger(generation: generation)

        while isCurrent(generation) {
            guard await wait(Self.periodicInterval, generation: generation) else {
                return
            }
            await attemptCurrentTrigger(generation: generation)
        }
    }

    private func attemptCurrentTrigger(generation: UInt) async {
        var retryCount = 0
        var didRetryConflict = false

        while isCurrent(generation) {
            guard await eligibility().permitsReporting else { return }
            guard let payload = await currentPayload() else { return }
            guard !(await store.hasSucceeded(
                day: payload.day,
                version: payload.version,
                brand: payload.brand,
                channel: payload.channel))
            else {
                return
            }

            // Consent/QA and packaging context can change while token state is
            // being read. Recheck immediately at the actual transport boundary.
            guard await maySend(payload, generation: generation) else { return }
            guard let request = Self.request(for: payload) else { return }

            let response: DailyActiveTransportResponse
            do {
                response = try await transport.send(request)
            } catch {
                guard isCurrent(generation), retryCount < Self.maximumRetryCount else {
                    return
                }
                let delay = Self.retryDelays[retryCount]
                retryCount += 1
                guard await wait(delay, generation: generation) else { return }
                continue
            }

            guard isCurrent(generation) else { return }
            switch response.statusCode {
            case 204:
                // A late response from a stopped generation or revoked consent
                // must never become persisted success state.
                guard await maySend(payload, generation: generation) else { return }
                await store.markSucceeded(
                    day: payload.day,
                    version: payload.version,
                    brand: payload.brand,
                    channel: payload.channel)
                return

            case 409 where !didRetryConflict:
                didRetryConflict = true
                // Looping rebuilds now/day/token and dynamically rereads both
                // eligibility and reporting context before one immediate retry.
                continue

            case 429:
                guard retryCount < Self.maximumRetryCount else { return }
                let delay = retryDelay(
                    retryAfter: response.retryAfter,
                    fallbackIndex: retryCount)
                retryCount += 1
                guard await wait(delay, generation: generation) else { return }
                continue

            case 500 ... 599:
                guard retryCount < Self.maximumRetryCount else { return }
                let delay = Self.retryDelays[retryCount]
                retryCount += 1
                guard await wait(delay, generation: generation) else { return }
                continue

            default:
                // Any other 4xx, a second 409, and every non-204 2xx/3xx
                // stop this trigger. The next lifecycle trigger may try again.
                return
            }
        }
    }

    private func currentPayload() async -> DailyActivePayload? {
        let date = now()
        guard
            let context = await context(),
            let record = await store.record(for: date)
        else {
            return nil
        }
        return DailyActivePayload(
            day: DailyActivePayload.utcDay(for: date),
            token: record.token,
            version: context.version,
            brand: context.brand,
            channel: context.channel)
    }

    private func maySend(_ payload: DailyActivePayload, generation: UInt) async -> Bool {
        guard
            isCurrent(generation),
            await eligibility().permitsReporting,
            let currentContext = await context()
        else {
            return false
        }
        return currentContext == DailyActiveReportingContext(
            version: payload.version,
            brand: payload.brand,
            channel: payload.channel)
    }

    private func wait(_ duration: Duration, generation: UInt) async -> Bool {
        let sleep = self.sleep
        do {
            try await sleep(duration)
        } catch {
            return false
        }
        return isCurrent(generation) && !Task<Never, Never>.isCancelled
    }

    private func isCurrent(_ candidate: UInt) -> Bool {
        isStarted && candidate == generation && !Task<Never, Never>.isCancelled
    }

    private func retryDelay(retryAfter: String?, fallbackIndex: Int) -> Duration {
        guard let retryAfter else { return Self.retryDelays[fallbackIndex] }
        let value = retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int(value), seconds >= 0 {
            return .seconds(min(max(seconds, 1), 15 * 60))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryDate = formatter.date(from: value) else {
            return Self.retryDelays[fallbackIndex]
        }
        let seconds = Int(retryDate.timeIntervalSince(now()).rounded(.up))
        return .seconds(min(max(seconds, 1), 15 * 60))
    }

    private static func request(for payload: DailyActivePayload) -> URLRequest? {
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "\(payload.brand)/\(payload.version) daily-active/1",
            forHTTPHeaderField: "User-Agent")
        return request
    }
}
