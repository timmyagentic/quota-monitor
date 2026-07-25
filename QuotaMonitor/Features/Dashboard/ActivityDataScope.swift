import Foundation

/// The Activity card can either describe the history QuotaMonitor has indexed
/// locally or the complete activity reported by the signed-in Codex account.
/// This is deliberately separate from `ProviderFilter`: changing it must not
/// affect Forecast, Trends, Composition, History, or Sessions.
enum ActivityDataScope: String, CaseIterable, Identifiable, Sendable {
    case indexed
    case account

    var id: Self { self }
}

/// Presentation state for the optional Codex account activity source.
/// A refresh never removes the last good snapshot, so switching sources does
/// not make an already-rendered card flash empty during transient failures.
enum CodexAccountUsageState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CodexAccountUsageSnapshot)
    case refreshing(CodexAccountUsageSnapshot)
    case stale(CodexAccountUsageSnapshot)
    case unavailable

    var snapshot: CodexAccountUsageSnapshot? {
        switch self {
        case .loaded(let snapshot),
             .refreshing(let snapshot),
             .stale(let snapshot):
            return snapshot
        case .idle, .loading, .unavailable:
            return nil
        }
    }

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

enum ActivityCoverage {
    /// The account and indexed totals come from different systems, so only
    /// show an estimated ratio when it is mathematically safe and cannot imply
    /// more than 100% coverage.
    static func percentage(indexed: Int64, account: Int64?) -> Double? {
        guard let account,
              account > 0,
              indexed >= 0,
              indexed <= account else { return nil }
        return Double(indexed) / Double(account) * 100
    }
}
