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

final class DailyActiveURLSessionTransport: DailyActiveTransport, @unchecked Sendable {
    private let sessionDelegate: DailyActiveURLSessionDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = makeEphemeralConfiguration()) {
        let sessionDelegate = DailyActiveURLSessionDelegate()
        self.sessionDelegate = sessionDelegate
        session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil)
    }

    deinit {
        sessionDelegate.cancelAll()
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
        try await sessionDelegate.send(request, using: session)
    }
}

final class DailyActiveURLSessionDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var requests: [Int: DailyActiveURLSessionRequestState] = [:]

    func send(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> DailyActiveTransportResponse {
        let state = DailyActiveURLSessionRequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation: continuation)
                let task = session.dataTask(with: request)
                state.install(task: task)
                register(state, for: task.taskIdentifier)
                if state.isFinished {
                    remove(taskIdentifier: task.taskIdentifier)
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    func cancelAll() {
        let states = lock.withLock {
            let values = Array(requests.values)
            requests.removeAll()
            return values
        }
        for state in states { state.cancel() }
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let state = remove(taskIdentifier: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            state.finish(.failure(URLError(.badServerResponse)))
            return
        }

        let result = DailyActiveTransportResponse(
            statusCode: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        // The wire contract has no response body. Cancel at the header boundary
        // so a malicious or broken endpoint cannot make the app buffer bytes.
        completionHandler(.cancel)
        state.finish(.success(result))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Response disposition is `.cancel`; discard any bytes already in
        // flight without retaining or accumulating them.
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let state = remove(taskIdentifier: task.taskIdentifier) else { return }
        state.finish(.failure(error ?? URLError(.badServerResponse)))
    }

    private func register(_ state: DailyActiveURLSessionRequestState, for taskIdentifier: Int) {
        lock.withLock { requests[taskIdentifier] = state }
    }

    @discardableResult
    private func remove(taskIdentifier: Int) -> DailyActiveURLSessionRequestState? {
        lock.withLock { requests.removeValue(forKey: taskIdentifier) }
    }
}

private final class DailyActiveURLSessionRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DailyActiveTransportResponse, any Error>?
    private var task: URLSessionDataTask?
    private var result: Result<DailyActiveTransportResponse, any Error>?

    var isFinished: Bool {
        lock.withLock { result != nil }
    }

    func install(
        continuation: CheckedContinuation<DailyActiveTransportResponse, any Error>
    ) {
        let completed = lock.withLock { () -> Result<DailyActiveTransportResponse, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func install(task: URLSessionDataTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return result != nil
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel()
        finish(.failure(URLError(.cancelled)))
    }

    func finish(_ newResult: Result<DailyActiveTransportResponse, any Error>) {
        let continuation: CheckedContinuation<DailyActiveTransportResponse, any Error>? =
            lock.withLock {
                guard result == nil else { return nil }
                result = newResult
                let value = self.continuation
                self.continuation = nil
                task = nil
                return value
            }
        continuation?.resume(with: newResult)
    }
}

private struct TriggerAttemptState: Sendable {
    var retryCount = 0
    var didRetryConflict = false
}

private enum TriggerAttemptStep: Sendable {
    case finished
    case retry(TriggerAttemptState, after: Duration?)
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

    deinit {
        lifecycleTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation &+= 1
        let currentGeneration = generation
        let delay = initialJitter()
        let sleep = self.sleep
        let runTrigger: @Sendable () async -> Void = { [weak self, sleep] in
            var state = TriggerAttemptState()
            while !Task<Never, Never>.isCancelled {
                guard let step = await self?.performAttempt(
                    generation: currentGeneration,
                    state: state)
                else {
                    return
                }
                switch step {
                case .finished:
                    return
                case let .retry(nextState, delay):
                    state = nextState
                    guard let delay else { continue }
                    do {
                        try await sleep(delay)
                    } catch {
                        return
                    }
                    guard !Task<Never, Never>.isCancelled else { return }
                }
            }
        }
        lifecycleTask = Task { [sleep, runTrigger] in
            if delay > .zero {
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard !Task<Never, Never>.isCancelled else { return }
            }

            await runTrigger()
            while !Task<Never, Never>.isCancelled {
                do {
                    try await sleep(Self.periodicInterval)
                } catch {
                    return
                }
                guard !Task<Never, Never>.isCancelled else { return }
                await runTrigger()
            }
        }
    }

    func stop() {
        guard isStarted || lifecycleTask != nil else { return }
        isStarted = false
        generation &+= 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    private func performAttempt(
        generation: UInt,
        state: TriggerAttemptState
    ) async -> TriggerAttemptStep {
        guard isCurrent(generation) else { return .finished }
        let currentEligibility = await eligibility()
        guard isCurrent(generation), currentEligibility.permitsReporting else {
            return .finished
        }
        guard
            let payload = await currentPayload(generation: generation),
            isCurrent(generation)
        else {
            return .finished
        }
        let hasSucceeded = await store.hasSucceeded(
            day: payload.day,
            version: payload.version,
            brand: payload.brand,
            channel: payload.channel)
        guard isCurrent(generation), !hasSucceeded else { return .finished }

        // Consent/QA and packaging context can change while token state is
        // being read. Recheck immediately at the actual transport boundary.
        guard await maySend(payload, generation: generation), isCurrent(generation) else {
            return .finished
        }
        guard let request = Self.request(for: payload) else { return .finished }

        let response: DailyActiveTransportResponse
        do {
            response = try await transport.send(request)
        } catch {
            guard isCurrent(generation), state.retryCount < Self.maximumRetryCount else {
                return .finished
            }
            var nextState = state
            let delay = Self.retryDelays[nextState.retryCount]
            nextState.retryCount += 1
            return .retry(nextState, after: delay)
        }

        guard isCurrent(generation) else { return .finished }
        switch response.statusCode {
        case 204:
            // A late response from a stopped generation or revoked consent
            // must never become persisted success state.
            guard await maySend(payload, generation: generation), isCurrent(generation) else {
                return .finished
            }
            await store.markSucceeded(
                day: payload.day,
                version: payload.version,
                brand: payload.brand,
                channel: payload.channel)
            return .finished

        case 409 where !state.didRetryConflict:
            var nextState = state
            nextState.didRetryConflict = true
            // The next step rebuilds now/day/token and dynamically rereads both
            // eligibility and reporting context before one immediate retry.
            return .retry(nextState, after: nil)

        case 429:
            guard state.retryCount < Self.maximumRetryCount else { return .finished }
            var nextState = state
            let delay = retryDelay(
                retryAfter: response.retryAfter,
                fallbackIndex: nextState.retryCount)
            nextState.retryCount += 1
            return .retry(nextState, after: delay)

        case 500 ... 599:
            guard state.retryCount < Self.maximumRetryCount else { return .finished }
            var nextState = state
            let delay = Self.retryDelays[nextState.retryCount]
            nextState.retryCount += 1
            return .retry(nextState, after: delay)

        default:
            // Any other 4xx, a second 409, and every non-204 2xx/3xx
            // stop this trigger. The next lifecycle trigger may try again.
            return .finished
        }
    }

    private func currentPayload(generation: UInt) async -> DailyActivePayload? {
        guard isCurrent(generation) else { return nil }
        let date = now()
        let reportingContext = await context()
        guard isCurrent(generation), let reportingContext else { return nil }
        let record = await store.record(for: date)
        guard isCurrent(generation), let record else { return nil }
        return DailyActivePayload(
            day: DailyActivePayload.utcDay(for: date),
            token: record.token,
            version: reportingContext.version,
            brand: reportingContext.brand,
            channel: reportingContext.channel)
    }

    private func maySend(_ payload: DailyActivePayload, generation: UInt) async -> Bool {
        guard isCurrent(generation) else { return false }
        let currentEligibility = await eligibility()
        guard isCurrent(generation), currentEligibility.permitsReporting else { return false }
        let currentContext = await context()
        guard isCurrent(generation), let currentContext else { return false }
        return currentContext == DailyActiveReportingContext(
            version: payload.version,
            brand: payload.brand,
            channel: payload.channel)
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
