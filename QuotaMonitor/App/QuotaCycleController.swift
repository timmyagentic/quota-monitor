import Foundation

extension AppEnvironment {
    /// Reads bounded current windows independently of the full Dashboard cache.
    /// Generation checks also cover account switches and scans during a read.
    func refreshQuotaCycles() {
        quotaCycleRefreshGeneration &+= 1
        let generation = quotaCycleRefreshGeneration
        let codex = latestRateLimits
        let claude = latestClaudeUsage
        let current = QuotaCycleSelection.make(codex: codex, claude: claude, stored: [])
        quotaCycleUsages.removeAll { usage in
            !current.contains {
                $0.id == usage.id && $0.observation.capturedAt == usage.cycle.observation.capturedAt
                    && $0.observation.resetAt == usage.cycle.observation.resetAt
                    && $0.observation.usedPercent == usage.cycle.observation.usedPercent
                    && ($0.observation.scope == nil || $0.observation.scope == usage.cycle.observation.scope)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let (database, _) = try self.ensureServices()
                let usages = try await database.pool.read { db in
                    let stored = try QuotaCycleStore.cycles(db: db)
                    let cycles = QuotaCycleSelection.make(codex: codex, claude: claude, stored: stored)
                    return try Aggregator.quotaCycleUsage(db: db, cycles: cycles)
                }
                guard self.quotaCycleRefreshGeneration == generation else { return }
                self.quotaCycleUsages = usages
            } catch {
                guard self.quotaCycleRefreshGeneration == generation else { return }
                self.quotaCycleUsages = []
                Log.storage.error("quota cycle query failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func quotaCycle(provider: String, bucket: String, resetAt: Date) -> QuotaCycle? {
        quotaCycleUsages.first {
            $0.cycle.observation.provider == provider && $0.cycle.observation.bucket == bucket
                && abs($0.cycle.observation.resetAt.timeIntervalSince(resetAt)) < 0.01
        }?.cycle
    }
}

enum QuotaCycleSelection {
    static func make(
        codex: RateLimitSnapshot?, claude: ClaudeUsageSnapshot?, stored: [QuotaCycle]
    ) -> [QuotaCycle] {
        var observations: [QuotaCycle.Observation] = []
        if let codex {
            for (bucket, window) in [("primary", codex.primary), ("secondary", codex.secondary)] {
                if let window {
                    observations.append(.init(provider: "codex", bucket: bucket,
                        scope: codex.observationScope, plan: codex.planType,
                        capturedAt: codex.capturedAt, resetAt: window.resetAt,
                        duration: window.windowDuration, usedPercent: window.usedPercent))
                }
            }
        }
        if let claude {
            for (bucket, window) in [("primary", claude.fiveHour), ("secondary", claude.sevenDay)] {
                if let window {
                    observations.append(.init(provider: "claude", bucket: bucket,
                        scope: claude.observationScope, plan: claude.tier,
                        capturedAt: claude.capturedAt, resetAt: window.resetAt,
                        duration: window.windowDuration, usedPercent: window.usedPercent))
                }
            }
        }
        return observations.map { observation in
            let prior = stored.first {
                $0.observation.provider == observation.provider
                    && $0.observation.bucket == observation.bucket
                    && $0.observation.capturedAt <= observation.capturedAt.addingTimeInterval(0.01)
            }
            // Hydrated legacy sample rows have no scope; identical timestamp,
            // deadline and quota bind them to the atomically persisted state.
            if let prior,
               abs(prior.observation.capturedAt.timeIntervalSince(observation.capturedAt)) < 0.01,
               prior.observation.resetAt == observation.resetAt,
               prior.observation.usedPercent == observation.usedPercent,
               prior.observation.plan == observation.plan,
               observation.scope == nil || observation.scope == prior.observation.scope {
                return prior
            }
            return QuotaCycle.resolve(observation, previous: prior)
        }
    }
}
